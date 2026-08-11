#import "QCLANServer.h"
#import "QCStore.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>

static const uint16_t kDefaultLANPort    = 35691;
static const uint16_t kDiscoveryPort     = 35693;
static NSString * const kDiscoveryMagic  = @"QC_DISCOVER";
static NSString * const kDiscoveryReply  = @"QC_HERE";

@interface QCLANServer () {
    int _listenSocket;
    int _discoverySocket;
    dispatch_queue_t _queue;
    dispatch_source_t _source;
    dispatch_source_t _discoverySource;
    NSMutableArray<QCLANPeer *> *_peers;
    NSMutableDictionary<NSString *, QCLANPeer *> *_discoveredPeers;
    NSString *_pairCode;
}
@end

@implementation QCLANPeer

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[QCLANPeer class]]) return NO;
    return [self.peerId isEqualToString:((QCLANPeer *)object).peerId];
}

- (NSUInteger)hash {
    return self.peerId.hash;
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
        _peers = [NSMutableArray array];
        _discoveredPeers = [NSMutableDictionary dictionary];
        _port = kDefaultLANPort;
        [self generatePairCode];
        [self loadPeers];
    }
    return self;
}

- (void)generatePairCode {
    uint32_t code = arc4random_uniform(900000) + 100000;
    _pairCode = [NSString stringWithFormat:@"%06u", code];
    // Save to defaults so preference bundle can read it
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSUserDefaults standardUserDefaults] setObject:_pairCode forKey:@"lanPairingCode"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    });
}

- (void)loadPeers {
    NSString *path = @"/var/mobile/Library/QuickClipboard/peers.plist";
    NSArray *arr = [NSArray arrayWithContentsOfFile:path];
    for (NSDictionary *dict in arr) {
        QCLANPeer *peer = [[QCLANPeer alloc] init];
        peer.name   = dict[@"name"];
        peer.address = dict[@"address"];
        peer.port   = [dict[@"port"] unsignedShortValue] ?: kDefaultLANPort;
        peer.pairCode = dict[@"pairCode"];
        peer.paired = YES;
        peer.peerId = [NSString stringWithFormat:@"%@:%hu", peer.address, peer.port];
        peer.lastSeen = [NSDate date];
        [_peers addObject:peer];
    }
}

- (void)savePeers {
    NSString *path = @"/var/mobile/Library/QuickClipboard/peers.plist";
    NSMutableArray *arr = [NSMutableArray array];
    for (QCLANPeer *peer in _peers) {
        [arr addObject:@{
            @"name":    peer.name    ?: @"",
            @"address": peer.address ?: @"",
            @"port":    @(peer.port),
            @"pairCode":peer.pairCode ?: @""
        }];
    }
    [arr writeToFile:path atomically:YES];
}

#pragma mark - Server lifecycle

- (void)start {
    dispatch_async(_queue, ^{
        [self startHTTPServer];
        [self startDiscoveryListener];
    });
}

- (void)stop {
    dispatch_async(_queue, ^{
        if (self->_source) {
            dispatch_source_cancel(self->_source);
            self->_source = nil;
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
    });
}

- (void)startHTTPServer {
    if (_listenSocket > 0) return;
    _listenSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (_listenSocket < 0) return;
    int on = 1;
    setsockopt(_listenSocket, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kDefaultLANPort);
    addr.sin_addr.s_addr = INADDR_ANY;
    if (bind(_listenSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(_listenSocket);
        _listenSocket = 0;
        return;
    }
    listen(_listenSocket, 5);
    _source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _listenSocket, 0, _queue);
    dispatch_source_set_event_handler(_source, ^{
        [self acceptConnection];
    });
    dispatch_resume(_source);
}

- (void)startDiscoveryListener {
    _discoverySocket = socket(AF_INET, SOCK_DGRAM, 0);
    if (_discoverySocket < 0) return;

    int on = 1;
    setsockopt(_discoverySocket, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    setsockopt(_discoverySocket, SOL_SOCKET, SO_BROADCAST, &on, sizeof(on));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kDiscoveryPort);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(_discoverySocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(_discoverySocket);
        _discoverySocket = 0;
        return;
    }

    _discoverySource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _discoverySocket, 0, _queue);
    dispatch_source_set_event_handler(_discoverySource, ^{
        [self handleDiscoveryPacket];
    });
    dispatch_resume(_discoverySource);
}

