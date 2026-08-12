export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = QuickClipboardPrefs

QuickClipboardPrefs_FILES = QCRootListController.m QCWebDAVController.m QCLANController.m QCLANLogViewController.m ../QCClipItem.m ../QCStore.m ../QCLANServer.m ../QCLANLogger.m
QuickClipboardPrefs_INSTALL_PATH = /Library/PreferenceBundles
QuickClipboardPrefs_FRAMEWORKS = UIKit
QuickClipboardPrefs_LIBRARIES = sqlite3 z
QuickClipboardPrefs_CFLAGS = -fobjc-arc -Wno-error -Wno-unused-variable -Wno-unused-function -Wno-deprecated-declarations -I..
QuickClipboardPrefs_LDFLAGS = -Wl,-U,_OBJC_CLASS_\$$_PSListController -Wl,-U,_OBJC_METACLASS_\$$_PSListController

include $(THEOS_MAKE_PATH)/bundle.mk
