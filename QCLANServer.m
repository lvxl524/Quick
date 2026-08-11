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


#pragma mark - QCLANPeer

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


#pragma mark - QCLANServer

@interface QCLANServer () <NSNetServiceDelegate> {
    int _listenSocket;
    int _discoverySocket;
    dispatch_queue_t _queue;
    dispatch_source_t _listenSource;
    dispatch_source_t _discoverySource;
    NSMutableArray<QCLANPeer *> *_peers;
    NSMutableDictionary<NSString *, QCLANPeer *> *_discoveredPeers;
    NSString *_pairCode;
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
        _peers = [NSMutableArray array];
        _discoveredPeers = [NSMutableDictionary dictionary];
        _port = kDefaultLANPort;
        _listenSocket = 0;
        _discoverySocket = 0;
        _running = NO;
        [self generatePairCode];
        [self loadPeers];
    }
    return self;
}

- (BOOL)isRunning {
    return _running;
}

#pragma mark - Pairing Code

- (void)generatePairCode {
    uint32_t code = arc4random_uniform(900000) + 100000;
    _pairCode = [NSString stringWithFormat:@"%06u", code];
    [[NSUserDefaults standardUserDefaults] setObject:_pairCode forKey:@"lanPairingCode"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - Peer Persistence

- (void)loadPeers {
    NSString *path = @"/var/mobile/Library/QuickClipboard/peers.plist";
    NSArray *arr = [NSArray arrayWithContentsOfFile:path];
    [_peers removeAllObjects];
    for (NSDictionary *dict in arr) {
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        QCLANPeer *peer = [[QCLANPeer alloc] init];
        peer.name     = dict[@"name"]     ?: @"Unknown";
        peer.address  = dict[@"address"]  ?: @"";
        peer.port     = [dict[@"port"] unsignedShortValue] ?: kDefaultLANPort;
        peer.pairCode = dict[@"pairCode"] ?: @"";
        peer.paired   = YES;
        peer.peerId   = [NSString stringWithFormat:@"%@:%hu", peer.address, peer.port];
        peer.lastSeen = [NSDate date];
        [_peers addObject:peer];
    }
    NSLog(@"[QuickClipboard] Loaded %lu paired peers", (unsigned long)_peers.count);
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
            @"name":     peer.name     ?: @"",
            @"address":  peer.address  ?: @"",
            @"port":     @(peer.port),
            @"pairCode": peer.pairCode ?: @""
        }];
    }
    [arr writeToFile:path atomically:YES];
    NSLog(@"[QuickClipboard] Saved %lu peers", (unsigned long)_peers.count);
}


#pragma mark - Server Lifecycle

