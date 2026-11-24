// VSAIEngine.m — implémentation provisoire (étage 2 non activé dans la 0.9.0).
#include "VSAIEngine.h"
#include <stddef.h>

int vs_ai_available(void) { return 0; }
const char *vs_ai_status_text(void) { return "IA : pas encore disponible -> moteur Naturel utilisé"; }
VSAI *vs_ai_create(float sampleRate) { (void)sampleRate; return NULL; }
void vs_ai_destroy(VSAI *a) { (void)a; }
int vs_ai_process(VSAI *a, const float *in, float *out, int n) { (void)a; (void)in; (void)out; (void)n; return 1; }
float vs_ai_latency_ms(const VSAI *a) { (void)a; return 0.f; }
