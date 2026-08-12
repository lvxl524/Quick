#import "QuickClipboard.h"

NS_ASSUME_NONNULL_BEGIN

@interface QCClipManager : NSObject
+ (instancetype)sharedManager;
- (void)capturePasteboard:(UIPasteboard *)pasteboard;
- (void)writeItemToPasteboard:(QCClipItem *)item;
- (void)writeItemToPasteboard:(QCClipItem *)item suppressBroadcast:(BOOL)suppress;
// v1.3.10: 剪贴板轮询兜底 (仅在 SpringBoard 进程调用)。
// 不依赖 UIPasteboard hook, 通过 changeCount 轮询发现剪贴板变化。
- (void)startPasteboardPolling;
@end

NS_ASSUME_NONNULL_END
