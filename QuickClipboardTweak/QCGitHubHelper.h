#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface QCGitHubHelper : NSObject
+ (instancetype)sharedHelper;
@property (nonatomic, copy, readonly, nullable) NSString *accessToken;
- (void)loginWithPersonalAccessToken:(NSString *)token completion:(void (^)(BOOL success, NSString *message))completion;
- (void)createRepositoryNamed:(NSString *)name completion:(void (^)(BOOL success, NSString *message))completion;
- (void)uploadDebAtPath:(NSString *)path toRepo:(NSString *)repoName completion:(void (^)(BOOL success, NSString *message))completion;
@end

NS_ASSUME_NONNULL_END
