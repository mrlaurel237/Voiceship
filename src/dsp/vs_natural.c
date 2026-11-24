// vs_natural.c — moteur « Naturel » (voir vs_natural.h pour l'explication générale).
#include "vs_natural.h"
#include "vs_accel.h"
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

#define NR      8192            // tampons circulaires (fréquence interne) : 340 ms à 24 kHz
#define NRM     (NR - 1)
#define ORD_MAX 32              // ordre LPC maximal
#define NHOP    128             // trames d'analyse mémorisées (128 × 4 ms)
#define NMK     256             // marques de période mémorisées
#define NXD     2048
#define NXDM    (NXD - 1)
#define KW      80              // points de fréquence pour déformer l'enveloppe (formants)
#define HB      63              // longueur du filtre demi-bande (48 kHz <-> 24 kHz)
#define HBP     32              // longueur de chaque phase de l'interpolateur
#define HOST_CHUNK 512
#define FIFO    4096
#define FIFOM   (FIFO - 1)
#define LAGMAX  160
#define TMPN    1024

typedef struct { float b0, b1, b2, a1, a2, z1, z2; } BQ;

static void bq_set(BQ *q, int type, float fc, float fs, float Q, float gainDb) {   // RBJ
    float A = powf(10.f, gainDb / 40.f);
    float w = 2.f * (float)M_PI * fc / fs, c = cosf(w), s = sinf(w), al = s / (2.f * Q);
    float b0, b1, b2, a0, a1, a2;
    if (type == 0) {        // passe-bas
        b0 = (1.f - c) * 0.5f; b1 = 1.f - c; b2 = b0; a0 = 1.f + al; a1 = -2.f * c; a2 = 1.f - al;
    } else if (type == 1) { // passe-haut
        b0 = (1.f + c) * 0.5f; b1 = -(1.f + c); b2 = b0; a0 = 1.f + al; a1 = -2.f * c; a2 = 1.f - al;
    } else {                // cloche (égaliseur)
        b0 = 1.f + al * A; b1 = -2.f * c; b2 = 1.f - al * A; a0 = 1.f + al / A; a1 = -2.f * c; a2 = 1.f - al / A;
    }
    q->b0 = b0 / a0; q->b1 = b1 / a0; q->b2 = b2 / a0; q->a1 = a1 / a0; q->a2 = a2 / a0;
}
static inline float bq_run(BQ *q, float x) {
    float y = q->b0 * x + q->z1;
    q->z1 = q->b1 * x - q->a1 * y + q->z2;
    q->z2 = q->b2 * x - q->a2 * y;
    return y;
}

struct VSNat {
    // ── fréquences ──
    float srHost, fs; int R;
    // ── rééchantillonnage ×2 (filtre demi-bande) ──
    float hb[HB], ph0[HBP], ph1[HBP];
    float dh[2 * 64]; int dpos, dphase;
    float uh[2 * HBP]; int upos;
    float fifo[FIFO]; int fr, fw;
    float ib[HOST_CHUNK + 4], ob[HOST_CHUNK + 4], tmpb[HOST_CHUNK + 4];
    // ── tampons de la voix (fréquence interne) ──
    float x[NR], e[NR], xpe[NR], y[NR], ws[NR], vc[NR];
    long long w;
    float pePrev;
    // ── analyse LPC (enveloppe = formants) ──
    int ordFull, ord, ordUsed, hop, nwin;
    float lpcWin[TMPN], frame[TMPN], lagw[ORD_MAX + 1];
    long long hopDone, hopNext;
    long long nh;
    float kS[NHOP][ORD_MAX], gS[NHOP]; long long hopStart[NHOP];
    float kAprev[ORD_MAX], kAcur[ORD_MAX];
    float bA[ORD_MAX + 1], bS[ORD_MAX + 1];
    long long synHop;
    // ── déformation des formants ──
    float warpAlpha; int warpOrd;
    float Cw[KW * (ORD_MAX + 1)], Sw[KW * (ORD_MAX + 1)], Cr[(ORD_MAX + 1) * KW];
    float avec[ORD_MAX + 1], re[KW], im[KW], Sp[KW], rp[ORD_MAX + 1];
    // ── hauteur (F0) et marques de période ──
    int D; float xd[NXD]; long long wd; float acc; int accn;
    int lagMin, lagMax, Wd, Pmin, Pmax, Pdef, LA;
    float rcor[LAGMAX + 4], tmp[TMPN], tmp2[TMPN];
    long long mpos[NMK]; float mP[NMK], mC[NMK], mF[NMK]; unsigned char mV[NMK]; long long nm;
    long long cand; int candInit; float prevP; int prevV, vstate;
    // ── synthèse PSOLA ──
    long long ts; int tsInit; long long fin, outDone;
    int Dfix, Hmax, Hcap;
    float lfMean, lfSmooth; int lfInit; float vibPh, voicedRun;
    uint32_t rng;
    // ── apériodicité / souffle ──
    BQ apLP, nLP, brHP, tilt;
    float EeH, EnH, EeL;
    // ── sortie ──
    float dePrev, ein, eout, gain;
    vDSP_biquad_Setup eq; float eqDelay[2 * 4 + 2]; int eqN;
    BQ dsSide, dsAudio; float dsEnvS, dsEnvF, dsGain;
    float gateEnv, gateGain; int gateOpen, gateHold;
    // ── diagnostic ──
    float lastF0in, lastF0out; long long underruns, faults;
};