- (void)handleDiscoveryPacket {
    char buffer[1024];
    struct sockaddr_in senderAddr;
    socklen_t senderLen = sizeof(senderAddr);
    ssize_t len = recvfrom(_discoverySocket, buffer, sizeof(buffer) - 1, 0,
                           (struct sockaddr *)&senderAddr, &senderLen);
    if (len <= 0) return;
    buffer[len] = '\0';
    NSString *msg = [NSString stringWithUTF8String:buffer];

    NSString *senderIP = [NSString stringWithUTF8String:inet_ntoa(senderAddr.sin_addr)];

    if ([msg isEqualToString:kDiscoveryMagic]) {
        // Someone is scanning — reply with our info
        NSString *deviceName = [[UIDevice currentDevice] name];
        NSString *reply = [NSString stringWithFormat:@"%@|%@|%hu|%@",
                           kDiscoveryReply, deviceName, kDefaultLANPort, _pairCode];
        NSData *replyData = [reply dataUsingEncoding:NSUTF8StringEncoding];
        sendto(_discoverySocket, replyData.bytes, replyData.length, 0,
               (struct sockaddr *)&senderAddr, senderLen);
    } else if ([msg hasPrefix:kDiscoveryReply]) {
        // We received a reply to our own scan — parse device info
        // Format: QC_HERE|DeviceName|Port|PairCode
        NSArray *parts = [msg componentsSeparatedByString:@"|"];
        if (parts.count >= 4) {
            NSString *name = parts[1];
            uint16_t port = (uint16_t)[parts[2] intValue];
            NSString *code = parts[3];

            QCLANPeer *peer = [[QCLANPeer alloc] init];
            peer.name    = name;
            peer.address = senderIP;
            peer.port    = port;
            peer.pairCode = code;
            peer.peerId  = [NSString stringWithFormat:@"%@:%hu", senderIP, port];
            peer.lastSeen = [NSDate date];
            peer.paired  = NO;

            // Check if already paired
            for (QCLANPeer *p in _peers) {
                if ([p.peerId isEqualToString:peer.peerId]) {
                    peer.paired = YES;
                    peer.name = p.name; // use stored name
                    break;
                }
            }

            _discoveredPeers[peer.peerId] = peer;
        }
    }
}

#pragma mark - Scanning

- (void)scanForDevicesWithCompletion:(void (^)(NSArray<QCLANPeer *> *devices))completion {
    dispatch_async(_queue, ^{
        [self->_discoveredPeers removeAllObjects];

        // Send UDP broadcast on all network interfaces
        [self sendDiscoveryBroadcast];

        // Wait 2.5 seconds for replies, then return results
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), self->_queue, ^{
            NSArray *results = [self->_discoveredPeers.allValues sortedArrayUsingComparator:^NSComparisonResult(QCLANPeer *a, QCLANPeer *b) {
                return [a.name compare:b.name];
            }];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(results);
            });
        });
    });
}

