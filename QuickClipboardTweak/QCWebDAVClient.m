#import "QCWebDAVClient.h"
#import "QCStore.h"
#import <CommonCrypto/CommonCryptor.h>

static NSString * const kWebDAVPrefsKey = @"webdavConfig";

@interface QCWebDAVClient () {
    NSURL *_baseURL;
    NSString *_username;
    NSString *_password;
    NSString *_rootDir;
    NSString *_encryptionKey;
    NSURLSession *_session;
    dispatch_queue_t _queue;
}
@end

@implementation QCWebDAVClient

+ (instancetype)sharedClient {
    static QCWebDAVClient *client = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        client = [[QCWebDAVClient alloc] init];
    });
    return client;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.mosheng.quickclipboard.webdav", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 30;
        _session = [NSURLSession sessionWithConfiguration:cfg];
        [self loadFromPrefs];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loadFromPrefs) name:QCWebDAVSyncRequestNotification object:nil];
    }
    return self;
}

- (void)configureWithURL:(NSString *)url username:(NSString *)username password:(NSString *)password rootDir:(NSString *)rootDir encryptionKey:(NSString *)key {
    _baseURL = [NSURL URLWithString:url];
    _username = username;
    _password = password;
    _rootDir = rootDir.length ? rootDir : @"quickclipboard";
    _encryptionKey = key;
    [self persist];
}

- (void)persist {
    NSDictionary *dict = @{
        @"url": _baseURL.absoluteString ?: @"",
        @"username": _username ?: @"",
        @"password": _password ?: @"",
        @"rootDir": _rootDir ?: @"quickclipboard",
        @"encryptionKey": _encryptionKey ?: @""
    };
    NSMutableDictionary *prefs = [self prefs];
    prefs[kWebDAVPrefsKey] = dict;
    [prefs writeToFile:QC_PREFS_PATH atomically:YES];
}

- (void)loadFromPrefs {
    NSDictionary *cfg = [self prefs][kWebDAVPrefsKey];
    if (cfg) {
        _baseURL = [NSURL URLWithString:cfg[@"url"]];
        _username = cfg[@"username"];
        _password = cfg[@"password"];
        _rootDir = cfg[@"rootDir"] ?: @"quickclipboard";
        _encryptionKey = cfg[@"encryptionKey"];
    }
}

- (NSMutableDictionary *)prefs {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:QC_PREFS_PATH];
    return dict ? [dict mutableCopy] : [NSMutableDictionary dictionary];
}

- (BOOL)isConfigured {
    return _baseURL != nil && _username.length > 0 && _password.length > 0;
}

- (NSURL *)remoteURLForPath:(NSString *)path {
    NSString *fullPath = [NSString stringWithFormat:@"%@/%@", _rootDir, path];
    return [NSURL URLWithString:fullPath relativeToURL:_baseURL].absoluteURL;
}

- (NSURLRequest *)requestWithURL:(NSURL *)url method:(NSString *)method body:(nullable NSData *)body {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = method;
    NSString *auth = [NSString stringWithFormat:@"%@:%@", _username, _password];
    NSString *base64 = [[auth dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    [req setValue:[NSString stringWithFormat:@"Basic %@", base64] forHTTPHeaderField:@"Authorization"];
    if (body) req.HTTPBody = body;
    return req;
}

- (void)testConnectionWithCompletion:(void (^)(BOOL success, NSString *message))completion {
    if (![self isConfigured]) {
        completion(NO, @"未配置 WebDAV");
        return;
    }
    // Try to create root dir then propfind
    [self ensureRemoteRoot:^(BOOL ok, NSString *msg) {
        completion(ok, msg);
    }];
}

- (void)ensureRemoteRoot:(void (^)(BOOL success, NSString *message))completion {
    NSURLRequest *req = [self requestWithURL:[self remoteURLForPath:@""] method:@"MKCOL" body:nil];
    [[_session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = [(NSHTTPURLResponse *)response statusCode];
        if (code == 201 || code == 405) {
            completion(YES, @"连接成功");
        } else {
            completion(NO, error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)code]);
        }
    }] resume];
}

- (void)pushWithCompletion:(void (^)(BOOL success, NSString *message))completion {
    if (!completion) completion = ^(BOOL s, NSString *m){};
    if (![self isConfigured]) { completion(NO, @"未配置"); return; }
    dispatch_async(_queue, ^{
        [self ensureRemoteRoot:^(BOOL ok, NSString *msg) {
            if (!ok) { completion(NO, msg); return; }
            NSArray *items = [[QCStore sharedStore] allItems];
            NSError *err = nil;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:[self serializeItems:items] options:0 error:&err];
            if (err) { completion(NO, err.localizedDescription); return; }
            NSData *payload = _encryptionKey.length ? [self encrypt:jsonData key:_encryptionKey] : jsonData;
            NSURLRequest *req = [self requestWithURL:[self remoteURLForPath:@"sync.json"] method:@"PUT" body:payload];
            [[self->_session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSInteger code = [(NSHTTPURLResponse *)response statusCode];
                completion(code == 201 || code == 204, error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)code]);
            }] resume];
        }];
    });
}

