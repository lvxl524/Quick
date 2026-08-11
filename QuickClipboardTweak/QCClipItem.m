#import "QuickClipboard.h"
#import <CommonCrypto/CommonDigest.h>

NSString * const QCClipDidChangeNotification = @"com.mosheng.quickclipboard.clipChanged";
NSString * const QCWebDAVSyncRequestNotification = @"com.mosheng.quickclipboard.webdavSync";
NSString * const QCLANDevicePairedNotification = @"com.mosheng.quickclipboard.lanPaired";
NSString * const QCLANSyncReceivedNotification = @"com.mosheng.quickclipboard.lanSyncReceived";

@implementation QCClipItem

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _uuid = [[NSUUID UUID] UUIDString];
        _createdAt = [NSDate date];
        _updatedAt = [NSDate date];
        _favorite = NO;
        _deleted = NO;
        _type = QCClipTypePlainText;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.uuid forKey:@"uuid"];
    [coder encodeInteger:self.type forKey:@"type"];
    [coder encodeObject:self.payload forKey:@"payload"];
    [coder encodeObject:self.textRepresentation forKey:@"textRepresentation"];
    [coder encodeObject:self.createdAt forKey:@"createdAt"];
    [coder encodeObject:self.updatedAt forKey:@"updatedAt"];
    [coder encodeBool:self.favorite forKey:@"favorite"];
    [coder encodeBool:self.deleted forKey:@"deleted"];
    [coder encodeObject:self.deviceID forKey:@"deviceID"];
    [coder encodeObject:self.checkSum forKey:@"checkSum"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _uuid = [coder decodeObjectOfClass:[NSString class] forKey:@"uuid"];
        _type = [coder decodeIntegerForKey:@"type"];
        _payload = [coder decodeObjectOfClass:[NSData class] forKey:@"payload"];
        _textRepresentation = [coder decodeObjectOfClass:[NSString class] forKey:@"textRepresentation"];
        _createdAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"createdAt"];
        _updatedAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"updatedAt"];
        _favorite = [coder decodeBoolForKey:@"favorite"];
        _deleted = [coder decodeBoolForKey:@"deleted"];
        _deviceID = [coder decodeObjectOfClass:[NSString class] forKey:@"deviceID"];
        _checkSum = [coder decodeObjectOfClass:[NSString class] forKey:@"checkSum"];
    }
    return self;
}

- (NSDictionary *)toDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"uuid"] = self.uuid ?: @"";
    dict[@"type"] = @(self.type);
    dict[@"payload"] = [self.payload base64EncodedStringWithOptions:0] ?: @"";
    dict[@"textRepresentation"] = self.textRepresentation ?: @"";
    dict[@"createdAt"] = @((NSInteger)[self.createdAt timeIntervalSince1970]);
    dict[@"updatedAt"] = @((NSInteger)[self.updatedAt timeIntervalSince1970]);
    dict[@"favorite"] = @(self.favorite);
    dict[@"deleted"] = @(self.deleted);
    dict[@"deviceID"] = self.deviceID ?: @"";
    dict[@"checkSum"] = self.checkSum ?: @"";
    return dict;
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    QCClipItem *item = [[QCClipItem alloc] init];
    item.uuid = dict[@"uuid"] ?: [[NSUUID UUID] UUIDString];
    item.type = [dict[@"type"] integerValue];
    item.payload = [[NSData alloc] initWithBase64EncodedString:dict[@"payload"] options:0];
    item.textRepresentation = dict[@"textRepresentation"];
    item.createdAt = [NSDate dateWithTimeIntervalSince1970:[dict[@"createdAt"] integerValue]];
    item.updatedAt = [NSDate dateWithTimeIntervalSince1970:[dict[@"updatedAt"] integerValue]];
    item.favorite = [dict[@"favorite"] boolValue];
    item.deleted = [dict[@"deleted"] boolValue];
    item.deviceID = dict[@"deviceID"];
    item.checkSum = dict[@"checkSum"];
    return item;
}

- (NSString *)computeCheckSum {
    NSMutableData *data = [NSMutableData data];
    if (self.payload) [data appendData:self.payload];
    if (self.textRepresentation) {
        [data appendData:[self.textRepresentation dataUsingEncoding:NSUTF8StringEncoding]];
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    return output;
}

@end
