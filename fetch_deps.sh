#!/bin/sh
# Télécharge Signalsmith Stretch (MIT) et Signalsmith Linear dans ./vendor.
# Si quelque chose échoue, on sort sans erreur : la compilation utilise alors le moteur PSOLA de secours.
cd "$(dirname "$0")" || exit 0
if [ -f vendor/signalsmith-stretch.h ] && [ -d vendor/lin_repo ]; then exit 0; fi
rm -rf vendor /tmp/vs_stretch /tmp/vs_linear
mkdir -p vendor
git clone --depth=1 https://github.com/Signalsmith-Audio/signalsmith-stretch.git /tmp/vs_stretch >/dev/null 2>&1 || { rm -rf vendor; exit 0; }
git clone --depth=1 https://github.com/Signalsmith-Audio/linear.git /tmp/vs_linear >/dev/null 2>&1 || { rm -rf vendor; exit 0; }
cp /tmp/vs_stretch/signalsmith-stretch.h vendor/ || { rm -rf vendor; exit 0; }
mv /tmp/vs_linear vendor/lin_repo
rm -rf vendor/lin_repo/.git
if [ -f vendor/lin_repo/stft.h ]; then ln -s lin_repo vendor/signalsmith-linear; fi
if [ -z "$(find vendor/lin_repo -name stft.h | head -1)" ]; then rm -rf vendor; fi
exit 0
