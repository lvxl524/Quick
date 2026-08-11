#import "QCLANServer.h"
#import "QCStore.h"
#import "QCDeviceAuthenticator.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

static const uint16_t kDefaultLANPort = 35691;

@implementation QCLANPeer
@end

@interface QCLANServer () {
    int _listenSocket;
    dispatch_queue_t _queue;
    dispatch_source_t _source;
    NSMutableArray<QCLANPeer *> *_peers;
    NSString *_pairCode;
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
        _port = kDefaultLANPort;
        [self generatePairCode];
        [self loadPeers];
    }
    return self;
}

- (void)generatePairCode {
    uint32_t code = arc4random_uniform(900000) + 100000;
    _pairCode = [NSString stringWithFormat:@"%06u", code];
}

- (void)loadPeers {
    NSString *path = @"/var/mobile/Library/QuickClipboard/peers.plist";
    NSArray *arr = [NSArray arrayWithContentsOfFile:path];
    for (NSDictionary *dict in arr) {
        QCLANPeer *peer = [[QCLANPeer alloc] init];
        peer.name = dict[@"name"];
        peer.address = dict[@"address"];
        peer.pairCode = dict[@"pairCode"];
        [_peers addObject:peer];
    }
}

- (void)savePeers {
    NSString *path = @"/var/mobile/Library/QuickClipboard/peers.plist";
    NSMutableArray *arr = [NSMutableArray array];
    for (QCLANPeer *peer in _peers) {
        [arr addObject:@{@"name":peer.name ?: @"", @"address":peer.address ?: @"", @"pairCode":peer.pairCode ?: @""}];
    }
    [arr writeToFile:path atomically:YES];
}

- (void)start {
    dispatch_async(_queue, ^{
        if (self->_listenSocket > 0) return;
        self->_listenSocket = socket(AF_INET, SOCK_STREAM, 0);
        if (self->_listenSocket < 0) return;
        int on = 1;
        setsockopt(self->_listenSocket, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(kDefaultLANPort);
        addr.sin_addr.s_addr = INADDR_ANY;
        if (bind(self->_listenSocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            close(self->_listenSocket);
            self->_listenSocket = 0;
            return;
        }
        listen(self->_listenSocket, 5);
        self->_source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, self->_listenSocket, 0, self->_queue);
        dispatch_source_set_event_handler(self->_source, ^{
            [self acceptConnection];
        });
        dispatch_resume(self->_source);
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
    });
}

- (void)acceptConnection {
    struct sockaddr_in clientAddr;
    socklen_t len = sizeof(clientAddr);
    int client = accept(_listenSocket, (struct sockaddr *)&clientAddr, &len);
    if (client < 0) return;
    dispatch_async(_queue, ^{
        [self handleClient:client];
    });
}

- (void)handleClient:(int)clientSocket {
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
            if ([arr isKindOfClass:[NSArray class]]) [self mergeRemoteItems:arr];
        }
        responseData = [@"{\"ok\":true}" dataUsingEncoding:NSUTF8StringEncoding];
    } else if ([request containsString:@"GET /ping"]) {
        NSString *resp = [NSString stringWithFormat:@"{\"name\":\"%@\",\"code\":\"%@\"}", [self deviceName], _pairCode];
        responseData = [resp dataUsingEncoding:NSUTF8StringEncoding];
    }
    
    NSString *status = responseData ? @"200 OK" : @"404 Not Found";
    NSString *headers = [NSString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", status, (unsigned long)responseData.length];
    NSMutableData *full = [NSMutableData data];
    [full appendData:[headers dataUsingEncoding:NSUTF8StringEncoding]];
    if (responseData) [full appendData:responseData];
    send(clientSocket, full.bytes, full.length, 0);
    close(clientSocket);
}

- (NSArray *)serializeItems:(NSArray<QCClipItem *> *)items {
    NSMutableArray *arr = [NSMutableArray array];
    for (QCClipItem *item in items) [arr addObject:[item toDictionary]];
    return arr;
}

- (void)mergeRemoteItems:(NSArray *)arr {
    for (NSDictionary *dict in arr) {
        QCClipItem *item = [QCClipItem fromDictionary:dict];
        QCClipItem *existing = [[QCStore sharedStore] itemWithCheckSum:item.checkSum];
        if (!existing) [[QCStore sharedStore] saveItem:item];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:QCClipDidChangeNotification object:nil];
}

- (void)broadcastChange {
    for (QCLANPeer *peer in [_peers copy]) {
        [self pushToPeer:peer completion:nil];
    }
}

- (void)pairWithAddress:(NSString *)address code:(NSString *)code completion:(void (^)(BOOL success, NSString *message))completion {
    [self pingAddress:address completion:^(BOOL ok, NSString *name) {
        if (!ok) { completion(NO, @"无法连接设备"); return; }
        QCLANPeer *peer = [[QCLANPeer alloc] init];
        peer.name = name;
        peer.address = address;
        peer.pairCode = code;
        peer.lastSeen = [NSDate date];
        [self->_peers addObject:peer];
        [self savePeers];
        [[NSNotificationCenter defaultCenter] postNotificationName:QCLANDevicePairedNotification object:peer];
        completion(YES, [NSString stringWithFormat:@"已配对 %@", name]);
    }];
}

- (void)pingAddress:(NSString *)address completion:(void (^)(BOOL success, NSString *name))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%d/ping", address, kDefaultLANPort]];
    NSURLRequest *req = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data) { completion(NO, nil); return; }
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        completion(dict != nil, dict[@"name"]);
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
        completion(ok, ok ? @"已推送" : error.localizedDescription);
    }] resume];
}

- (void)pullFromPeer:(QCLANPeer *)peer completion:(void (^)(BOOL success, NSString *message))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@:%d/sync", peer.address, kDefaultLANPort]];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!data) { completion(NO, error.localizedDescription); return; }
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([arr isKindOfClass:[NSArray class]]) [self mergeRemoteItems:arr];
        completion(YES, [NSString stringWithFormat:@"拉取 %lu 条", (unsigned long)arr.count]);
    }] resume];
}

- (NSString *)deviceName {
    return [[UIDevice currentDevice] name];
}

- (NSArray<QCLANPeer *> *)pairedDevices {
    return [_peers copy];
}

@end