- (void)start {
    dispatch_async(_queue, ^{
        if (self->_running) {
            NSLog(@"[QuickClipboard] LAN server already running");
            return;
        }
        NSLog(@"[QuickClipboard] Starting LAN server...");
        [self startHTTPServer];
        [self startDiscoveryListener];
        self->_running = YES;
        [self publishBonjour];
        NSLog(@"[QuickClipboard] LAN server started on port %d, pair code: %@", kDefaultLANPort, self->_pairCode);
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


#pragma mark - HTTP Server

- (void)startHTTPServer {
    _listenSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (_listenSocket < 0) {
        NSLog(@"[QuickClipboard] ERROR: Failed to create TCP socket: %s", strerror(errno));
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
        close(_listenSocket);
        _listenSocket = 0;
        return;
    }

    if (listen(_listenSocket, 10) < 0) {
        NSLog(@"[QuickClipboard] ERROR: Failed to listen: %s", strerror(errno));
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

- (void)handleClient:(int)clientSocket fromAddress:(NSString *)address {
    // Read request with timeout
    struct timeval tv;
    tv.tv_sec = 10;
    tv.tv_usec = 0;
    setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    char buffer[16384];
    ssize_t received = recv(clientSocket, buffer, sizeof(buffer) - 1, 0);
    if (received <= 0) { close(clientSocket); return; }
    buffer[received] = '\0';
    NSString *request = [NSString stringWithUTF8String:buffer];

    // Parse HTTP request line
    NSArray *lines = [request componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) { close(clientSocket); return; }

    NSString *firstLine = lines[0];
    NSArray *reqParts = [firstLine componentsSeparatedByString:@" "];
    if (reqParts.count < 2) { close(clientSocket); return; }

    NSString *method = reqParts[0];
    NSString *path = reqParts[1];

    // Extract body for POST requests
    NSString *body = nil;
    NSRange bodySep = [request rangeOfString:@"\r\n\r\n"];
    if (bodySep.location != NSNotFound) {
        body = [request substringFromIndex:bodySep.location + 4];
    }

    NSLog(@"[QuickClipboard] HTTP %@ %@ from %@", method, path, address);

    NSData *responseData = nil;
    int statusCode = 200;
    NSString *contentType = @"application/json";

    // ---- Route: GET /ping ----
    if ([path isEqualToString:@"/ping"]) {
        NSDictionary *info = @{
            @"name": [self deviceName],
            @"code": _pairCode,
            @"port": @(kDefaultLANPort),
            @"version": QC_VERSION
        };
        responseData = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];

    // ---- Route: GET /scan ----
    } else if ([path isEqualToString:@"/scan"]) {
        NSArray *results = [self performScanNow];
        NSMutableArray *jsonDevices = [NSMutableArray array];
        for (QCLANPeer *p in results) {
            [jsonDevices addObject:@{
                @"name":     p.name     ?: @"",
                @"address":  p.address  ?: @"",
                @"port":     @(p.port),
                @"pairCode": p.pairCode ?: @"",
                @"peerId":   p.peerId   ?: @"",
                @"paired":   @(p.paired)
            }];
        }
        responseData = [NSJSONSerialization dataWithJSONObject:@{@"devices": jsonDevices} options:0 error:nil];

    // ---- Route: POST /pair ----
    } else if ([path isEqualToString:@"/pair"] && [method isEqualToString:@"POST"]) {
        NSDictionary *req = body ? [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        NSString *pairAddr = req[@"address"];
        NSNumber *pairPort = req[@"port"];
        NSString *pairCode = req[@"code"];
        uint16_t port = pairPort ? [pairPort unsignedShortValue] : kDefaultLANPort;

        if (!pairAddr || !pairCode) {
            responseData = [self jsonError:@"缺少 address 或 code 参数"];
            statusCode = 400;
        } else {
            BOOL ok = [self verifyAndPairAddress:pairAddr port:port code:pairCode];
            if (ok) {
                responseData = [NSJSONSerialization dataWithJSONObject:@{@"ok": @YES, @"message": @"配对成功"} options:0 error:nil];
            } else {
                responseData = [self jsonError:@"配对失败：无法验证配对码或设备不可达"];
                statusCode = 400;
            }
        }

    // ---- Route: GET /peers ----
    } else if ([path isEqualToString:@"/peers"] && [method isEqualToString:@"GET"]) {
        NSMutableArray *jsonPeers = [NSMutableArray array];
        for (QCLANPeer *p in _peers) {
            [jsonPeers addObject:@{
                @"name":     p.name     ?: @"",
                @"address":  p.address  ?: @"",
                @"port":     @(p.port),
                @"pairCode": p.pairCode ?: @"",
                @"peerId":   p.peerId   ?: @"",
                @"paired":   @(p.paired),
                @"lastSeen": @([p.lastSeen timeIntervalSince1970])
            }];
        }
        responseData = [NSJSONSerialization dataWithJSONObject:@{@"peers": jsonPeers} options:0 error:nil];

    // ---- Route: DELETE /peers ----
    } else if ([path hasPrefix:@"/peers/"] && [method isEqualToString:@"DELETE"]) {
        NSString *peerId = [path substringFromIndex:7]; // remove "/peers/"
        peerId = [peerId stringByRemovingPercentEncoding];
        [self removePeerById:peerId];
        responseData = [NSJSONSerialization dataWithJSONObject:@{@"ok": @YES} options:0 error:nil];

    // ---- Route: GET /sync ----
    } else if ([path isEqualToString:@"/sync"] && [method isEqualToString:@"GET"]) {
        NSArray *items = [[QCStore sharedStore] allItems];
        responseData = [NSJSONSerialization dataWithJSONObject:[self serializeItems:items] options:0 error:nil];

    // ---- Route: POST /sync ----
    } else if ([path isEqualToString:@"/sync"] && [method isEqualToString:@"POST"]) {
        if (body) {
            NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
            NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([arr isKindOfClass:[NSArray class]]) {
                [self mergeRemoteItems:arr fromAddress:address];
            }
        }
        responseData = [NSJSONSerialization dataWithJSONObject:@{@"ok": @YES, @"synced": @YES} options:0 error:nil];

    // ---- Route: GET /info ----
    } else if ([path isEqualToString:@"/info"] || [path isEqualToString:@"/"]) {
        NSDictionary *info = @{
            @"name":    [self deviceName],
            @"code":    _pairCode,
            @"port":    @(kDefaultLANPort),
            @"version": QC_VERSION,
            @"running": @(_running),
            @"peers":   @(_peers.count)
        };
        responseData = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];

    } else {
        responseData = [self jsonError:@"Not Found"];
        statusCode = 404;
    }

    // Send response
    NSString *statusStr = statusCode == 200 ? @"200 OK" :
                          statusCode == 400 ? @"400 Bad Request" : @"404 Not Found";

    if (!responseData) {
        responseData = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    }

    NSString *headers = [NSString stringWithFormat:
        @"HTTP/1.1 %@\r\n"
        @"Content-Type: %@\r\n"
        @"Content-Length: %lu\r\n"
        @"Connection: close\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"Server: QuickClipboard/%@@\r\n"
        @"\r\n",
        statusStr, contentType,
        (unsigned long)responseData.length, QC_VERSION];

    NSMutableData *full = [NSMutableData data];
    [full appendData:[headers dataUsingEncoding:NSUTF8StringEncoding]];
    [full appendData:responseData];
    send(clientSocket, full.bytes, full.length, 0);
    close(clientSocket);
}

- (NSData *)jsonError:(NSString *)message {
    return [NSJSONSerialization dataWithJSONObject:@{@"error": message} options:0 error:nil];
}


#pragma mark - Discovery Listener (UDP port 35693)

- (void)startDiscoveryListener {
    _discoverySocket = socket(AF_INET, SOCK_DGRAM, 0);
    if (_discoverySocket < 0) {
        NSLog(@"[QuickClipboard] ERROR: Failed to create discovery UDP socket: %s", strerror(errno));
        return;
    }

    int on = 1;
    setsockopt(_discoverySocket, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
    setsockopt(_discoverySocket, SOL_SOCKET, SO_BROADCAST, &on, sizeof(on));

    // Increase receive buffer
    int rcvBuf = 256 * 1024;
    setsockopt(_discoverySocket, SOL_SOCKET, SO_RCVBUF, &rcvBuf, sizeof(rcvBuf));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kDiscoveryPort);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(_discoverySocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[QuickClipboard] ERROR: Failed to bind discovery port %d: %s", kDiscoveryPort, strerror(errno));
        close(_discoverySocket);
        _discoverySocket = 0;
        return;
    }

    _discoverySource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _discoverySocket, 0, _queue);
    dispatch_source_set_event_handler(_discoverySource, ^{
        // Drain all available packets
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

    if (len <= 0) return; // EAGAIN means no more data

    buffer[len] = '\0';
    NSString *msg = [NSString stringWithUTF8String:buffer];
    NSString *senderIP = [NSString stringWithUTF8String:inet_ntoa(senderAddr.sin_addr)];

    // Ignore our own broadcasts
    if ([self isLocalAddress:senderIP]) return;

    if ([msg isEqualToString:kDiscoveryMagic]) {
        // Someone is scanning — reply with QC_HERE
        NSString *deviceName = [self deviceName];
        NSString *reply = [NSString stringWithFormat:@"%@|%@|%hu|%@",
                           kDiscoveryReply, deviceName, kDefaultLANPort, _pairCode];
        NSData *replyData = [reply dataUsingEncoding:NSUTF8StringEncoding];
        ssize_t sent = sendto(_discoverySocket, replyData.bytes, replyData.length, 0,
                             (struct sockaddr *)&senderAddr, senderLen);
        NSLog(@"[QuickClipboard] Discovery reply sent to %@:%d (%zd bytes)",
              senderIP, ntohs(senderAddr.sin_port), sent);

    } else if ([msg hasPrefix:kDiscoveryReply]) {
        // We received a discovery reply
        NSArray *parts = [msg componentsSeparatedByString:@"|"];
        if (parts.count >= 4) {
            NSString *name  = parts[1];
            uint16_t port   = (uint16_t)[parts[2] intValue] ?: kDefaultLANPort;
            NSString *code  = parts[3];

            QCLANPeer *peer = [[QCLANPeer alloc] init];
            peer.name     = name;
            peer.address  = senderIP;
            peer.port     = port;
            peer.pairCode = code;
            peer.peerId   = [NSString stringWithFormat:@"%@:%hu", senderIP, port];
            peer.lastSeen = [NSDate date];
            peer.paired   = NO;

            for (QCLANPeer *p in _peers) {
                if ([p.peerId isEqualToString:peer.peerId]) {
                    peer.paired = YES;
                    peer.name  = p.name;
                    break;
                }
            }

            @synchronized (_discoveredPeers) {
                _discoveredPeers[peer.peerId] = peer;
            }
            NSLog(@"[QuickClipboard] Discovered: %@@%@:%d (paired=%d)", name, senderIP, port, peer.paired);
        }
    }
}


#pragma mark - Scanning

- (void)scanForDevicesWithCompletion:(void (^)(NSArray<QCLANPeer *> *devices))completion {
    dispatch_async(_queue, ^{
        [self performScanWithCompletion:completion];
    });
}

- (void)performScanWithCompletion:(void (^)(NSArray<QCLANPeer *> *devices))completion {
    [_discoveredPeers removeAllObjects];

    // Send discovery broadcast on all interfaces
    [self sendDiscoveryBroadcast];

    // Wait for replies
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), _queue, ^{
        // Resend once more for reliability
        [self sendDiscoveryBroadcast];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), self->_queue, ^{
            NSArray *results = [self->_discoveredPeers.allValues sortedArrayUsingComparator:^NSComparisonResult(QCLANPeer *a, QCLANPeer *b) {
                return [a.name compare:b.name];
            }];

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(results);
            });
        });
    });
}

