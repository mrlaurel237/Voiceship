// vs_accel.h — accès à Accelerate/vDSP.
// Sur iPhone : vraies fonctions vDSP (vectorisées NEON par Apple).
// Ailleurs (banc de test Linux) : versions C simples, mêmes signatures, mêmes résultats.
#ifndef VS_ACCEL_H
#define VS_ACCEL_H

#ifdef __APPLE__
#include <Accelerate/Accelerate.h>
#else
#include <stddef.h>
#include <stdlib.h>
typedef long vDSP_Stride;
typedef unsigned long vDSP_Length;
typedef struct vDSP_biquad_SetupStruct { int M; double c[5 * 8]; } *vDSP_biquad_Setup;

static inline void vDSP_dotpr(const float *a, vDSP_Stride ia, const float *b, vDSP_Stride ib, float *r, vDSP_Length n) {
    float s = 0.f;
    for (vDSP_Length i = 0; i < n; i++) s += a[i * ia] * b[i * ib];
    *r = s;
}
static inline void vDSP_svesq(const float *a, vDSP_Stride ia, float *r, vDSP_Length n) {
    float s = 0.f;
    for (vDSP_Length i = 0; i < n; i++) s += a[i * ia] * a[i * ia];
    *r = s;
}
// C (M×N) = A (M×P) · B (P×N), matrices en ligne
static inline void vDSP_mmul(const float *A, vDSP_Stride ia, const float *B, vDSP_Stride ib, float *C, vDSP_Stride ic,
                             vDSP_Length M, vDSP_Length N, vDSP_Length P) {
    (void)ia; (void)ib; (void)ic;
    for (vDSP_Length m = 0; m < M; m++)
        for (vDSP_Length n = 0; n < N; n++) {
            float s = 0.f;
            for (vDSP_Length p = 0; p < P; p++) s += A[m * P + p] * B[p * N + n];
            C[m * N + n] = s;
        }
}
static inline void vDSP_vmul(const float *a, vDSP_Stride ia, const float *b, vDSP_Stride ib, float *c, vDSP_Stride ic, vDSP_Length n) {
    for (vDSP_Length i = 0; i < n; i++) c[i * ic] = a[i * ia] * b[i * ib];
}
static inline void vDSP_vsma(const float *a, vDSP_Stride ia, const float *s, const float *b, vDSP_Stride ib, float *c, vDSP_Stride ic, vDSP_Length n) {
    for (vDSP_Length i = 0; i < n; i++) c[i * ic] = a[i * ia] * *s + b[i * ib];
}
static inline vDSP_biquad_Setup vDSP_biquad_CreateSetup(const double *coef, vDSP_Length M) {
    vDSP_biquad_Setup s = (vDSP_biquad_Setup)calloc(1, sizeof(*s));
    s->M = (int)M;
    for (vDSP_Length i = 0; i < 5 * M; i++) s->c[i] = coef[i];
    return s;
}
static inline void vDSP_biquad_DestroySetup(vDSP_biquad_Setup s) { free(s); }
// delay : 2*M+2 valeurs (même convention qu'Apple : x[n-1], x[n-2] puis y[n-1], y[n-2] de chaque section)
static inline void vDSP_biquad(vDSP_biquad_Setup s, float *delay, const float *x, vDSP_Stride ix, float *y, vDSP_Stride iy, vDSP_Length n) {
    for (vDSP_Length i = 0; i < n; i++) {
        float v = x[i * ix];
        for (int m = 0; m < s->M; m++) {
            const double *c = &s->c[5 * m];
            float *d = &delay[2 * m];
            float x1 = d[0], x2 = d[1], y1 = d[2], y2 = d[3];
            float o = (float)(c[0] * v + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2);
            d[0] = v; d[1] = x1;
            if (m == s->M - 1) { d[2] = o; d[3] = y1; }
            v = o;
        }
        y[i * iy] = v;
    }
}
#endif
#endif
