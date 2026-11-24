// VSEngine.mm — moteurs, sécurité temps réel et statistiques.
//
// Règles du thread audio (callback) respectées ici :
//   - aucune allocation, aucun verrou, aucun appel Objective-C ;
//   - les moteurs sont créés/détruits par un thread de service (« worker ») ;
//   - chaque bloc est chronométré : si le moteur ne tient plus le temps réel, il est rétrogradé ;
//   - un plantage dans un moteur est intercepté (SIGSEGV/SIGBUS…) : le moteur est désactivé,
//     l'application continue, et le plantage est mémorisé pour les lancements suivants.
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <signal.h>
#include <setjmp.h>
#include <fcntl.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <new>
#include "VSEngine.h"
#include "dsp/vs_natural.h"
#include "ai/VSAIEngine.h"
#include "license/VSLicense.h"
#ifdef VS_STRETCH
#include "signalsmith-stretch.h"     // bibliothèque open source (MIT) utilisée par le moteur Rapide
#else
#include "dsp/vs_psola_legacy.h"     // repli si la bibliothèque n'a pas pu être téléchargée à la compilation
#endif

volatile int g_vsTestActive = 0;

// ───────────────────────── moteur Rapide (celui de la 0.8.0) ─────────────────────────
typedef struct { float b0, b1, b2, a1, a2, z1, z2; } FBq;
static void fbq_make(FBq *q, int hp, float fc, float sr, float Q) {
    float w = 2.f * (float)M_PI * fc / sr, c = cosf(w), sn = sinf(w), al = sn / (2.f * Q), a0 = 1.f + al;
    if (hp) { q->b0 = (1.f + c) / 2.f / a0; q->b1 = -(1.f + c) / a0; q->b2 = q->b0; }
    else    { q->b0 = (1.f - c) / 2.f / a0; q->b1 = (1.f - c) / a0;  q->b2 = q->b0; }
    q->a1 = -2.f * c / a0; q->a2 = (1.f - al) / a0; q->z1 = q->z2 = 0.f;
}
static inline float fbq_run(FBq *q, float x) {
    float y = q->b0 * x + q->z1;
    q->z1 = q->b1 * x - q->a1 * y + q->z2;
    q->z2 = q->b2 * x - q->a2 * y;
    return y;
}
static const float kModeTone[4] = {0.f, 6000.f, 4500.f, 3500.f};
static const float kModeLP[4]   = {0.f, 11000.f, 8000.f, 6500.f};

struct FastEng {
#ifdef VS_STRETCH
    signalsmith::stretch::SignalsmithStretch<float> st;
    float lastSemi = -999.f, lastForm = -999.f, lastTone = -999.f;
#else
    VSPitch p;
#endif
    float sr = 48000.f;
    FBq hp, lp; int mode = -1;
};
static FastEng *fast_new(float sr) {
    FastEng *f = new (std::nothrow) FastEng();
    if (!f) return NULL;
    f->sr = sr;
#ifdef VS_STRETCH
    f->st.presetDefault(1, sr, true);
    f->st.setFormantBase(110.f / sr);
#else
    vs_pitch_init(&f->p, sr);
#endif
    return f;
}
static float fast_latency_ms(FastEng *f) {
#ifdef VS_STRETCH
    return (float)(f->st.inputLatency() + f->st.outputLatency()) * 1000.f / f->sr;
#else
    return (float)f->p.Dfix * 1000.f / f->sr;
#endif
}
static void fast_process(FastEng *f, const float *in, float *out, int n, const VSSettings *s) {
    int mode = s->fastMode & 3;
    if (f->mode != mode) {
        fbq_make(&f->hp, 1, 80.f, f->sr, 0.707f);
        if (kModeLP[mode] > 0.f && kModeLP[mode] < f->sr * 0.45f) fbq_make(&f->lp, 0, kModeLP[mode], f->sr, 0.707f);
        else { memset(&f->lp, 0, sizeof f->lp); f->lp.b0 = 1.f; }
        f->mode = mode;
    }
    float semi = s->semitones;
    float formSemi = 12.f * log2f(1.f + s->formantPct / 100.f);
#ifdef VS_STRETCH
    float tone = kModeTone[mode];
    if (semi != f->lastSemi || tone != f->lastTone) {
        f->st.setTransposeSemitones(semi, tone > 0.f ? tone / f->sr : 0.f);
        f->lastSemi = semi; f->lastTone = tone;
    }
    if (formSemi != f->lastForm) { f->st.setFormantSemitones(formSemi, true); f->lastForm = formSemi; }
    float *ib[1] = { const_cast<float *>(in) };
    float *ob[1] = { out };
    f->st.process(ib, n, ob, n);
#else
    vs_pitch_chunk(&f->p, in, out, n, exp2f(semi / 12.f), exp2f(formSemi / 12.f));
#endif
    for (int i = 0; i < n; i++) out[i] = fbq_run(&f->hp, fbq_run(&f->lp, out[i]));
}

