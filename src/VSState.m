// VSState.m — réglages partagés (voir VSState.h).
#import <Foundation/Foundation.h>
#include <notify.h>
#include <stdio.h>
#include <math.h>
#include "VSState.h"

VSSettings g_set;
int g_isSpringBoard = 0;
static int g_token = 0;
static const char *kNote = "com.local.voiceshift.v9.changed";
static const char *kConf[] = {
    "/var/jb/var/mobile/Library/Preferences/voiceshift.v9.conf",
    "/var/mobile/Library/Preferences/voiceshift.v9.conf" };
static const char *kOldConf[] = {      // réglages de la 0.8 (migration)
    "/var/jb/var/mobile/Library/Preferences/voiceshift.v6.conf",
    "/var/mobile/Library/Preferences/voiceshift.v6.conf" };

// Préréglages réglés sur ta voix (≈ 96 Hz en moyenne) : cibles 170 / 190 / 215 Hz.
const VSPreset kVSPresets[VS_NPRESETS] = {
    { "Douce",      "posée, un peu grave",  10.f, 14.f, 0.30f, 4, 1, 3 },
    { "Naturelle",  "voix de femme moyenne", 12.f, 17.f, 0.20f, 3, 1, 4 },
    { "Pétillante", "jeune, plus aiguë",    14.f, 20.f, 0.15f, 2, 2, 5 },
};

void vs_state_defaults(VSSettings *s) {
    memset(s, 0, sizeof(*s));
    // par défaut : le combo préféré (moteur Rapide + préréglage Douce)
    s->enabled = 1; s->engine = VS_ENGINE_FAST; s->fastMode = 1; s->failSilence = 1;
    s->deesser = 1; s->gate = 1; s->eq = 1;
    const VSPreset *p = &kVSPresets[0];
    s->preset = 1; s->semitones = p->semitones; s->formantPct = p->formantPct; s->breath = p->breath;
    s->smooth = p->smooth; s->vibrato = p->vibrato; s->expr = p->expr;
}

static float clampf_(float v, float a, float b) { return v < a ? a : (v > b ? b : v); }
static int clampi_(int v, int a, int b) { return v < a ? a : (v > b ? b : v); }

void vs_state_clamp(VSSettings *s) {
    s->enabled = s->enabled ? 1 : 0;
    s->engine = clampi_(s->engine, 0, 2);
    s->fastMode &= 3;
    s->preset = clampi_(s->preset, 0, VS_NPRESETS);
    s->failSilence = s->failSilence ? 1 : 0;
    s->semitones = roundf(clampf_(s->semitones, -12.f, 16.f) * 2.f) / 2.f;
    s->formantPct = roundf(clampf_(s->formantPct, -20.f, 40.f));
    s->breath = roundf(clampf_(s->breath, 0.f, 1.f) * 20.f) / 20.f;
    s->smooth = clampi_(s->smooth, 0, 7); s->vibrato = clampi_(s->vibrato, 0, 7); s->expr = clampi_(s->expr, 0, 7);
    s->deesser = s->deesser ? 1 : 0; s->gate = s->gate ? 1 : 0; s->eq = s->eq ? 1 : 0;
}

void vs_state_snapshot(VSSettings *out) {
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    memcpy(out, &g_set, sizeof(*out));
}

void vs_state_apply_preset(int idx) {
    if (idx < 1 || idx > VS_NPRESETS) return;
    const VSPreset *p = &kVSPresets[idx - 1];
    VSSettings s = g_set;
    s.preset = idx; s.semitones = p->semitones; s.formantPct = p->formantPct; s.breath = p->breath;
    s.smooth = p->smooth; s.vibrato = p->vibrato; s.expr = p->expr; s.enabled = 1;
    vs_state_clamp(&s);
    g_set = s;
}

void vs_state_apply_favorite(void) {
    vs_state_apply_preset(1);
    g_set.engine = VS_ENGINE_FAST;
}

