#import "QuickClipboard.h"

NS_ASSUME_NONNULL_BEGIN

@interface QCClipManager : NSObject
+ (instancetype)sharedManager;
- (void)capturePasteboard:(UIPasteboard *)pasteboard;
- (void)writeItemToPasteboard:(QCClipItem *)item;
@end

NS_ASSUME_NONNULL_END