// ───────────────────────── instance de moteur ─────────────────────────
struct VSInst {
    int run;            // VS_RUN_*
    float sr;
    VSNat *nat;
    FastEng *fast;
    VSAI *ai;
};
static VSInst *inst_create(int run, float sr) {          // thread de service uniquement
    VSInst *i = (VSInst *)calloc(1, sizeof(VSInst));
    if (!i) return NULL;
    i->run = run; i->sr = sr;
    switch (run) {
        case VS_RUN_FAST: i->fast = fast_new(sr); if (!i->fast) { free(i); return NULL; } break;
        case VS_RUN_NATURAL:
        case VS_RUN_NATURAL_ECO: i->nat = vs_nat_create(sr); if (!i->nat) { free(i); return NULL; } break;
        case VS_RUN_AI: i->ai = vs_ai_create(sr); if (!i->ai) { free(i); return NULL; } break;
        default: free(i); return NULL;
    }
    return i;
}
static void inst_destroy(VSInst *i) {
    if (!i) return;
    if (i->fast) delete i->fast;
    if (i->nat) vs_nat_destroy(i->nat);
    if (i->ai) vs_ai_destroy(i->ai);
    free(i);
}
static float inst_latency_ms(VSInst *i) {
    if (i->nat) return vs_nat_latency_ms(i->nat);
    if (i->fast) return fast_latency_ms(i->fast);
    if (i->ai) return vs_ai_latency_ms(i->ai);
    return 0.f;
}
static void nat_params(const VSSettings *s, int eco, VSNatParams *p) {
    p->semitones = s->semitones; p->formantPct = s->formantPct; p->breath = s->breath;
    p->smoothing = vs_set_smoothing(s); p->vibrato = vs_set_vibrato(s); p->expressivity = vs_set_expressivity(s);
    p->deesser = s->deesser; p->gate = s->gate; p->eq = s->eq; p->economy = eco;
}
static int inst_process(VSInst *i, const float *in, float *out, int n, const VSSettings *s) {
    switch (i->run) {
        case VS_RUN_FAST: fast_process(i->fast, in, out, n, s); return 0;
        case VS_RUN_NATURAL:
        case VS_RUN_NATURAL_ECO: { VSNatParams p; nat_params(s, i->run == VS_RUN_NATURAL_ECO, &p); return vs_nat_process(i->nat, in, out, n, &p); }
        case VS_RUN_AI: return vs_ai_process(i->ai, in, out, n);
    }
    return 1;
}

// ───────────────────────── chaîne de repli ─────────────────────────
// IA -> Naturel -> Naturel éco -> sécurité ; Naturel -> Naturel éco -> sécurité ; Rapide -> sécurité
static const int kChainAI[]   = { VS_RUN_AI, VS_RUN_NATURAL, VS_RUN_NATURAL_ECO, VS_RUN_FAILSAFE };
static const int kChainNat[]  = { VS_RUN_NATURAL, VS_RUN_NATURAL_ECO, VS_RUN_FAILSAFE };
static const int kChainFast[] = { VS_RUN_FAST, VS_RUN_FAILSAFE };
static volatile int g_degrade[3] = {0, 0, 0};          // position dans la chaîne, par moteur demandé
static volatile int g_banned = 0;                       // moteurs ayant planté (bit = VS_RUN_*)
static volatile int g_reason = VS_REASON_NONE;

static int chain_len(int req) { return req == VS_ENGINE_AI ? 4 : (req == VS_ENGINE_NATURAL ? 3 : 2); }
static const int *chain_of(int req) { return req == VS_ENGINE_AI ? kChainAI : (req == VS_ENGINE_NATURAL ? kChainNat : kChainFast); }