// ── position de l'icône flottante ──
static int g_fabToken = 0;
static int g_fabSide = 1; static float g_fabY = 0.30f;
static void (^g_fabCb)(void) = nil;
static const char *kFabNote = "com.local.voiceshift.v9.fab";
void vs_fab_get(int *side, float *yFrac) { *side = g_fabSide; *yFrac = g_fabY; }
static uint64_t fab_pack(void) { return (1ULL << 63) | ((uint64_t)(g_fabSide & 1) << 16) | (uint64_t)lroundf(g_fabY * 1000.f); }
static void fab_pull(void) {
    uint64_t v = 0;
    if (notify_get_state(g_fabToken, &v) != NOTIFY_STATUS_OK || !(v & (1ULL << 63))) return;
    g_fabSide = (int)((v >> 16) & 1); g_fabY = (float)(v & 0xFFFF) / 1000.f;
    if (g_fabY < 0.f || g_fabY > 1.f) g_fabY = 0.3f;
}
void vs_fab_set(int side, float yFrac) {
    g_fabSide = side ? 1 : 0; g_fabY = yFrac < 0.f ? 0.f : (yFrac > 1.f ? 1.f : yFrac);
    notify_set_state(g_fabToken, fab_pack());
    notify_post(kFabNote);
}
void vs_fab_on_change(void (^cb)(void)) { g_fabCb = cb; }

// ── format 64 bits publié par notifyd ──
// 63 valide · 0 actif · 1-2 moteur · 3-4 qualité Rapide · 5-6 préréglage · 7 silence si panne
// 8-15 demi-tons×2+64 · 16-21 formants+20 · 22-26 souffle×20 · 27-29 lissage · 30-32 vibrato
// 33-35 expressivité · 36 de-esser · 37 gate · 38 EQ · 39-62 réservé
uint64_t vs_state_pack(const VSSettings *s) {
    uint64_t v = 1ULL << 63;
    v |= (uint64_t)(s->enabled & 1);
    v |= (uint64_t)(s->engine & 3) << 1;
    v |= (uint64_t)(s->fastMode & 3) << 3;
    v |= (uint64_t)(s->preset & 3) << 5;
    v |= (uint64_t)(s->failSilence & 1) << 7;
    v |= (uint64_t)(((int)lroundf(s->semitones * 2.f) + 64) & 0xFF) << 8;
    v |= (uint64_t)(((int)lroundf(s->formantPct) + 20) & 0x3F) << 16;
    v |= (uint64_t)((int)lroundf(s->breath * 20.f) & 0x1F) << 22;
    v |= (uint64_t)(s->smooth & 7) << 27;
    v |= (uint64_t)(s->vibrato & 7) << 30;
    v |= (uint64_t)(s->expr & 7) << 33;
    v |= (uint64_t)(s->deesser & 1) << 36;
    v |= (uint64_t)(s->gate & 1) << 37;
    v |= (uint64_t)(s->eq & 1) << 38;
    return v;
}

int vs_state_unpack(uint64_t v, VSSettings *s) {
    if (!(v & (1ULL << 63))) return 0;
    s->enabled = (int)(v & 1);
    s->engine = (int)((v >> 1) & 3);
    s->fastMode = (int)((v >> 3) & 3);
    s->preset = (int)((v >> 5) & 3);
    s->failSilence = (int)((v >> 7) & 1);
    s->semitones = (float)((int)((v >> 8) & 0xFF) - 64) / 2.f;
    s->formantPct = (float)((int)((v >> 16) & 0x3F) - 20);
    s->breath = (float)((v >> 22) & 0x1F) / 20.f;
    s->smooth = (int)((v >> 27) & 7);
    s->vibrato = (int)((v >> 30) & 7);
    s->expr = (int)((v >> 33) & 7);
    s->deesser = (int)((v >> 36) & 1);
    s->gate = (int)((v >> 37) & 1);
    s->eq = (int)((v >> 38) & 1);
    vs_state_clamp(s);
    return 1;
}

