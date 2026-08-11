#import "QuickClipboard.h"

NS_ASSUME_NONNULL_BEGIN

@interface QCWebDAVClient : NSObject
+ (instancetype)sharedClient;
- (void)configureWithURL:(NSString *)url username:(NSString *)username password:(NSString *)password rootDir:(NSString *)rootDir encryptionKey:(nullable NSString *)key;
- (BOOL)isConfigured;
- (void)testConnectionWithCompletion:(void (^)(BOOL success, NSString *message))completion;
- (void)pushWithCompletion:(nullable void (^)(BOOL success, NSString *message))completion;
- (void)pullWithCompletion:(nullable void (^)(BOOL success, NSString *message))completion;
- (void)performAutoSyncIfEnabled;
@end

NS_ASSUME_NONNULL_END
