# Jailbreak ROOTLESS (iOS 15 / 16) : palera1n rootless (iPhone 8 = puce A11),
# Dopamine / Serotonin (A12 et +). Commente la ligne seulement pour palera1n ROOTFUL.
THEOS_PACKAGE_SCHEME = rootless

ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FakeCam
FakeCam_FILES = Tweak.xm
FakeCam_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FakeCam_FRAMEWORKS = UIKit AVFoundation QuartzCore CoreImage CoreGraphics CoreMedia ImageIO Photos

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Camera 2>/dev/null || true"
