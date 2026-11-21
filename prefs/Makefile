TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AppInfoPressPrefs
AppInfoPressPrefs_FILES = AIPRootListController.m
AppInfoPressPrefs_FRAMEWORKS = UIKit
AppInfoPressPrefs_INSTALL_PATH = /Library/PreferenceBundles
AppInfoPressPrefs_CFLAGS = -fobjc-arc
AppInfoPressPrefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
