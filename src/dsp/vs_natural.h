// vs_natural.h — moteur « Naturel » de VoiceShift (analyse / synthèse source-filtre).
//
// Idée générale (expliquée simplement) :
//   La voix = une SOURCE (les cordes vocales : hauteur F0 + souffle/bruit)
//           passée dans un FILTRE (le conduit vocal : bouche, gorge -> les formants).
//   1. On estime le filtre (enveloppe spectrale) par prédiction linéaire (LPC) toutes les 4 ms.
//   2. On "retire" ce filtre : il reste la source seule (le "résiduel").
//   3. On change la hauteur de la source seule (PSOLA, période par période), avec une courbe
//      de F0 lissée, plus expressive, et un léger vibrato optionnel.
//   4. Apériodicité : au-dessus de ~3,5 kHz la source est surtout du bruit ; on remplace ce bruit
//      recopié (qui sonnerait métallique) par du bruit neuf de même énergie, plus du souffle.
//   5. On remet un filtre... mais déformé : formants remontés de +12 à +20 % (conduit vocal plus court).
//   6. Finitions : coupe-bas 120 Hz, présence 3-5 kHz, de-esser, noise gate, limiteur.
//
// Contraintes temps réel : aucune allocation après vs_nat_create(), aucun verrou, aucun appel système.
// Toute la mémoire est dans la structure (≈ 400 Ko par instance).
#ifndef VS_NATURAL_H
#define VS_NATURAL_H
#ifdef __cplusplus
extern "C" {
#endif

typedef struct VSNatParams {
    float semitones;     // hauteur : -12..+16 demi-tons
    float formantPct;    // formants : -20..+40 % (une voix féminine : +12 à +20 %)
    float breath;        // souffle : 0..1
    float smoothing;     // lissage de la courbe de F0 : 0..1
    float vibrato;       // vibrato : 0..1 (0 = aucun ; 1 = ±25 cents)
    float expressivity;  // amplitude de l'intonation : 1.0 = identique, 1.4 = 40 % plus mélodique
    int   deesser;       // 1 = atténue les « s » sifflants
    int   gate;          // 1 = noise gate (coupe le bruit de fond entre les phrases)
    int   eq;            // 1 = coupe-bas 120 Hz + présence 3-5 kHz
    int   economy;       // 1 = mode économique (moins de calcul : pour iPhone surchargé)
} VSNatParams;

typedef struct VSNat VSNat;

typedef struct VSNatStats {
    float latencyMs;     // latence algorithmique du moteur
    float f0In;          // dernière hauteur détectée (Hz, 0 = non voisé)
    float f0Out;         // hauteur produite (Hz)
    long long underruns; // échantillons sortis sans traitement complet (devrait rester ~0)
    long long faults;    // valeurs invalides corrigées (NaN, saturation)
} VSNatStats;

// Création / destruction : à appeler HORS du thread audio (allocation).
VSNat *vs_nat_create(float sampleRate);
void   vs_nat_destroy(VSNat *e);
// Remet l'état à zéro (pas d'allocation, utilisable n'importe où).
void   vs_nat_reset(VSNat *e);
// Traite n échantillons mono (n quelconque). in et out peuvent être le même tableau.
// Retourne 0 si tout va bien, sinon un code d'erreur (le tampon de sortie reste valide).
int    vs_nat_process(VSNat *e, const float *in, float *out, int n, const VSNatParams *p);
float  vs_nat_latency_ms(const VSNat *e);
void   vs_nat_stats(const VSNat *e, VSNatStats *s);
void   vs_nat_default_params(VSNatParams *p);

#ifdef __cplusplus
}
#endif
#endif
