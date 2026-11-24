# VoiceShift 0.9 — rapport

## 1. Audit de la 0.8.0 (avant toute modification)

| Constat | Conséquence |
|---|---|
| Moteur « Rapide » = Signalsmith Stretch réglé en `presetDefault` (blocs de 120 ms). | **Latence mesurée : 150 ms** (presque 2× l'objectif de 80 ms). |
| Ce moteur est un *vocodeur de phase* : il décale tout le spectre puis tente de recaler les formants. | Son « métallique / phasé », surtout sur les grands décalages. |
| Ta voix : **96 Hz** en moyenne (86 à 113 Hz). V1 = +7 demi-tons → **≈ 144 Hz**. | 144 Hz = zone masculine / androgyne. Une voix de femme parle à 165–255 Hz. D'où le « encore un peu masculine ». |
| Ton intonation varie sur 4,5 demi-tons ; la voix de référence féminine (ref1) sur ≈ 15. | Une voix décalée mais « plate » reste perçue comme masculine. |
| Allocation mémoire (`new`, `malloc`) et verrou **dans le thread audio** quand un nouveau flux micro apparaît ; lecture du format micro (`AudioUnitGetProperty`) dans le callback. | Risque de craquements au début d'un appel / d'un vocal. |
| Recyclage d'un moteur encore utilisé par un autre thread quand les 16 emplacements sont pleins. | Risque de plantage de l'app hôte après de nombreux vocaux. |
| Tous les canaux traités séparément (le micro est mono). | Calcul doublé pour rien sur certains flux. |
| `vs dsp.c` : ancien fichier jamais compilé. | Supprimé. |

## 2. Étage 1 — moteur « Naturel » (livré)

### Comment ça marche (simplement)
La voix = **une source** (les cordes vocales : hauteur + souffle) qui passe dans **un filtre** (la bouche et la gorge : les *formants*, qui donnent le timbre). Une femme n'a pas seulement une voix plus haute : son conduit vocal est plus court (formants **+12 à +20 %**), sa voix est plus soufflée et plus mélodique.

Le moteur sépare ces éléments et les règle **indépendamment** :

1. **Formants** : toutes les 4 ms, une analyse LPC (prédiction linéaire) mesure le « filtre ». On l'enlève : il reste la source pure.
2. **Hauteur (F0)** : la source est découpée période par période (PSOLA) et rejouée plus vite. Comme le timbre a été retiré avant, il ne bouge pas avec la hauteur, donc pas d'effet « chipmunk ».
   - repères de période au 1/10ᵉ d'échantillon près, ce qui supprime le grésillement ;
   - courbe de F0 **lissée** (réglable), **intonation élargie** (×1,0 à ×1,56), **vibrato** léger optionnel (5,3 Hz, ±25 cents max, seulement sur les voyelles tenues).
3. **Apériodicité** (idée du vocodeur WORLD) : au-dessus de ~3,5 kHz, la source est du bruit. Recopié, ce bruit sonne métallique. Il est donc **remplacé par du bruit neuf de même énergie**. Le réglage **Souffle** ajoute une aspiration naturelle et adoucit la source.
4. On remet le filtre **déformé** : formants multipliés par 1,12–1,20.
5. Finitions : coupe-bas 120 Hz (24 dB/oct), −2,5 dB vers 230 Hz (moins de « poitrine »), +3 dB de présence à 3,8 kHz, **de-esser**, **noise gate**, limiteur doux, volume aligné sur ta voix.

Pourquoi pas WORLD tel quel : ses fenêtres d'analyse (≈ 3 périodes) et son estimation de F0 ajoutent trop de latence. LPC + PSOLA, avec la même séparation source / filtre / bruit, tient en 32 ms.

### Mesures (banc d'essai sur ton enregistrement `me.mp3.m4a`)
| | Rapide V1 (+7 / +3) | Naturel « Naturelle » |
|---|---|---|
| Latence du moteur | **150 ms** | **32 ms** |
| Hauteur obtenue (médiane) | 144 Hz | 193 Hz |
| Processeur (PC, 1 cœur) | — | ≈ 0,9 % → estimé **3–5 %** sur iPhone X |

Latence totale estimée sur iPhone : 32 ms (moteur) + ≈ 10–25 ms (micro et tampons iOS) = **≈ 45–60 ms** (< 80 ms).
Le moteur n'alloue aucune mémoire dans le callback. Il utilise Accelerate/vDSP pour les corrélations, les produits matriciels de la déformation des formants et l'égaliseur. Les filtres récursifs (treillis LPC) sont en C scalaire, car vDSP n'a pas d'équivalent pour des coefficients qui changent à chaque échantillon.

Testé sans erreur mémoire (AddressSanitizer / UBSan) à 8, 16, 22,05, 24, 32, 44,1 et 48 kHz, sur des signaux extrêmes (silence, saturation, bruit pur, carré) et pendant 30 min en continu. Ce test est rejoué automatiquement sur GitHub (`dsp-test.yml`).

### Préréglages (calés sur ta voix à 96 Hz)
| | Hauteur | Formants | Souffle | Cible |
|---|---|---|---|---|
| Douce | +10 | +14 % | 30 % | ≈ 170 Hz |
| Naturelle (défaut) | +12 | +17 % | 20 % | ≈ 190 Hz |
| Pétillante | +14 | +20 % | 15 % | ≈ 215 Hz |

### Sécurité
- Les moteurs sont créés et détruits par un thread de service, jamais dans le thread audio.
- Chaque bloc audio est chronométré. Si le moteur dépasse 75 % du temps réel en moyenne (≈ 1 s), ou 120 % sur 4 blocs de suite, il est **rétrogradé** : IA → Naturel → Naturel éco → mode sécurité.
- Un plantage dans un moteur (SIGSEGV/SIGBUS/SIGILL/SIGFPE) est intercepté : le moteur est désactivé et **l'app continue**. C'est mémorisé dans le dossier de l'app, donc le moteur reste désactivé au lancement suivant (bouton « Réessayer »). Limite honnête : c'est la meilleure protection possible, pas une garantie absolue, car une corruption mémoire peut toucher l'app avant d'être détectée.
- Mode sécurité = **silence** par défaut, pour ne jamais révéler ta vraie voix en direct. On peut choisir « voix d'origine ».
- NaN / saturation : détectés et neutralisés à chaque échantillon.

### Emplacements réservés
- `src/license/VSLicense.{h,m}` : interface de licence (abonnement), tout est débloqué aujourd'hui. Seule la fonction `vs_license_allows()` est consultée, en cache et sans réseau, donc utilisable depuis le thread audio.
- `src/ai/VSAIEngine.{h,m}` : interface du moteur IA (voir §3).

## 3. Étage 2 — moteur « IA » : rapport honnête

### Ce qui a été mesuré
LLVC (Koe AI, arXiv 2311.00873) est le modèle de conversion de voix open source le plus léger en faible latence. J'ai reconstruit un modèle **de même architecture et de même taille** (Waveformer : encodeur à convolutions dilatées 512 canaux × 8, décodeur transformer 256, morceaux de 13 ms à 16 kHz). Les poids officiels n'étaient pas téléchargeables depuis cet environnement, mais la vitesse ne dépend que de l'architecture.

- 3,2 M paramètres, **≈ 7 GFLOP/s** à fournir en continu.
- Sur un cœur de PC récent : 3,1–4,7 ms par morceau de 13 ms, soit **0,24–0,36 × le temps réel**. C'est exactement le chiffre publié (« 2,8× plus rapide que le temps réel »), donc la reconstruction est fidèle.
- Le moteur Naturel, en comparaison, coûte ≈ 0,009 × le temps réel : **≈ 40× moins cher**.

### iPhone X (A11) : faisable ?
**Probablement non, en tout cas pas de façon fiable.**
- Le **Neural Engine de l'A11 n'est pas accessible** aux apps (Core ML l'utilise à partir de l'A12). Il reste le CPU et le GPU.
- CPU : un cœur « Monsoon » a environ 1/3 de la puissance vectorielle du cœur de PC mesuré et ≈ 0,5–0,6× sa vitesse sur le reste. Estimation : **0,6 à 1,0 × le temps réel**, avant le surcoût de Core ML (≈ 1–2 ms par appel) et la chauffe. C'est trop juste.
- GPU : le calcul serait assez rapide, mais chaque appel coûte plusieurs ms de lancement pour 13 ms d'audio. Et en live TikTok, le GPU sert déjà à la caméra et à l'encodage.
- Même s'il tenait : LLVC travaille à 16 kHz (son « téléphone large bande », moins riche que les 24 kHz du moteur Naturel). Le modèle pré-entraîné imite **une seule voix réelle** (une lectrice de LibriSpeech). Pour un produit sous abonnement, il faudrait entraîner une voix cible dont tu as les droits (quelques heures de GPU, impossible ici).
- **iPhone 7 (A10)** : non.

Pour trancher avec un vrai chiffre, la **0.9.1** ajoute le bouton **« Mesurer l'IA sur cet iPhone »**. Il compile ce modèle de test avec Core ML sur le téléphone, exécute 200 morceaux (CPU, puis CPU+GPU) et affiche le temps réel mesuré. Critère retenu : 95 % des morceaux en moins de 60 % de leur durée. Le modèle de test a des poids aléatoires : il ne sert qu'au chronomètre et ne touche jamais au micro.

### Sur quel iPhone ce serait faisable
- **iPhone XS / XR (A12)** : Neural Engine accessible, plausible.
- **iPhone 11 (A13) et plus récents** : confortable (CPU nettement plus rapide + accélérateur matriciel + Neural Engine).
- RVC (même « allégé ») : non, sur aucun iPhone sous 80 ms. Il repose sur HuBERT/ContentVec (≈ 95 M paramètres) et un vocodeur HiFi-GAN, soit des centaines de GFLOP/s. Même sur PC, on l'utilise avec 150–300 ms de tampon.

### Recommandation
Garder **Naturel** comme moteur principal sur iPhone X. Ne développer l'IA que si (1) le bouton de mesure donne ✓ sur ton iPhone X, ou si tu passes à un A12+, **et** (2) une voix cible sous licence est entraînée. L'interface `VSAIEngine` et la chaîne de repli sont prêtes : un futur modèle s'y branche sans toucher au reste.

Fichiers : `tools/ai_bench/llvc_proxy_bench.py` (mesure), `tools/ai_bench/convert_coreml.py` (conversion Core ML).
