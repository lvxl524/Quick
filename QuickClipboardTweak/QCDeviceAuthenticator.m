#import "QCDeviceAuthenticator.h"

@implementation QCDeviceAuthenticator

+ (instancetype)sharedAuthenticator {
    static QCDeviceAuthenticator *auth = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        auth = [[QCDeviceAuthenticator alloc] init];
    });
    return auth;
}

- (NSString *)deviceIdentifier {
    return [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"unknown";
}

- (NSString *)generatePairCode {
    uint32_t code = arc4random_uniform(900000) + 100000;
    return [NSString stringWithFormat:@"%06u", code];
}

- (BOOL)verifyCode:(NSString *)code {
    return code.length == 6;
}

@end
