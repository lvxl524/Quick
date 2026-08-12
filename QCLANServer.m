#import "QCLANServer.h"
#import "QCStore.h"
#import "QCLANLogger.h"
#import "QCLANPrefs.h"
#import "QCClipManager.h"
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <CommonCrypto/CommonDigest.h>

#pragma mark - 与桌面端 (Rust/Tauri) 一致的协议常量

static const uint16_t kDefaultLANPort    = 35691;  // HTTP 端口
static const uint16_t kDiscoveryPort     = 35692;  // UDP 发现端口
static NSString * const kDiscoveryProtocol = @"quickclipboard-sync-transfer-lan-discovery";
static NSString * const kHTTPProtocol      = @"quickclipboard-sync-transfer-lan-http";

// 配对码: TTL 300s, 最多 5 次尝试 (与桌面端 DEFAULT_PAIRING_CODE_TTL_SECS / MAX_ATTEMPTS 一致)
static const NSTimeInterval kPairCodeTTL       = 300.0;
static const NSInteger      kPairCodeMaxAttempts = 5;

// 本地管理端点仅允许 loopback 访问
static NSString * const kLoopbackIP = @"127.0.0.1";

// 请求体上限 (与桌面端 MAX_REQUEST_BODY_SIZE 对齐, 直传暂支持到 512MB)
static const NSUInteger kMaxRequestBodySize = 512 * 1024 * 1024;

static NSString * const kDeviceIDDefaultsKey = @"sync_transfer_device_id"; // 与桌面端一致
static NSString * const kPairCodeDefaultsKey  = @"lanPairingCode";
static NSString * const kPairCodeExpiryDefaultsKey = @"lanPairingCodeExpiresAtMs";
static NSString * const kPairCodeAttemptsDefaultsKey = @"lanPairingFailedAttempts";


#pragma mark - QCLANPeer

@implementation QCLANPeer

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[QCLANPeer class]]) return NO;
    return [self.deviceId isEqualToString:((QCLANPeer *)object).deviceId];
}

- (NSUInteger)hash {
    return self.deviceId.hash;
}

@end


#pragma mark - QCLANServer

@interface QCLANServer () <NSNetServiceDelegate> {
    int _listenSocket;
    int _discoverySocket;
    dispatch_queue_t _queue;
    dispatch_queue_t _discoveryQueue;   // UDP 独立队列, 避免同步扫描阻塞 HTTP 主队列时收不到响应
    dispatch_queue_t _scanQueue;        // 扫描专用队列 (同一 socket 收发, 不阻塞 HTTP 主队列)
    dispatch_source_t _listenSource;
    dispatch_source_t _discoverySource;
    NSMutableArray<QCLANPeer *> *_peers;
    NSMutableDictionary<NSString *, QCLANPeer *> *_discoveredPeers;
    BOOL _running;

    // Bonjour
    NSNetService *_netService;
}
@end

@implementation QCLANServer

+ (instancetype)sharedServer {
    static QCLANServer *server = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        server = [[QCLANServer alloc] init];
    });
    return server;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.mosheng.quickclipboard.lan", DISPATCH_QUEUE_SERIAL);
        _discoveryQueue = dispatch_queue_create("com.mosheng.quickclipboard.lan.discovery", DISPATCH_QUEUE_SERIAL);
        _scanQueue = dispatch_queue_create("com.mosheng.quickclipboard.lan.scan", DISPATCH_QUEUE_SERIAL);
        _peers = [NSMutableArray array];
        _discoveredPeers = [NSMutableDictionary dictionary];
        _port = kDefaultLANPort;
        _listenSocket = 0;
        _discoverySocket = 0;
        _running = NO;
        [self ensurePairingCode];
        [self loadPeers];
    }
    return self;
}

- (BOOL)isRunning {
    return _running;
}

- (NSString *)pairCode {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kPairCodeDefaultsKey] ?: @"------";
}

#pragma mark - Device Identity (与桌面端一致的持久化 UUID)

- (NSString *)deviceId {
    // 跨进程统一身份: 设置页(Preferences)与 SpringBoard 必须返回同一个值,
    // 否则推送时 X-Device-Id 与桌面端配对时备案的 device_id 不匹配 -> 403
    return [QCLANPrefs deviceId];
}

#pragma mark - Pairing Code (TTL + 尝试次数, 与桌面端一致)

- (void)ensurePairingCode {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *code = [defaults stringForKey:kPairCodeDefaultsKey];
    NSTimeInterval expiresAt = [defaults doubleForKey:kPairCodeExpiryDefaultsKey];
    NSTimeInterval nowMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
    if (code.length != 6 || expiresAt <= nowMs) {
        [self refreshPairCode];
    }
}

- (void)refreshPairCode {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    uint32_t code = arc4random_uniform(900000) + 100000;
    [defaults setObject:[NSString stringWithFormat:@"%06u", code] forKey:kPairCodeDefaultsKey];
    NSTimeInterval nowMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
    [defaults setDouble:(nowMs + kPairCodeTTL * 1000.0) forKey:kPairCodeExpiryDefaultsKey];
    [defaults setInteger:0 forKey:kPairCodeAttemptsDefaultsKey];
    [defaults synchronize];
}

- (BOOL)verifyPairingCode:(NSString *)code {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *expected = [defaults stringForKey:kPairCodeDefaultsKey];
    NSTimeInterval expiresAt = [defaults doubleForKey:kPairCodeExpiryDefaultsKey];
    NSTimeInterval nowMs = [[NSDate date] timeIntervalSince1970] * 1000.0;
    NSInteger attempts = [defaults integerForKey:kPairCodeAttemptsDefaultsKey];

    if (expected.length != 6 || expiresAt <= nowMs) {
        [self refreshPairCode];
        return NO; // 已过期
    }
    if (attempts >= kPairCodeMaxAttempts) {
        return NO; // 尝试次数过多
    }
    if (![expected isEqualToString:[code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]]) {
        [defaults setInteger:attempts + 1 forKey:kPairCodeAttemptsDefaultsKey];
        [defaults synchronize];
        return NO; // 不正确
    }
    [defaults setInteger:0 forKey:kPairCodeAttemptsDefaultsKey];
    [defaults synchronize];
    return YES;
}

#pragma mark - Peer Persistence (新格式: device_id / base_url / peer_token)