// Synchronous scan used by HTTP /scan endpoint
// Runs on a temporary global queue to avoid deadlocking _queue
- (NSArray<QCLANPeer *> *)performScanNow {
    dispatch_queue_t scanQueue = dispatch_queue_create("com.mosheng.qc.scantmp", DISPATCH_QUEUE_SERIAL);
    __block NSArray *results = @[];

    dispatch_sync(scanQueue, ^{
        NSMutableDictionary<NSString *, QCLANPeer *> *found = [NSMutableDictionary dictionary];

        [self sendDiscoveryBroadcast];

        // Wait 2.5s with a poll loop
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.5];
        BOOL resent = NO;

        while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
            // Check for new discoveries
            @synchronized (self->_discoveredPeers) {
                for (NSString *key in self->_discoveredPeers) {
                    if (!found[key]) {
                        found[key] = self->_discoveredPeers[key];
                    }
                }
            }

            // Resend halfway
            if (!resent && [[NSDate date] timeIntervalSinceDate:deadline] < -1.5) {
                [self sendDiscoveryBroadcast];
                resent = YES;
            }

            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }

        results = [found.allValues sortedArrayUsingComparator:^NSComparisonResult(QCLANPeer *a, QCLANPeer *b) {
            return [a.name compare:b.name];
        }];
    });

    return results;
}