- (void)sendDiscoveryBroadcast {
    if (_discoverySocket <= 0) return;

    NSData *data = [kDiscoveryMagic dataUsingEncoding:NSUTF8StringEncoding];

    // Broadcast to 255.255.255.255
    struct sockaddr_in broadAddr;
    memset(&broadAddr, 0, sizeof(broadAddr));
    broadAddr.sin_family = AF_INET;
    broadAddr.sin_port = htons(kDiscoveryPort);
    broadAddr.sin_addr.s_addr = inet_addr("255.255.255.255");

    sendto(_discoverySocket, data.bytes, data.length, 0,
           (struct sockaddr *)&broadAddr, sizeof(broadAddr));

    // Also try subnet broadcast for each interface
    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) == 0) {
        for (struct ifaddrs *ifa = ifaddr; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            // Skip loopback
            if (strncmp(ifa->ifa_name, "lo", 2) == 0) continue;

            struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
            struct sockaddr_in *mask = (struct sockaddr_in *)ifa->ifa_netmask;
            if (!mask) continue;

            // Calculate subnet broadcast
            uint32_t ip   = ntohl(sin->sin_addr.s_addr);
            uint32_t nm   = ntohl(mask->sin_addr.s_addr);
            uint32_t bcast = ip | ~nm;

            struct sockaddr_in bcastAddr;
            memset(&bcastAddr, 0, sizeof(bcastAddr));
            bcastAddr.sin_family = AF_INET;
            bcastAddr.sin_port = htons(kDiscoveryPort);
            bcastAddr.sin_addr.s_addr = htonl(bcast);

            sendto(_discoverySocket, data.bytes, data.length, 0,
                   (struct sockaddr *)&bcastAddr, sizeof(bcastAddr));
        }
        freeifaddrs(ifaddr);
    }
}

#pragma mark - Device management

- (void)removePeer:(QCLANPeer *)peer {
    dispatch_async(_queue, ^{
        [self->_peers removeObject:peer];
        [self savePeers];
    });
}

- (NSArray<QCLANPeer *> *)pairedDevices {
    return [_peers copy];
}

- (NSArray<QCLANPeer *> *)discoveredDevices {
    return [_discoveredPeers.allValues copy];
}

#pragma mark - HTTP connection handling

- (void)acceptConnection {
    struct sockaddr_in clientAddr;
    socklen_t len = sizeof(clientAddr);
    int client = accept(_listenSocket, (struct sockaddr *)&clientAddr, &len);
    if (client < 0) return;
    dispatch_async(_queue, ^{
        [self handleClient:client fromAddress:[NSString stringWithUTF8String:inet_ntoa(clientAddr.sin_addr)]];
    });
}

- (void)handleClient:(int)clientSocket fromAddress:(NSString *)address {
    char buffer[8192];
    ssize_t received = recv(clientSocket, buffer, sizeof(buffer) - 1, 0);
    if (received <= 0) { close(clientSocket); return; }
    buffer[received] = '\0';
    NSString *request = [NSString stringWithUTF8String:buffer];

    NSData *responseData = nil;
    if ([request containsString:@"GET /sync"]) {
        NSArray *items = [[QCStore sharedStore] allItems];
        responseData = [NSJSONSerialization dataWithJSONObject:[self serializeItems:items] options:0 error:nil];
    } else if ([request containsString:@"POST /sync"]) {
        NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
        if (bodyRange.location != NSNotFound) {
            NSString *body = [request substringFromIndex:bodyRange.location + bodyRange.length];
            NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
            NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([arr isKindOfClass:[NSArray class]]) {
                [self mergeRemoteItems:arr fromAddress:address];
            }
        }
        responseData = [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
    } else if ([request containsString:@"GET /ping"]) {
        NSString *resp = [NSString stringWithFormat:@"{\"name\":\"%@\",\"code\":\"%@\"}", [self deviceName], _pairCode];
        responseData = [resp dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSString *status = responseData ? @"200 OK" : @"404 Not Found";
    NSString *headers = [NSString stringWithFormat:
        @"HTTP/1.1 %@\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
        status, (unsigned long)responseData.length];
    NSMutableData *full = [NSMutableData data];
    [full appendData:[headers dataUsingEncoding:NSUTF8StringEncoding]];
    if (responseData) [full appendData:responseData];
    send(clientSocket, full.bytes, full.length, 0);
    close(clientSocket);
}

#pragma mark - Serialization

- (NSArray *)serializeItems:(NSArray<QCClipItem *> *)items {
    NSMutableArray *arr = [NSMutableArray array];
    for (QCClipItem *item in items) [arr addObject:[item toDictionary]];
    return arr;
}

- (void)mergeRemoteItems:(NSArray *)arr fromAddress:(NSString *)address {
    BOOL receivedNew = NO;
    for (NSDictionary *dict in arr) {
        QCClipItem *item = [QCClipItem fromDictionary:dict];
        QCClipItem *existing = [[QCStore sharedStore] itemWithCheckSum:item.checkSum];
        if (!existing) {
            [[QCStore sharedStore] saveItem:item];
            receivedNew = YES;
        }
    }
    if (receivedNew) {
        [[NSNotificationCenter defaultCenter] postNotificationName:QCClipDidChangeNotification object:nil];
        // Post sync notification if enabled
        BOOL notifyEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"lanSyncNotifyEnabled"];
        if (notifyEnabled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:QCLANSyncReceivedNotification
                                                                    object:nil
                                                                  userInfo:@{@"count": @(arr.count)}];
            });
        }
    }
}

