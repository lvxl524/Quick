#import <UIKit/UIKit.h>
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

%end

%ctor {
    @autoreleasepool {
        NSLog(@"[QuickClipboard] Tweak loaded");
        [[QCLANServer sharedServer] start];
        // Ensure QCClipManager is initialized so notification observers are registered
        [QCClipManager sharedManager];
    }
}

%dtor {
    [[QCLANServer sharedServer] stop];
}
