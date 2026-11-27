# FakeCam v8 (iPhone 8, jailbreaké rootless)

**Un seul fichier : le `.deb`.** Il contient :

1. le **tweak** : remplace l'aperçu de l'app **Appareil photo** par ta photo **et enregistre cette même vue quand tu prends la photo** ;
2. l'**app FakeCam** (icône sur l'écran d'accueil) : tu y choisis la photo et tu actives / coupes l'effet.

> ⚠️ À utiliser pour du test, une démo ou un usage personnel. Pas pour contourner une vérification d'identité ni tromper quelqu'un.

## Compiler (GitHub Actions)

1. Pousse tout le dossier sur ton repo (dont `.github/workflows/build.yml` et `layout/`).
2. Onglet **Actions** → **Build FakeCam** → **Run workflow**.
3. Quand c'est vert, télécharge l'artifact `fakecam-deb` (le `.deb`).

## Installer

Ouvre le `.deb` avec Zebra / Sileo → installe → **respring**. L'app **FakeCam** apparaît sur l'écran d'accueil
(sinon : respring ou `uicache -a`). Si tu avais installé une ancienne version de l'app via TrollStore, supprime-la d'abord.

## Utiliser

1. Ouvre l'app **FakeCam** → **Choisir une photo / vidéo** (vidéo : convertie en 720p, sans son, 60 s max, lue en boucle).
2. Règle le média dans l'app :
   - **Zoom** 1× à 4×, **Rotation** −180° à +180° (+ boutons ↺ / ↻ 90°), **Position X / Y** ;
   - **Filtre** : Noir & blanc, Noir, Sépia, Chrome, Instantané, Vif, Chaud, Froid ;
   - **Réinitialiser les réglages** remet tout à zéro.
3. Chaque réglage est appliqué automatiquement dans l'Appareil photo (message ✅ en bas de l'écran).
   Le média est **recadré automatiquement à la taille réelle de l'aperçu** : il s'adapte à chaque mode (Photo, Vidéo, Carré...) sans déformation.
4. Ouvre l'**Appareil photo** : ta photo remplace l'aperçu. Tu peux aussi pincer / glisser directement dans l'Appareil photo.
5. Quand tu appuies sur le déclencheur, **la photo sauvegardée est exactement ce que tu vois à l'écran** (recadrage, zoom, rotation, décalage, filtre ; en mode vidéo, l'image courante) — pas l'image du capteur. La vignette dans le coin correspond aussi.
6. L'interrupteur coupe / réactive l'effet, **Supprimer la photo** remet la vraie caméra (et la vraie photo enregistrée).

Un nouveau média remet les réglages à zéro. L'original est conservé : tu peux rouvrir l'app et continuer à régler.

## Comment ça marche

L'app écrit `original.jpg` (ou `video.mp4`), `settings.plist` (et un fichier `disabled` pour couper) dans :

```
/var/jb/var/mobile/Library/FakeCam/
/var/mobile/Media/FakeCam/
```

puis envoie une notification Darwin (`com.lemaso.fakecam.reload`). Le tweak, chargé dans l'app Appareil photo, recharge le média et les réglages aussitôt (ou au retour de l'app au premier plan), et les applique à la taille de l'aperçu. Au déclenchement, il fige ce rendu et intercepte `AVCapturePhoto` (et l'écriture dans Photos) pour enregistrer cette image à la place de la capture réelle.

L'app est installée par le jailbreak (`/var/jb/Applications`) avec l'entitlement `no-sandbox` (`FakeCamPicker/entitlements.plist`) pour écrire dans ces dossiers.

## Dépannage

- **Rien ne change dans l'Appareil photo** : fais un respring, ferme complètement l'Appareil photo, rouvre-le en mode Photo.
- **L'app affiche ❌ Écriture impossible** : désinstalle toute ancienne copie de l'app (TrollStore comprise), réinstalle le `.deb`, puis respring.
- **Mode rootful** (palera1n `-f`) : commente `THEOS_PACKAGE_SCHEME = rootless` dans le `Makefile` et recompile. L'app écrit alors dans `/var/mobile/Media/FakeCam/`.

## Compatibilité

iPhone 8 / iOS 15 → 16.x, jailbreak rootless (palera1n ; Dopamine et Serotonin demandent une puce A12 ou plus). Dépendance : `mobilesubstrate` (ElleKit), `uikittools` (uicache).