- (void)sendDiscoveryBroadcast {
    // Use a separate socket for sending broadcasts
    int sendSock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sendSock < 0) {
        NSLog(@"[QuickClipboard] ERROR: Failed to create broadcast socket: %s", strerror(errno));
        return;
    }

    int on = 1;
    setsockopt(sendSock, SOL_SOCKET, SO_BROADCAST, &on, sizeof(on));

    NSData *data = [kDiscoveryMagic dataUsingEncoding:NSUTF8StringEncoding];

    // 1. Global broadcast
    struct sockaddr_in broadAddr;
    memset(&broadAddr, 0, sizeof(broadAddr));
    broadAddr.sin_family = AF_INET;
    broadAddr.sin_port = htons(kDiscoveryPort);
    broadAddr.sin_addr.s_addr = inet_addr("255.255.255.255");
    sendto(sendSock, data.bytes, data.length, 0,
           (struct sockaddr *)&broadAddr, sizeof(broadAddr));

    // 2. Subnet broadcasts on each interface
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

            char ipStr[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &bcastAddr.sin_addr, ipStr, sizeof(ipStr));
            NSLog(@"[QuickClipboard] Broadcast to %s on %s", ipStr, ifa->ifa_name);
        }
        freeifaddrs(ifaddr);
    }

    close(sendSock);
    NSLog(@"[QuickClipboard] Discovery broadcast sent");
}


#pragma mark - Pairing (with code validation)

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

