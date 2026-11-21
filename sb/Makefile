TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AppInfoPressSB
AppInfoPressSB_FILES = Tweak.x AIPShared.m
AppInfoPressSB_CFLAGS = -fobjc-arc
AppInfoPressSB_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
