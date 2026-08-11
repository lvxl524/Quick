export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = QuickClipboardPrefs

QuickClipboardPrefs_FILES = QCRootListController.m QCWebDAVController.m QCLANController.m QCBuildController.m
QuickClipboardPrefs_INSTALL_PATH = /Library/PreferenceBundles
QuickClipboardPrefs_FRAMEWORKS = UIKit
QuickClipboardPrefs_CFLAGS = -fobjc-arc -Wno-error -Wno-unused-variable -Wno-unused-function
QuickClipboardPrefs_LDFLAGS = -weak_framework Preferences

include $(THEOS_MAKE_PATH)/bundle.mk