- (BOOL)verifyAndPairAddress:(NSString *)address port:(uint16_t)port code:(NSString *)code {
    // Step 1: Ping the device to verify it's reachable and get its pair code
    __block NSDictionary *pingResult = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%d/ping", address, port];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:5.0];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.connectionProxyDictionary = @{}; // bypass proxy
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data && !err) {
            pingResult = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }
        dispatch_semaphore_signal(sem);
    }] resume];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)));

    if (!pingResult) {
        NSLog(@"[QuickClipboard] Pair failed: device %@:%d unreachable", address, port);
        return NO;
    }

    NSString *remoteName = pingResult[@"name"];
    NSString *remoteCode = pingResult[@"code"];

    // Step 2: Validate pairing code
    if (![remoteCode isEqualToString:code]) {
        NSLog(@"[QuickClipboard] Pair failed: code mismatch (expected %@, got %@)", code, remoteCode);
        return NO;
    }

    // Step 3: Create/update peer
    QCLANPeer *peer = [[QCLANPeer alloc] init];
    peer.name     = remoteName ?: address;
    peer.address  = address;
    peer.port     = port;
    peer.pairCode = code;
    peer.peerId   = [NSString stringWithFormat:@"%@:%hu", address, port];
    peer.lastSeen = [NSDate date];
    peer.paired   = YES;

    [_peers removeObject:peer]; // remove duplicate
    [_peers addObject:peer];
    [self savePeers];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:QCLANDevicePairedNotification object:peer];
    });

    NSLog(@"[QuickClipboard] Paired with %@ (%@@:%d)", remoteName, address, port);
    return YES;
}

- (void)pingAddress:(NSString *)address completion:(void (^)(BOOL success, NSString *name))completion {
    [self pingAddress:address port:kDefaultLANPort completion:completion];
}

- (void)pingAddress:(NSString *)address port:(uint16_t)port completion:(void (^)(BOOL success, NSString *name))completion {
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%d/ping", address, port];
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


#pragma mark - Peer Management

- (NSArray<QCLANPeer *> *)pairedDevices {
    return [_peers copy];
}

- (NSArray<QCLANPeer *> *)discoveredDevices {
    return [_discoveredPeers.allValues copy];
}

- (void)removePeer:(QCLANPeer *)peer {
    dispatch_async(_queue, ^{
        [self removePeerById:peer.peerId];
    });
}

- (void)removePeerById:(NSString *)peerId {
    QCLANPeer *found = nil;
    for (QCLANPeer *p in _peers) {
        if ([p.peerId isEqualToString:peerId]) {
            found = p;
            break;
        }
    }
    if (found) {
        [_peers removeObject:found];
        [self savePeers];
        NSLog(@"[QuickClipboard] Removed peer: %@", peerId);
    }
}


#pragma mark - Bonjour

- (void)publishBonjour {
    // Publish _quickclipboard._tcp service via Bonjour
    // This allows desktop clients to discover the iOS device without manual IP entry
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *serviceName = [self deviceName];
        self->_netService = [[NSNetService alloc] initWithDomain:@"local."
                                                            type:@"_quickclipboard._tcp."
                                                            name:serviceName
                                                            port:kDefaultLANPort];

        // TXT record with extra info
        NSDictionary *txtDict = @{
            @"code":    self->_pairCode,
            @"version": QC_VERSION,
            @"device":  @"iOS"
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
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    NSLog(@"[QuickClipboard] Bonjour publish failed: %@", errorDict);
}


#pragma mark - Data Serialization

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


#pragma mark - Sync Operations

- (void)broadcastChange {
    for (QCLANPeer *peer in [_peers copy]) {
        [self pushToPeer:peer completion:nil];
    }
}

- (void)pushToPeer:(QCLANPeer *)peer completion:(void (^)(BOOL success, NSString *message))completion {
    NSArray *items = [[QCStore sharedStore] allItems];
    NSData *json = [NSJSONSerialization dataWithJSONObject:[self serializeItems:items] options:0 error:nil];

    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%d/sync", peer.address, peer.port];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = json;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 10.0;

    NSLog(@"[QuickClipboard] Pushing %lu items to %@", (unsigned long)items.count, peer.peerId);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL ok = [(NSHTTPURLResponse *)response statusCode] == 200;
        if (!ok) NSLog(@"[QuickClipboard] Push to %@ failed: %@", peer.peerId, error.localizedDescription);
        if (completion) completion(ok, ok ? @"已推送" : error.localizedDescription ?: @"推送失败");
    }] resume];
}

- (void)pullFromPeer:(QCLANPeer *)peer completion:(void (^)(BOOL success, NSString *message))completion {
    NSString *urlStr = [NSString stringWithFormat:@"http://%@:%d/sync", peer.address, peer.port];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 10.0;

    NSLog(@"[QuickClipboard] Pulling from %@", peer.peerId);

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data) {
            NSLog(@"[QuickClipboard] Pull from %@ failed: %@", peer.peerId, error.localizedDescription);
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