- (void)loadPeers {
    NSString *path = @"/var/mobile/Library/QuickClipboard/peers.plist";
    NSArray *arr = [NSArray arrayWithContentsOfFile:path];
    NSMutableArray *migrated = [NSMutableArray array];
    [_peers removeAllObjects];
    for (id obj in arr) {
        if (![obj isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *dict = obj;
        QCLANPeer *peer = [[QCLANPeer alloc] init];
        // 新格式
        NSString *deviceId = dict[@"device_id"] ?: dict[@"deviceId"];
        if (deviceId.length == 0) {
            // 旧格式迁移: 以 address:port 生成稳定的 device_id
            NSString *addr = dict[@"address"] ?: @"";
            NSNumber *port = dict[@"port"];
            NSString *legacy = [NSString stringWithFormat:@"%@:%@", addr, port ?: @(kDefaultLANPort)];
            deviceId = [self md5:legacy];
        }
        peer.deviceId  = deviceId;
        peer.name      = dict[@"device_name"] ?: dict[@"name"] ?: @"Unknown";
        peer.address   = dict[@"address"] ?: @"";
        peer.port      = dict[@"port"] ? [dict[@"port"] unsignedShortValue] : kDefaultLANPort;
        NSString *baseURL = dict[@"base_url"] ?: dict[@"baseURL"];
        peer.baseURL   = baseURL.length > 0 ? baseURL : [NSString stringWithFormat:@"http://%@:%hu", peer.address, peer.port];
        peer.peerToken = dict[@"peer_token"] ?: dict[@"peerToken"];
        peer.pairCode  = dict[@"pairCode"];
        peer.paired    = peer.peerToken.length > 0;
        peer.pairedAt  = dict[@"paired_at_ms"] ? [NSDate dateWithTimeIntervalSince1970:[dict[@"paired_at_ms"] doubleValue] / 1000.0] : nil;
        peer.lastSeen  = dict[@"last_seen_at_ms"] ? [NSDate dateWithTimeIntervalSince1970:[dict[@"last_seen_at_ms"] doubleValue] / 1000.0] : nil;
        [_peers addObject:peer];
        [migrated addObject:peer];
    }
    if (migrated.count > 0) [self savePeers];
    NSLog(@"[QuickClipboard] Loaded %lu paired peers", (unsigned long)_peers.count);
    [[QCLANLogger sharedLogger] info:@"SYS" fmt:@"加载已配对设备 %lu 台 (peers.plist)", (unsigned long)_peers.count];
}

- (void)reloadPeers {
    dispatch_async(_queue, ^{
        [self loadPeers];
    });
}

- (void)savePeers {
    NSString *dir = @"/var/mobile/Library/QuickClipboard";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"peers.plist"];
    NSMutableArray *arr = [NSMutableArray array];
    for (QCLANPeer *peer in _peers) {
        [arr addObject:@{
            @"device_id":         peer.deviceId ?: @"",
            @"device_name":       peer.name ?: @"",
            @"address":           peer.address ?: @"",
            @"port":              @(peer.port),
            @"base_url":          peer.baseURL ?: @"",
            @"peer_token":        peer.peerToken ?: @"",
            @"paired_at_ms":      @(peer.pairedAt ? [peer.pairedAt timeIntervalSince1970] * 1000.0 : 0),
            @"last_seen_at_ms":   @(peer.lastSeen ? [peer.lastSeen timeIntervalSince1970] * 1000.0 : 0),
        }];
    }
    [arr writeToFile:path atomically:YES];
    NSLog(@"[QuickClipboard] Saved %lu peers", (unsigned long)_peers.count);
}

- (NSString *)md5:(NSString *)input {
    const char *cStr = [input UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    return output;
}


#pragma mark - Server Lifecycle

- (void)start {
    dispatch_async(_queue, ^{
        if (self->_running) {
            NSLog(@"[QuickClipboard] LAN server already running");
            return;
        }
        NSLog(@"[QuickClipboard] Starting LAN server...");
        [[QCLANLogger sharedLogger] info:@"SYS" fmt:@"启动局域网服务: device_id=%@ 配对码=%@",
         [self deviceId], self.pairCode];
        [self startHTTPServer];
        [self startDiscoveryListener];
        self->_running = YES;
        [self publishBonjour];
        NSLog(@"[QuickClipboard] LAN server started on port %d, device_id: %@, pair code: %@",
              kDefaultLANPort, [self deviceId], self.pairCode);
        [[QCLANLogger sharedLogger] info:@"SYS" fmt:@"局域网服务已启动 (HTTP %d / UDP %d), 本机IP: %@",
         kDefaultLANPort, kDiscoveryPort, [self primaryLocalIP] ?: @"?"];
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        if (!self->_running) return;
        NSLog(@"[QuickClipboard] Stopping LAN server...");
        [self unpublishBonjour];
        if (self->_listenSource) {
            dispatch_source_cancel(self->_listenSource);
            self->_listenSource = nil;
        }
        if (self->_listenSocket > 0) {
            close(self->_listenSocket);
            self->_listenSocket = 0;
        }
        if (self->_discoverySource) {
            dispatch_source_cancel(self->_discoverySource);
            self->_discoverySource = nil;
        }
        if (self->_discoverySocket > 0) {
            close(self->_discoverySocket);
            self->_discoverySocket = 0;
        }
        self->_running = NO;
        NSLog(@"[QuickClipboard] LAN server stopped");
    });
}


#pragma mark - HTTP Server (桌面端兼容 /qc-sync/* 端点)

- (void)startHTTPServer {
    _listenSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (_listenSocket < 0) {
        NSLog(@"[QuickClipboard] ERROR: Failed to create TCP socket: %s", strerror(errno));
        [[QCLANLogger sharedLogger] error:@"SYS" fmt:@"创建 TCP socket 失败: %s", strerror(errno)];
        return;
    }

    int on = 1;
    setsockopt(_listenSocket, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kDefaultLANPort);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(_listenSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[QuickClipboard] ERROR: Failed to bind TCP port %d: %s", kDefaultLANPort, strerror(errno));
        [[QCLANLogger sharedLogger] error:@"SYS" fmt:@"HTTP 端口 %d 绑定失败: %s (可能被其他进程占用)", kDefaultLANPort, strerror(errno)];
        close(_listenSocket);
        _listenSocket = 0;
        return;
    }

    if (listen(_listenSocket, 32) < 0) {
        NSLog(@"[QuickClipboard] ERROR: Failed to listen: %s", strerror(errno));
        [[QCLANLogger sharedLogger] error:@"SYS" fmt:@"HTTP listen 失败: %s", strerror(errno)];
        close(_listenSocket);
        _listenSocket = 0;
        return;
    }

    _listenSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _listenSocket, 0, _queue);
    dispatch_source_set_event_handler(_listenSource, ^{
        [self acceptConnection];
    });
    dispatch_source_set_cancel_handler(_listenSource, ^{
        if (self->_listenSocket > 0) {
            close(self->_listenSocket);
            self->_listenSocket = 0;
        }
    });
    dispatch_resume(_listenSource);

    NSLog(@"[QuickClipboard] HTTP server listening on 0.0.0.0:%d", kDefaultLANPort);
}

- (void)acceptConnection {
    struct sockaddr_in clientAddr;
    socklen_t len = sizeof(clientAddr);
    int client = accept(_listenSocket, (struct sockaddr *)&clientAddr, &len);
    if (client < 0) return;

    NSString *address = [NSString stringWithUTF8String:inet_ntoa(clientAddr.sin_addr)];
    dispatch_async(_queue, ^{
        [self handleClient:client fromAddress:address];
    });
}

// 读取完整 HTTP 请求 (header + body)
- (NSDictionary *)readHTTPRequest:(int)socket {
    NSMutableData *buffer = [NSMutableData data];
    char chunk[4096];
    NSRange headerRange = NSMakeRange(NSNotFound, 0);

    // 1. 读取直到 header 结束 (\r\n\r\n)
    while (headerRange.location == NSNotFound) {
        ssize_t n = recv(socket, chunk, sizeof(chunk), 0);
        if (n <= 0) return nil;
        [buffer appendBytes:chunk length:(NSUInteger)n];
        NSData *data = buffer;
        if (data.length >= 4) {
            const char *bytes = data.bytes;
            for (NSUInteger i = 0; i + 4 <= data.length; i++) {
                if (bytes[i] == '\r' && bytes[i+1] == '\n' && bytes[i+2] == '\r' && bytes[i+3] == '\n') {
                    headerRange = NSMakeRange(i + 4, 0);
                    break;
                }
            }
        }
        if (buffer.length > 64 * 1024) return nil; // header 过大
    }

    NSData *headerData = [buffer subdataWithRange:NSMakeRange(0, headerRange.location)];
    NSString *headerText = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    if (!headerText) return nil;

    NSArray *lines = [headerText componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) return nil;
    NSArray *reqParts = [lines[0] componentsSeparatedByString:@" "];
    if (reqParts.count < 2) return nil;
    NSString *method = reqParts[0];
    NSString *target = reqParts[1];

    // 解析 header + Content-Length
    NSUInteger contentLength = 0;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [line substringToIndex:colon.location];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        headers[name.lowercaseString] = value;
        if ([name.lowercaseString isEqualToString:@"content-length"]) {
            contentLength = (NSUInteger)[value integerValue];
        }
    }
    if (contentLength > kMaxRequestBodySize) {
        return @{@"method": method, @"path": target, @"query": @{}, @"headers": headers, @"body": [NSData data], @"error": @"body too large"};
    }

    // 2. 读取 body
    NSData *alreadyRead = [buffer subdataWithRange:headerRange];
    NSMutableData *body = [NSMutableData dataWithData:alreadyRead];
    while (body.length < contentLength) {
        ssize_t n = recv(socket, chunk, sizeof(chunk), 0);
        if (n <= 0) break;
        [body appendBytes:chunk length:(NSUInteger)n];
    }
    if (body.length > contentLength) {
        body = [NSMutableData dataWithData:[body subdataWithRange:NSMakeRange(0, contentLength)]];
    }

    // 解析 query
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    NSRange qMark = [target rangeOfString:@"?"];
    NSString *path = target;
    if (qMark.location != NSNotFound) {
        path = [target substringToIndex:qMark.location];
        NSString *qs = [target substringFromIndex:qMark.location + 1];
        for (NSString *pair in [qs componentsSeparatedByString:@"&"]) {
            NSArray *kv = [pair componentsSeparatedByString:@"="];
            if (kv.count == 2) {
                query[[kv[0] stringByRemovingPercentEncoding]] = [kv[1] stringByRemovingPercentEncoding];
            }
        }
    }

    return @{@"method": method, @"path": path, @"query": query, @"headers": headers, @"body": body};
}

- (void)sendHTTPResponse:(int)socket statusCode:(NSInteger)statusCode body:(NSData *)body contentType:(NSString *)contentType {
    NSString *statusText = statusCode == 200 ? @"OK" :
                           statusCode == 400 ? @"Bad Request" :
                           statusCode == 403 ? @"Forbidden" :
                           statusCode == 404 ? @"Not Found" : @"Internal Server Error";
    if (!body) body = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    if (!contentType) contentType = @"application/json; charset=utf-8";

    NSString *headers = [NSString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\n"
        @"Content-Type: %@\r\n"
        @"Content-Length: %lu\r\n"
        @"Connection: close\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"\r\n",
        (long)statusCode, statusText, contentType, (unsigned long)body.length];

    NSMutableData *full = [NSMutableData data];
    [full appendData:[headers dataUsingEncoding:NSUTF8StringEncoding]];
    [full appendData:body];
    send(socket, full.bytes, full.length, 0);
}

- (NSData *)jsonResponse:(id)obj statusCode:(NSInteger *)statusCode {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) {
        if (statusCode) *statusCode = 500;
        return [@"{\"message\":\"序列化响应失败\"}" dataUsingEncoding:NSUTF8StringEncoding];
    }
    return data;
}

