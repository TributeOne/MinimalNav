ARCHS = arm64
# Deployment target stays at 14.0 for every package scheme: the profile button is a
# plain UIButtonTypeCustom and uses imageEdgeInsets/adjustsImageWhenHighlighted, which
# the iOS 15+ SDK marks deprecated (and Theos turns into errors) but still honours.
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MinimalNav
$(TWEAK_NAME)_FILES = Tweak.x
$(TWEAK_NAME)_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