- (void)pullWithCompletion:(void (^)(BOOL success, NSString *message))completion {
    if (!completion) completion = ^(BOOL s, NSString *m){};
    if (![self isConfigured]) { completion(NO, @"未配置"); return; }
    dispatch_async(_queue, ^{
        NSURLRequest *req = [self requestWithURL:[self remoteURLForPath:@"sync.json"] method:@"GET" body:nil];
        [[self->_session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger code = [(NSHTTPURLResponse *)response statusCode];
            if (code != 200 || !data) { completion(NO, error.localizedDescription ?: @"无远程数据"); return; }
            NSData *decoded = self->_encryptionKey.length ? [self decrypt:data key:self->_encryptionKey] : data;
            NSError *err = nil;
            NSArray *arr = [NSJSONSerialization JSONObjectWithData:decoded options:0 error:&err];
            if (err || ![arr isKindOfClass:[NSArray class]]) { completion(NO, @"数据格式错误"); return; }
            [self mergeRemoteItems:arr];
            completion(YES, [NSString stringWithFormat:@"同步 %lu 条", (unsigned long)arr.count]);
        }] resume];
    });
}

- (void)performAutoSyncIfEnabled {
    NSDictionary *prefs = [self prefs];
    NSDictionary *cfg = prefs[kWebDAVPrefsKey];
    if (![cfg[@"autoPullEnabled"] boolValue] && ![cfg[@"autoPushEnabled"] boolValue]) return;
    if ([cfg[@"autoPullEnabled"] boolValue]) [self pullWithCompletion:nil];
    NSTimeInterval delay = [cfg[@"pushDelay"] doubleValue] ?: 10.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        NSDictionary *currentPrefs = [self prefs];
        NSDictionary *currentCfg = currentPrefs[kWebDAVPrefsKey];
        if ([currentCfg[@"autoPushEnabled"] boolValue]) [self pushWithCompletion:nil];
    });
}

- (NSArray *)serializeItems:(NSArray<QCClipItem *> *)items {
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:items.count];
    for (QCClipItem *item in items) [arr addObject:[item toDictionary]];
    return arr;
}

- (void)mergeRemoteItems:(NSArray *)arr {
    for (NSDictionary *dict in arr) {
        QCClipItem *item = [QCClipItem fromDictionary:dict];
        QCClipItem *existing = [[QCStore sharedStore] itemWithCheckSum:item.checkSum];
        if (!existing) {
            [[QCStore sharedStore] saveItem:item];
        } else if ([item.updatedAt compare:existing.updatedAt] == NSOrderedDescending) {
            existing.favorite = item.favorite;
            existing.deleted = item.deleted;
            existing.updatedAt = item.updatedAt;
            [[QCStore sharedStore] updateItem:existing];
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:QCClipDidChangeNotification object:nil];
}

#pragma mark - Simple AES encryption (for demo, use proper key derivation in production)

- (NSData *)encrypt:(NSData *)data key:(NSString *)key {
    char keyPtr[kCCKeySizeAES256 + 1];
    bzero(keyPtr, sizeof(keyPtr));
    [key getCString:keyPtr maxLength:sizeof(keyPtr) encoding:NSUTF8StringEncoding];
    NSUInteger dataLength = data.length;
    size_t bufferSize = dataLength + kCCBlockSizeAES128;
    void *buffer = malloc(bufferSize);
    size_t numBytesEncrypted = 0;
    CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, keyPtr, kCCKeySizeAES256, NULL, data.bytes, dataLength, buffer, bufferSize, &numBytesEncrypted);
    return [NSData dataWithBytesNoCopy:buffer length:numBytesEncrypted];
}

- (NSData *)decrypt:(NSData *)data key:(NSString *)key {
    char keyPtr[kCCKeySizeAES256 + 1];
    bzero(keyPtr, sizeof(keyPtr));
    [key getCString:keyPtr maxLength:sizeof(keyPtr) encoding:NSUTF8StringEncoding];
    NSUInteger dataLength = data.length;
    size_t bufferSize = dataLength + kCCBlockSizeAES128;
    void *buffer = malloc(bufferSize);
    size_t numBytesDecrypted = 0;
    CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, keyPtr, kCCKeySizeAES256, NULL, data.bytes, dataLength, buffer, bufferSize, &numBytesDecrypted);
    return [NSData dataWithBytesNoCopy:buffer length:numBytesDecrypted];
}

@end