- (void)handleClient:(int)clientSocket fromAddress:(NSString *)address {
    struct timeval tv;
    tv.tv_sec = 30;
    tv.tv_usec = 0;
    setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    NSDictionary *request = [self readHTTPRequest:clientSocket];
    if (!request) { close(clientSocket); return; }
    if (request[@"error"]) {
        [self sendHTTPResponse:clientSocket statusCode:400 body:[@"{\"message\":\"请求体过大\"}" dataUsingEncoding:NSUTF8StringEncoding] contentType:@"application/json; charset=utf-8"];
        close(clientSocket);
        return;
    }

    NSString *method = request[@"method"];
    NSString *path   = request[@"path"];
    NSDictionary *query  = request[@"query"];
    NSDictionary *headers = request[@"headers"];
    NSData *body     = request[@"body"];

    NSLog(@"[QuickClipboard] HTTP %@ %@ from %@", method, path, address);
    [[QCLANLogger sharedLogger] info:@"NET" fmt:@"HTTP %@ %@ 来自 %@", method, path, address];

    NSInteger statusCode = 200;
    NSData *responseData = nil;
    NSString *contentType = @"application/json; charset=utf-8";

    // ================= /qc-sync/* 桌面端兼容端点 =================

    // GET /qc-sync/hello —— 无需授权
    if ([path isEqualToString:@"/qc-sync/hello"] && [method isEqualToString:@"GET"]) {
        responseData = [self jsonResponse:@{
            @"device_id":   [self deviceId],
            @"device_name": [self deviceName],
            @"protocol":    kHTTPProtocol,
            @"version":     @1,
        } statusCode:&statusCode];
        [[QCLANLogger sharedLogger] info:@"PAIR" fmt:@"响应 hello 请求: device_id=%@", [self deviceId]];

    // POST /qc-sync/pairing/confirm —— 无需授权
    } else if ([path isEqualToString:@"/qc-sync/pairing/confirm"] && [method isEqualToString:@"POST"]) {
        responseData = [self handlePairingConfirmWithBody:body remoteIP:address statusCode:&statusCode];

    // ================= 本地管理端点 (仅 loopback, 无需授权) =================

    // GET /ping —— 本地 UI 获取配对码/状态
    } else if ([path isEqualToString:@"/ping"] && [method isEqualToString:@"GET"] && [address isEqualToString:kLoopbackIP]) {
        responseData = [self jsonResponse:@{
            @"name":      [self deviceName],
            @"code":      self.pairCode,
            @"port":      @(kDefaultLANPort),
            @"version":   QC_VERSION,
            @"device_id": [self deviceId],
        } statusCode:&statusCode];

    // POST /pair-code —— 本地 UI 刷新配对码 (重置 TTL 与尝试次数)
    } else if ([path isEqualToString:@"/pair-code"] && [method isEqualToString:@"POST"] && [address isEqualToString:kLoopbackIP]) {
        [self refreshPairCode];
        responseData = [self jsonResponse:@{@"code": self.pairCode} statusCode:&statusCode];
        [[QCLANLogger sharedLogger] info:@"UI" fmt:@"本地UI刷新配对码: %@", self.pairCode];

    // GET /scan —— 本地 UI 触发扫描
    } else if ([path isEqualToString:@"/scan"] && [method isEqualToString:@"GET"] && [address isEqualToString:kLoopbackIP]) {
        NSArray *results = [self performScanNow];
        NSMutableArray *jsonDevices = [NSMutableArray array];
        for (QCLANPeer *p in results) {
            [jsonDevices addObject:[self peerJSON:p]];
        }
        responseData = [self jsonResponse:@{@"devices": jsonDevices} statusCode:&statusCode];
        [[QCLANLogger sharedLogger] info:@"SCAN" fmt:@"本地UI触发扫描: 发现 %lu 台设备", (unsigned long)results.count];

    // POST /pair —— 本地 UI 发起配对 (走 /qc-sync/hello + /qc-sync/pairing/confirm)
    } else if ([path isEqualToString:@"/pair"] && [method isEqualToString:@"POST"] && [address isEqualToString:kLoopbackIP]) {
        NSDictionary *req = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        NSString *pairAddr = req[@"address"];
        NSString *pairCode = req[@"code"];
        NSNumber *pairPort = req[@"port"];
        uint16_t port = pairPort ? [pairPort unsignedShortValue] : kDefaultLANPort;
        if (!pairAddr || !pairCode) {
            responseData = [self jsonResponse:@{@"error": @"缺少 address 或 code 参数"} statusCode:&statusCode];
            statusCode = 400;
        } else {
            BOOL ok = [self verifyAndPairAddress:pairAddr port:port code:pairCode];
            if (ok) {
                responseData = [self jsonResponse:@{@"ok": @YES, @"message": @"配对成功"} statusCode:&statusCode];
                [[QCLANLogger sharedLogger] info:@"PAIR" fmt:@"本地UI配对成功: %@", pairAddr];
            } else {
                responseData = [self jsonResponse:@{@"error": @"配对失败：无法验证配对码或设备不可达"} statusCode:&statusCode];
                statusCode = 400;
                [[QCLANLogger sharedLogger] error:@"PAIR" fmt:@"本地UI配对失败: %@ (码 %@)", pairAddr, pairCode];
            }
        }

    // GET /peers —— 本地 UI 列出已配对设备
    } else if ([path isEqualToString:@"/peers"] && [method isEqualToString:@"GET"] && [address isEqualToString:kLoopbackIP]) {
        NSMutableArray *jsonPeers = [NSMutableArray array];
        for (QCLANPeer *p in _peers) {
            [jsonPeers addObject:[self peerJSON:p]];
        }
        responseData = [self jsonResponse:@{@"peers": jsonPeers} statusCode:&statusCode];

    // DELETE /peers/<device_id>
    } else if ([path hasPrefix:@"/peers/"] && [method isEqualToString:@"DELETE"] && [address isEqualToString:kLoopbackIP]) {
        NSString *deviceId = [[path substringFromIndex:7] stringByRemovingPercentEncoding];
        [self removePeerByDeviceId:deviceId];
        responseData = [self jsonResponse:@{@"ok": @YES} statusCode:&statusCode];
        [[QCLANLogger sharedLogger] info:@"UI" fmt:@"本地UI删除已配对设备: %@", deviceId];

    // GET /sync —— 本地 UI 拉取全部
    } else if ([path isEqualToString:@"/sync"] && [method isEqualToString:@"GET"] && [address isEqualToString:kLoopbackIP]) {
        NSArray *items = [[QCStore sharedStore] allItems];
        responseData = [self jsonResponse:[self serializeItems:items] statusCode:&statusCode];

    // POST /sync —— 本地 UI 推送
    } else if ([path isEqualToString:@"/sync"] && [method isEqualToString:@"POST"] && [address isEqualToString:kLoopbackIP]) {
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        if ([arr isKindOfClass:[NSArray class]]) {
            [self mergeRemoteItems:arr fromAddress:address];
        }
        responseData = [self jsonResponse:@{@"ok": @YES, @"synced": @YES} statusCode:&statusCode];

    // ================= 需授权端点 (Bearer token + X-Device-Id) =================

    } else if ([self isAuthorizedRequest:headers]) {

        // GET /qc-sync/status
        if ([path isEqualToString:@"/qc-sync/status"] && [method isEqualToString:@"GET"]) {
            responseData = [self jsonResponse:[self runtimeStatusJSON] statusCode:&statusCode];

        // GET /qc-sync/snapshot
        } else if ([path isEqualToString:@"/qc-sync/snapshot"] && [method isEqualToString:@"GET"]) {
            responseData = [self jsonResponse:[self snapshotJSON] statusCode:&statusCode];

        // GET /qc-sync/records/history?since=ms
        } else if ([path isEqualToString:@"/qc-sync/records/history"] && [method isEqualToString:@"GET"]) {
            NSNumber *since = query[@"since"] ? @([query[@"since"] longLongValue]) : nil;
            responseData = [self jsonResponse:[self historyBatchSince:since] statusCode:&statusCode];

        // POST /qc-sync/records/history
        } else if ([path isEqualToString:@"/qc-sync/records/history"] && [method isEqualToString:@"POST"]) {
            responseData = [self handleReceiveHistory:body statusCode:&statusCode];

        // GET /qc-sync/records/favorites?since=ms
        } else if ([path isEqualToString:@"/qc-sync/records/favorites"] && [method isEqualToString:@"GET"]) {
            NSNumber *since = query[@"since"] ? @([query[@"since"] longLongValue]) : nil;
            responseData = [self jsonResponse:[self favoritesBatchSince:since] statusCode:&statusCode];

        // POST /qc-sync/records/favorites
        } else if ([path isEqualToString:@"/qc-sync/records/favorites"] && [method isEqualToString:@"POST"]) {
            responseData = [self handleReceiveFavorites:body statusCode:&statusCode];

        // GET /qc-sync/groups
        } else if ([path isEqualToString:@"/qc-sync/groups"] && [method isEqualToString:@"GET"]) {
            responseData = [self jsonResponse:@{@"groups": @[]} statusCode:&statusCode];

        // POST /qc-sync/groups
        } else if ([path isEqualToString:@"/qc-sync/groups"] && [method isEqualToString:@"POST"]) {
            responseData = [self jsonResponse:@{@"groups": @[]} statusCode:&statusCode];

        // GET /qc-sync/tombstones?since=ms
        } else if ([path isEqualToString:@"/qc-sync/tombstones"] && [method isEqualToString:@"GET"]) {
            responseData = [self jsonResponse:@{@"tombstones": @[]} statusCode:&statusCode];

        // POST /qc-sync/tombstones
        } else if ([path isEqualToString:@"/qc-sync/tombstones"] && [method isEqualToString:@"POST"]) {
            responseData = [self jsonResponse:@{@"tombstones": @[]} statusCode:&statusCode];

        // GET /qc-sync/files/<image_id>
        } else if ([path hasPrefix:@"/qc-sync/files/"] && [method isEqualToString:@"GET"]) {
            NSString *imageId = [[path substringFromIndex:14] stringByRemovingPercentEncoding];
            NSData *imageData = [self imageDataForImageId:imageId];
            if (imageData) {
                responseData = imageData;
                contentType = @"image/png";
            } else {
                responseData = [self jsonResponse:@{@"message": @"文件不存在"} statusCode:&statusCode];
                statusCode = 404;
            }

        // PUT /qc-sync/files/<image_id>
        } else if ([path hasPrefix:@"/qc-sync/files/"] && [method isEqualToString:@"PUT"]) {
            NSString *imageId = [[path substringFromIndex:14] stringByRemovingPercentEncoding];
            [self saveImageData:body forImageId:imageId];
            responseData = [self jsonResponse:@{@"saved": @YES} statusCode:&statusCode];

        } else {
            responseData = [self jsonResponse:@{@"message": @"未找到接口"} statusCode:&statusCode];
            statusCode = 404;
            [[QCLANLogger sharedLogger] warn:@"NET" fmt:@"已授权但未找到接口: %@ %@", method, path];
        }
    } else {
        responseData = [self jsonResponse:@{@"message": @"未授权的局域网同步请求"} statusCode:&statusCode];
        statusCode = 403;
        NSString *auth = headers[@"authorization"] ?: @"(无)";
        NSString *xid  = headers[@"x-device-id"] ?: @"(无)";
        [[QCLANLogger sharedLogger] error:@"NET" fmt:@"鉴权失败: %@ %@ 来自 %@ (Authorization=%@, X-Device-Id=%@)",
         method, path, address, auth, xid];
    }

    [self sendHTTPResponse:clientSocket statusCode:statusCode body:responseData contentType:contentType];
    close(clientSocket);
}


