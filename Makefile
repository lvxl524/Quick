export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64 arm64e

INSTALL_TARGET_PROCESSES = SpringBoard backboardd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QuickClipboardTweak

QuickClipboardTweak_FILES = Tweak.xm QCClipItem.m QCClipManager.m QCStore.m QCWebDAVClient.m QCLANServer.m QCGitHubHelper.m QCDeviceAuthenticator.m
QuickClipboardTweak_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-nullability-completeness -Wno-error=nonnull -Wno-error -Wno-unused-variable -Wno-unused-function
QuickClipboardTweak_PRIVATE_FRAMEWORKS = AppSupport
QuickClipboardTweak_FRAMEWORKS = UIKit
QuickClipboardTweak_LIBRARIES = sqlite3 z

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += quickclipboardprefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard"
