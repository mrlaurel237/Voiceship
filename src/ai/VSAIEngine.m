// VSAIEngine.m — étage 2 (IA).
// Dans la 0.9.x, AUCUN modèle de conversion n'est livré : vs_ai_available() vaut 0 et le moteur Naturel est utilisé.
// Ce fichier contient le banc de mesure Core ML qui répond à la question « l'iPhone tient-il le temps réel ? ».
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#include <sys/utsname.h>
#include <mach/mach_time.h>
#include "VSAIEngine.h"

#define BENCH_DIR  @"/var/jb/Library/Application Support/VoiceShift"
#define BENCH_NAME @"vs_ai_bench"
static const double kChunkMs = 13.0;          // 208 échantillons à 16 kHz (morceau de LLVC)

int vs_ai_available(void) { return 0; }
const char *vs_ai_status_text(void) {
    return "IA (expérimental) : aucun modèle de conversion installé -> moteur Naturel utilisé. "
           "« Mesurer l'IA » teste la vitesse de cet iPhone.";
}
VSAI *vs_ai_create(float sampleRate) { (void)sampleRate; return NULL; }
void vs_ai_destroy(VSAI *a) { (void)a; }
int vs_ai_process(VSAI *a, const float *in, float *out, int n) { (void)a; (void)in; (void)out; (void)n; return 1; }
float vs_ai_latency_ms(const VSAI *a) { (void)a; return 0.f; }

static NSString *device_name(void) {
    struct utsname u; uname(&u);
    NSString *m = [NSString stringWithUTF8String:u.machine];
    NSDictionary *known = @{ @"iPhone9,1": @"iPhone 7 (A10)", @"iPhone9,3": @"iPhone 7 (A10)",
                             @"iPhone9,2": @"iPhone 7 Plus (A10)", @"iPhone9,4": @"iPhone 7 Plus (A10)",
                             @"iPhone10,3": @"iPhone X (A11)", @"iPhone10,6": @"iPhone X (A11)",
                             @"iPhone10,1": @"iPhone 8 (A11)", @"iPhone10,4": @"iPhone 8 (A11)",
                             @"iPhone10,2": @"iPhone 8 Plus (A11)", @"iPhone10,5": @"iPhone 8 Plus (A11)",
                             @"iPhone11,2": @"iPhone XS (A12)", @"iPhone11,8": @"iPhone XR (A12)",
                             @"iPhone12,1": @"iPhone 11 (A13)", @"iPhone13,2": @"iPhone 12 (A14)" };
    return known[m] ?: m;
}

static MLModel *load_model(MLComputeUnits units, NSString **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *caches = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *compiled = [caches stringByAppendingPathComponent:BENCH_NAME @".mlmodelc"];
    NSError *e = nil;
    if (![fm fileExistsAtPath:compiled]) {
        NSString *src = [BENCH_DIR stringByAppendingPathComponent:BENCH_NAME @".mlpackage"];
        if (![fm isReadableFileAtPath:src]) {
            // les apps (WhatsApp, TikTok…) sont isolées : elles n'ont pas le droit de lire les fichiers du tweak
            *err = @"modèle illisible ici : lance la mesure depuis l'écran d'accueil (ou réinstalle le .deb).";
            return nil;
        }
        NSURL *tmp = [MLModel compileModelAtURL:[NSURL fileURLWithPath:src] error:&e];   // compilation sur l'iPhone
        if (!tmp) { *err = [NSString stringWithFormat:@"compilation Core ML impossible : %@", e.localizedDescription]; return nil; }
        [fm removeItemAtPath:compiled error:nil];
        if (![fm moveItemAtURL:tmp toURL:[NSURL fileURLWithPath:compiled] error:&e]) compiled = tmp.path;
    }
    MLModelConfiguration *cfg = [MLModelConfiguration new];
    cfg.computeUnits = units;
    MLModel *m = [MLModel modelWithContentsOfURL:[NSURL fileURLWithPath:compiled] configuration:cfg error:&e];
    if (!m) *err = [NSString stringWithFormat:@"chargement impossible : %@", e.localizedDescription];
    return m;
}