#pragma mark - 授权校验 (Bearer token + X-Device-Id, 与桌面端一致)

- (BOOL)isAuthorizedRequest:(NSDictionary *)headers {
    NSString *authorization = headers[@"authorization"] ?: @"";
    NSString *deviceId = headers[@"x-device-id"] ?: @"";
    if (![authorization hasPrefix:@"Bearer "]) return NO;
    NSString *token = [[authorization substringFromIndex:7] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (deviceId.length == 0 || token.length == 0) return NO;
    for (QCLANPeer *peer in _peers) {
        if ([peer.deviceId isEqualToString:deviceId] && [peer.peerToken isEqualToString:token]) {
            peer.lastSeen = [NSDate date];
            return YES;
        }
    }
    return NO;
}


#pragma mark - 配对确认 (服务端侧, 桌面端协议)

- (NSData *)handlePairingConfirmWithBody:(NSData *)body remoteIP:(NSString *)remoteIP statusCode:(NSInteger *)statusCode {
    NSDictionary *req = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if (![req isKindOfClass:[NSDictionary class]]) {
        if (statusCode) *statusCode = 400;
        [[QCLANLogger sharedLogger] error:@"PAIR" fmt:@"配对确认: 请求体解析失败 (来自 %@)", remoteIP];
        return [self jsonResponse:@{@"message": @"解析配对请求失败"} statusCode:statusCode];
    }

    NSString *deviceId   = [req[@"device_id"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *deviceName = req[@"device_name"];
    NSString *baseURL    = req[@"base_url"];
    NSString *pairCode   = req[@"pairing_code"];

    if (deviceId.length == 0) {
        if (statusCode) *statusCode = 400;
        [[QCLANLogger sharedLogger] error:@"PAIR" fmt:@"配对确认: 设备ID为空 (来自 %@)", remoteIP];
        return [self jsonResponse:@{@"message": @"设备 ID 不能为空"} statusCode:statusCode];
    }
    if ([deviceId isEqualToString:[self deviceId]]) {
        if (statusCode) *statusCode = 400;
        [[QCLANLogger sharedLogger] error:@"PAIR" fmt:@"配对确认: 拒绝与本机自身配对 (来自 %@)", remoteIP];
        return [self jsonResponse:@{@"message": @"不能配对当前设备自身"} statusCode:statusCode];
    }
    if (![self verifyPairingCode:pairCode]) {
        if (statusCode) *statusCode = 400;
        NSInteger attempts = [[NSUserDefaults standardUserDefaults] integerForKey:kPairCodeAttemptsDefaultsKey];
        [[QCLANLogger sharedLogger] error:@"PAIR" fmt:@"配对确认: 配对码错误/过期 (输入=%@, 已失败%d/5, 来自 %@)",
         pairCode ?: @"空", (int)attempts, remoteIP];
        return [self jsonResponse:@{@"message": @"配对码不正确或已过期"} statusCode:statusCode];
    }

    // 与桌面端 normalize_pairing_base_url 一致: 空/回环地址替换为请求方 IP
    NSString *trimmed = [baseURL stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL needsNormalize = trimmed.length == 0 ||
        [trimmed containsString:@"127.0.0.1"] ||
        [trimmed containsString:@"localhost"] ||
        [trimmed containsString:@"[::1]"];
    if (needsNormalize) {
        NSUInteger port = kDefaultLANPort;
        NSArray *parts = [trimmed componentsSeparatedByString:@":"];
        if (parts.count >= 2) {
            NSUInteger lastPort = [parts.lastObject integerValue];
            if (lastPort > 0) port = lastPort;
        }
        trimmed = [NSString stringWithFormat:@"http://%@:%lu", remoteIP, (unsigned long)port];
    }
    baseURL = trimmed;

    // 生成 peer_token (UUID4)
    NSString *peerToken = [[NSUUID UUID] UUIDString].lowercaseString;

    // upsert peer
    QCLANPeer *peer = [[QCLANPeer alloc] init];
    peer.deviceId  = deviceId;
    peer.name      = deviceName.length > 0 ? deviceName : deviceId;
    peer.address   = remoteIP;
    peer.port      = kDefaultLANPort;
    peer.baseURL   = baseURL;
    peer.peerToken = peerToken;
    peer.paired    = YES;
    peer.pairedAt  = [NSDate date];
    peer.lastSeen  = [NSDate date];

    [_peers removeObject:peer];
    [_peers addObject:peer];
    [self savePeers];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:QCLANDevicePairedNotification object:peer];
    });

    NSLog(@"[QuickClipboard] Paired with %@ (%@ via %@)", deviceName, deviceId, baseURL);
    [[QCLANLogger sharedLogger] info:@"PAIR" fmt:@"配对成功: %@ (%@, base=%@, token=%@…)",
     deviceName ?: @"?", deviceId, baseURL, peerToken.length > 12 ? [peerToken substringToIndex:12] : peerToken];

    if (statusCode) *statusCode = 200;
    return [self jsonResponse:@{@"peer_token": peerToken, @"expires_at_ms": [NSNull null]} statusCode:statusCode];
}


#pragma mark - 运行时状态 (桌面端 /qc-sync/status 结构)

- (NSDictionary *)runtimeStatusJSON {
    NSMutableArray *endpoints = [NSMutableArray array];
    for (NSString *ip in [self localIPAddresses]) {
        [endpoints addObject:@{
            @"ip": ip,
            @"base_url": [NSString stringWithFormat:@"http://%@:%d", ip, kDefaultLANPort],
        }];
    }
    return @{
        @"device_id": [self deviceId],
        @"device_name": [self deviceName],
        @"http_port": @(kDefaultLANPort),
        @"http_running": @(_running),
        @"discovery_running": @(_running),
        @"local_endpoints": endpoints,
        @"pairing_code": @{
            @"pairing_code": self.pairCode,
            @"expires_at_ms": @([[NSUserDefaults standardUserDefaults] doubleForKey:kPairCodeExpiryDefaultsKey]),
            @"remaining_attempts": @(MAX(0, kPairCodeMaxAttempts - [[NSUserDefaults standardUserDefaults] integerForKey:kPairCodeAttemptsDefaultsKey])),
        },
        @"paired_count": @(_peers.count),
    };
}


#pragma mark - 快照 (桌面端 /qc-sync/snapshot 结构)

- (NSDictionary *)snapshotJSON {
    NSMutableDictionary *historyStates = [NSMutableDictionary dictionary];
    NSMutableDictionary *favoriteStates = [NSMutableDictionary dictionary];
    for (QCClipItem *item in [[QCStore sharedStore] allItems]) {
        long long updatedMs = (long long)([item.updatedAt timeIntervalSince1970] * 1000.0);
        if (item.favorite) {
            favoriteStates[item.uuid] = @(updatedMs);
        } else {
            historyStates[item.uuid] = @(updatedMs);
        }
    }
    return @{
        @"device_id": [self deviceId],
        @"history_states": historyStates,
        @"favorite_states": favoriteStates,
        @"groups": @[],
        @"tombstone_states": @{},
    };
}


#pragma mark - 记录批次 (桌面端 LanRecordBatch 结构)

- (NSDictionary *)historyBatchSince:(NSNumber *)sinceMs {
    return [self recordBatchForFavorite:NO sinceMs:sinceMs collection:@"history"];
}

- (NSDictionary *)favoritesBatchSince:(NSNumber *)sinceMs {
    return [self recordBatchForFavorite:YES sinceMs:sinceMs collection:@"favorites"];
}

- (NSDictionary *)recordBatchForFavorite:(BOOL)favorite sinceMs:(NSNumber *)sinceMs collection:(NSString *)collection {
    NSArray *items = favorite ? [[QCStore sharedStore] favoriteItems] : [[QCStore sharedStore] allItems];
    NSMutableArray *records = [NSMutableArray array];
    for (QCClipItem *item in items) {
        if (favorite && !item.favorite) continue;
        if (sinceMs) {
            long long updatedMs = (long long)([item.updatedAt timeIntervalSince1970] * 1000.0);
            if (updatedMs <= [sinceMs longLongValue]) continue;
        }
        [records addObject:[self cloudRecordFromItem:item]];
    }
    return @{@"collection": collection, @"records": records};
}

// 接收历史记录 (桌面端: 过滤已删除 → upsert → 返回 changed)
- (NSData *)handleReceiveHistory:(NSData *)body statusCode:(NSInteger *)statusCode {
    NSDictionary *batch = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSArray *records = [batch isKindOfClass:[NSDictionary class]] ? batch[@"records"] : nil;
    NSMutableArray *changed = [NSMutableArray array];
    QCClipItem *latestItem = nil;
    if ([records isKindOfClass:[NSArray class]]) {
        for (NSDictionary *dict in records) {
            if (![dict isKindOfClass:[NSDictionary class]]) continue;
            QCClipItem *item = [self itemFromCloudRecord:dict];
            if (!item) continue;
            QCClipItem *existing = [[QCStore sharedStore] itemWithCheckSum:item.checkSum];
            if (existing) {
                // 仅在远端更新更晚时覆盖
                if ([item.updatedAt compare:existing.updatedAt] == NSOrderedDescending) {
                    item.favorite = existing.favorite;
                    [[QCStore sharedStore] saveItem:item];
                    [changed addObject:[self cloudRecordFromItem:item]];
                    latestItem = item;
                }
            } else {
                [[QCStore sharedStore] saveItem:item];
                [changed addObject:[self cloudRecordFromItem:item]];
                latestItem = item;
            }
        }
        if (changed.count > 0) {
            [[NSNotificationCenter defaultCenter] postNotificationName:QCClipDidChangeNotification object:nil];
            BOOL notifyEnabled = [QCLANPrefs boolForKey:@"lanSyncNotifyEnabled" defaultValue:NO];
            if (notifyEnabled) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:QCLANSyncReceivedNotification
                                                                        object:nil
                                                                      userInfo:@{@"count": @(changed.count)}];
                });
            }
            // 关键修复: 收到的记录写入系统剪贴板, 用户可直接粘贴 (电脑端复制 → 手机端剪贴板)
            if (latestItem) {
                [[QCClipManager sharedManager] writeItemToPasteboard:latestItem];
                NSString *preview = latestItem.textRepresentation;
                if (preview.length > 40) preview = [preview substringToIndex:40];
                [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"已把收到的内容写入剪贴板: %@", preview];
            }
        }
    }
    [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"收到 %lu 条历史记录, 变更 %lu 条",
     (unsigned long)records.count, (unsigned long)changed.count];
    if (statusCode) *statusCode = 200;
    return [self jsonResponse:@{@"collection": @"history", @"records": changed} statusCode:statusCode];
}

