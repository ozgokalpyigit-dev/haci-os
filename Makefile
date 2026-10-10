TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HaciOS
HaciOS_FILES = HaciOS.x
HaciOS_CFLAGS = -fobjc-arc
HaciOS_FRAMEWORKS = UIKit Foundation QuartzCore WebKit

include $(THEOS_MAKE_PATH)/tweak.mk
