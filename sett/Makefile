TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = Preferences

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AppInfoPressSettings
AppInfoPressSettings_FILES = Tweak.x AIPShared.m
AppInfoPressSettings_CFLAGS = -fobjc-arc
AppInfoPressSettings_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