- (NSData *)handleReceiveFavorites:(NSData *)body statusCode:(NSInteger *)statusCode {
    NSDictionary *batch = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSArray *records = [batch isKindOfClass:[NSDictionary class]] ? batch[@"records"] : nil;
    NSMutableArray *changed = [NSMutableArray array];
    if ([records isKindOfClass:[NSArray class]]) {
        for (NSDictionary *dict in records) {
            if (![dict isKindOfClass:[NSDictionary class]]) continue;
            QCClipItem *item = [self itemFromCloudRecord:dict];
            if (!item) continue;
            item.favorite = YES;
            QCClipItem *existing = [[QCStore sharedStore] itemWithCheckSum:item.checkSum];
            if (existing) {
                if ([item.updatedAt compare:existing.updatedAt] == NSOrderedDescending) {
                    [[QCStore sharedStore] saveItem:item];
                    [changed addObject:[self cloudRecordFromItem:item]];
                }
            } else {
                [[QCStore sharedStore] saveItem:item];
                [changed addObject:[self cloudRecordFromItem:item]];
            }
        }
        if (changed.count > 0) {
            [[NSNotificationCenter defaultCenter] postNotificationName:QCClipDidChangeNotification object:nil];
        }
    }
    if (statusCode) *statusCode = 200;
    return [self jsonResponse:@{@"collection": @"favorites", @"records": changed} statusCode:statusCode];
}

// 图片文件存取
- (NSData *)imageDataForImageId:(NSString *)imageId {
    for (QCClipItem *item in [[QCStore sharedStore] allItems]) {
        if ([item.uuid isEqualToString:imageId] && item.type == QCClipTypeImage && item.payload.length > 0) {
            return item.payload;
        }
    }
    return nil;
}

- (void)saveImageData:(NSData *)data forImageId:(NSString *)imageId {
    if (data.length == 0 || imageId.length == 0) return;
    QCClipItem *item = [[QCClipItem alloc] init];
    item.uuid = imageId;
    item.type = QCClipTypeImage;
    item.payload = data;
    item.textRepresentation = @"[图片]";
    item.checkSum = [item computeCheckSum];
    QCClipItem *existing = [[QCStore sharedStore] itemWithCheckSum:item.checkSum];
    if (!existing) {
        [[QCStore sharedStore] saveItem:item];
    }
}


#pragma mark - CloudRecord <-> QCClipItem 双向转换

- (NSDictionary *)cloudRecordFromItem:(QCClipItem *)item {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[@"uuid"] = item.uuid ?: @"";
    record[@"source_device_id"] = item.deviceID ?: [self deviceId];
    record[@"is_remote"] = @NO;
    record[@"content"] = item.textRepresentation ?: @"";
    if (item.type == QCClipTypeRichText) {
        record[@"html_content"] = item.textRepresentation ?: @"";
    }
    record[@"content_type"] = [self contentTypeForItemType:item.type];
    if (item.type == QCClipTypeImage) {
        record[@"image_id"] = item.uuid;
    }
    if (item.textRepresentation.length > 0) {
        NSString *title = item.textRepresentation;
        if (title.length > 40) title = [title substringToIndex:40];
        record[@"title"] = title;
    }
    record[@"group_name"] = @"全部";
    record[@"item_order"] = @0;
    record[@"paste_count"] = @0;
    record[@"created_at"] = @((long long)([item.createdAt timeIntervalSince1970] * 1000.0));
    record[@"updated_at"] = @((long long)([item.updatedAt timeIntervalSince1970] * 1000.0));
    return record;
}

- (QCClipItem *)itemFromCloudRecord:(NSDictionary *)record {
    NSString *uuid = record[@"uuid"];
    if (uuid.length == 0) return nil;

    QCClipItem *item = [[QCClipItem alloc] init];
    item.uuid = uuid;
    item.deviceID = record[@"source_device_id"] ?: [self deviceId];
    item.textRepresentation = record[@"content"] ?: @"";
    NSString *contentType = record[@"content_type"] ?: @"text/plain";
    item.type = [self itemTypeForContentType:contentType];

    if (item.type == QCClipTypeImage) {
        // 图片: 尝试按 image_id 从本机库取 payload, 否则以文本占位
        NSString *imageId = record[@"image_id"];
        if (imageId.length > 0) {
            NSData *payload = [self imageDataForImageId:imageId];
            if (payload) item.payload = payload;
        }
    } else {
        item.payload = [item.textRepresentation dataUsingEncoding:NSUTF8StringEncoding];
    }

    long long createdAtMs = [record[@"created_at"] longLongValue];
    long long updatedAtMs = [record[@"updated_at"] longLongValue];
    item.createdAt = createdAtMs > 0 ? [NSDate dateWithTimeIntervalSince1970:createdAtMs / 1000.0] : [NSDate date];
    item.updatedAt = updatedAtMs > 0 ? [NSDate dateWithTimeIntervalSince1970:updatedAtMs / 1000.0] : [NSDate date];
    item.checkSum = [item computeCheckSum];
    return item;
}

- (NSString *)contentTypeForItemType:(QCClipType)type {
    switch (type) {
        case QCClipTypeRichText: return @"text/html";
        case QCClipTypeImage:    return @"image/png";
        case QCClipTypeURL:      return @"text/uri-list";
        case QCClipTypeFile:     return @"application/octet-stream";
        default:                 return @"text/plain";
    }
}

- (QCClipType)itemTypeForContentType:(NSString *)contentType {
    if ([contentType hasPrefix:@"image/"]) return QCClipTypeImage;
    if ([contentType hasPrefix:@"text/html"]) return QCClipTypeRichText;
    if ([contentType hasPrefix:@"text/uri-list"]) return QCClipTypeURL;
    return QCClipTypePlainText;
}


#pragma mark - Discovery Listener (UDP 35692, 桌面端 JSON 协议)

- (void)startDiscoveryListener {
    _discoverySocket = socket(AF_INET, SOCK_DGRAM, 0);
    if (_discoverySocket < 0) {
        NSLog(@"[QuickClipboard] ERROR: Failed to create discovery UDP socket: %s", strerror(errno));
        [[QCLANLogger sharedLogger] error:@"SYS" fmt:@"创建 UDP 发现 socket 失败: %s", strerror(errno)];
        return;
    }

    int on = 1;
    setsockopt(_discoverySocket, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    setsockopt(_discoverySocket, SOL_SOCKET, SO_BROADCAST, &on, sizeof(on));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kDiscoveryPort);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(_discoverySocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[QuickClipboard] ERROR: Failed to bind discovery port %d: %s", kDiscoveryPort, strerror(errno));
        [[QCLANLogger sharedLogger] error:@"SYS" fmt:@"UDP 发现端口 %d 绑定失败: %s", kDiscoveryPort, strerror(errno)];
        close(_discoverySocket);
        _discoverySocket = 0;
        return;
    }

    _discoverySource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _discoverySocket, 0, _discoveryQueue);
    dispatch_source_set_event_handler(_discoverySource, ^{
        while (1) {
            [self handleDiscoveryPacket];
        }
    });
    dispatch_source_set_cancel_handler(_discoverySource, ^{
        if (self->_discoverySocket > 0) {
            close(self->_discoverySocket);
            self->_discoverySocket = 0;
        }
    });
    dispatch_resume(_discoverySource);

    NSLog(@"[QuickClipboard] Discovery listener on UDP 0.0.0.0:%d", kDiscoveryPort);
}

- (void)handleDiscoveryPacket {
    char buffer[2048];
    struct sockaddr_in senderAddr;
    socklen_t senderLen = sizeof(senderAddr);
    ssize_t len = recvfrom(_discoverySocket, buffer, sizeof(buffer) - 1, MSG_DONTWAIT,
                           (struct sockaddr *)&senderAddr, &senderLen);

    if (len <= 0) return;

    NSString *msg = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)len encoding:NSUTF8StringEncoding];
    if (!msg) return;
    NSString *senderIP = [NSString stringWithUTF8String:inet_ntoa(senderAddr.sin_addr)];

    NSDictionary *packet = [NSJSONSerialization JSONObjectWithData:[msg dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![packet isKindOfClass:[NSDictionary class]]) return;

    NSString *protocol = packet[@"protocol"];
    NSString *kind     = packet[@"kind"];
    NSString *deviceId = packet[@"device_id"] ?: @"";

    if (![protocol isEqualToString:kDiscoveryProtocol]) {
        [[QCLANLogger sharedLogger] warn:@"NET" fmt:@"收到非本协议 UDP 包 (protocol=%@) 来自 %@, 忽略",
         protocol ?: @"空", senderIP];
        return;
    }
    if ([deviceId isEqualToString:[self deviceId]]) return; // 忽略自己

    if ([kind isEqualToString:@"request"]) {
        // 收到扫描请求 → 回复 response 包 (与桌面端 response_packet 一致)
        NSDictionary *reply = @{
            @"protocol":    kDiscoveryProtocol,
            @"kind":        @"response",
            @"device_id":   [self deviceId],
            @"device_name": [self deviceName],
            @"http_port":   @(kDefaultLANPort),
        };
        NSData *replyData = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
        ssize_t sent = sendto(_discoverySocket, replyData.bytes, replyData.length, 0,
                             (struct sockaddr *)&senderAddr, senderLen);
        NSLog(@"[QuickClipboard] Discovery response sent to %@:%d (%zd bytes)",
              senderIP, ntohs(senderAddr.sin_port), sent);
        [[QCLANLogger sharedLogger] info:@"NET" fmt:@"收到发现请求, 已回复响应包给 %@ (%zd bytes)",
         senderIP, sent];

    } else if ([kind isEqualToString:@"response"]) {
        // 收到发现响应 (对方直接回 35692) → 记录 peer, 复用统一解析逻辑
        NSData *pkt = [msg dataUsingEncoding:NSUTF8StringEncoding];
        @synchronized (_discoveredPeers) {
            [self consumeDiscoveryResponseData:pkt fromSender:&senderAddr intoDict:_discoveredPeers];
        }
    }
}