#pragma mark - Sync operations

- (void)broadcastChange {
    for (QCLANPeer *peer in [_peers copy]) {
        [self pushToPeer:peer completion:nil];
    }
}

- (void)pairWithAddress:(NSString *)address code:(NSString *)code completion:(void (^)(BOOL success, NSString *message))completion {
    [self pingAddress:address completion:^(BOOL ok, NSString *name) {
        if (!ok) {
            if (completion) completion(NO, @"无法连接设备，请确认对方已开启 HTTP 服务");
            return;
        }
        QCLANPeer *peer = [[QCLANPeer alloc] init];
        peer.name     = name;
        peer.address  = address;
        peer.port     = kDefaultLANPort;
        peer.pairCode = code;
        peer.peerId   = [NSString stringWithFormat:@"%@:%hu", address, kDefaultLANPort];
        peer.lastSeen = [NSDate date];
        peer.paired   = YES;

        // Remove duplicate if exists
        [self->_peers removeObject:peer];

        [self->_peers addObject:peer];
        [self savePeers];

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:QCLANDevicePairedNotification object:peer];
        });
        if (completion) completion(YES, [NSString stringWithFormat:@"已与 %@ 配对成功", name]);
    }];
}

- (void)pingAddress:(NSString *)address completion:(void (^)(BOOL success, NSString *name))completion {
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%d/ping", address, kDefaultLANPort];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSURLRequest *req = [NSURLRequest requestWithURL:url
                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                     timeoutInterval:5.0];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data || error) {
            if (completion) completion(NO, nil);
            return;
        }
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (completion) completion(dict != nil, dict[@"name"]);
    }] resume];
}

- (void)pushToPeer:(QCLANPeer *)peer completion:(void (^)(BOOL success, NSString *message))completion {
    NSArray *items = [[QCStore sharedStore] allItems];
    NSData *json = [NSJSONSerialization dataWithJSONObject:[self serializeItems:items] options:0 error:nil];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%d/sync", peer.address, kDefaultLANPort]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.HTTPBody = json;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL ok = [(NSHTTPURLResponse *)response statusCode] == 200;
        if (completion) completion(ok, ok ? @"已推送" : error.localizedDescription ?: @"推送失败");
    }] resume];
}

- (void)pullFromPeer:(QCLANPeer *)peer completion:(void (^)(BOOL success, NSString *message))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%d/sync", peer.address, kDefaultLANPort]];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data) {
            if (completion) completion(NO, error.localizedDescription);
            return;
        }
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([arr isKindOfClass:[NSArray class]]) {
            [self mergeRemoteItems:arr fromAddress:peer.address];
        }
        if (completion) completion(YES, [NSString stringWithFormat:@"拉取 %lu 条", (unsigned long)arr.count]);
    }] resume];
}

#pragma mark - Helpers

- (NSString *)deviceName {
    return [[UIDevice currentDevice] name];
}

@end
