// VSLicense.h — EMPLACEMENT RÉSERVÉ pour un futur module de licence (abonnement).
// Rien n'est vérifié aujourd'hui : toutes les fonctions sont débloquées.
//
// Pour brancher un vrai système plus tard, il suffit de réimplémenter VSLicense.m :
//   - vs_license_refresh() : vérifier le reçu / jeton (hors thread audio, en arrière-plan) ;
//   - vs_license_allows()  : répondre instantanément depuis une valeur en cache
//                            (cette fonction peut être appelée depuis le thread audio : pas de réseau,
//                            pas de verrou, pas d'allocation).
// Le reste du tweak n'interroge la licence QUE par ces fonctions.
#ifndef VS_LICENSE_H
#define VS_LICENSE_H
#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    VS_FEATURE_ENGINE_FAST = 0,
    VS_FEATURE_ENGINE_NATURAL,
    VS_FEATURE_ENGINE_AI,
    VS_FEATURE_PRESETS,
    VS_FEATURE_TEST_MODE,
} VSFeature;

typedef enum {
    VS_LICENSE_UNLIMITED = 0,   // aujourd'hui : tout est permis
    VS_LICENSE_TRIAL,
    VS_LICENSE_ACTIVE,
    VS_LICENSE_EXPIRED,
} VSLicenseStatus;

void            vs_license_init(void);                 // appelé une fois au chargement
void            vs_license_refresh(void);              // à appeler hors du thread audio
VSLicenseStatus vs_license_status(void);
int             vs_license_allows(VSFeature f);        // sûr pour le thread audio
const char     *vs_license_label(void);                // texte affiché dans le panneau

#ifdef __cplusplus
}
#endif
#endif