// ── fichier de configuration (SpringBoard uniquement) ──
static int g_cfgVer = 0;
static int load_v9(VSSettings *s) {
    for (int k = 0; k < 2; k++) {
        FILE *f = fopen(kConf[k], "r");
        if (!f) continue;
        char line[96];
        g_cfgVer = 0;
        while (fgets(line, sizeof line, f)) {
            int i; float x;
            if (sscanf(line, "enabled=%d", &i) == 1) s->enabled = i;
            else if (sscanf(line, "engine=%d", &i) == 1) s->engine = i;
            else if (sscanf(line, "fastmode=%d", &i) == 1) s->fastMode = i;
            else if (sscanf(line, "preset=%d", &i) == 1) s->preset = i;
            else if (sscanf(line, "failsilence=%d", &i) == 1) s->failSilence = i;
            else if (sscanf(line, "semitones=%f", &x) == 1) s->semitones = x;
            else if (sscanf(line, "formantpct=%f", &x) == 1) s->formantPct = x;
            else if (sscanf(line, "breath=%f", &x) == 1) s->breath = x;
            else if (sscanf(line, "smooth=%d", &i) == 1) s->smooth = i;
            else if (sscanf(line, "vibrato=%d", &i) == 1) s->vibrato = i;
            else if (sscanf(line, "expr=%d", &i) == 1) s->expr = i;
            else if (sscanf(line, "deesser=%d", &i) == 1) s->deesser = i;
            else if (sscanf(line, "gate=%d", &i) == 1) s->gate = i;
            else if (sscanf(line, "eq=%d", &i) == 1) s->eq = i;
            else if (sscanf(line, "cfgver=%d", &i) == 1) g_cfgVer = i;
            else if (sscanf(line, "fabside=%d", &i) == 1) g_fabSide = i & 1;
            else if (sscanf(line, "faby=%f", &x) == 1) g_fabY = (x >= 0.f && x <= 1.f) ? x : 0.3f;
        }
        fclose(f);
        return 1;
    }
    return 0;
}
static int load_v6(VSSettings *s) {             // 0.8.0 : on garde « Rapide » et ses réglages
    for (int k = 0; k < 2; k++) {
        FILE *f = fopen(kOldConf[k], "r");
        if (!f) continue;
        char line[64]; int e = 1, m = 1; float semi = 7.f, form = 3.f;
        while (fgets(line, sizeof line, f)) {
            int i; float x;
            if (sscanf(line, "enabled=%d", &i) == 1) e = i;
            else if (sscanf(line, "semitones=%f", &x) == 1) semi = x;
            else if (sscanf(line, "formant=%f", &x) == 1) form = x;
            else if (sscanf(line, "mode=%d", &i) == 1) m = i;
        }
        fclose(f);
        s->enabled = e; s->fastMode = m & 3; s->preset = 0;
        s->engine = VS_ENGINE_NATURAL;        // nouveau moteur par défaut ; réglages V1 conservés en « perso »
        s->semitones = semi;
        s->formantPct = (exp2f(form / 12.f) - 1.f) * 100.f;   // demi-tons -> %
        return 1;
    }
    return 0;
}
static void save_file(void) {                   // ne réussit que hors sandbox (SpringBoard)
    VSSettings s = g_set;
    for (int k = 0; k < 2; k++) {
        FILE *f = fopen(kConf[k], "w");
        if (!f) continue;
        fprintf(f, "cfgver=2\n");
        fprintf(f, "enabled=%d\nengine=%d\nfastmode=%d\npreset=%d\nfailsilence=%d\nsemitones=%.1f\nformantpct=%.0f\n"
                   "breath=%.2f\nsmooth=%d\nvibrato=%d\nexpr=%d\ndeesser=%d\ngate=%d\neq=%d\nfabside=%d\nfaby=%.3f\n",
                s.enabled, s.engine, s.fastMode, s.preset, s.failSilence, s.semitones, s.formantPct,
                s.breath, s.smooth, s.vibrato, s.expr, s.deesser, s.gate, s.eq, g_fabSide, g_fabY);
        fclose(f);
        return;
    }
}

static void pull(void) {
    uint64_t st = 0;
    if (notify_get_state(g_token, &st) != NOTIFY_STATUS_OK) return;
    VSSettings s = g_set;
    if (vs_state_unpack(st, &s)) { g_set = s; __atomic_thread_fence(__ATOMIC_RELEASE); }
}

void vs_state_publish(void) {
    vs_state_clamp(&g_set);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    notify_set_state(g_token, vs_state_pack(&g_set));
    notify_post(kNote);
    if (g_isSpringBoard) save_file();
}

void vs_state_init(void (^onChange)(void)) {
    vs_state_defaults(&g_set);
    if (g_isSpringBoard) {
        if (load_v9(&g_set)) {
            // 0.9.2 : une seule fois, on passe au combo préféré (Rapide + Douce)
            if (g_cfgVer < 2) { int en = g_set.enabled; vs_state_apply_favorite(); g_set.enabled = en; }
        } else load_v6(&g_set);
        vs_state_clamp(&g_set);
    }
    notify_register_dispatch(kNote, &g_token, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        pull();
        if (g_isSpringBoard) save_file();
        if (onChange) onChange();
    });
    notify_register_dispatch(kFabNote, &g_fabToken, dispatch_get_main_queue(), ^(int t) {
        (void)t;
        fab_pull();
        if (g_isSpringBoard) save_file();
        if (g_fabCb) g_fabCb();
    });
    if (g_isSpringBoard) {                       // au démarrage : SpringBoard sème l'état pour toutes les apps
        notify_set_state(g_token, vs_state_pack(&g_set));
        notify_post(kNote);
        notify_set_state(g_fabToken, fab_pack());
    } else { pull(); fab_pull(); }
}
