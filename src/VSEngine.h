// VSEngine.h — gestion des moteurs (Rapide / Naturel / IA), sécurité et statistiques.
#ifndef VS_ENGINE_H
#define VS_ENGINE_H
#include <stdint.h>
#include "VSState.h"
#ifdef __cplusplus
extern "C" {
#endif

// Moteurs effectivement exécutés (le moteur demandé peut être rétrogradé automatiquement)
enum { VS_RUN_NONE = -1, VS_RUN_FAST = 0, VS_RUN_NATURAL = 1, VS_RUN_NATURAL_ECO = 2, VS_RUN_AI = 3, VS_RUN_FAILSAFE = 4 };

enum { VS_FMT_F32 = 1, VS_FMT_S16 = 2 };
typedef struct { void *base; int stride; } VSChan;     // stride en échantillons

typedef struct VSEngineStats {
    int      requested;        // moteur demandé (VS_ENGINE_*)
    int      running;          // moteur réellement utilisé (VS_RUN_*)
    float    loadPct;          // usage processeur du thread audio (moyenne glissante, % du temps réel)
    float    peakPct;          // pic récent
    float    engineLatencyMs;  // latence ajoutée par le moteur
    float    f0In, f0Out;      // hauteur détectée / produite (moteur Naturel)
    float    sampleRate;
    uint32_t buffers;          // tampons micro traités
    int      reason;           // dernière raison de rétrogradation (VS_REASON_*)
} VSEngineStats;

enum { VS_REASON_NONE = 0, VS_REASON_OVERLOAD, VS_REASON_CRASH, VS_REASON_CRASH_BEFORE, VS_REASON_CREATE_FAILED, VS_REASON_AI_UNAVAILABLE };

void vs_engine_init(void);                // au chargement du tweak (thread principal)
void vs_engine_prepare(void);             // depuis un hook non temps réel : démarre le thread de service
// Thread audio : traite le micro. ch[0] est transformé, les autres canaux reçoivent une copie.
void vs_engine_process(void *key, float sampleRate, int fmt, const VSChan *ch, int nch, int frames);
void vs_engine_stats(VSEngineStats *out);
void vs_engine_retry(void);               // efface les rétrogradations et les plantages mémorisés
const char *vs_engine_run_name(int run);
const char *vs_engine_reason_text(int reason);

extern volatile int g_vsTestActive;       // pendant le mode test, les hooks ne touchent pas au micro

// Mode test : traite un enregistrement complet hors temps réel avec le moteur demandé.
// Retourne le moteur utilisé (VS_RUN_*), *seconds = temps de calcul, *latencyMs = latence du moteur.
int vs_engine_render_offline(const VSSettings *s, float sampleRate, const float *in, float *out, int n,
                             double *seconds, float *latencyMs);

#ifdef __cplusplus
}
#endif
#endif