#pragma mark - Scanning (桌面端 discovery 请求包)

// 发送桌面端格式的 discovery 请求包 (kind=request, http_port=0)
// 用调用方传入的 socket 发送 (该 socket 保持存活以接收响应, 与桌面端 discover() 一致)
- (void)sendDiscoveryBroadcastOnSocket:(int)sendSock {
    if (sendSock < 0) {
        [[QCLANLogger sharedLogger] error:@"NET" fmt:@"发送发现广播失败: socket 无效"];
        return;
    }

    NSDictionary *request = @{
        @"protocol":    kDiscoveryProtocol,
        @"kind":        @"request",
        @"device_id":   [self deviceId],
        @"device_name": [self deviceName],
        @"http_port":   @0,
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];

    // 1. 全局广播
    struct sockaddr_in broadAddr;
    memset(&broadAddr, 0, sizeof(broadAddr));
    broadAddr.sin_family = AF_INET;
    broadAddr.sin_port = htons(kDiscoveryPort);
    broadAddr.sin_addr.s_addr = inet_addr("255.255.255.255");
    sendto(sendSock, data.bytes, data.length, 0,
           (struct sockaddr *)&broadAddr, sizeof(broadAddr));

    // 2. 各接口子网广播
    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) == 0) {
        for (struct ifaddrs *ifa = ifaddr; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            if (strncmp(ifa->ifa_name, "lo", 2) == 0) continue;
            if (!ifa->ifa_netmask) continue;

            struct sockaddr_in *sin  = (struct sockaddr_in *)ifa->ifa_addr;
            struct sockaddr_in *mask = (struct sockaddr_in *)ifa->ifa_netmask;

            uint32_t ip    = ntohl(sin->sin_addr.s_addr);
            uint32_t nm    = ntohl(mask->sin_addr.s_addr);
            uint32_t bcast = ip | ~nm;

            struct sockaddr_in bcastAddr;
            memset(&bcastAddr, 0, sizeof(bcastAddr));
            bcastAddr.sin_family = AF_INET;
            bcastAddr.sin_port = htons(kDiscoveryPort);
            bcastAddr.sin_addr.s_addr = htonl(bcast);

            sendto(sendSock, data.bytes, data.length, 0,
                   (struct sockaddr *)&bcastAddr, sizeof(bcastAddr));
        }
        freeifaddrs(ifaddr);
    }

    NSLog(@"[QuickClipboard] Discovery request broadcast sent via socket %d", sendSock);
    [[QCLANLogger sharedLogger] info:@"NET" fmt:@"发送 UDP 发现广播 (255.255.255.255:%d + 各子网广播, socket %d)",
     kDiscoveryPort, sendSock];
}

// 解析一条 UDP 发现响应包并写入扫描结果字典 (与桌面端 discover() 的 response 过滤逻辑一致)
- (void)consumeDiscoveryResponseData:(NSData *)data
                          fromSender:(struct sockaddr_in *)senderAddr
                             intoDict:(NSMutableDictionary<NSString *, QCLANPeer *> *)dict {
    NSDictionary *packet = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![packet isKindOfClass:[NSDictionary class]]) return;

    NSString *protocol = packet[@"protocol"];
    NSString *kind     = packet[@"kind"];
    NSString *deviceId = packet[@"device_id"] ?: @"";
    NSString *deviceName = packet[@"device_name"] ?: @"Unknown";
    NSNumber *httpPort = packet[@"http_port"];

    if (![protocol isEqualToString:kDiscoveryProtocol]) {
        [[QCLANLogger sharedLogger] warn:@"NET" fmt:@"收到非本协议 UDP 包 (protocol=%@), 忽略", protocol ?: @"空"];
        return;
    }
    if (![kind isEqualToString:@"response"]) return; // 只消费 response
    if (deviceId.length == 0 || [deviceId isEqualToString:[self deviceId]]) return; // 忽略自身

    NSString *senderIP = senderAddr ? [NSString stringWithUTF8String:inet_ntoa(senderAddr->sin_addr)] : @"?";
    uint16_t port = httpPort ? [httpPort unsignedShortValue] : kDefaultLANPort;
    NSString *baseURL = [NSString stringWithFormat:@"http://%@:%hu", senderIP, port];

    QCLANPeer *peer = [[QCLANPeer alloc] init];
    peer.deviceId  = deviceId;
    peer.name      = deviceName;
    peer.address   = senderIP;
    peer.port      = port;
    peer.baseURL   = baseURL;
    peer.lastSeen  = [NSDate date];
    peer.paired    = NO;

    for (QCLANPeer *p in _peers) {
        if ([p.deviceId isEqualToString:peer.deviceId]) {
            peer.paired = YES;
            peer.name  = p.name;
            peer.peerToken = p.peerToken;
            break;
        }
    }

    dict[peer.deviceId] = peer;
    NSLog(@"[QuickClipboard] Discovered via scan socket: %@ (%@, base: %@, paired=%d)", deviceName, deviceId, baseURL, peer.paired);
    [[QCLANLogger sharedLogger] info:@"NET" fmt:@"扫描收到响应: %@ (%@, base=%@, 已配对=%d)",
     deviceName, deviceId, baseURL, peer.paired];
}

// 扫描核心: 同一 UDP socket 发送广播并接收响应 (与桌面端 discover() 完全一致),
// 修复旧版"发送后立即关闭 socket 导致响应丢包、永远扫不到设备"的问题
- (NSArray<QCLANPeer *> *)performScanCoreDuration:(NSTimeInterval)duration {
    @synchronized (_discoveredPeers) {
        [_discoveredPeers removeAllObjects];
    }
    [[QCLANLogger sharedLogger] info:@"SCAN" fmt:@"开始扫描局域网 (UDP %d, 持续%.1f秒)", kDiscoveryPort, duration];

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        NSLog(@"[QuickClipboard] ERROR: Failed to create scan socket: %s", strerror(errno));
        [[QCLANLogger sharedLogger] error:@"NET" fmt:@"创建扫描 socket 失败: %s", strerror(errno)];
        return @[];
    }

    int on = 1;
    setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &on, sizeof(on));

    // 绑定随机端口: 固定源端口, 保证对端 response 能回到本 socket
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = 0;
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[QuickClipboard] ERROR: Failed to bind scan socket: %s", strerror(errno));
        [[QCLANLogger sharedLogger] error:@"NET" fmt:@"扫描 socket bind 失败: %s", strerror(errno)];
        close(sock);
        return @[];
    }

    NSMutableDictionary<NSString *, QCLANPeer *> *found = [NSMutableDictionary dictionary];
    [self sendDiscoveryBroadcastOnSocket:sock];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:duration];
    BOOL resent = NO;

    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        // 100ms 接收超时, 避免忙等, 同时能按时重发广播
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 100000;
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        char buffer[2048];
        struct sockaddr_in senderAddr;
        socklen_t senderLen = sizeof(senderAddr);
        ssize_t len = recvfrom(sock, buffer, sizeof(buffer) - 1, 0,
                               (struct sockaddr *)&senderAddr, &senderLen);
        if (len > 0) {
            NSData *pkt = [NSData dataWithBytes:buffer length:(NSUInteger)len];
            [self consumeDiscoveryResponseData:pkt fromSender:&senderAddr intoDict:found];
        }

        NSTimeInterval remaining = [deadline timeIntervalSinceNow];
        if (!resent && remaining < duration * 0.4) {
            [self sendDiscoveryBroadcastOnSocket:sock];
            resent = YES;
            [[QCLANLogger sharedLogger] info:@"SCAN" fmt:@"扫描过半, 重发发现广播"];
        }
    }

    close(sock);

    NSArray *results = [found.allValues sortedArrayUsingComparator:^NSComparisonResult(QCLANPeer *a, QCLANPeer *b) {
        return [a.name compare:b.name];
    }];
    [[QCLANLogger sharedLogger] info:@"SCAN" fmt:@"扫描完成: 发现 %lu 台设备", (unsigned long)results.count];
    @synchronized (_discoveredPeers) {
        [_discoveredPeers removeAllObjects];
        for (QCLANPeer *p in results) _discoveredPeers[p.deviceId] = p;
    }
    return results;
}

// 异步扫描 (UI 调用): 扫描在独立队列执行, 不阻塞 HTTP 主队列
- (void)performScanWithCompletion:(void (^)(NSArray<QCLANPeer *> *devices))completion {
    dispatch_async(_scanQueue, ^{
        NSArray *results = [self performScanCoreDuration:3.0];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(results);
        });
    });
}

// 兼容入口 (头文件声明保留)
- (void)scanForDevicesWithCompletion:(void (^)(NSArray<QCLANPeer *> *devices))completion {
    [self performScanWithCompletion:completion];
}

// 同步扫描 (本地 HTTP /scan 调用, 独立队列避免死锁)
- (NSArray<QCLANPeer *> *)performScanNow {
    __block NSArray *results = @[];
    dispatch_sync(_scanQueue, ^{
        results = [self performScanCoreDuration:2.5];
    });
    return results;
}


