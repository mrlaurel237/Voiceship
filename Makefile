export THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

# Télécharge la bibliothèque de transformation de voix (si le réseau le permet)
VS_FETCH := $(shell sh $(CURDIR)/fetch_deps.sh)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VoiceShift
VoiceShift_FILES = Tweak.xm
VoiceShift_FRAMEWORKS = UIKit AudioToolbox AVFoundation CoreMedia
VoiceShift_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

ifneq ($(wildcard $(CURDIR)/vendor/signalsmith-stretch.h),)
VoiceShift_CFLAGS += -DVS_STRETCH=1 -I$(CURDIR)/vendor -I$(CURDIR)/vendor/lin_repo -I$(CURDIR)/vendor/lin_repo/include
VoiceShift_CXXFLAGS += -std=c++17
VoiceShift_OBJCXXFLAGS += -std=c++17
endif

include $(THEOS_MAKE_PATH)/tweak.mk
