#!/bin/bash
set -e

# Ajuste si ton Theos n'est pas dans ~/theos
export THEOS="${THEOS:-$HOME/theos}"

cd "$(dirname "$0")"

# Les scripts DEBIAN doivent être exécutables (perdu après un zip/rar/git sur Windows)
chmod 755 layout/DEBIAN/postinst layout/DEBIAN/postrm

# App FakeCam (embarquée dans le .deb) : nécessite macOS + Xcode (xcrun) et ldid
if command -v xcrun >/dev/null 2>&1; then
  APP="$PWD/layout/Applications/FakeCam.app"
  rm -rf "$APP" && mkdir -p "$APP"
  (cd FakeCamPicker && \
    xcrun --sdk iphoneos clang -arch arm64 -fobjc-arc -miphoneos-version-min=14.0 \
      -framework UIKit -framework Foundation -framework PhotosUI -framework CoreImage \
      -framework CoreGraphics -framework QuartzCore -framework AVFoundation -framework CoreMedia \
      main.m -o "$APP/FakeCamPicker" && \
    cp Info.plist "$APP/Info.plist" && \
    ldid -Sentitlements.plist "$APP/FakeCamPicker")
else
  echo "⚠️  xcrun introuvable : l'app FakeCam ne sera pas incluse (utilise GitHub Actions)."
fi

echo "THEOS = $THEOS"
make clean
make package

echo ""
echo "Terminé. Le .deb se trouve dans ./packages/"