static int effective_run(int req) {
    if (req < 0 || req > 2) req = VS_ENGINE_NATURAL;
    const int *c = chain_of(req); int n = chain_len(req);
    for (int k = g_degrade[req]; k < n; k++) {
        int r = c[k];
        if (r == VS_RUN_FAILSAFE) return r;
        if (g_banned & (1 << r)) continue;
        if (r == VS_RUN_AI && !vs_ai_available()) continue;
        if (r == VS_RUN_AI && !vs_license_allows(VS_FEATURE_ENGINE_AI)) continue;
        if ((r == VS_RUN_NATURAL || r == VS_RUN_NATURAL_ECO) && !vs_license_allows(VS_FEATURE_ENGINE_NATURAL)) continue;
        return r;
    }
    return VS_RUN_FAILSAFE;
}
static void degrade(int req, int run, int reason) {     // passe au moteur suivant de la chaîne
    const int *c = chain_of(req); int n = chain_len(req);
    int pos = g_degrade[req];
    for (int k = pos; k < n; k++) if (c[k] == run) { pos = k + 1; break; }
    if (pos >= n) pos = n - 1;
    g_degrade[req] = pos;
    g_reason = reason;
}

// ───────────────────────── mémoire des plantages (par application) ─────────────────────────
static char g_sentinel[1024] = {0};
static void sentinel_write(int bannedMask) {             // async-signal-safe (open/write/close)
    if (!g_sentinel[0]) return;
    int fd = open(g_sentinel, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    char b[4] = { 'B', (char)('0' + (bannedMask & 0x3F)), '\n', 0 };
    ssize_t r = write(fd, b, 3); (void)r;
    close(fd);
}
static void sentinel_read(void) {
    if (!g_sentinel[0]) return;
    int fd = open(g_sentinel, O_RDONLY);
    if (fd < 0) return;
    char b[4] = {0};
    if (read(fd, b, 3) >= 2 && b[0] == 'B') {
        g_banned = (b[1] - '0') & 0x3F;
        if (g_banned) g_reason = VS_REASON_CRASH_BEFORE;
    }
    close(fd);
}

// ───────────────────────── interception des plantages ─────────────────────────
static __thread sigjmp_buf *t_jb = NULL;
static __thread volatile int t_inEngine = 0;
static __thread volatile int t_run = -1;
static struct sigaction g_oldAct[32];
static volatile int g_guardInstalled = 0;
static const int kSigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE };

static void guard_handler(int sig, siginfo_t *info, void *ctx) {
    if (t_inEngine && t_jb) {
        t_inEngine = 0;
        int r = t_run;
        if (r >= 0 && r < 8) { g_banned |= (1 << r); sentinel_write(g_banned); }
        siglongjmp(*t_jb, 1);                              // retour au tampon audio : l'app continue
    }
    // plantage hors de VoiceShift : on rend la main au gestionnaire d'origine
    struct sigaction *o = (sig > 0 && sig < 32) ? &g_oldAct[sig] : NULL;
    if (o && (o->sa_flags & SA_SIGINFO) && o->sa_sigaction) { o->sa_sigaction(sig, info, ctx); return; }
    if (o && o->sa_handler != SIG_DFL && o->sa_handler != SIG_IGN && o->sa_handler) { o->sa_handler(sig); return; }
    struct sigaction d; memset(&d, 0, sizeof d); d.sa_handler = SIG_DFL; sigemptyset(&d.sa_mask);
    sigaction(sig, &d, NULL);                              // l'instruction fautive se rejoue et le système termine l'app normalement
}
static void guard_install(void) {                         // thread de service, une seule fois
    if (g_guardInstalled) return;
    g_guardInstalled = 1;
    for (size_t k = 0; k < sizeof kSigs / sizeof kSigs[0]; k++) {
        struct sigaction a; memset(&a, 0, sizeof a);
        a.sa_sigaction = guard_handler;
        a.sa_flags = SA_SIGINFO | SA_NODEFER | SA_ONSTACK;
        sigemptyset(&a.sa_mask);
        sigaction(kSigs[k], &a, &g_oldAct[kSigs[k]]);
    }
}

// ───────────────────────── emplacements (un par flux micro) ─────────────────────────
#define MAXSLOTS 16
enum { SL_FREE = 0, SL_PENDING = 1, SL_ACTIVE = 2, SL_DYING = 3 };
typedef struct {
    int state;
    void *key; float sr;
    VSInst *cur;
    int busy;
    int want;
    uint64_t lastUse;
    int failedRun;          // dernier moteur dont la création a échoué
    float loadEma; int over, spikes;
} Slot;
static Slot g_slots[MAXSLOTS];
static dispatch_semaphore_t g_sem = NULL;
static volatile int g_workerUp = 0;
static mach_timebase_info_data_t g_tb;