// ───────────────────────── utilitaires ─────────────────────────
static inline float rnd_u(uint32_t *s) {         // bruit blanc -1..1 (xorshift, sans allocation)
    uint32_t x = *s; x ^= x << 13; x ^= x >> 17; x ^= x << 5; *s = x;
    return (float)(int32_t)x * (1.f / 2147483648.f);
}
static inline float clampf(float v, float a, float b) { return v < a ? a : (v > b ? b : v); }

// Levinson-Durbin : autocorrélation r[0..p] -> coefficients de réflexion k[0..p-1] ; retourne l'erreur.
static float levinson(const float *r, int p, float *k, float *a /* p+1 */) {
    float E = r[0];
    a[0] = 1.f;
    for (int i = 1; i <= p; i++) a[i] = 0.f;
    if (!(E > 1e-12f)) { for (int i = 0; i < p; i++) k[i] = 0.f; return 0.f; }
    for (int i = 1; i <= p; i++) {
        float accv = r[i];
        for (int j = 1; j < i; j++) accv += a[j] * r[i - j];
        float ki = -accv / E;
        if (!(ki > -0.9995f && ki < 0.9995f)) {          // instable : on s'arrête à cet ordre
            for (int j = i - 1; j < p; j++) k[j] = 0.f;
            return E;
        }
        for (int j = 1; j <= i / 2; j++) {
            float t1 = a[j], t2 = a[i - j];
            a[j] = t1 + ki * t2; a[i - j] = t2 + ki * t1;
        }
        a[i] = ki; k[i - 1] = ki;
        E *= (1.f - ki * ki);
    }
    return E;
}
static void build_warp(VSNat *e, float alpha) {           // tables pour déplacer les formants
    int p = e->ord;
    for (int i = 0; i < KW; i++) {
        float om = (float)M_PI * ((float)i + 0.5f) / (float)KW;
        float th = om / alpha;
        if (th > (float)M_PI) th = 2.f * (float)M_PI - th;    // voix plus grave : on replie
        if (th < 0.f) th = 0.f;
        for (int m = 0; m <= p; m++) {
            e->Cw[i * (p + 1) + m] = cosf((float)m * th);
            e->Sw[i * (p + 1) + m] = sinf((float)m * th);
        }
    }
    for (int kk = 0; kk <= p; kk++)
        for (int i = 0; i < KW; i++) {
            float om = (float)M_PI * ((float)i + 0.5f) / (float)KW;
            e->Cr[kk * KW + i] = cosf((float)kk * om) / (float)KW;
        }
    e->warpAlpha = alpha; e->warpOrd = p;
}

// ───────────────────────── création ─────────────────────────
void vs_nat_default_params(VSNatParams *p) {
    p->semitones = 12.f; p->formantPct = 17.f; p->breath = 0.2f; p->smoothing = 0.45f;
    p->vibrato = 0.15f; p->expressivity = 1.3f; p->deesser = 1; p->gate = 1; p->eq = 1; p->economy = 0;
}

static void setup_eq(VSNat *e) {
    double c[5 * 4]; int n = 0; BQ q;
    float fs = e->fs;
    bq_set(&q, 1, 120.f, fs, 0.5412f, 0.f); c[5*n]=q.b0; c[5*n+1]=q.b1; c[5*n+2]=q.b2; c[5*n+3]=q.a1; c[5*n+4]=q.a2; n++;
    bq_set(&q, 1, 120.f, fs, 1.3066f, 0.f); c[5*n]=q.b0; c[5*n+1]=q.b1; c[5*n+2]=q.b2; c[5*n+3]=q.a1; c[5*n+4]=q.a2; n++;
    bq_set(&q, 2, 230.f, fs, 0.9f, -2.5f);  c[5*n]=q.b0; c[5*n+1]=q.b1; c[5*n+2]=q.b2; c[5*n+3]=q.a1; c[5*n+4]=q.a2; n++;   // moins de « poitrine »
    if (fs * 0.5f > 6000.f) {
        bq_set(&q, 2, 3800.f, fs, 0.8f, 3.f); c[5*n]=q.b0; c[5*n+1]=q.b1; c[5*n+2]=q.b2; c[5*n+3]=q.a1; c[5*n+4]=q.a2; n++; // présence
    }
    e->eq = vDSP_biquad_CreateSetup(c, (vDSP_Length)n);
    e->eqN = n;
}

