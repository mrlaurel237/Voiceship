// VSAIEngine.h — moteur « IA » (conversion de voix par réseau de neurones), EXPÉRIMENTAL.
// Étage 2 : tant que vs_ai_available() renvoie 0, VoiceShift utilise automatiquement le moteur Naturel.
// Contrat identique aux autres moteurs : création hors thread audio, traitement sans allocation.
#ifndef VS_AI_ENGINE_H
#define VS_AI_ENGINE_H
#ifdef __cplusplus
extern "C" {
#endif

typedef struct VSAI VSAI;

int    vs_ai_available(void);                 // 1 seulement si un VRAI modèle de conversion est installé ET a passé le test de vitesse
const char *vs_ai_status_text(void);          // explication courte affichée dans le panneau
VSAI  *vs_ai_create(float sampleRate);        // NULL si indisponible
void   vs_ai_destroy(VSAI *a);
int    vs_ai_process(VSAI *a, const float *in, float *out, int n);
float  vs_ai_latency_ms(const VSAI *a);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import <Foundation/Foundation.h>
// Mesure réelle sur cet iPhone avec le modèle de test (taille LLVC, poids aléatoires : il ne sert qu'au chronomètre).
// Appelle done() sur le thread principal avec un rapport lisible.
void vs_ai_benchmark(void (^done)(NSString *report));
#endif
#endif