static inline uint64_t now_ns(void) { return mach_absolute_time() * g_tb.numer / g_tb.denom; }
#define LD(x)     __atomic_load_n(&(x), __ATOMIC_SEQ_CST)
#define ST(x, v)  __atomic_store_n(&(x), (v), __ATOMIC_SEQ_CST)

static void wait_not_busy(Slot *s) {
    for (int i = 0; i < 400 && LD(s->busy); i++) usleep(500);     // au plus 200 ms
}

static void *worker_main(void *arg) {
    (void)arg;
    pthread_setname_np("VoiceShift.worker");
    guard_install();
    for (;;) {
        dispatch_semaphore_wait(g_sem, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC));
        uint64_t t = now_ns();
        for (int i = 0; i < MAXSLOTS; i++) {
            Slot *s = &g_slots[i];
            int st = LD(s->state);
            if (st == SL_FREE) continue;
            // emplacement inutilisé depuis 15 s : on libère la mémoire
            if (t - LD(s->lastUse) > 15ULL * NSEC_PER_SEC) {
                int exp = st;
                if (!__atomic_compare_exchange_n(&s->state, &exp, SL_DYING, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) continue;
                VSInst *old = __atomic_exchange_n(&s->cur, (VSInst *)NULL, __ATOMIC_SEQ_CST);
                wait_not_busy(s);
                if (old && !(g_banned & (1 << old->run))) inst_destroy(old);   // un moteur ayant planté n'est jamais touché
                s->key = NULL;
                ST(s->state, SL_FREE);
                continue;
            }
            int want = LD(s->want);
            VSInst *cur = LD(s->cur);
            if (want >= 0 && want != VS_RUN_FAILSAFE && (!cur || cur->run != want) && s->failedRun != want) {
                VSInst *ni = inst_create(want, s->sr);
                if (!ni) { s->failedRun = want; continue; }
                VSInst *old = __atomic_exchange_n(&s->cur, ni, __ATOMIC_SEQ_CST);
                wait_not_busy(s);
                if (old && !(g_banned & (1 << old->run))) inst_destroy(old);
            }
            if (st == SL_PENDING) ST(s->state, SL_ACTIVE);
        }
    }
    return NULL;
}

void vs_engine_prepare(void) {
    if (__atomic_exchange_n(&g_workerUp, 1, __ATOMIC_SEQ_CST)) return;
    pthread_t th; pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, worker_main, NULL) != 0) g_workerUp = 0;
    pthread_attr_destroy(&at);
}