void vs_nat_reset(VSNat *e) {
    vDSP_biquad_Setup eq = e->eq; int eqN = e->eqN;
    float hb[HB], ph0[HBP], ph1[HBP], win[TMPN], lagw[ORD_MAX + 1];
    memcpy(hb, e->hb, sizeof hb); memcpy(ph0, e->ph0, sizeof ph0); memcpy(ph1, e->ph1, sizeof ph1);
    memcpy(win, e->lpcWin, sizeof win); memcpy(lagw, e->lagw, sizeof lagw);
    float srHost = e->srHost, fs = e->fs; int R = e->R;
    int ordFull = e->ordFull, hop = e->hop, nwin = e->nwin, D = e->D;
    int lagMin = e->lagMin, lagMax = e->lagMax, Wd = e->Wd, Pmin = e->Pmin, Pmax = e->Pmax, Pdef = e->Pdef, LA = e->LA;
    int Dfix = e->Dfix, Hmax = e->Hmax, Hcap = e->Hcap;
    BQ apLP = e->apLP, nLP = e->nLP, brHP = e->brHP, tilt = e->tilt, ds = e->dsSide;

    memset(e, 0, sizeof(*e));
    e->eq = eq; e->eqN = eqN;
    memcpy(e->hb, hb, sizeof hb); memcpy(e->ph0, ph0, sizeof ph0); memcpy(e->ph1, ph1, sizeof ph1);
    memcpy(e->lpcWin, win, sizeof win); memcpy(e->lagw, lagw, sizeof lagw);
    e->srHost = srHost; e->fs = fs; e->R = R;
    e->ordFull = ordFull; e->ord = ordFull; e->ordUsed = ordFull; e->hop = hop; e->nwin = nwin; e->D = D;
    e->lagMin = lagMin; e->lagMax = lagMax; e->Wd = Wd; e->Pmin = Pmin; e->Pmax = Pmax; e->Pdef = Pdef; e->LA = LA;
    e->Dfix = Dfix; e->Hmax = Hmax; e->Hcap = Hcap;
    apLP.z1 = apLP.z2 = 0; nLP.z1 = nLP.z2 = 0; brHP.z1 = brHP.z2 = 0; tilt.z1 = tilt.z2 = 0; ds.z1 = ds.z2 = 0;
    e->apLP = apLP; e->nLP = nLP; e->brHP = brHP; e->tilt = tilt; e->dsSide = ds; e->dsAudio = ds;
    e->gain = 1.f; e->dsGain = 1.f; e->gateGain = 1.f; e->gateOpen = 1;
    e->rng = 0x9E3779B9u;
    e->hopNext = hop;
    e->fr = 0; e->fw = 2;                               // 2 échantillons d'avance dans la file de sortie
    build_warp(e, 1.f);
}

VSNat *vs_nat_create(float sr) {
    if (!(sr >= 7900.f && sr <= 200000.f)) return NULL;
    VSNat *e = (VSNat *)calloc(1, sizeof(VSNat));
    if (!e) return NULL;
    e->srHost = sr;
    e->R = sr > 32000.f ? 2 : 1;
    e->fs = sr / (float)e->R;
    float fs = e->fs;
    // filtre demi-bande (Kaiser β=5,65 ≈ 60 dB)
    {
        double beta = 5.65, i0b = 0;
        for (int k = 0, t = 1; k < 30; k++) { double f = 1; for (int j = 1; j <= k; j++) f *= (beta / 2) / j; i0b += f * f; (void)t; }
        int c = (HB - 1) / 2;
        for (int n = 0; n < HB; n++) {
            int m = n - c;
            double sinc = m == 0 ? 0.5 : sin(M_PI * m / 2.0) / (M_PI * m);
            double r = (double)m / c, arg = beta * sqrt(fmax(0.0, 1.0 - r * r)), i0 = 0;
            for (int k = 0; k < 30; k++) { double f = 1; for (int j = 1; j <= k; j++) f *= (arg / 2) / j; i0 += f * f; }
            e->hb[n] = (float)(sinc * i0 / i0b);
        }
        for (int j = 0; j < HBP; j++) {             // phases de l'interpolateur (gain ×2)
            e->ph0[j] = (2 * j < HB) ? 2.f * e->hb[2 * j] : 0.f;
            e->ph1[j] = (2 * j + 1 < HB) ? 2.f * e->hb[2 * j + 1] : 0.f;
        }
    }
    // analyse LPC
    int ord = (int)lrintf(fs / 1000.f) + 4; if (ord > ORD_MAX) ord = ORD_MAX; if (ord < 10) ord = 10;
    e->ordFull = ord;
    e->hop = (int)lrintf(fs * 0.004f);
    e->nwin = (int)lrintf(fs * 0.025f); if (e->nwin > TMPN) e->nwin = TMPN;
    for (int i = 0; i < e->nwin; i++) e->lpcWin[i] = 0.5f - 0.5f * cosf(2.f * (float)M_PI * ((float)i + 0.5f) / (float)e->nwin);
    for (int i = 0; i <= ORD_MAX; i++) { float f = 2.f * (float)M_PI * 60.f * (float)i / fs; e->lagw[i] = expf(-0.5f * f * f); }
    // hauteur : 72..450 Hz en entrée
    e->D = (int)lrintf(fs / 8000.f); if (e->D < 1) e->D = 1;
    float sd = fs / (float)e->D;
    e->lagMin = (int)(sd / 450.f); if (e->lagMin < 4) e->lagMin = 4;
    e->lagMax = (int)(sd / 72.f);  if (e->lagMax > LAGMAX) e->lagMax = LAGMAX;
    e->Wd   = (int)(e->lagMax * 1.25f);
    e->Pmin = (int)(fs / 450.f);
    e->Pmax = (int)(fs / 72.f);
    e->Pdef = (int)(fs * 0.006f);
    e->Hmax = e->Pmax + 2;
    // demi-largeur maximale d'un grain : la voix monte (homme -> femme), donc les périodes produites sont courtes
    e->Hcap = (int)(0.62f * (float)e->Pmax);
    if (e->Hcap < e->Pdef) e->Hcap = e->Pdef;
    {
        int la1 = (e->Wd / 2 + 2) * e->D, la2 = (int)(0.75f * e->Pmax) + 4;
        e->LA = la1 > la2 ? la1 : la2;
    }
    // latence fixe : marques prêtes (LA + 1 période) + un demi-grain + marge
    {
        int a1 = e->LA + (int)(0.7f * (float)e->Pmax), a2 = e->hop + e->Hcap;
        e->Dfix = (a1 > a2 ? a1 : a2) + e->Hcap + (int)(fs * 0.002f);
#ifdef VS_OFFLINE_TEST
        const char *ov = getenv("VS_DFIX_MS");
        if (ov) e->Dfix = (int)(atof(ov) * fs / 1000.f);
#endif
    }
    // filtres de l'excitation
    bq_set(&e->apLP, 0, fminf(3500.f, fs * 0.30f), fs, 0.707f, 0.f);
    e->nLP = e->apLP;
    bq_set(&e->brHP, 1, 1500.f, fs, 0.707f, 0.f);
    bq_set(&e->tilt, 0, 2200.f, fs, 0.6f, 0.f);
    bq_set(&e->dsSide, 1, fminf(5500.f, fs * 0.36f), fs, 0.707f, 0.f);
    setup_eq(e);
    if (!e->eq) { free(e); return NULL; }
    vs_nat_reset(e);
    return e;
}

