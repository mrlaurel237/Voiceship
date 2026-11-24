// Banc d'essai hors iPhone : traite un fichier PCM float32 mono brut comme le ferait le tweak.
// Usage : offline_test in.f32 out.f32 samplerate block semitones formantPct breath [smooth vib expr eco]
#include "../src/dsp/vs_natural.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
int main(int argc, char **argv) {
    if (argc < 8) { fprintf(stderr, "usage\n"); return 1; }
    FILE *f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); long nb = ftell(f); fseek(f, 0, SEEK_SET);
    int n = (int)(nb / 4); float *x = malloc(nb), *y = malloc(nb);
    fread(x, 4, n, f); fclose(f);
    float sr = atof(argv[3]); int B = atoi(argv[4]);
    VSNatParams p; vs_nat_default_params(&p);
    p.semitones = atof(argv[5]); p.formantPct = atof(argv[6]); p.breath = atof(argv[7]);
    if (argc > 8) p.smoothing = atof(argv[8]);
    if (argc > 9) p.vibrato = atof(argv[9]);
    if (argc > 10) p.expressivity = atof(argv[10]);
    if (argc > 11) p.economy = atoi(argv[11]);
    if (getenv("VS_NOPOST")) { p.deesser = 0; p.gate = 0; p.eq = 0; }
    VSNat *e = vs_nat_create(sr);
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    double worst = 0; int k = 0, bi = 0;
    while (k < n) {
        int c = B; if (getenv("VS_VARBLOCK")) c = 100 + (bi * 37) % 900;
        if (c > n - k) c = n - k;
        struct timespec a, b; clock_gettime(CLOCK_MONOTONIC, &a);
        vs_nat_process(e, x + k, y + k, c, &p);
        clock_gettime(CLOCK_MONOTONIC, &b);
        double dt = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) * 1e-9;
        double load = dt / (c / sr); if (load > worst && k > sr) worst = load;
        k += c; bi++;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double tt = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
    VSNatStats s; vs_nat_stats(e, &s);
    printf("latence %.1f ms | CPU moyen %.2f %% (pire bloc %.1f %%) | sous-alimentation %lld | défauts %lld\n",
           s.latencyMs, 100.0 * tt / (n / sr), 100.0 * worst, s.underruns, s.faults);
    f = fopen(argv[2], "wb"); fwrite(y, 4, n, f); fclose(f);
    vs_nat_destroy(e);
    return 0;
}
