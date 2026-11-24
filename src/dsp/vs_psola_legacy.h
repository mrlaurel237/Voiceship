// VoiceShift DSP v2 : PSOLA en temps réel (décalage de hauteur + timbre séparés).
// - La hauteur (pitch) est décalée en rejouant les "grains" de chaque période de la voix
//   plus ou moins souvent : l'intonation naturelle (montées, descentes, micro-variations)
//   est conservée, ce qui évite le côté robotique.
// - Le timbre (formants) se règle à part en rééchantillonnant chaque grain : une voix
//   féminine a un conduit vocal plus court, donc des formants ~15 % plus hauts.
// - Les sons sans hauteur (s, f, ch, souffle) passent presque sans modification.
#ifndef VS_DSP_H
#define VS_DSP_H
#include <math.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>

#define VS_N    16384
#define VS_M    (VS_N - 1)
#define VS_XD   4096
#define VS_XDM  (VS_XD - 1)
#define VS_MK   256
#define VS_MKM  (VS_MK - 1)
#define VS_LAGS 320

typedef struct {
    float x[VS_N];      // entrée
    float y[VS_N];      // sortie en cours d'accumulation (somme des grains fenêtrés)
    float ws[VS_N];     // somme des fenêtres (pour normaliser)
    float xd[VS_XD];    // entrée décimée (pour la détection de hauteur)
    int64_t w;          // échantillons reçus
    int64_t wd;         // échantillons décimés
    float sr; int D;
    int Dfix, Pdef, Pmin, Pmax, Hmax, LA;
    int lagMin, lagMax, Wd;
    float accum; int accn;
    int64_t mpos[VS_MK]; float mP[VS_MK]; unsigned char mV[VS_MK]; int64_t nm;
    int64_t cand; int candInit;
    int64_t ts; int tsInit;
    int64_t fin;        // les échantillons < fin sont définitifs
    int64_t outDone;    // les échantillons < outDone ont déjà été émis
    float ein, eout, gain;   // suivi de niveau pour garder le même volume qu'à l'entrée
    float prevP; int prevV; int vstate;   // mémoire de la hauteur (lissage, anti erreurs d'octave)
    uint32_t rng; int64_t lastK; int flip;
    int64_t underruns;       // diagnostic : échantillons sortis sans traitement
} VSPitch;

static inline void vs_pitch_init(VSPitch *p, float sr) {
    memset(p, 0, sizeof(*p));
    if (sr < 8000.f) sr = 8000.f;
    p->sr = sr;
    p->D = (int)(sr / 12000.f + 0.5f); if (p->D < 1) p->D = 1;
    float sd = sr / (float)p->D;
    p->lagMin = (int)(sd / 420.f); if (p->lagMin < 4) p->lagMin = 4;
    p->lagMax = (int)(sd / 70.f);  if (p->lagMax > VS_LAGS - 3) p->lagMax = VS_LAGS - 3;
    p->Wd   = (int)(p->lagMax * 1.5f);
    p->Pmin = (int)(sr / 420.f);
    p->Pmax = (int)(sr / 70.f);
    p->Pdef = (int)(sr * 0.010f);
    p->Hmax = (int)(sr * 0.021f) + 2;
    p->LA   = (int)(sr * 0.016f);
    p->Dfix = (int)(sr * 0.055f);          // latence fixe ~55 ms
    p->gain = 1.f; p->rng = 2463534242u; p->lastK = -1;
}

static inline float vs_xat(const VSPitch *p, int64_t i) { return p->x[i & VS_M]; }

// Détecte la période autour de la position m. Retourne 1 si voisé.
static inline int vs_estimate(const VSPitch *p, int64_t m, float *per, float *conf, float thr) {
    int64_t c = m / p->D;
    int W = p->Wd, h = W / 2;
    *conf = 0.f; *per = (float)p->Pdef;
    if (c + h > p->wd - 1 || c - h - p->lagMax < 1) return 0;
    double e0 = 0;
    for (int n = -h; n < h; n++) { float v = p->xd[(c + n) & VS_XDM]; e0 += (double)v * v; }
    if (e0 / W < 2e-6) return 0;                       // silence
    float r[VS_LAGS]; float rmax = -1.f;
    for (int t = p->lagMin - 1; t <= p->lagMax + 1; t++) {
        double num = 0, et = 0;
        for (int n = -h; n < h; n++) {
            float a = p->xd[(c + n) & VS_XDM], b = p->xd[(c + n - t) & VS_XDM];
            num += (double)a * b; et += (double)b * b;
        }
        float v = (float)(num / (sqrt(e0 * et) + 1e-9));
        r[t] = v;
        if (t >= p->lagMin && t <= p->lagMax && v > rmax) rmax = v;
    }
    int best = -1;
    for (int t = p->lagMin; t <= p->lagMax; t++)       // plus petit pic proche du max (évite les erreurs d'octave)
        if (r[t] >= 0.88f * rmax && r[t] >= r[t - 1] && r[t] >= r[t + 1]) { best = t; break; }
    if (best < 0) return 0;
    float a = r[best - 1], b = r[best], cc = r[best + 1];
    float den = a - 2.f * b + cc, d = 0.f;
    if (fabsf(den) > 1e-9f) d = 0.5f * (a - cc) / den;
    if (d > 1.f) d = 1.f; if (d < -1.f) d = -1.f;
    *per = ((float)best + d) * (float)p->D;
    *conf = b;
    return b > thr;
}