// Exécute N morceaux en réinjectant les états (comme en streaming réel). Renvoie moyenne et 95e centile (ms).
static BOOL run_bench(MLModel *m, int N, double *mean, double *p95, NSString **err) {
    NSMutableDictionary<NSString *, MLFeatureValue *> *in = [NSMutableDictionary new];
    for (NSString *name in m.modelDescription.inputDescriptionsByName) {
        MLFeatureDescription *d = m.modelDescription.inputDescriptionsByName[name];
        NSError *e = nil;
        MLMultiArray *a = [[MLMultiArray alloc] initWithShape:d.multiArrayConstraint.shape dataType:MLMultiArrayDataTypeFloat32 error:&e];
        if (!a) { *err = @"mémoire insuffisante"; return NO; }
        float *p = (float *)a.dataPointer;
        for (NSInteger i = 0; i < a.count; i++) p[i] = [name isEqualToString:@"x"] ? (float)((i * 7919) % 200) / 1000.f - 0.1f : 0.f;
        in[name] = [MLFeatureValue featureValueWithMultiArray:a];
    }
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double *t = (double *)calloc((size_t)N, sizeof(double));
    for (int k = -20; k < N; k++) {                       // 20 tours de chauffe
        @autoreleasepool {
            NSError *e = nil;
            MLDictionaryFeatureProvider *fp = [[MLDictionaryFeatureProvider alloc] initWithDictionary:in error:&e];
            uint64_t t0 = mach_absolute_time();
            id<MLFeatureProvider> out = [m predictionFromFeatures:fp error:&e];
            uint64_t t1 = mach_absolute_time();
            if (!out) { free(t); *err = [NSString stringWithFormat:@"exécution impossible : %@", e.localizedDescription]; return NO; }
            for (NSString *name in in.allKeys) {          // états de sortie -> entrées du morceau suivant
                if ([name isEqualToString:@"x"]) continue;
                MLFeatureValue *v = [out featureValueForName:[@"o_" stringByAppendingString:name]];
                if (v) in[name] = v;
            }
            if (k >= 0) t[k] = (double)(t1 - t0) * tb.numer / tb.denom / 1e6;
        }
    }
    double s = 0; for (int k = 0; k < N; k++) s += t[k];
    *mean = s / N;
    for (int i = 1; i < N; i++) { double v = t[i]; int j = i - 1; while (j >= 0 && t[j] > v) { t[j + 1] = t[j]; j--; } t[j + 1] = v; }
    *p95 = t[(int)(N * 0.95)];
    free(t);
    return YES;
}

void vs_ai_benchmark(void (^done)(NSString *report)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableString *r = [NSMutableString stringWithFormat:@"%@ — modèle taille LLVC (3,2 M paramètres)\n", device_name()];
        struct { MLComputeUnits u; NSString *name; } modes[] = { { MLComputeUnitsCPUOnly, @"CPU" }, { MLComputeUnitsAll, @"CPU+GPU(+NE)" } };
        BOOL anyOK = NO;
        NSString *src = [BENCH_DIR stringByAppendingPathComponent:BENCH_NAME @".mlpackage"];
        if (![NSFileManager.defaultManager isReadableFileAtPath:[src stringByAppendingPathComponent:@"Manifest.json"]]) {
            [r appendString:@"Mesure impossible dans cette app : iOS l'empêche de lire les fichiers du tweak (c'est normal, ce n'est pas ton iPhone qui est en cause).\n"
                            "→ Ferme l'app, puis touche l'icône rose sur l'ÉCRAN D'ACCUEIL et relance la mesure."];
            dispatch_async(dispatch_get_main_queue(), ^{ done(r); });
            return;
        }
        for (int i = 0; i < 2; i++) {
            NSString *err = nil; double mean = 0, p95 = 0;
            MLModel *m = load_model(modes[i].u, &err);
            if (m && run_bench(m, 200, &mean, &p95, &err)) {
                // temps réel « sûr » : le 95e centile doit rester sous 60 % de la durée du morceau
                BOOL ok = p95 < 0.6 * kChunkMs;
                anyOK |= ok;
                [r appendFormat:@"%@ : %.1f ms / morceau de 13 ms (pire 5 %% : %.1f ms) → %.0f %% du temps réel %@\n",
                                modes[i].name, mean, p95, mean / kChunkMs * 100.0, ok ? @"✓" : @"✗"];
            } else [r appendFormat:@"%@ : %@\n", modes[i].name, err];
        }
        [r appendString:anyOK ? @"Verdict : assez rapide. (Un vrai modèle de voix reste à installer.)"
                              : @"Verdict : trop lent pour le direct → moteur Naturel conservé."];
        dispatch_async(dispatch_get_main_queue(), ^{ done(r); });
    });
}