static Slot *slot_get(void *key, float sr, uint64_t t) {
    for (int i = 0; i < MAXSLOTS; i++) {
        Slot *s = &g_slots[i];
        int st = LD(s->state);
        if ((st == SL_ACTIVE || st == SL_PENDING) && s->key == key && s->sr == sr) return s;
    }
    for (int i = 0; i < MAXSLOTS; i++) {
        Slot *s = &g_slots[i];
        int exp = SL_FREE;
        if (__atomic_compare_exchange_n(&s->state, &exp, SL_PENDING, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
            s->key = key; s->sr = sr; s->failedRun = -1; s->loadEma = 0.f; s->over = 0; s->spikes = 0;
            ST(s->lastUse, t); ST(s->want, VS_RUN_NONE);
            return s;
        }
    }
    return NULL;
}

// ───────────────────────── statistiques ─────────────────────────
static VSEngineStats g_stats;

void vs_engine_stats(VSEngineStats *out) {
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    *out = g_stats;
    out->reason = g_reason;
    VSSettings s; vs_state_snapshot(&s);
    out->requested = s.engine;
    if (g_stats.buffers == 0) out->running = effective_run(s.engine);
}

const char *vs_engine_run_name(int run) {
    switch (run) {
        case VS_RUN_FAST: return "Rapide";
        case VS_RUN_NATURAL: return "Naturel";
        case VS_RUN_NATURAL_ECO: return "Naturel (éco)";
        case VS_RUN_AI: return "IA";
        case VS_RUN_FAILSAFE: return "Sécurité";
    }
    return "—";
}
const char *vs_engine_reason_text(int r) {
    switch (r) {
        case VS_REASON_OVERLOAD: return "processeur saturé : moteur plus léger activé";
        case VS_REASON_CRASH: return "erreur dans le moteur : désactivé (l'app continue)";
        case VS_REASON_CRASH_BEFORE: return "un moteur avait planté ici : désactivé";
        case VS_REASON_CREATE_FAILED: return "mémoire insuffisante pour le moteur";
        case VS_REASON_AI_UNAVAILABLE: return "IA indisponible : moteur Naturel utilisé";
    }
    return "";
}

void vs_engine_retry(void) {
    g_degrade[0] = g_degrade[1] = g_degrade[2] = 0;
    g_banned = 0; g_reason = VS_REASON_NONE;
    if (g_sentinel[0]) unlink(g_sentinel);
    for (int i = 0; i < MAXSLOTS; i++) g_slots[i].failedRun = -1;
    if (g_sem) dispatch_semaphore_signal(g_sem);
}

void vs_engine_init(void) {
    mach_timebase_info(&g_tb);
    g_sem = dispatch_semaphore_create(0);
    memset(&g_stats, 0, sizeof g_stats);
    g_stats.running = VS_RUN_NONE;
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches"];
    NSString *p = [dir stringByAppendingPathComponent:@"com.local.voiceshift.crash"];
    if (p.fileSystemRepresentation) strlcpy(g_sentinel, p.fileSystemRepresentation, sizeof g_sentinel);
    sentinel_read();
}

// ───────────────────────── traitement temps réel ─────────────────────────
static void failsafe(const VSSettings *s, int fmt, const VSChan *ch, int nch, int frames) {
    if (!s->failSilence) return;                              // voix d'origine : on ne touche à rien
    for (int c = 0; c < nch; c++) {
        if (fmt == VS_FMT_F32) { float *d = (float *)ch[c].base; for (int i = 0; i < frames; i++) d[(size_t)i * ch[c].stride] = 0.f; }
        else { int16_t *d = (int16_t *)ch[c].base; for (int i = 0; i < frames; i++) d[(size_t)i * ch[c].stride] = 0; }
    }
}

static int guarded(VSInst *inst, const float *in, float *out, int n, const VSSettings *s) {
    sigjmp_buf jb;
    if (sigsetjmp(jb, 0)) { t_inEngine = 0; t_jb = NULL; return -1; }   // plantage intercepté
    t_jb = &jb; t_run = inst->run; t_inEngine = 1;
    int rc = inst_process(inst, in, out, n, s);
    t_inEngine = 0; t_jb = NULL;
    return rc;
}

#define CH 1024
void vs_engine_process(void *key, float sr, int fmt, const VSChan *ch, int nch, int frames) {
    if (g_vsTestActive || !ch || nch <= 0 || frames <= 0 || !ch[0].base || ch[0].stride <= 0) return;
    if (fmt != VS_FMT_F32 && fmt != VS_FMT_S16) return;
    VSSettings s; vs_state_snapshot(&s);
    if (!s.enabled) return;
    if (!(sr >= 7900.f && sr <= 200000.f)) return;
    if (!g_workerUp) vs_engine_prepare();                      // normalement déjà fait par un hook non temps réel

    uint64_t t0 = now_ns();
    int run = effective_run(s.engine);
    Slot *sl = slot_get(key, sr, t0);
    if (run == VS_RUN_FAILSAFE || !sl) { failsafe(&s, fmt, ch, nch, frames); g_stats.running = VS_RUN_FAILSAFE; return; }
    ST(sl->lastUse, t0);
    if (LD(sl->want) != run) { ST(sl->want, run); dispatch_semaphore_signal(g_sem); }
    if (sl->failedRun == run) {                                 // création impossible (mémoire) : moteur suivant
        degrade(s.engine, run, VS_REASON_CREATE_FAILED);
        failsafe(&s, fmt, ch, nch, frames); return;
    }

    ST(sl->busy, 1);
    VSInst *inst = LD(sl->cur);
    if (!inst || (g_banned & (1 << inst->run))) {              // moteur en préparation (quelques ms au début)
        ST(sl->busy, 0);
        failsafe(&s, fmt, ch, nch, frames);
        return;
    }
    float in[CH], out[CH];
    int done = 0, crashed = 0;
    while (done < frames && !crashed) {
        int n = frames - done; if (n > CH) n = CH;
        const VSChan *c0 = &ch[0];
        if (fmt == VS_FMT_F32) { const float *d = (const float *)c0->base + (size_t)done * c0->stride; for (int i = 0; i < n; i++) in[i] = d[(size_t)i * c0->stride]; }
        else { const int16_t *d = (const int16_t *)c0->base + (size_t)done * c0->stride; for (int i = 0; i < n; i++) in[i] = d[(size_t)i * c0->stride] * (1.f / 32768.f); }
        if (guarded(inst, in, out, n, &s) < 0) { crashed = 1; break; }
        for (int c = 0; c < nch; c++) {
            if (!ch[c].base) continue;
            if (fmt == VS_FMT_F32) {
                float *d = (float *)ch[c].base + (size_t)done * ch[c].stride;
                for (int i = 0; i < n; i++) { float v = out[i]; d[(size_t)i * ch[c].stride] = v > 1.f ? 1.f : (v < -1.f ? -1.f : (v == v ? v : 0.f)); }
            } else {
                int16_t *d = (int16_t *)ch[c].base + (size_t)done * ch[c].stride;
                for (int i = 0; i < n; i++) { float v = out[i] * 32768.f; v = v > 32767.f ? 32767.f : (v < -32768.f ? -32768.f : (v == v ? v : 0.f)); d[(size_t)i * ch[c].stride] = (int16_t)v; }
            }
        }
        done += n;
    }
    float lat = inst_latency_ms(inst);
    int instRun = inst->run;
    float f0i = 0.f, f0o = 0.f;
    if (inst->nat && !crashed) { VSNatStats ns; vs_nat_stats(inst->nat, &ns); f0i = ns.f0In; f0o = ns.f0Out; }
    ST(sl->busy, 0);

    if (crashed) {
        // le moteur a planté : il est banni (mémorisé), le reste du tampon est sécurisé
        degrade(s.engine, instRun, VS_REASON_CRASH);
        VSChan rest[8]; int k = nch < 8 ? nch : 8;
        for (int c = 0; c < k; c++) {
            size_t bps = fmt == VS_FMT_F32 ? 4 : 2;
            rest[c].base = (char *)ch[c].base + (size_t)done * ch[c].stride * bps; rest[c].stride = ch[c].stride;
        }
        failsafe(&s, fmt, rest, k, frames - done);
        dispatch_semaphore_signal(g_sem);
        return;
    }

    // ── chien de garde temps réel ──
    uint64_t t1 = now_ns();
    float budget = (float)frames / sr;
    float load = (float)((double)(t1 - t0) * 1e-9) / budget;
    sl->loadEma += (load - sl->loadEma) * 0.05f;
    sl->spikes = load > 1.2f ? sl->spikes + 1 : 0;
    sl->over = sl->loadEma > 0.75f ? sl->over + 1 : 0;
    if (sl->spikes >= 4 || sl->over >= 60) {
        degrade(s.engine, instRun, VS_REASON_OVERLOAD);
        sl->spikes = 0; sl->over = 0; sl->loadEma = 0.f;
        dispatch_semaphore_signal(g_sem);
    }
    g_stats.running = instRun;
    g_stats.loadPct = sl->loadEma * 100.f;
    g_stats.peakPct = fmaxf(g_stats.peakPct * 0.995f, load * 100.f);
    g_stats.engineLatencyMs = lat;
    g_stats.f0In = f0i; g_stats.f0Out = f0o;
    g_stats.sampleRate = sr;
    g_stats.buffers++;
    __atomic_thread_fence(__ATOMIC_RELEASE);
}

// ───────────────────────── mode test (hors temps réel) ─────────────────────────
int vs_engine_render_offline(const VSSettings *s, float sr, const float *in, float *out, int n, double *seconds, float *latencyMs) {
    int run = effective_run(s->engine);
    *seconds = 0; *latencyMs = 0;
    if (run == VS_RUN_FAILSAFE) { memcpy(out, in, sizeof(float) * (size_t)n); return run; }
    VSInst *inst = inst_create(run, sr);
    if (!inst) { memcpy(out, in, sizeof(float) * (size_t)n); return VS_RUN_FAILSAFE; }
    *latencyMs = inst_latency_ms(inst);
    uint64_t t0 = now_ns();
    for (int k = 0; k < n; k += 256) {
        int c = n - k < 256 ? n - k : 256;
        if (guarded(inst, in + k, out + k, c, s) < 0) {          // plantage pendant le test
            degrade(s->engine, run, VS_REASON_CRASH);
            memset(out + k, 0, sizeof(float) * (size_t)(n - k));
            *seconds = (double)(now_ns() - t0) * 1e-9;
            return VS_RUN_FAILSAFE;                               // instance volontairement abandonnée
        }
    }
    *seconds = (double)(now_ns() - t0) * 1e-9;
    inst_destroy(inst);
    return run;
}