void vs_nat_destroy(VSNat *e) {
    if (!e) return;
    if (e->eq) vDSP_biquad_DestroySetup(e->eq);
    free(e);
}

float vs_nat_latency_ms(const VSNat *e) {
    float l = (float)e->Dfix / e->fs;
    if (e->R == 2) l += (float)(HB - 1 + 2) / e->srHost;
    return l * 1000.f;
}

void vs_nat_stats(const VSNat *e, VSNatStats *s) {
    s->latencyMs = vs_nat_latency_ms(e);
    s->f0In = e->lastF0in; s->f0Out = e->lastF0out;
    s->underruns = e->underruns; s->faults = e->faults;
}

// ───────────────────────── analyse : une trame LPC ─────────────────────────
static void do_hop(VSNat *e, long long hs) {
    int p = e->ord, nw = e->nwin, hop = e->hop;
    long long end = hs + hop;
    long long st = end - nw;
    for (int i = 0; i < nw; i++) { long long t = st + i; e->frame[i] = t >= 0 ? e->xpe[t & NRM] : 0.f; }
    vDSP_vmul(e->frame, 1, e->lpcWin, 1, e->frame, 1, (vDSP_Length)nw);
    float r[ORD_MAX + 1] = {0}, a[ORD_MAX + 1], k[ORD_MAX];
    for (int i = 0; i <= p; i++) { float v; vDSP_dotpr(e->frame, 1, e->frame + i, 1, &v, (vDSP_Length)(nw - i)); r[i] = v * e->lagw[i]; }
    r[0] = r[0] * 1.0001f + 1e-9f;
    levinson(r, p, k, a);

    // enveloppe déformée : formants multipliés par alpha
    long long hidx = e->nh & (NHOP - 1);
    {
        for (int i = 0; i <= p; i++) e->avec[i] = a[i];
        vDSP_mmul(e->Cw, 1, e->avec, 1, e->re, 1, KW, 1, (vDSP_Length)(p + 1));
        vDSP_mmul(e->Sw, 1, e->avec, 1, e->im, 1, KW, 1, (vDSP_Length)(p + 1));
        for (int i = 0; i < KW; i++) {
            float m2 = e->re[i] * e->re[i] + e->im[i] * e->im[i];
            e->Sp[i] = 1.f / (m2 + 1e-6f);
        }
        vDSP_mmul(e->Cr, 1, e->Sp, 1, e->rp, 1, (vDSP_Length)(p + 1), 1, KW);
        for (int i = 0; i <= p; i++) e->rp[i] *= e->lagw[i];
        e->rp[0] = e->rp[0] * 1.0001f + 1e-9f;
        float a2[ORD_MAX + 1];
        float Eb = levinson(e->rp, p, e->kS[hidx], a2);
        e->gS[hidx] = sqrtf(Eb > 0.f ? Eb : 0.f);
        for (int i = p; i < ORD_MAX; i++) e->kS[hidx][i] = 0.f;
    }
    e->hopStart[hidx] = hs;

    // filtre inverse (treillis) : x -> résiduel, coefficients interpolés le long de la trame
    float inv = 1.f / (float)hop;
    for (int i = 0; i < p; i++) e->kAcur[i] = k[i];
    for (int n = 0; n < hop; n++) {
        long long t = hs + n;
        float fr = (float)(n + 1) * inv;
        float f = e->xpe[t & NRM];
        float bprev = f;                             // b_0[n] = x[n]
        float fcur = f;
        for (int i = 0; i < p; i++) {
            float ki = e->kAprev[i] + (e->kAcur[i] - e->kAprev[i]) * fr;
            float bold = e->bA[i];                   // b_i[n-1]
            float fn = fcur + ki * bold;
            float bn = bold + ki * fcur;
            e->bA[i] = bprev;                        // mémorise b_i[n] pour la prochaine fois
            bprev = bn;
            fcur = fn;
        }
        e->e[t & NRM] = fcur;
    }
    for (int i = 0; i < p; i++) e->kAprev[i] = e->kAcur[i];
    e->nh++;
    e->hopDone = end;
}

