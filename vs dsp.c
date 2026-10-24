// VoiceShift DSP: décaleur de hauteur (pitch shifter) à deux têtes de lecture
// avec fondu enchaîné (Hann). Décale aussi les formants, ce qui est voulu
// pour un changement de genre de la voix.
#ifndef VS_DSP_H
#define VS_DSP_H
#include <math.h>
#include <string.h>

#define VS_BUF 8192             // taille du tampon circulaire (puissance de 2)
#define VS_MASK (VS_BUF - 1)

typedef struct {
    float buf[VS_BUF];
    int   w;        // position d'écriture
    float phase;    // phase du balayage, 0..1
    float winLen;   // longueur de la fenêtre en échantillons
    float ratio;    // rapport de hauteur courant (lissé)
    int   inited;
} VSPitch;

static inline void vs_pitch_init(VSPitch *p, float sampleRate) {
    memset(p, 0, sizeof(*p));
    float w = sampleRate * 0.034f;          // ~34 ms : bon compromis pour la voix
    if (w < 256.f) w = 256.f;
    if (w > 4096.f) w = 4096.f;
    p->winLen = w;
    p->ratio = 1.f;
    p->inited = 1;
}

static inline float vs_win(float ph) {      // fenêtre de Hann, somme des 2 têtes = 1
    float s = sinf(3.14159265f * ph);
    return s * s;
}

static inline float vs_read(const VSPitch *p, float delay) {
    float pos = (float)p->w - delay;
    int   i0 = (int)floorf(pos);
    float fr = pos - (float)i0;
    float a = p->buf[i0 & VS_MASK];
    float b = p->buf[(i0 + 1) & VS_MASK];
    return a + (b - a) * fr;
}

// Traite n échantillons contigus. 'target' = rapport de hauteur voulu (2^(demitons/12)).
static inline void vs_pitch_chunk(VSPitch *p, const float *in, float *out, int n, float target) {
    float r  = p->ratio;
    float dr = (target - r) / (float)(n > 0 ? n : 1);   // changement progressif, sans clic
    float inv = 1.f / p->winLen;
    for (int i = 0; i < n; i++) {
        p->buf[p->w & VS_MASK] = in[i];
        p->w++;
        r += dr;
        p->phase += (1.f - r) * inv;
        if (p->phase >= 1.f) p->phase -= 1.f;
        if (p->phase <  0.f) p->phase += 1.f;
        float ph2 = p->phase + 0.5f; if (ph2 >= 1.f) ph2 -= 1.f;
        float y = vs_read(p, p->phase * p->winLen) * vs_win(p->phase)
                + vs_read(p, ph2      * p->winLen) * vs_win(ph2);
        out[i] = y;
    }
    p->ratio = target;
}
#endif
