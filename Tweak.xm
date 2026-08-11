#import <UIKit/UIKit.h>
#import "QuickClipboard.h"
#import "QCClipManager.h"
#import "QCLANServer.h"

static BOOL QCShouldCapturePasteboard(UIPasteboard *pb) {
    // Filter out internal/system pasteboards if needed
    return pb == [UIPasteboard generalPasteboard];
}

%hook UIPasteboard

- (void)setString:(NSString *)string {
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

- (void)setURL:(NSURL *)url {
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