// ───────────────────────── hauteur ─────────────────────────
static int estimate(VSNat *e, long long m, float *per, float *conf, float thr) {
    long long c = m / e->D;
    int W = e->Wd, h = W / 2;
    *conf = 0.f; *per = (float)e->Pdef;
    if (c + h > e->wd - 1 || c - h - e->lagMax - 2 < 0) return 0;
    int L = W + e->lagMax + 2;                       // copie linéaire : [c-h-lagMax-2, c+h)
    long long s0 = c - h - e->lagMax - 2;
    if (L > TMPN) return 0;
    for (int i = 0; i < L; i++) e->tmp[i] = e->xd[(s0 + i) & NXDM];
    const float *a = e->tmp + (L - W);               // segment actuel
    float e0; vDSP_svesq(a, 1, &e0, (vDSP_Length)W);
    if (e0 / (float)W < 2e-6f) return 0;             // silence
    float rmax = -1.f;
    for (int t = e->lagMin - 1; t <= e->lagMax + 1; t++) {
        const float *b = a - t;
        float num, et;
        vDSP_dotpr(a, 1, b, 1, &num, (vDSP_Length)W);
        vDSP_svesq(b, 1, &et, (vDSP_Length)W);
        float v = num / (sqrtf(e0 * et) + 1e-9f);
        e->rcor[t] = v;
        if (t >= e->lagMin && t <= e->lagMax && v > rmax) rmax = v;
    }
    int best = -1;
    for (int t = e->lagMin; t <= e->lagMax; t++)     // plus petit pic proche du max : évite les erreurs d'octave
        if (e->rcor[t] >= 0.88f * rmax && e->rcor[t] >= e->rcor[t - 1] && e->rcor[t] >= e->rcor[t + 1]) { best = t; break; }
    if (best < 0) return 0;
    float ra = e->rcor[best - 1], rb = e->rcor[best], rc = e->rcor[best + 1];
    float den = ra - 2.f * rb + rc, d = 0.f;
    if (fabsf(den) > 1e-9f) d = 0.5f * (ra - rc) / den;
    d = clampf(d, -1.f, 1.f);
    *per = ((float)best + d) * (float)e->D;
    *conf = rb;
    return rb > thr;
}

static void gen_marks(VSNat *e) {
    for (;;) {
        if (!e->candInit) { e->cand = 2 * (long long)e->Pmax + e->Dfix / 4; e->candInit = 1; }
        if (e->w - e->cand < e->LA) return;
        float per, conf;
        int v = estimate(e, e->cand, &per, &conf, e->vstate ? 0.35f : 0.5f);    // hystérésis
        e->vstate = v;
        float P, frac = 0.f; long long pos = e->cand;
        if (v) {
            P = per;
            if (e->prevV && e->prevP > 0.f) {
                float ra = P / e->prevP;
                if (ra > 1.8f && ra < 2.2f) P *= 0.5f;          // erreurs d'octave
                else if (ra > 0.45f && ra < 0.55f) P *= 2.f;
                ra = P / e->prevP;
                if (ra > 0.7f && ra < 1.43f) P = 0.5f * P + 0.5f * e->prevP;
            }
            P = clampf(P, (float)e->Pmin, (float)e->Pmax);
            long long best = pos;
            if (e->prevV && e->nm > 0) {
                frac = 0.f;
                // alignement : ressemblance avec la période précédente (marques régulières = pas de grésillement)
                long long mp = e->mpos[(e->nm - 1) & (NMK - 1)];
                int Wn = (int)(P * 0.5f), Rr = (int)(P * 0.2f);
                int Ln = 2 * Wn + 1;
                if (Ln + 2 * Rr + 1 <= TMPN && Ln <= TMPN) {
                    // signal pré-accentué : pics de corrélation plus fins -> repères plus précis
                    for (int n = 0; n < Ln; n++) e->tmp2[n] = e->xpe[(mp - Wn + n) & NRM];
                    for (int n = 0; n < Ln + 2 * Rr; n++) e->tmp[n] = e->xpe[(pos - Rr - Wn + n) & NRM];
                    float er; vDSP_svesq(e->tmp2, 1, &er, (vDSP_Length)Ln);
                    float bc = -2.f; int bsh = Rr;
                    for (int sh = 0; sh <= 2 * Rr; sh++) {
                        float num, ec;
                        vDSP_dotpr(e->tmp + sh, 1, e->tmp2, 1, &num, (vDSP_Length)Ln);
                        vDSP_svesq(e->tmp + sh, 1, &ec, (vDSP_Length)Ln);
                        float cc = num / sqrtf(er * ec + 1e-12f);
                        e->rcor[sh < LAGMAX ? sh : LAGMAX] = cc;
                        if (cc > bc) { bc = cc; bsh = sh; }
                    }
                    best = pos - Rr + bsh;
                    // précision inférieure à l'échantillon (interpolation parabolique du pic)
                    if (bsh > 0 && bsh < 2 * Rr && bsh < LAGMAX) {
                        float ca = e->rcor[bsh - 1], cb = e->rcor[bsh], cc2 = e->rcor[bsh + 1];
                        float den = ca - 2.f * cb + cc2;
                        if (fabsf(den) > 1e-9f) frac = clampf(0.5f * (ca - cc2) / den, -0.5f, 0.5f);
                    }
                    frac += e->mF[(e->nm - 1) & (NMK - 1)];     // la référence avait elle-même un décalage
                    if (frac >= 0.5f) { frac -= 1.f; best++; } else if (frac < -0.5f) { frac += 1.f; best--; }
                }
            } else {
                int rad = (int)(P * 0.25f);
                float bv = -1.f;
                for (long long q = pos - rad; q <= pos + rad; q++) {
                    float sm = fabsf(0.25f * (e->x[(q - 1) & NRM] + 2.f * e->x[q & NRM] + e->x[(q + 1) & NRM]));
                    if (sm > bv) { bv = sm; best = q; }
                }
            }
            pos = best;
            e->prevP = P;
        } else P = (float)e->Pdef;
        e->prevV = v;
        int idx = (int)(e->nm & (NMK - 1));
        e->mpos[idx] = pos; e->mP[idx] = P; e->mV[idx] = (unsigned char)v; e->mC[idx] = v ? conf : 0.f; e->mF[idx] = frac; e->nm++;
        e->lastF0in = v ? e->fs / P : 0.f;
        e->cand = pos + (long long)lrintf(P);
    }
}