#pragma mark - Pairing (客户端侧: 走桌面端 /qc-sync/hello + /qc-sync/pairing/confirm)

- (void)pairWithAddress:(NSString *)address
                   port:(uint16_t)port
                   code:(NSString *)code
             completion:(void (^)(BOOL success, NSString *message))completion {

    dispatch_async(_queue, ^{
        BOOL ok = [self verifyAndPairAddress:address port:port code:code];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                if (completion) completion(YES, @"配对成功");
            } else {
                if (completion) completion(NO, @"配对失败：无法验证配对码或设备不可达");
            }
        });
    });
}

// 与桌面端 pair_with_peer 一致的客户端配对流程
- (BOOL)verifyAndPairAddress:(NSString *)address port:(uint16_t)port code:(NSString *)code {
    NSString *baseURL = [NSString stringWithFormat:@"http://%@:%hu", address, port];

    // Step 1: GET /qc-sync/hello 获取设备信息并校验协议
    [[QCLANLogger sharedLogger] info:@"PAIR" fmt:@"开始配对 %@ (配对码 %@)", baseURL, code];
    NSDictionary *hello = [self httpGetJSON:[baseURL stringByAppendingString:@"/qc-sync/hello"] timeout:5.0];
    if (!hello) {
        NSLog(@"[QuickClipboard] Pair failed: %@ unreachable", baseURL);
        [[QCLANLogger sharedLogger] error:@"PAIR" fmt:@"GET /qc-sync/hello 失败: %@ 不可达或超时", baseURL];
        return NO;
    }
    NSString *remoteId = hello[@"device_id"];
    NSString *remoteName = hello[@"device_name"] ?: address;
    NSString *remoteProtocol = hello[@"protocol"];
    if (![remoteProtocol isEqualToString:kHTTPProtocol]) {
        NSLog(@"[QuickClipboard] Pair failed: %@ is not a compatible QuickClipboard service", baseURL);
        [[QCLANLogger sharedLogger] error:@"PAIR" fmt:@"协议不匹配: %@ 返回 protocol=%@ (期望 %@)",
         baseURL, remoteProtocol ?: @"空", kHTTPProtocol];
        return NO;
    }
    if ([remoteId isEqualToString:[self deviceId]]) {
        NSLog(@"[QuickClipboard] Pair failed: cannot pair with self");
        [[QCLANLogger sharedLogger] error:@"PAIR" fmt:@"拒绝配对自身设备 (%@)", remoteId];
        return NO;
    }
    [[QCLANLogger sharedLogger] info:@"PAIR" fmt:@"hello 成功: 目标 %@ (device_id=%@)", remoteName, remoteId];

    // Step 2: POST /qc-sync/pairing/confirm
    NSDictionary *payload = @{
        @"device_id":   [self deviceId],
        @"device_name": [self deviceName],
        @"base_url":    [NSString stringWithFormat:@"http://%@:%d", [self primaryLocalIP] ?: @"127.0.0.1", kDefaultLANPort],
        @"pairing_code": code ?: @"",
    };
    NSDictionary *confirm = [self httpPostJSON:baseURL path:@"/qc-sync/pairing/confirm" body:payload timeout:8.0];
    if (!confirm) {
        NSLog(@"[QuickClipboard] Pair failed: pairing/confirm error from %@", baseURL);
        [[QCLANLogger sharedLogger] error:@"PAIR" fmt:@"POST /qc-sync/pairing/confirm 失败: %@ 无响应或返回非JSON", baseURL];
        return NO;
    }
    NSString *peerToken = confirm[@"peer_token"];
    if (peerToken.length == 0) {
        NSLog(@"[QuickClipboard] Pair failed: no peer_token in response: %@", confirm);
        [[QCLANLogger sharedLogger] error:@"PAIR" fmt:@"确认响应缺少 peer_token: %@", confirm];
        return NO;
    }
    [[QCLANLogger sharedLogger] info:@"PAIR" fmt:@"配对确认成功, 已获得 peer_token"];

    // Step 3: 保存 peer
    QCLANPeer *peer = [[QCLANPeer alloc] init];
    peer.deviceId  = remoteId;
    peer.name      = remoteName;
    peer.address   = address;
    peer.port      = port;
    peer.baseURL   = baseURL;
    peer.peerToken = peerToken;
    peer.pairCode  = code;
    peer.paired    = YES;
    peer.pairedAt  = [NSDate date];
    peer.lastSeen  = [NSDate date];

    [_peers removeObject:peer];
    [_peers addObject:peer];
    [self savePeers];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:QCLANDevicePairedNotification object:peer];
    });

    NSLog(@"[QuickClipboard] Paired with %@ (%@ via %@, token=%@)", remoteName, remoteId, baseURL, peerToken);
    [[QCLANLogger sharedLogger] info:@"PAIR" fmt:@"配对完成并已保存: %@ (%@)", remoteName, baseURL];
    return YES;
}

#pragma mark - HTTP 客户端辅助 (走 /qc-sync/* 端点)

- (NSDictionary *)httpGetJSON:(NSString *)urlString timeout:(NSTimeInterval)timeout {
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:timeout];
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.connectionProxyDictionary = @{};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    __block NSDictionary *result = nil;
    __block NSError *capturedError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data && !err) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) result = json;
            else capturedError = [NSError errorWithDomain:@"QCLANHTTP" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"响应不是JSON"}];
        } else if (err) {
            capturedError = err;
        }
        dispatch_semaphore_signal(sem);
    }] resume];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 1) * NSEC_PER_SEC)));
    if (capturedError) {
        [[QCLANLogger sharedLogger] error:@"NET" fmt:@"GET %@ 失败: %@ (code=%ld)",
         urlString, capturedError.localizedDescription ?: @"?", (long)capturedError.code];
    }
    return result;
}

- (NSDictionary *)httpPostJSON:(NSString *)baseURL path:(NSString *)path body:(NSDictionary *)body timeout:(NSTimeInterval)timeout {
    NSURL *url = [NSURL URLWithString:[baseURL stringByAppendingString:path]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:timeout];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.connectionProxyDictionary = @{};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    __block NSDictionary *result = nil;
    __block NSError *capturedError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data && !err) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) result = json;
            else capturedError = [NSError errorWithDomain:@"QCLANHTTP" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"响应不是JSON"}];
        } else if (err) {
            capturedError = err;
        }
        dispatch_semaphore_signal(sem);
    }] resume];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 1) * NSEC_PER_SEC)));
    if (capturedError) {
        [[QCLANLogger sharedLogger] error:@"NET" fmt:@"POST %@%@ 失败: %@ (code=%ld)",
         baseURL, path, capturedError.localizedDescription ?: @"?", (long)capturedError.code];
    }
    return result;
}


#pragma mark - Peer Management

- (NSArray<QCLANPeer *> *)pairedDevices {
    return [_peers copy];
}

- (NSArray<QCLANPeer *> *)discoveredDevices {
    return [_discoveredPeers.allValues copy];
}

- (void)removePeer:(QCLANPeer *)peer {
    dispatch_async(_queue, ^{
        [self removePeerByDeviceId:peer.deviceId];
    });
}

- (void)removePeerByDeviceId:(NSString *)deviceId {
    QCLANPeer *found = nil;
    for (QCLANPeer *p in _peers) {
        if ([p.deviceId isEqualToString:deviceId]) {
            found = p;
            break;
        }
    }
    if (found) {
        [_peers removeObject:found];
        [self savePeers];
        NSLog(@"[QuickClipboard] Removed peer: %@", deviceId);
        [[QCLANLogger sharedLogger] info:@"UI" fmt:@"已移除已配对设备: %@", deviceId];
    } else {
        [[QCLANLogger sharedLogger] warn:@"UI" fmt:@"移除设备失败: 未找到 %@", deviceId];
    }
}

- (NSDictionary *)peerJSON:(QCLANPeer *)p {
    return @{
        @"device_id":   p.deviceId   ?: @"",
        @"device_name": p.name       ?: @"",
        @"address":     p.address    ?: @"",
        @"port":        @(p.port),
        @"base_url":    p.baseURL    ?: @"",
        @"paired":      @(p.paired),
        @"last_seen":   @(p.lastSeen ? [p.lastSeen timeIntervalSince1970] : 0),
    };
}


#pragma mark - Bonjour

- (void)publishBonjour {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *serviceName = [self deviceName];
        self->_netService = [[NSNetService alloc] initWithDomain:@"local."
                                                            type:@"_quickclipboard._tcp."
                                                            name:serviceName
                                                            port:kDefaultLANPort];

        NSDictionary *txtDict = @{
            @"device_id": [self deviceId],
            @"version":   QC_VERSION,
            @"device":    @"iOS"
        };
        self->_netService.TXTRecordData = [NSNetService dataFromTXTRecordDictionary:txtDict];
        self->_netService.delegate = self;
        [self->_netService publishWithOptions:NSNetServiceListenForConnections];

        NSLog(@"[QuickClipboard] Bonjour publishing: %@._quickclipboard._tcp. on port %d",
              serviceName, kDefaultLANPort);
    });
}

- (void)unpublishBonjour {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_netService) {
            [self->_netService stop];
            self->_netService = nil;
            NSLog(@"[QuickClipboard] Bonjour unpublished");
        }
    });
}

// NSNetServiceDelegate
- (void)netServiceDidPublish:(NSNetService *)sender {
    NSLog(@"[QuickClipboard] Bonjour published: %@", sender.name);
    [[QCLANLogger sharedLogger] info:@"SYS" fmt:@"Bonjour 发布成功: %@._quickclipboard._tcp", sender.name];
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    NSLog(@"[QuickClipboard] Bonjour publish failed: %@", errorDict);
    [[QCLANLogger sharedLogger] warn:@"SYS" fmt:@"Bonjour 发布失败: %@", errorDict];
}


#pragma mark - Data Serialization (本地旧格式, 保留兼容)

- (NSArray *)serializeItems:(NSArray<QCClipItem *> *)items {
    NSMutableArray *arr = [NSMutableArray array];
    for (QCClipItem *item in items) [arr addObject:[item toDictionary]];
    return arr;
}