// Pose des marques (une par période de voix) à mesure que l'entrée arrive.
static inline void vs_gen_marks(VSPitch *p) {
    for (;;) {
        if (!p->candInit) { p->cand = 2 * (int64_t)p->Pmax; p->candInit = 1; }
        if (p->w - p->cand < p->LA) return;
        float per, conf;
        int v = vs_estimate(p, p->cand, &per, &conf, p->vstate ? 0.35f : 0.5f);   // hystérésis voisé/non voisé
        p->vstate = v;
        float P; int64_t pos = p->cand;
        if (v) {
            P = per;
            if (p->prevV && p->prevP > 0.f) {
                float ra = P / p->prevP;
                if (ra > 1.8f && ra < 2.2f) P *= 0.5f;           // erreurs d'octave
                else if (ra > 0.45f && ra < 0.55f) P *= 2.f;
                ra = P / p->prevP;
                if (ra > 0.7f && ra < 1.43f) P = 0.5f * P + 0.5f * p->prevP;   // lissage : moins de tremblement
            }
            if (P < p->Pmin) P = (float)p->Pmin; if (P > p->Pmax) P = (float)p->Pmax;
            int rad = (int)(P * 0.25f);
            int64_t best = pos;
            if (p->prevV && p->nm > 0) {
                // alignement par ressemblance de forme d'onde avec la période précédente
                int64_t mp = p->mpos[(p->nm - 1) & VS_MKM];
                int Wn = (int)(P * 0.5f), R = (int)(P * 0.2f);
                double er = 0;
                for (int n = -Wn; n <= Wn; n++) { float b = vs_xat(p, mp + n); er += (double)b * b; }
                double bc = -2.0;
                for (int sh = -R; sh <= R; sh++) {
                    double num = 0, ec = 0;
                    for (int n = -Wn; n <= Wn; n++) { float a = vs_xat(p, pos + sh + n), b = vs_xat(p, mp + n); num += (double)a * b; ec += (double)a * a; }
                    double c = num / sqrt(er * ec + 1e-12);
                    if (c > bc) { bc = c; best = pos + sh; }
                }
            } else {
                float bv = -1.f;
                for (int64_t q = pos - rad; q <= pos + rad; q++) {
                    float sm = 0.25f * (vs_xat(p, q - 1) + 2.f * vs_xat(p, q) + vs_xat(p, q + 1));
                    float a = fabsf(sm);
                    if (a > bv) { bv = a; best = q; }
                }
            }
            pos = best;
            p->prevP = P;
        } else P = (float)p->Pdef;
        p->prevV = v;
        int idx = (int)(p->nm & VS_MKM);
        p->mpos[idx] = pos; p->mP[idx] = P; p->mV[idx] = (unsigned char)v; p->nm++;
        p->cand = pos + (int64_t)lrintf(P);
    }
}

static inline float vs_interp(const VSPitch *p, double pos) {      // interpolation cubique (Catmull-Rom)
    int64_t i = (int64_t)floor(pos); float f = (float)(pos - (double)i);
    float a = vs_xat(p, i - 1), b = vs_xat(p, i), c = vs_xat(p, i + 1), d = vs_xat(p, i + 2);
    return b + 0.5f * f * (c - a + f * (2.f * a - 5.f * b + 4.f * c - d + f * (3.f * (b - c) + d - a)));
}