// ───────────────────────── synthèse PSOLA de la source ─────────────────────────
static void synth(VSNat *e, const VSNatParams *pp) {
    const float LN2_12 = 0.05776227f;               // ln(2)/12
    for (;;) {
        if (e->nm < 3) return;
        if (!e->tsInit) { e->ts = e->mpos[1 & (NMK - 1)]; e->tsInit = 1; if (e->ts < e->outDone) e->ts = e->outDone; }
        long long newest = e->mpos[(e->nm - 1) & (NMK - 1)];
        // un futur repère sera au moins 0,7 période plus loin : on peut avancer jusqu'à newest + 0,3 période
        if ((float)newest + 0.3f * e->mP[(e->nm - 1) & (NMK - 1)] < (float)e->ts) return;
        long long kk = e->nm - 1;
        long long bestd = llabs(e->mpos[kk & (NMK - 1)] - e->ts);
        for (long long j = e->nm - 2; j >= 0 && j >= e->nm - NMK + 1; j--) {
            long long mp = e->mpos[j & (NMK - 1)];
            long long d = llabs(mp - e->ts);
            if (d < bestd) { bestd = d; kk = j; }
            else if (mp < e->ts) break;
        }
        int ki = (int)(kk & (NMK - 1));
        long long m = e->mpos[ki]; float Pin = e->mP[ki]; int v = e->mV[ki]; float conf = e->mC[ki], mf = e->mF[ki];
        float Pout = Pin;
        if (v) {
            float lf = logf(e->fs / Pin);
            float dt = Pin / e->fs;
            if (!e->lfInit || e->voicedRun <= 0.f) {
                if (!e->lfInit) { e->lfMean = lf; e->lfInit = 1; }
                e->lfSmooth = lf;
            }
            float tauS = 0.012f + 0.11f * clampf(pp->smoothing, 0.f, 1.f);
            e->lfSmooth += (lf - e->lfSmooth) * (dt / (tauS + dt));
            e->lfMean += (lf - e->lfMean) * (dt / (1.5f + dt));
            float lfx = lf + clampf(pp->smoothing, 0.f, 1.f) * 0.85f * (e->lfSmooth - lf);
            lfx = e->lfMean + clampf(pp->expressivity, 0.5f, 2.f) * (lfx - e->lfMean);
            e->voicedRun += dt;
            e->vibPh += 2.f * (float)M_PI * 5.3f * dt;
            if (e->vibPh > 2.f * (float)M_PI) e->vibPh -= 2.f * (float)M_PI;
            float vd = clampf(pp->vibrato, 0.f, 1.f) * 0.0145f * clampf((e->voicedRun - 0.25f) / 0.3f, 0.f, 1.f);
            float lo = lfx + clampf(pp->semitones, -12.f, 16.f) * LN2_12 + vd * sinf(e->vibPh);
            Pout = e->fs / expf(lo);
            Pout = clampf(Pout, e->fs / 700.f, e->fs / 55.f);
            e->lastF0out = e->fs / Pout;
        } else {
            e->voicedRun = 0.f;
            e->lastF0out = 0.f;
        }
        int H = (int)lrintf(v ? fminf(Pin, Pout) : Pin);
        if (H < 8) H = 8;
        if (H > e->Hcap) H = e->Hcap;
        if (e->hopDone < m + H + 3) return;           // résiduel pas encore prêt
        e->rng ^= e->rng << 13; e->rng ^= e->rng >> 17; e->rng ^= e->rng << 5;
        float rnd = ((float)(e->rng & 0xFFFF) / 32768.f) - 1.f;
        int step = (int)lrintf(v ? Pout * (1.f + 0.003f * rnd) : Pin);
        if (step < 8) step = 8;
        float invH = (float)M_PI / (float)H;
        float cv = v ? conf : 0.f;
        for (int i = -H; i <= H; i++) {
            long long o = e->ts + i;
            if (o < e->outDone) continue;
            float wv = 0.5f + 0.5f * cosf(invH * ((float)i - mf));
            // lecture du résiduel à la position fractionnaire m + mf + i (interpolation cubique)
            long long q = m + i + (mf < 0.f ? -1 : 0);
            float fq = mf < 0.f ? 1.f + mf : mf;
            float r0 = e->e[(q - 1) & NRM], r1 = e->e[q & NRM], r2 = e->e[(q + 1) & NRM], r3 = e->e[(q + 2) & NRM];
            float s = r1 + 0.5f * fq * (r2 - r0 + fq * (2.f * r0 - 5.f * r1 + 4.f * r2 - r3 + fq * (3.f * (r1 - r2) + r3 - r0)));
            e->y[o & NRM] += s * wv; e->ws[o & NRM] += wv; e->vc[o & NRM] += wv * cv;
        }
        e->ts += step;
        e->fin = e->ts - e->Hcap;
    }
}

