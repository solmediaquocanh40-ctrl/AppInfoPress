TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += sb sett prefs

include $(THEOS_MAKE_PATH)/aggregate.mk
