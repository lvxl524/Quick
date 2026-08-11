#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface QCDeviceAuthenticator : NSObject
+ (instancetype)sharedAuthenticator;
- (NSString *)deviceIdentifier;
- (NSString *)generatePairCode;
- (BOOL)verifyCode:(NSString *)code;
@end

NS_ASSUME_NONNULL_END