// ───────────────────────── cœur à fréquence interne ─────────────────────────
static int core(VSNat *e, const float *in, float *out, int n, const VSNatParams *pp) {
    int err = 0;
    // réglages qui changent la structure : ordre LPC (mode éco) et déformation des formants
    int ordWanted = pp->economy ? (e->ordFull * 3) / 5 : e->ordFull;
    if (ordWanted != e->ord) {
        e->ord = ordWanted;
        for (int i = ordWanted; i < ORD_MAX; i++) { e->kAprev[i] = 0.f; e->bA[i] = 0.f; e->bS[i] = 0.f; }
        build_warp(e, e->warpAlpha);
    }
    float alpha = 1.f + clampf(pp->formantPct, -20.f, 40.f) / 100.f;
    if (fabsf(alpha - e->warpAlpha) > 0.002f) build_warp(e, alpha);

    long long w0 = e->w;
    for (int i = 0; i < n; i++) {
        float s = in[i];
        long long t = e->w;
        e->x[t & NRM] = s;
        float pe = s - 0.9f * e->pePrev; e->pePrev = s;
        e->xpe[t & NRM] = pe;
        e->acc += s;
        if (++e->accn >= e->D) { e->xd[e->wd & NXDM] = e->acc / (float)e->D; e->wd++; e->acc = 0.f; e->accn = 0; }
        e->w = t + 1;
        if (e->w >= e->hopNext) { do_hop(e, e->hopNext - e->hop); e->hopNext += e->hop; }
    }
    gen_marks(e);
    synth(e, pp);

    // ── sortie : excitation mixte -> filtre des formants -> finitions ──
    const float kE = 1.f / (0.06f * e->fs), kG = 1.f / (0.08f * e->fs), kAp = 1.f / (0.008f * e->fs);
    const float breath = clampf(pp->breath, 0.f, 1.f);
    const int p = e->ord;
    const int eco = pp->economy;
    for (int i = 0; i < n; i++) {
        long long idx = w0 + i - e->Dfix;
        if (idx < 0) { out[i] = 0.f; continue; }
        float eP, cv;
        float wsum = e->ws[idx & NRM];
        if (idx < e->fin) {
            float nrm = wsum > 1.f ? wsum : 1.f;
            eP = e->y[idx & NRM] / nrm;
            cv = wsum > 1e-3f ? e->vc[idx & NRM] / wsum : 0.f;
        } else { eP = e->e[idx & NRM]; cv = 0.f; e->underruns++; }
        e->y[idx & NRM] = 0.f; e->ws[idx & NRM] = 0.f; e->vc[idx & NRM] = 0.f;
        e->outDone = idx + 1;

        // apériodicité : le haut du spectre (bruit) est remplacé par du bruit neuf de même énergie
        float vmix = clampf((cv - 0.35f) / 0.35f, 0.f, 1.f);
        float ex = eP;
        if (!eco) {
            float eL = bq_run(&e->apLP, eP), eH = eP - eL;
            float nz = rnd_u(&e->rng) * 1.732f;
            float nL = bq_run(&e->nLP, nz), nH = nz - nL;
            e->EeH += (eH * eH - e->EeH) * kAp;
            e->EnH += (nH * nH - e->EnH) * kAp;
            e->EeL += (eL * eL - e->EeL) * kAp;
            float krep = vmix * clampf(0.45f + 0.4f * breath, 0.f, 0.9f);
            float gn = sqrtf(e->EeH / (e->EnH + 1e-12f));
            ex = eL + (1.f - krep) * eH + krep * gn * nH;
            // souffle (aspiration) : bruit au-dessus de 1,5 kHz, suit l'énergie de la voix
            float nb = bq_run(&e->brHP, rnd_u(&e->rng) * 1.732f);
            ex += breath * 0.55f * vmix * sqrtf(e->EeL) * nb;
            // source plus douce (pente spectrale plus forte, typique d'une voix féminine)
            float tl = bq_run(&e->tilt, ex);
            ex += (0.45f * breath * vmix) * (tl - ex);
        }

        // filtre des formants déformés (treillis récursif, coefficients interpolés)
        while (e->synHop + 1 < e->nh && e->hopStart[(e->synHop + 1) & (NHOP - 1)] <= idx) e->synHop++;
        long long h = e->synHop & (NHOP - 1), hp = (e->synHop > 0 ? e->synHop - 1 : 0) & (NHOP - 1);
        float fr = clampf((float)(idx - e->hopStart[h] + 1) / (float)e->hop, 0.f, 1.f);
        float g = e->gS[hp] + (e->gS[h] - e->gS[hp]) * fr;
        float f = ex * g;
        for (int k = p - 1; k >= 0; k--) {
            float kk = e->kS[hp][k] + (e->kS[h][k] - e->kS[hp][k]) * fr;
            f = f - kk * e->bS[k];
            e->bS[k + 1] = e->bS[k] + kk * f;
        }
        e->bS[0] = f;
        float yv = f + 0.9f * e->dePrev;              // désaccentuation (inverse de la pré-accentuation)
        if (!isfinite(yv) || fabsf(yv) > 1e3f) {      // sécurité : jamais de NaN ni d'explosion
            memset(e->bS, 0, sizeof e->bS); yv = 0.f; e->faults++; err = 2;
        }
        e->dePrev = yv;

        // même volume que la voix d'origine (comparaison avec l'entrée alignée)
        float xi = e->x[idx & NRM];
        e->ein  += (xi * xi - e->ein) * kE;
        e->eout += (yv * yv - e->eout) * kE;
        float gt = sqrtf((e->ein + 1e-9f) / (e->eout + 1e-9f));
        gt = clampf(gt, 0.3f, 3.f);
        e->gain += (gt - e->gain) * kG;
        out[i] = yv * e->gain;
    }

    // ── égaliseur : coupe-bas 120 Hz, moins de « poitrine », présence ──
    if (pp->eq && e->eq) {
        vDSP_biquad(e->eq, e->eqDelay, out, 1, e->tmpb, 1, (vDSP_Length)n);
        memcpy(out, e->tmpb, sizeof(float) * (size_t)n);
    }
    // ── de-esser, noise gate, limiteur ──
    const float aFast = 1.f - expf(-1.f / (0.0007f * e->fs)), rSlow = 1.f - expf(-1.f / (0.05f * e->fs));
    const float gA = 1.f - expf(-1.f / (0.002f * e->fs)), gR = 1.f - expf(-1.f / (0.15f * e->fs));
    const float thrOpen = 0.0035f, thrClose = 0.0018f;   // ≈ -49 / -55 dBFS
    for (int i = 0; i < n; i++) {
        long long idx = w0 + i - e->Dfix;
        float v = out[i];
        if (pp->deesser) {
            float sd = bq_run(&e->dsSide, v), sa = sd;
            float as = fabsf(sd), af = fabsf(v);
            e->dsEnvS += (as - e->dsEnvS) * (as > e->dsEnvS ? aFast : rSlow);
            e->dsEnvF += (af - e->dsEnvF) * (af > e->dsEnvF ? aFast : rSlow);
            float ratio = e->dsEnvS / (e->dsEnvF + 1e-6f);
            float tg = (e->dsEnvS > 0.01f && ratio > 0.45f) ? clampf(0.45f / ratio, 0.3f, 1.f) : 1.f;
            e->dsGain += (tg - e->dsGain) * (tg < e->dsGain ? aFast : rSlow);
            v = v - (1.f - e->dsGain) * sa;
        }
        if (pp->gate && idx >= 0) {
            float xi = fabsf(e->x[idx & NRM]);
            e->gateEnv += (xi - e->gateEnv) * (xi > e->gateEnv ? gA : gR);
            if (e->gateEnv > thrOpen) { e->gateOpen = 1; e->gateHold = (int)(0.12f * e->fs); }
            else if (e->gateEnv < thrClose) { if (e->gateHold > 0) e->gateHold--; else e->gateOpen = 0; }
            float tgt = e->gateOpen ? 1.f : 0.03f;
            e->gateGain += (tgt - e->gateGain) * (tgt > e->gateGain ? gA : (gR * 0.5f));
            v *= e->gateGain;
        }
        float av = fabsf(v);
        if (av > 0.85f) v = (v > 0 ? 1.f : -1.f) * (0.85f + 0.15f * tanhf((av - 0.85f) / 0.15f));
        out[i] = clampf(v, -1.f, 1.f);
    }
    return err;
}