- (void)mergeRemoteItems:(NSArray *)arr fromAddress:(NSString *)address {
    BOOL receivedNew = NO;
    for (NSDictionary *dict in arr) {
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        QCClipItem *item = [QCClipItem fromDictionary:dict];
        QCClipItem *existing = [[QCStore sharedStore] itemWithCheckSum:item.checkSum];
        if (!existing) {
            [[QCStore sharedStore] saveItem:item];
            receivedNew = YES;
        }
    }
    if (receivedNew) {
        [[NSNotificationCenter defaultCenter] postNotificationName:QCClipDidChangeNotification object:nil];
        BOOL notifyEnabled = [QCLANPrefs boolForKey:@"lanSyncNotifyEnabled" defaultValue:NO];
        if (notifyEnabled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:QCLANSyncReceivedNotification
                                                                    object:nil
                                                                  userInfo:@{@"count": @(arr.count)}];
            });
        }
    }
}


#pragma mark - Sync Operations (走桌面端 /qc-sync/records/history + Bearer 授权)

- (void)broadcastChange {
    NSArray *peers = [_peers copy];
    if (peers.count > 0) {
        [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"剪贴板变化, 自动推送到 %lu 台已配对设备", (unsigned long)peers.count];
    }
    for (QCLANPeer *peer in peers) {
        [self pushToPeer:peer completion:nil];
    }
}

- (void)pushToPeer:(QCLANPeer *)peer completion:(void (^)(BOOL success, NSString *message))completion {
    if (!peer.peerToken.length || !peer.baseURL.length) {
        NSLog(@"[QuickClipboard] Push skipped: peer %@ not paired", peer.deviceId);
        [[QCLANLogger sharedLogger] warn:@"SYNC" fmt:@"推送跳过: %@ 未配对", peer.deviceId];
        if (completion) completion(NO, @"设备未配对");
        return;
    }

    NSArray *items = [[QCStore sharedStore] allItems];
    NSMutableArray *records = [NSMutableArray array];
    for (QCClipItem *item in items) {
        [records addObject:[self cloudRecordFromItem:item]];
    }
    if (records.count == 0) {
        // 本机没有记录时明确提示, 避免"点了没反应"的困惑
        [[QCLANLogger sharedLogger] warn:@"SYNC" fmt:@"推送跳过: 本机剪贴板暂无记录 (%@)", peer.baseURL];
        if (completion) completion(NO, @"本机剪贴板暂无记录可推送");
        return;
    }
    NSDictionary *batch = @{@"collection": @"history", @"records": records};
    NSData *json = [NSJSONSerialization dataWithJSONObject:batch options:0 error:nil];

    NSString *urlStr = [peer.baseURL stringByAppendingString:@"/qc-sync/records/history"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = json;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", peer.peerToken] forHTTPHeaderField:@"Authorization"];
    [req setValue:[self deviceId] forHTTPHeaderField:@"X-Device-Id"];
    req.timeoutInterval = 30.0;

    NSLog(@"[QuickClipboard] Pushing %lu records to %@ (%@)", (unsigned long)records.count, peer.deviceId, peer.baseURL);
    [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"推送 %lu 条记录到 %@ (%@)",
     (unsigned long)records.count, peer.name ?: peer.deviceId, peer.baseURL];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.connectionProxyDictionary = @{};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = [(NSHTTPURLResponse *)response statusCode];
        BOOL ok = code == 200;
        NSString *detail = nil;
        if (data.length > 0) {
            NSDictionary *respJson = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([respJson isKindOfClass:[NSDictionary class]]) {
                detail = respJson[@"message"];
            }
        }
        if (!ok) {
            NSLog(@"[QuickClipboard] Push to %@ failed: %@ (HTTP %ld)", peer.deviceId,
                  error.localizedDescription ?: (detail ?: @"非200响应"), (long)code);
            [[QCLANLogger sharedLogger] error:@"SYNC" fmt:@"推送到 %@ 失败: %@ (HTTP %ld, 详情: %@)",
             peer.baseURL, error.localizedDescription ?: @"非200响应", (long)code,
             detail ?: @"(无)"];
        } else {
            [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"推送成功: %@", peer.baseURL];
        }
        if (completion) {
            if (ok) {
                // 桌面端增量同步: 响应体带 pushed 数量, 0 表示对方已是最新 (并非没反应)
                NSInteger pushedCount = 0;
                if ([respJson isKindOfClass:[NSDictionary class]]) {
                    pushedCount = [respJson[@"pushed"] integerValue];
                }
                if (pushedCount > 0) {
                    [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"推送成功: %@ (%ld 条)",
                     peer.baseURL, (long)pushedCount];
                    completion(YES, [NSString stringWithFormat:@"已推送 %ld 条记录", (long)pushedCount]);
                } else {
                    [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"推送完成: %@ (双方已同步, 0 条)",
                     peer.baseURL];
                    completion(YES, @"已同步，双方无新内容（0 条）");
                }
            } else if (error) {
                completion(NO, error.localizedDescription ?: @"推送失败");
            } else if (detail.length > 0) {
                // 桌面端 403 等会返回具体原因 (如: 局域网接收已关闭), 直接透传给用户
                completion(NO, [NSString stringWithFormat:@"对方拒绝: %@", detail]);
            } else {
                completion(NO, [NSString stringWithFormat:@"推送失败 (HTTP %ld)", (long)code]);
            }
        }
    }] resume];
}

- (void)pullFromPeer:(QCLANPeer *)peer completion:(void (^)(BOOL success, NSString *message))completion {
    if (!peer.peerToken.length || !peer.baseURL.length) {
        NSLog(@"[QuickClipboard] Pull skipped: peer %@ not paired", peer.deviceId);
        [[QCLANLogger sharedLogger] warn:@"SYNC" fmt:@"拉取跳过: %@ 未配对", peer.deviceId];
        if (completion) completion(NO, @"设备未配对");
        return;
    }

    NSString *urlStr = [peer.baseURL stringByAppendingString:@"/qc-sync/records/history"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.timeoutInterval = 30.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", peer.peerToken] forHTTPHeaderField:@"Authorization"];
    [req setValue:[self deviceId] forHTTPHeaderField:@"X-Device-Id"];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.connectionProxyDictionary = @{};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    NSLog(@"[QuickClipboard] Pulling from %@ (%@)", peer.deviceId, peer.baseURL);
    [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"从 %@ 拉取记录 (%@)",
     peer.name ?: peer.deviceId, peer.baseURL];

    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data) {
            NSLog(@"[QuickClipboard] Pull from %@ failed: %@", peer.deviceId, error.localizedDescription);
            [[QCLANLogger sharedLogger] error:@"SYNC" fmt:@"从 %@ 拉取失败: %@",
             peer.baseURL, error.localizedDescription ?: @"无数据"];
            if (completion) completion(NO, error.localizedDescription ?: @"拉取失败");
            return;
        }
        NSDictionary *batch = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *records = [batch isKindOfClass:[NSDictionary class]] ? batch[@"records"] : nil;
        NSUInteger count = 0;
        QCClipItem *latestItem = nil;
        if ([records isKindOfClass:[NSArray class]]) {
            NSMutableArray *received = [NSMutableArray array];
            for (NSDictionary *dict in records) {
                QCClipItem *item = [self itemFromCloudRecord:dict];
                if (!item) continue;
                QCClipItem *existing = [[QCStore sharedStore] itemWithCheckSum:item.checkSum];
                if (!existing) {
                    [[QCStore sharedStore] saveItem:item];
                    count++;
                    latestItem = item;
                }
            }
            if (count > 0) {
                [[NSNotificationCenter defaultCenter] postNotificationName:QCClipDidChangeNotification object:nil];
                // 关键修复: 拉取到的记录写入系统剪贴板, 用户可直接粘贴
                if (latestItem) {
                    [[QCClipManager sharedManager] writeItemToPasteboard:latestItem];
                    NSString *preview = latestItem.textRepresentation;
                    if (preview.length > 40) preview = [preview substringToIndex:40];
                    [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"已把拉取内容写入剪贴板: %@", preview];
                }
            }
        }
        [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"拉取完成: 新增 %lu 条", (unsigned long)count];
        if (completion) completion(YES, [NSString stringWithFormat:@"拉取 %lu 条", (unsigned long)count]);
    }] resume];
}


#pragma mark - Helpers

- (NSString *)deviceName {
    return [[UIDevice currentDevice] name];
}

- (NSString *)primaryLocalIP {
    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) != 0) return nil;
    NSString *ip = nil;
    for (struct ifaddrs *ifa = ifaddr; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        if (strncmp(ifa->ifa_name, "lo", 2) == 0) continue;
        char addrBuf[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr, addrBuf, sizeof(addrBuf));
        ip = [NSString stringWithUTF8String:addrBuf];
        break;
    }
    freeifaddrs(ifaddr);
    return ip;
}

- (NSArray<NSString *> *)localIPAddresses {
    NSMutableArray *ips = [NSMutableArray array];
    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) == 0) {
        for (struct ifaddrs *ifa = ifaddr; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            if (strncmp(ifa->ifa_name, "lo", 2) == 0) continue;
            char addrBuf[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr, addrBuf, sizeof(addrBuf));
            NSString *ip = [NSString stringWithUTF8String:addrBuf];
            if (![ips containsObject:ip]) [ips addObject:ip];
        }
        freeifaddrs(ifaddr);
    }
    return ips;
}

- (BOOL)isLocalAddress:(NSString *)addr {
    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) != 0) return NO;

    BOOL isLocal = NO;
    for (struct ifaddrs *ifa = ifaddr; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        char ip[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr, ip, sizeof(ip));
        if ([addr isEqualToString:[NSString stringWithUTF8String:ip]]) {
            isLocal = YES;
            break;
        }
    }
    freeifaddrs(ifaddr);
    return isLocal;
}

@end
