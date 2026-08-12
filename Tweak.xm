#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <unistd.h>
#import "QuickClipboard.h"
#import "QCClipManager.h"
#import "QCLANServer.h"

static BOOL QCShouldCapturePasteboard(UIPasteboard *pb) {
    // Filter out internal/system pasteboards if needed
    return pb == [UIPasteboard generalPasteboard];
}

// v1.3.9: 全面 hook UIPasteboard 的所有写入入口。
// 旧版只 hook setString:/setImage:/setURL: 三个便捷方法, 但现代 App
// (尤其微信) 复制时走 setItems:/setItems:options:/setData:forPasteboardType: 等
// 底层方法, 导致 hook 抓不到剪贴板变化 → 手机复制电脑收不到。
// v1.3.10: 补 setItemProviders:/setItemProviders:options: (iOS 11+ 新 API,
// 微信等 App 在 iOS 15+ 复制走 NSItemProvider 路径, 旧 hook 依然抓不到)。
// 多个方法级联触发同一变化时, 由 QCClipManager 的 2 秒去重窗口 +
// 0.8 秒抑制窗口兜底, 不会重复推送。

%hook UIPasteboard

- (void)setString:(NSString *)string {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

- (void)setStrings:(NSArray *)strings {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

- (void)setImage:(UIImage *)image {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

- (void)setImages:(NSArray *)images {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

- (void)setURL:(NSURL *)url {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

- (void)setURLs:(NSArray *)urls {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

- (void)setData:(NSData *)data forPasteboardType:(NSString *)pasteboardType {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

- (void)setValue:(id)value forPasteboardType:(NSString *)pasteboardType {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

- (void)setItems:(NSArray *)items {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

- (void)setItems:(NSArray *)items options:(NSDictionary *)options {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

- (void)addItems:(NSArray *)items {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

- (void)addItems:(NSArray *)items options:(NSDictionary *)options {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

// v1.3.10: iOS 11+ NSItemProvider 路径 (微信 iOS 15+ 复制主要走这里)
- (void)setItemProviders:(NSArray *)itemProviders {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

- (void)setItemProviders:(NSArray *)itemProviders options:(NSDictionary *)options {
    %orig;
    if (QCShouldCapturePasteboard(self)) {
        [[QCClipManager sharedManager] capturePasteboard:self];
    }
}

%end

// v1.3.10: UNUserNotificationCenter delegate —— 让 SpringBoard 在前台也弹横幅
// (iOS 10+ 前台本地通知默认不展示, 需要 delegate willPresent 返回 banner)。
@interface QCNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation QCNotificationDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}
@end

static QCNotificationDelegate *QCNotifDelegate = nil;

%ctor {
    @autoreleasepool {
        NSLog(@"[QuickClipboard] Tweak loaded (pid %d, bundle %@)",
              (int)getpid(), [[NSBundle mainBundle] bundleIdentifier] ?: @"?");
        [[QCLANServer sharedServer] start];
        // Ensure QCClipManager is initialized so notification observers are registered
        [QCClipManager sharedManager];
        // v1.3.10: SpringBoard 进程设置通知 delegate, 保证前台也弹横幅
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            QCNotifDelegate = [[QCNotificationDelegate alloc] init];
            [[UNUserNotificationCenter currentCenter] setDelegate:QCNotifDelegate];
            NSLog(@"[QuickClipboard] UNUserNotificationCenter delegate 已设置 (SpringBoard)");
        }
        // v1.3.10: 剪贴板轮询兜底 —— 只在 SpringBoard 进程启动,
        // 不依赖 hook 也能发现剪贴板变化 (微信等 App 的复制 hook 抓不到时兜底)。
        if ([bundleID isEqualToString:@"com.apple.springboard"]) {
            [[QCClipManager sharedManager] startPasteboardPolling];
            NSLog(@"[QuickClipboard] 剪贴板轮询兜底已启动 (SpringBoard)");
        }
    }
}

%dtor {
    [[QCLANServer sharedServer] stop];
}