// ───────────────────────── interface publique ─────────────────────────
static int process_chunk(VSNat *e, const float *in, float *out, int n, const VSNatParams *p) {
    if (e->R == 1) {
        int r = core(e, in, e->ob, n, p);
        memcpy(out, e->ob, sizeof(float) * (size_t)n);
        return r;
    }
    // 1) décimation 2:1
    int m = 0;
    for (int i = 0; i < n; i++) {
        e->dpos = (e->dpos + 1) & 63;
        e->dh[e->dpos] = in[i]; e->dh[e->dpos + 64] = in[i];
        e->dphase ^= 1;
        if (e->dphase) {
            float v; vDSP_dotpr(&e->dh[e->dpos + 64 - (HB - 1)], 1, e->hb, 1, &v, HB);
            e->ib[m++] = v;
        }
    }
    int err = core(e, e->ib, e->ob, m, p);
    // 2) interpolation 1:2 dans la file de sortie
    for (int j = 0; j < m; j++) {
        e->upos = (e->upos + 1) & (HBP - 1);
        e->uh[e->upos] = e->ob[j]; e->uh[e->upos + HBP] = e->ob[j];
        // u[j-i] pour i = 0..HBP-1 : lu à l'envers -> coefficients retournés via un pas négatif
        const float *base = &e->uh[e->upos + HBP];
        float a = 0.f, b = 0.f;
        for (int i = 0; i < HBP; i++) { float u = base[-i]; a += e->ph0[i] * u; b += e->ph1[i] * u; }
        e->fifo[e->fw & FIFOM] = a; e->fw++;
        e->fifo[e->fw & FIFOM] = b; e->fw++;
    }
    for (int i = 0; i < n; i++) {
        if (e->fr < e->fw) { out[i] = clampf(e->fifo[e->fr & FIFOM], -1.f, 1.f); e->fr++; }
        else { out[i] = 0.f; e->underruns++; }
    }
    return err;
}

int vs_nat_process(VSNat *e, const float *in, float *out, int n, const VSNatParams *p) {
    if (!e || !in || !out || n <= 0 || !p) return 1;
    int err = 0, done = 0;
    while (done < n) {
        int c = n - done; if (c > HOST_CHUNK) c = HOST_CHUNK;
        float inb[HOST_CHUNK];                       // copie : in et out peuvent être le même tableau
        memcpy(inb, in + done, sizeof(float) * (size_t)c);
        err |= process_chunk(e, inb, out + done, c, p);
        done += c;
    }
    return err;
}
