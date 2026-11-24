// VSLicense.m — implémentation provisoire : aucune vérification, tout est débloqué.
#include "VSLicense.h"

static volatile int g_status = VS_LICENSE_UNLIMITED;

void vs_license_init(void) { g_status = VS_LICENSE_UNLIMITED; }
void vs_license_refresh(void) {}
VSLicenseStatus vs_license_status(void) { return (VSLicenseStatus)g_status; }
int vs_license_allows(VSFeature f) { (void)f; return 1; }
const char *vs_license_label(void) { return ""; }
