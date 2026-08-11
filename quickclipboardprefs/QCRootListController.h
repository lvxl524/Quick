#import <UIKit/UIKit.h>

// PSListController exists at runtime in Preferences.framework (loaded by Settings app).
// We declare it here instead of linking Preferences to avoid compile-time linker errors.
@interface PSListController : UIViewController
- (id)specifiers;
@end

NS_ASSUME_NONNULL_BEGIN

@interface QCRootListController : PSListController
@end

NS_ASSUME_NONNULL_END