// Synthèse : place un grain par période de sortie. beta = rapport de hauteur, alpha = rapport de timbre.
static inline void vs_synth(VSPitch *p, float beta, float alpha) {
    for (;;) {
        if (p->nm < 3) return;
        if (!p->tsInit) { p->ts = p->mpos[1]; p->tsInit = 1; }
        int64_t newest = p->mpos[(p->nm - 1) & VS_MKM];
        if (newest < p->ts) return;
        int64_t kk = p->nm - 1;
        int64_t bestd = llabs(p->mpos[kk & VS_MKM] - p->ts);
        for (int64_t j = p->nm - 2; j >= 0 && j >= p->nm - VS_MK; j--) {
            int64_t mp = p->mpos[j & VS_MKM];
            int64_t d = llabs(mp - p->ts);
            if (d < bestd) { bestd = d; kk = j; }
            else if (mp < p->ts) break;
        }
        if (kk == p->lastK) {                              // ne jamais rejouer exactement le même grain (sinon bourdonnement)
            int64_t alt = p->flip ? kk - 1 : kk + 1; p->flip ^= 1;
            if (alt >= 0 && alt < p->nm && alt >= p->nm - VS_MK + 2) kk = alt;
        }
        int64_t m = p->mpos[kk & VS_MKM]; float P = p->mP[kk & VS_MKM]; int voiced = p->mV[kk & VS_MKM];
        float be = voiced ? beta : 1.f, al = voiced ? alpha : 1.f;
        int half = (int)lrintf(P / al); if (half < 8) half = 8; if (half > p->Hmax) half = p->Hmax;
        int span = (int)ceilf((float)half * al) + 3;
        if (p->w < m + span + 1) return;                  // pas encore assez d'entrée
        p->rng ^= p->rng << 13; p->rng ^= p->rng >> 17; p->rng ^= p->rng << 5;
        float rnd = ((float)(p->rng & 0xFFFF) / 32768.f) - 1.f;           // -1..1
        float jit = voiced ? 1.f + 0.010f * rnd : 1.f;                     // petites variations naturelles
        int step = (int)lrintf(P / be * jit); if (step < 8) step = 8;
        p->lastK = kk;
        for (int i = -half; i <= half; i++) {
            int64_t o = p->ts + i;
            if (o < p->outDone) continue;
            float win = 0.5f * (1.f + cosf(3.14159265f * (float)i / (float)half));
            float s = vs_interp(p, (double)m + (double)i * (double)al);
            p->y[o & VS_M] += s * win; p->ws[o & VS_M] += win;
        }
        p->ts += step;
        p->fin = p->ts - p->Hmax;
    }
}

// Traite n échantillons contigus (entrée -> sortie, même taille, latence fixe ~55 ms).
static inline void vs_pitch_chunk(VSPitch *p, const float *in, float *out, int n, float beta, float alpha) {
    if (beta < 0.4f) beta = 0.4f; if (beta > 2.5f) beta = 2.5f;
    if (alpha < 0.7f) alpha = 0.7f; if (alpha > 1.5f) alpha = 1.5f;
    int64_t w0 = p->w;
    for (int i = 0; i < n; i++) {
        float s = in[i];
        p->x[(w0 + i) & VS_M] = s;
        p->accum += s;
        if (++p->accn >= p->D) { p->xd[p->wd & VS_XDM] = p->accum / (float)p->D; p->wd++; p->accum = 0.f; p->accn = 0; }
    }
    p->w = w0 + n;
    vs_gen_marks(p);
    vs_synth(p, beta, alpha);
    const float kE = 1.f / (0.05f * p->sr), kG = 1.f / (0.03f * p->sr);
    for (int i = 0; i < n; i++) {
        int64_t idx = w0 + i - p->Dfix;
        if (idx < 0) { out[i] = 0.f; continue; }
        float v;
        if (idx < p->fin) {
            float ws = p->ws[idx & VS_M], yv = p->y[idx & VS_M];
            v = ws > 0.05f ? yv / ws : p->x[idx & VS_M];
        } else { v = p->x[idx & VS_M]; p->underruns++; }   // sous-alimentation : voix d'origine
        p->y[idx & VS_M] = 0.f; p->ws[idx & VS_M] = 0.f;
        p->outDone = idx + 1;
        // même volume que la voix d'origine (comparaison avec l'entrée retardée, donc alignée)
        float xi = p->x[idx & VS_M];
        p->ein  += (xi * xi - p->ein)  * kE;
        p->eout += (v  * v  - p->eout) * kE;
        float gt = sqrtf((p->ein + 1e-9f) / (p->eout + 1e-9f));
        if (gt > 2.5f) gt = 2.5f; if (gt < 0.4f) gt = 0.4f;
        p->gain += (gt - p->gain) * kG;
        v *= p->gain;
        out[i] = v > 1.f ? 1.f : (v < -1.f ? -1.f : v);
    }
}
#endif
