// VSState.h — réglages de VoiceShift partagés entre toutes les apps.
// SpringBoard (non sandboxé) sauvegarde sur disque ; les apps reçoivent l'état via notifyd (64 bits).
#ifndef VS_STATE_H
#define VS_STATE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

enum { VS_ENGINE_FAST = 0, VS_ENGINE_NATURAL = 1, VS_ENGINE_AI = 2 };

typedef struct VSSettings {
    int   enabled;
    int   engine;        // moteur demandé : Rapide / Naturel / IA
    int   fastMode;      // qualité du moteur Rapide (A..D)
    int   preset;        // 0 = personnalisé, 1..3 = préréglages féminins
    int   failSilence;   // en cas de panne : 1 = silence (ne révèle pas la vraie voix), 0 = voix d'origine
    float semitones;     // -12..+16
    float formantPct;    // -20..+40 %
    float breath;        // 0..1
    int   smooth;        // 0..7  lissage de la F0
    int   vibrato;       // 0..7
    int   expr;          // 0..7  expressivité (amplitude de l'intonation)
    int   deesser, gate, eq;
} VSSettings;

typedef struct VSPreset {
    const char *name, *hint;
    float semitones, formantPct, breath;
    int smooth, vibrato, expr;
} VSPreset;

#define VS_NPRESETS 3
extern const VSPreset kVSPresets[VS_NPRESETS];

extern VSSettings g_set;                     // lu par le thread audio, écrit par le thread principal
extern int g_isSpringBoard;

void vs_state_defaults(VSSettings *s);
void vs_state_clamp(VSSettings *s);
void vs_state_snapshot(VSSettings *out);     // copie cohérente pour le thread audio
void vs_state_apply_preset(int idx);         // 1..3
uint64_t vs_state_pack(const VSSettings *s);
int  vs_state_unpack(uint64_t st, VSSettings *s);
void vs_state_init(void (^onChange)(void));  // charge, s'abonne aux changements
void vs_state_publish(void);                 // après une modification locale
// conversions vers les paramètres DSP
static inline float vs_set_smoothing(const VSSettings *s) { return (float)s->smooth / 7.f; }
static inline float vs_set_vibrato(const VSSettings *s)   { return (float)s->vibrato / 7.f; }
static inline float vs_set_expressivity(const VSSettings *s) { return 1.f + 0.08f * (float)s->expr; }

#ifdef __cplusplus
}
#endif
#endif
