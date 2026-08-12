#import "QCLANController.h"
#import "QCLANServer.h"
#import "QCLANLogger.h"
#import "QCLANPrefs.h"
#import "QCStore.h"
#import <objc/runtime.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <netinet/in.h>

static NSString * const kLocalBaseURL = @"http://127.0.0.1:35691";


#pragma mark - UIButton Category

@implementation UIButton (QCLANPeerID)
static const void *kDeviceIdKey = &kDeviceIdKey;
- (NSString *)deviceId { return objc_getAssociatedObject(self, kDeviceIdKey); }
- (void)setDeviceId:(NSString *)deviceId { objc_setAssociatedObject(self, kDeviceIdKey, deviceId, OBJC_ASSOCIATION_COPY_NONATOMIC); }
@end


#pragma mark - Status Pill Component

@interface QCLANStatusPill : UIView
- (instancetype)initWithLabel:(NSString *)label value:(NSString *)value active:(BOOL)active;
- (void)updateValue:(NSString *)value active:(BOOL)active;
@end

@implementation QCLANStatusPill {
    UILabel *_labelLabel;
    UILabel *_valueLabel;
    BOOL _active;
}

- (instancetype)initWithLabel:(NSString *)label value:(NSString *)value active:(BOOL)active {
    self = [super init];
    if (self) {
        _active = active;
        self.layer.cornerRadius = 10;
        self.layer.masksToBounds = YES;
        [self applyStyle];

        _labelLabel = [[UILabel alloc] init];
        _labelLabel.text = label;
        _labelLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _labelLabel.textColor = [UIColor secondaryLabelColor];
        _labelLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_labelLabel];

        _valueLabel = [[UILabel alloc] init];
        _valueLabel.text = value;
        _valueLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
        _valueLabel.textColor = [UIColor labelColor];
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_valueLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_labelLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [_labelLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_valueLabel.leadingAnchor constraintEqualToAnchor:_labelLabel.trailingAnchor constant:3],
            [_valueLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.trailingAnchor constraintEqualToAnchor:_valueLabel.trailingAnchor constant:10],
            [self.heightAnchor constraintEqualToConstant:26],
        ]];
    }
    return self;
}

- (void)updateValue:(NSString *)value active:(BOOL)active {
    _valueLabel.text = value;
    _active = active;
    [self applyStyle];
}

- (void)applyStyle {
    if (_active) {
        self.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.12];
        self.layer.borderWidth = 1;
        self.layer.borderColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.35].CGColor;
    } else {
        self.backgroundColor = [UIColor tertiarySystemGroupedBackgroundColor];
        self.layer.borderWidth = 0;
    }
}
@end


#pragma mark - Card Component

@interface QCLANCardView : UIView
@property (nonatomic, strong) UIView *contentView;
- (instancetype)initWithTitle:(NSString *)title;
@end

@implementation QCLANCardView

- (instancetype)initWithTitle:(NSString *)title {
    self = [super init];
    if (self) {
        self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        self.layer.cornerRadius = 14;
        self.layer.masksToBounds = YES;

        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = title;
        titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        titleLabel.textColor = [UIColor secondaryLabelColor];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:titleLabel];

        _contentView = [[UIView alloc] init];
        _contentView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_contentView];

        [NSLayoutConstraint activateConstraints:@[
            [titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
            [titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [_contentView.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:10],
            [_contentView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [_contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [self.bottomAnchor constraintEqualToAnchor:_contentView.bottomAnchor constant:14],
        ]];
    }
    return self;
}
@end


#pragma mark - Main Controller

@interface QCLANController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) NSMutableArray<QCLANPeer *> *pairedDevices;
@property (nonatomic, strong) NSArray<QCLANPeer *> *discoveredDevices;

@property (nonatomic, assign) BOOL pairCodeVisible;
@property (nonatomic, assign) BOOL isScanning;
@property (nonatomic, assign) BOOL httpRunning;

@property (nonatomic, assign) BOOL sendEnabled;
@property (nonatomic, assign) BOOL receiveEnabled;
@property (nonatomic, assign) BOOL notifyEnabled;

@property (nonatomic, copy) NSString *pairingCode;
@property (nonatomic, copy) NSString *localAddress;

@property (nonatomic, copy) NSString *peersLoadError;
@property (nonatomic, assign) BOOL peersLoadedOnce;

@property (nonatomic, strong) UITextField *peerUrlField;
@property (nonatomic, strong) UITextField *peerCodeField;

@property (nonatomic, strong) QCLANStatusPill *httpPill;
@property (nonatomic, strong) QCLANStatusPill *pairedPill;
@property (nonatomic, strong) QCLANStatusPill *dataPill;
@property (nonatomic, strong) UILabel *codeLabel;
@property (nonatomic, strong) UILabel *endpointLabel;
@end

@implementation QCLANController

- (void)viewDidLoad {
    [super viewDidLoad];

    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"打开局域网设置页 (v%@)", QC_VERSION];

    self.defaults = [NSUserDefaults standardUserDefaults];
    self.pairedDevices = [NSMutableArray array];
    self.discoveredDevices = @[];

    // 三个开关走共享 plist (QCLANPrefs): 与 SpringBoard 进程(tweak) 互通,
    // 否则设置页改了后台收不到
    // v1.3.7: 自动推送默认开启, 实现"手机复制 → 电脑自动接收"开箱即用
    self.sendEnabled    = [QCLANPrefs boolForKey:@"lanSendEnabled" defaultValue:YES];
    self.receiveEnabled = [QCLANPrefs boolForKey:@"lanReceiveEnabled" defaultValue:YES];
    self.notifyEnabled  = [QCLANPrefs boolForKey:@"lanSyncNotifyEnabled" defaultValue:NO];
    self.pairCodeVisible = YES;
    self.httpRunning = YES;

    self.pairingCode = [self.defaults stringForKey:@"lanPairingCode"];
    if (!self.pairingCode || self.pairingCode.length == 0) {
        self.pairingCode = @"------";
    }

    self.localAddress = [self getLocalIPAddress] ?: @"未连接";

    [self loadPeersFromServer];

    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self.view addSubview:self.scrollView];

    [self buildUI];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadPeersFromServer];
    [self refreshServerStatus];
}

#pragma mark - Server Communication (via HTTP to local tweak process)

- (void)loadPeersFromServer {
    [self apiGet:@"/peers" completion:^(NSDictionary *json, NSError *error) {
        if (error || !json) {
            self.peersLoadError = [NSString stringWithFormat:@"无法获取设备列表: %@",
                                   error.localizedDescription ?: @"本地服务无响应"];
            self.peersLoadedOnce = YES;
            [[QCLANLogger sharedLogger] error:@"UI" fmt:@"获取已配对设备列表失败: %@",
             error.localizedDescription ?: @"无响应"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self buildUI];
            });
            return;
        }
        NSArray *peersArr = json[@"peers"];
        if (![peersArr isKindOfClass:[NSArray class]]) {
            self.peersLoadError = @"服务返回异常，请稍后下拉刷新";
            self.peersLoadedOnce = YES;
            [[QCLANLogger sharedLogger] error:@"UI" fmt:@"获取已配对设备列表失败: 响应格式异常"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self buildUI];
            });
            return;
        }

        [self.pairedDevices removeAllObjects];
        for (NSDictionary *dict in peersArr) {
            QCLANPeer *peer = [[QCLANPeer alloc] init];
            peer.name      = dict[@"device_name"] ?: dict[@"name"] ?: @"Unknown";
            peer.address   = dict[@"address"]  ?: @"";
            peer.port      = [dict[@"port"] unsignedShortValue];
            peer.pairCode  = dict[@"pairCode"] ?: @"";
            peer.deviceId  = dict[@"device_id"] ?: dict[@"deviceId"] ?: @"";
            peer.baseURL   = dict[@"base_url"] ?: @"";
            peer.peerToken = dict[@"peer_token"] ?: @"";
            peer.paired    = [dict[@"paired"] boolValue];
            // v1.3.7 修复: 服务端 peerJSON 输出的是 last_seen (下划线), 旧版读 lastSeen 永远取不到
            // → 解析为 1970 → 显示"496253小时前"。兼容两种字段名, 无效时间置 nil。
            double lastSeenTs = [dict[@"last_seen"] doubleValue];
            if (lastSeenTs <= 0) lastSeenTs = [dict[@"lastSeen"] doubleValue];
            peer.lastSeen  = lastSeenTs > 0 ? [NSDate dateWithTimeIntervalSince1970:lastSeenTs] : nil;
            if (peer.paired) [self.pairedDevices addObject:peer];
        }
        self.peersLoadError = nil;
        self.peersLoadedOnce = YES;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self buildUI];
        });
    }];
}

- (void)refreshServerStatus {
    [self apiGet:@"/ping" completion:^(NSDictionary *json, NSError *error) {
        if (json) {
            self.httpRunning = YES;
            NSString *code = json[@"code"];
            if (code) {
                self.pairingCode = code;
            }
        } else {
            self.httpRunning = NO;
            [[QCLANLogger sharedLogger] error:@"UI" fmt:@"本地服务 /ping 无响应: %@",
             error.localizedDescription ?: @"未知错误 (SpringBoard 端服务可能未启动)"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.httpPill) {
                [self.httpPill updateValue:self.httpRunning ? @"运行中" : @"已停止" active:self.httpRunning];
            }
        });
    }];
}

- (void)performScanViaServer {
    self.isScanning = YES;
    self.discoveredDevices = @[];
    [self buildUI]; // show scanning button state
    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"用户点击: 扫描局域网"];

    [self apiGet:@"/scan" completion:^(NSDictionary *json, NSError *error) {
        self.isScanning = NO;

        if (error || !json) {
            [[QCLANLogger sharedLogger] error:@"SCAN" fmt:@"扫描请求失败: %@",
             error.localizedDescription ?: @"无响应"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self buildUI];
                [self showAlert:@"扫描失败" message:error.localizedDescription ?: @"无法连接本地扫描服务"];
            });
            return;
        }

        NSMutableArray *devices = [NSMutableArray array];
        NSArray *devicesArr = json[@"devices"];
        if ([devicesArr isKindOfClass:[NSArray class]]) {
            for (NSDictionary *dict in devicesArr) {
                QCLANPeer *peer = [[QCLANPeer alloc] init];
                peer.name      = dict[@"device_name"] ?: dict[@"name"] ?: @"Unknown";
                peer.address   = dict[@"address"]  ?: @"";
                peer.port      = [dict[@"port"] unsignedShortValue];
                peer.pairCode  = dict[@"pairCode"] ?: @"";
                peer.deviceId  = dict[@"device_id"] ?: dict[@"deviceId"] ?: @"";
                peer.baseURL   = dict[@"base_url"] ?: @"";
                peer.peerToken = dict[@"peer_token"] ?: @"";
                peer.paired    = [dict[@"paired"] boolValue];
                [devices addObject:peer];
            }
        }
        self.discoveredDevices = devices;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self buildUI];
            if (devices.count == 0) {
                [[QCLANLogger sharedLogger] info:@"SCAN" fmt:@"扫描完成: 未发现设备 (共3秒, 2轮广播)"];
                [self showAlert:@"扫描完成"
                        message:@"未发现局域网设备。请确认：\n\n1. 电脑端 QuickClipboard 已开启局域网同步服务\n2. 手机和电脑在同一局域网\n3. 防火墙未阻止 UDP 35692 / TCP 35691 端口\n\n提示：也可手动输入电脑 IP + 配对码进行配对"];
            } else {
                NSMutableString *names = [NSMutableString string];
                for (QCLANPeer *p in devices) {
                    [names appendFormat:@"%@(%@) ", p.name ?: @"?", p.address ?: @"?"];
                }
                [[QCLANLogger sharedLogger] info:@"SCAN" fmt:@"扫描完成: 发现 %lu 台 -> %@",
                 (unsigned long)devices.count, names];
            }
        });
    }];
}

- (void)performPairWithAddress:(NSString *)addr code:(NSString *)code {
    NSDictionary *body = @{@"address": addr, @"code": code, @"port": @(35691)};
    [[QCLANLogger sharedLogger] info:@"PAIR" fmt:@"发起配对: %@ 码=%@", addr, code];

    [self apiPost:@"/pair" body:body completion:^(NSDictionary *json, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (json[@"ok"]) {
                self.peerUrlField.text = @"";
                self.peerCodeField.text = @"";
                [self loadPeersFromServer];
                [[QCLANLogger sharedLogger] info:@"PAIR" fmt:@"配对成功: %@", addr];
                [self showAlert:@"配对成功" message:@"设备已成功配对"];
            } else {
                NSString *msg = json[@"error"] ?: @"配对失败，请检查配对码是否正确";
                [[QCLANLogger sharedLogger] error:@"PAIR" fmt:@"配对失败 %@: %@", addr, msg];
                [self showAlert:@"配对失败" message:msg];
            }
        });
    }];
}

- (void)performRemovePeer:(NSString *)deviceId {
    NSString *encoded = [deviceId stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *path = [NSString stringWithFormat:@"/peers/%@", encoded];

    [self apiDelete:path completion:^(NSDictionary *json, NSError *error) {
        if (error || !json) {
            [[QCLANLogger sharedLogger] error:@"UI" fmt:@"删除设备请求失败: %@",
             error.localizedDescription ?: @"无响应"];
        } else {
            [[QCLANLogger sharedLogger] info:@"UI" fmt:@"已删除设备: %@", deviceId];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self loadPeersFromServer];
        });
    }];
}

#pragma mark - HTTP Helpers

- (void)apiGet:(NSString *)path completion:(void (^)(NSDictionary *json, NSError *error))completion {
    NSString *urlStr = [kLocalBaseURL stringByAppendingString:path];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:8.0];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) {
            if (completion) completion(nil, err);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (completion) completion(json, nil);
    }] resume];
}

- (void)apiPost:(NSString *)path body:(NSDictionary *)body completion:(void (^)(NSDictionary *json, NSError *error))completion {
    NSString *urlStr = [kLocalBaseURL stringByAppendingString:path];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:8.0];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) {
            if (completion) completion(nil, err);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (completion) completion(json, nil);
    }] resume];
}

- (void)apiDelete:(NSString *)path completion:(void (^)(NSDictionary *json, NSError *error))completion {
    NSString *urlStr = [kLocalBaseURL stringByAppendingString:path];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:8.0];
    req.HTTPMethod = @"DELETE";

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) {
            if (completion) completion(nil, err);
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (completion) completion(json, nil);
    }] resume];
}


#pragma mark - UI Builder

- (void)buildUI {
    for (UIView *v in self.scrollView.subviews) { [v removeFromSuperview]; }

    CGFloat pad = 16;
    CGFloat w = self.view.bounds.size.width - pad * 2;

    // ==========================================
    // Card 1: Service Status
    // ==========================================
    QCLANCardView *svcCard = [[QCLANCardView alloc] initWithTitle:@"HTTP 服务"];
    [self.scrollView addSubview:svcCard];

    UIView *toggleRow = [self toggleRowWithLabel:self.httpRunning ? @"运行中" : @"已停止"
                                        subtitle:@"局域网剪贴板同步服务 (运行于 SpringBoard)"
                                           isOn:self.httpRunning
                                         action:@selector(serviceToggled:)];

    UIView *pillsRow = [[UIView alloc] init];
    pillsRow.translatesAutoresizingMaskIntoConstraints = NO;
    [svcCard.contentView addSubview:pillsRow];

    self.httpPill   = [[QCLANStatusPill alloc] initWithLabel:@"HTTP" value:self.httpRunning ? @"运行中" : @"已停止" active:self.httpRunning];
    self.pairedPill = [[QCLANStatusPill alloc] initWithLabel:@"已配对" value:[NSString stringWithFormat:@"%lu台", (unsigned long)self.pairedDevices.count] active:NO];
    self.dataPill   = [[QCLANStatusPill alloc] initWithLabel:@"数据" value:[NSString stringWithFormat:@"%ld条", (long)[self clipCount]] active:NO];

    for (QCLANStatusPill *pill in @[self.httpPill, self.pairedPill, self.dataPill]) {
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        [pillsRow addSubview:pill];
    }

    [svcCard.contentView addSubview:toggleRow];
    toggleRow.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        [toggleRow.topAnchor constraintEqualToAnchor:svcCard.contentView.topAnchor],
        [toggleRow.leadingAnchor constraintEqualToAnchor:svcCard.contentView.leadingAnchor],
        [toggleRow.trailingAnchor constraintEqualToAnchor:svcCard.contentView.trailingAnchor],
        [toggleRow.heightAnchor constraintEqualToConstant:50],

        [pillsRow.topAnchor constraintEqualToAnchor:toggleRow.bottomAnchor constant:6],
        [pillsRow.leadingAnchor constraintEqualToAnchor:svcCard.contentView.leadingAnchor],
        [pillsRow.trailingAnchor constraintEqualToAnchor:svcCard.contentView.trailingAnchor],
        [pillsRow.bottomAnchor constraintEqualToAnchor:svcCard.contentView.bottomAnchor],
        [pillsRow.heightAnchor constraintEqualToConstant:28],

        [self.httpPill.leadingAnchor constraintEqualToAnchor:pillsRow.leadingAnchor],
        [self.httpPill.centerYAnchor constraintEqualToAnchor:pillsRow.centerYAnchor],
        [self.pairedPill.leadingAnchor constraintEqualToAnchor:self.httpPill.trailingAnchor constant:6],
        [self.pairedPill.centerYAnchor constraintEqualToAnchor:pillsRow.centerYAnchor],
        [self.dataPill.leadingAnchor constraintEqualToAnchor:self.pairedPill.trailingAnchor constant:6],
        [self.dataPill.centerYAnchor constraintEqualToAnchor:pillsRow.centerYAnchor],
    ]];

    svcCard.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [svcCard.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor constant:pad],
        [svcCard.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:pad],
        [svcCard.widthAnchor constraintEqualToConstant:w],
    ]];

    UIView *lastView = svcCard;

    // ==========================================
    // Card 2: Local Info
    // ==========================================
    QCLANCardView *localCard = [[QCLANCardView alloc] initWithTitle:@"本机信息"];
    [self.scrollView addSubview:localCard];

    UILabel *pcTitle = [[UILabel alloc] init];
    pcTitle.text = @"配对码";
    pcTitle.font = [UIFont systemFontOfSize:12];
    pcTitle.textColor = [UIColor secondaryLabelColor];
    pcTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [localCard.contentView addSubview:pcTitle];

    UIButton *toggleVisBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [toggleVisBtn setTitle:self.pairCodeVisible ? @"隐藏" : @"显示" forState:UIControlStateNormal];
    toggleVisBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    toggleVisBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [toggleVisBtn addTarget:self action:@selector(togglePairCodeVisibility) forControlEvents:UIControlEventTouchUpInside];
    [localCard.contentView addSubview:toggleVisBtn];

    UIButton *refreshBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [refreshBtn setTitle:@"刷新" forState:UIControlStateNormal];
    refreshBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    refreshBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [refreshBtn addTarget:self action:@selector(refreshPairingCode) forControlEvents:UIControlEventTouchUpInside];
    [localCard.contentView addSubview:refreshBtn];

    self.codeLabel = [[UILabel alloc] init];
    self.codeLabel.text = self.pairCodeVisible ? self.pairingCode : @"\u2022\u2022\u2022\u2022\u2022\u2022";
    self.codeLabel.font = [UIFont monospacedSystemFontOfSize:32 weight:UIFontWeightMedium];
    self.codeLabel.textAlignment = NSTextAlignmentCenter;
    self.codeLabel.textColor = [UIColor labelColor];
    self.codeLabel.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.codeLabel.layer.cornerRadius = 10;
    self.codeLabel.layer.masksToBounds = YES;
    self.codeLabel.layer.borderWidth = 1;
    self.codeLabel.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.5].CGColor;
    self.codeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [localCard.contentView addSubview:self.codeLabel];

    UILabel *epTitle = [[UILabel alloc] init];
    epTitle.text = @"本机地址";
    epTitle.font = [UIFont systemFontOfSize:12];
    epTitle.textColor = [UIColor secondaryLabelColor];
    epTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [localCard.contentView addSubview:epTitle];

    self.endpointLabel = [[UILabel alloc] init];
    self.endpointLabel.text = [NSString stringWithFormat:@"http://%@:35691", self.localAddress];
    self.endpointLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.endpointLabel.textColor = [UIColor labelColor];
    self.endpointLabel.numberOfLines = 0;
    self.endpointLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [localCard.contentView addSubview:self.endpointLabel];

    // Bonjour info
    UILabel *bonjourLabel = [[UILabel alloc] init];
    bonjourLabel.text = @"Bonjour: _quickclipboard._tcp (可被电脑端自动发现)";
    bonjourLabel.font = [UIFont systemFontOfSize:10];
    bonjourLabel.textColor = [UIColor tertiaryLabelColor];
    bonjourLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [localCard.contentView addSubview:bonjourLabel];

    [NSLayoutConstraint activateConstraints:@[
        [pcTitle.topAnchor constraintEqualToAnchor:localCard.contentView.topAnchor],
        [pcTitle.leadingAnchor constraintEqualToAnchor:localCard.contentView.leadingAnchor],
        [toggleVisBtn.centerYAnchor constraintEqualToAnchor:pcTitle.centerYAnchor],
        [toggleVisBtn.trailingAnchor constraintEqualToAnchor:refreshBtn.leadingAnchor constant:-4],
        [refreshBtn.centerYAnchor constraintEqualToAnchor:pcTitle.centerYAnchor],
        [refreshBtn.trailingAnchor constraintEqualToAnchor:localCard.contentView.trailingAnchor],

        [self.codeLabel.topAnchor constraintEqualToAnchor:pcTitle.bottomAnchor constant:8],
        [self.codeLabel.leadingAnchor constraintEqualToAnchor:localCard.contentView.leadingAnchor],
        [self.codeLabel.trailingAnchor constraintEqualToAnchor:localCard.contentView.trailingAnchor],
        [self.codeLabel.heightAnchor constraintEqualToConstant:54],

        [epTitle.topAnchor constraintEqualToAnchor:self.codeLabel.bottomAnchor constant:14],
        [epTitle.leadingAnchor constraintEqualToAnchor:localCard.contentView.leadingAnchor],
        [epTitle.trailingAnchor constraintEqualToAnchor:localCard.contentView.trailingAnchor],

        [self.endpointLabel.topAnchor constraintEqualToAnchor:epTitle.bottomAnchor constant:4],
        [self.endpointLabel.leadingAnchor constraintEqualToAnchor:localCard.contentView.leadingAnchor],
        [self.endpointLabel.trailingAnchor constraintEqualToAnchor:localCard.contentView.trailingAnchor],

        [bonjourLabel.topAnchor constraintEqualToAnchor:self.endpointLabel.bottomAnchor constant:4],
        [bonjourLabel.leadingAnchor constraintEqualToAnchor:localCard.contentView.leadingAnchor],
        [bonjourLabel.trailingAnchor constraintEqualToAnchor:localCard.contentView.trailingAnchor],
        [bonjourLabel.bottomAnchor constraintEqualToAnchor:localCard.contentView.bottomAnchor],
    ]];

    localCard.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [localCard.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:12],
        [localCard.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:pad],
        [localCard.widthAnchor constraintEqualToConstant:w],
    ]];
    lastView = localCard;

    // ==========================================
    // Card 3: Connect Device
    // ==========================================
    QCLANCardView *connectCard = [[QCLANCardView alloc] initWithTitle:@"连接设备"];
    [self.scrollView addSubview:connectCard];

    UIButton *scanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [scanBtn setTitle:self.isScanning ? @"扫描中..." : @"扫描局域网" forState:UIControlStateNormal];
    scanBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    scanBtn.backgroundColor = self.isScanning ? [UIColor systemGrayColor] : [UIColor systemBlueColor];
    [scanBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    scanBtn.layer.cornerRadius = 10;
    scanBtn.enabled = !self.isScanning;
    scanBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [scanBtn addTarget:self action:@selector(scanLan) forControlEvents:UIControlEventTouchUpInside];
    [connectCard.contentView addSubview:scanBtn];

    // Discovered devices
    UIView *discoveredContainer = [[UIView alloc] init];
    discoveredContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [connectCard.contentView addSubview:discoveredContainer];

    if (self.discoveredDevices.count > 0) {
        UIView *prevRow = nil;
        for (QCLANPeer *peer in self.discoveredDevices) {
            UIView *row = [self discoveredDeviceRow:peer];
            row.translatesAutoresizingMaskIntoConstraints = NO;
            [discoveredContainer addSubview:row];

            [NSLayoutConstraint activateConstraints:@[
                [row.leadingAnchor constraintEqualToAnchor:discoveredContainer.leadingAnchor],
                [row.trailingAnchor constraintEqualToAnchor:discoveredContainer.trailingAnchor],
                [row.heightAnchor constraintEqualToConstant:56],
            ]];
            if (prevRow) {
                [row.topAnchor constraintEqualToAnchor:prevRow.bottomAnchor constant:6].active = YES;
            } else {
                [row.topAnchor constraintEqualToAnchor:discoveredContainer.topAnchor].active = YES;
            }
            prevRow = row;
        }
        [discoveredContainer.bottomAnchor constraintEqualToAnchor:prevRow.bottomAnchor].active = YES;
    }

    UIView *divider = [[UIView alloc] init];
    divider.backgroundColor = [UIColor separatorColor];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    [connectCard.contentView addSubview:divider];

    UILabel *manualTitle = [[UILabel alloc] init];
    manualTitle.text = @"手动配对";
    manualTitle.font = [UIFont systemFontOfSize:12];
    manualTitle.textColor = [UIColor secondaryLabelColor];
    manualTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [connectCard.contentView addSubview:manualTitle];

    self.peerUrlField = [[UITextField alloc] init];
    self.peerUrlField.placeholder = @"192.168.1.10";
    self.peerUrlField.borderStyle = UITextBorderStyleRoundedRect;
    self.peerUrlField.font = [UIFont systemFontOfSize:14];
    self.peerUrlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.peerUrlField.keyboardType = UIKeyboardTypeDecimalPad;
    self.peerUrlField.translatesAutoresizingMaskIntoConstraints = NO;
    [connectCard.contentView addSubview:self.peerUrlField];

    self.peerCodeField = [[UITextField alloc] init];
    self.peerCodeField.placeholder = @"配对码";
    self.peerCodeField.borderStyle = UITextBorderStyleRoundedRect;
    self.peerCodeField.font = [UIFont systemFontOfSize:14];
    self.peerCodeField.translatesAutoresizingMaskIntoConstraints = NO;
    [connectCard.contentView addSubview:self.peerCodeField];

    UIButton *pairBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [pairBtn setTitle:@"配对" forState:UIControlStateNormal];
    pairBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    pairBtn.backgroundColor = [UIColor systemGreenColor];
    [pairBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    pairBtn.layer.cornerRadius = 10;
    pairBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [pairBtn addTarget:self action:@selector(pairDevice) forControlEvents:UIControlEventTouchUpInside];
    [connectCard.contentView addSubview:pairBtn];

    [NSLayoutConstraint activateConstraints:@[
        [scanBtn.topAnchor constraintEqualToAnchor:connectCard.contentView.topAnchor],
        [scanBtn.leadingAnchor constraintEqualToAnchor:connectCard.contentView.leadingAnchor],
        [scanBtn.trailingAnchor constraintEqualToAnchor:connectCard.contentView.trailingAnchor],
        [scanBtn.heightAnchor constraintEqualToConstant:40],

        [discoveredContainer.topAnchor constraintEqualToAnchor:scanBtn.bottomAnchor constant:10],
        [discoveredContainer.leadingAnchor constraintEqualToAnchor:connectCard.contentView.leadingAnchor],
        [discoveredContainer.trailingAnchor constraintEqualToAnchor:connectCard.contentView.trailingAnchor],

        [divider.topAnchor constraintEqualToAnchor:discoveredContainer.bottomAnchor constant:10],
        [divider.leadingAnchor constraintEqualToAnchor:connectCard.contentView.leadingAnchor],
        [divider.trailingAnchor constraintEqualToAnchor:connectCard.contentView.trailingAnchor],
        [divider.heightAnchor constraintEqualToConstant:0.5],

        [manualTitle.topAnchor constraintEqualToAnchor:divider.bottomAnchor constant:12],
        [manualTitle.leadingAnchor constraintEqualToAnchor:connectCard.contentView.leadingAnchor],
        [manualTitle.trailingAnchor constraintEqualToAnchor:connectCard.contentView.trailingAnchor],

        [self.peerUrlField.topAnchor constraintEqualToAnchor:manualTitle.bottomAnchor constant:6],
        [self.peerUrlField.leadingAnchor constraintEqualToAnchor:connectCard.contentView.leadingAnchor],
        [self.peerUrlField.trailingAnchor constraintEqualToAnchor:self.peerCodeField.leadingAnchor constant:-8],
        [self.peerUrlField.heightAnchor constraintEqualToConstant:38],

        [self.peerCodeField.topAnchor constraintEqualToAnchor:manualTitle.bottomAnchor constant:6],
        [self.peerCodeField.widthAnchor constraintEqualToConstant:90],
        [self.peerCodeField.trailingAnchor constraintEqualToAnchor:pairBtn.leadingAnchor constant:-8],
        [self.peerCodeField.heightAnchor constraintEqualToConstant:38],

        [pairBtn.topAnchor constraintEqualToAnchor:manualTitle.bottomAnchor constant:6],
        [pairBtn.trailingAnchor constraintEqualToAnchor:connectCard.contentView.trailingAnchor],
        [pairBtn.widthAnchor constraintEqualToConstant:72],
        [pairBtn.heightAnchor constraintEqualToConstant:38],
        [connectCard.contentView.bottomAnchor constraintEqualToAnchor:pairBtn.bottomAnchor],
    ]];

    connectCard.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [connectCard.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:12],
        [connectCard.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:pad],
        [connectCard.widthAnchor constraintEqualToConstant:w],
    ]];
    lastView = connectCard;

    // ==========================================
    // Card 4: Paired Devices
    // ==========================================
    QCLANCardView *pairedCard = [[QCLANCardView alloc] initWithTitle:@"已配对设备"];
    [self.scrollView addSubview:pairedCard];

    if (self.pairedDevices.count > 0) {
        UIView *prevRow = nil;
        for (QCLANPeer *peer in self.pairedDevices) {
            UIView *row = [self pairedDeviceRow:peer];
            row.translatesAutoresizingMaskIntoConstraints = NO;
            [pairedCard.contentView addSubview:row];

            [NSLayoutConstraint activateConstraints:@[
                [row.leadingAnchor constraintEqualToAnchor:pairedCard.contentView.leadingAnchor],
                [row.trailingAnchor constraintEqualToAnchor:pairedCard.contentView.trailingAnchor],
                [row.heightAnchor constraintEqualToConstant:72],
            ]];
            if (prevRow) {
                [row.topAnchor constraintEqualToAnchor:prevRow.bottomAnchor constant:8].active = YES;
            } else {
                [row.topAnchor constraintEqualToAnchor:pairedCard.contentView.topAnchor].active = YES;
            }
            prevRow = row;
        }
        [pairedCard.contentView.bottomAnchor constraintEqualToAnchor:prevRow.bottomAnchor].active = YES;
    } else {
        UILabel *emptyLabel = [[UILabel alloc] init];
        if (self.peersLoadError.length > 0) {
            emptyLabel.text = [NSString stringWithFormat:@"%@\n点击此处重新加载", self.peersLoadError];
            emptyLabel.textColor = [UIColor systemRedColor];
        } else {
            emptyLabel.text = @"暂无已配对设备\n扫描局域网或手动输入地址进行配对";
            emptyLabel.textColor = [UIColor tertiaryLabelColor];
        }
        emptyLabel.font = [UIFont systemFontOfSize:13];
        emptyLabel.textAlignment = NSTextAlignmentCenter;
        emptyLabel.numberOfLines = 2;
        emptyLabel.userInteractionEnabled = YES;
        emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [pairedCard.contentView addSubview:emptyLabel];
        [NSLayoutConstraint activateConstraints:@[
            [emptyLabel.topAnchor constraintEqualToAnchor:pairedCard.contentView.topAnchor constant:8],
            [emptyLabel.leadingAnchor constraintEqualToAnchor:pairedCard.contentView.leadingAnchor],
            [emptyLabel.trailingAnchor constraintEqualToAnchor:pairedCard.contentView.trailingAnchor],
            [emptyLabel.bottomAnchor constraintEqualToAnchor:pairedCard.contentView.bottomAnchor constant:-8],
        ]];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(loadPeersFromServer)];
        [emptyLabel addGestureRecognizer:tap];
    }

    pairedCard.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [pairedCard.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:12],
        [pairedCard.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:pad],
        [pairedCard.widthAnchor constraintEqualToConstant:w],
    ]];
    lastView = pairedCard;

    // ==========================================
    // Card 5: Auto Sync Settings
    // ==========================================
    QCLANCardView *syncCard = [[QCLANCardView alloc] initWithTitle:@"自动同步"];
    [self.scrollView addSubview:syncCard];

    UIView *sendRow = [self toggleRowWithLabel:@"自动推送（发送）"
                                      subtitle:@"剪贴板内容自动推送到已配对设备"
                                         isOn:self.sendEnabled
                                       action:@selector(sendToggled:)];

    UIView *recvRow = [self toggleRowWithLabel:@"自动拉取（接收）"
                                      subtitle:@"自动从已配对设备拉取最新内容"
                                         isOn:self.receiveEnabled
                                       action:@selector(receiveToggled:)];

    UIView *notifyRow = [self toggleRowWithLabel:@"同步通知提示"
                                        subtitle:@"收到同步内容时显示推送通知"
                                           isOn:self.notifyEnabled
                                         action:@selector(notifyToggled:)];

    for (UIView *row in @[sendRow, recvRow, notifyRow]) {
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [syncCard.contentView addSubview:row];
    }

    [NSLayoutConstraint activateConstraints:@[
        [sendRow.topAnchor constraintEqualToAnchor:syncCard.contentView.topAnchor],
        [sendRow.leadingAnchor constraintEqualToAnchor:syncCard.contentView.leadingAnchor],
        [sendRow.trailingAnchor constraintEqualToAnchor:syncCard.contentView.trailingAnchor],
        [sendRow.heightAnchor constraintEqualToConstant:50],

        [recvRow.topAnchor constraintEqualToAnchor:sendRow.bottomAnchor],
        [recvRow.leadingAnchor constraintEqualToAnchor:syncCard.contentView.leadingAnchor],
        [recvRow.trailingAnchor constraintEqualToAnchor:syncCard.contentView.trailingAnchor],
        [recvRow.heightAnchor constraintEqualToConstant:50],

        [notifyRow.topAnchor constraintEqualToAnchor:recvRow.bottomAnchor],
        [notifyRow.leadingAnchor constraintEqualToAnchor:syncCard.contentView.leadingAnchor],
        [notifyRow.trailingAnchor constraintEqualToAnchor:syncCard.contentView.trailingAnchor],
        [notifyRow.heightAnchor constraintEqualToConstant:50],
        [syncCard.contentView.bottomAnchor constraintEqualToAnchor:notifyRow.bottomAnchor],
    ]];

    syncCard.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [syncCard.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:12],
        [syncCard.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:pad],
        [syncCard.widthAnchor constraintEqualToConstant:w],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:syncCard.bottomAnchor constant:20],
    ]];
}


#pragma mark - Reusable Rows

- (UIView *)toggleRowWithLabel:(NSString *)label subtitle:(NSString *)subtitle isOn:(BOOL)isOn action:(SEL)action {
    UIView *row = [[UIView alloc] init];

    UILabel *titleL = [[UILabel alloc] init];
    titleL.text = label;
    titleL.font = [UIFont systemFontOfSize:15];
    titleL.textColor = [UIColor labelColor];
    titleL.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:titleL];

    UILabel *subL = [[UILabel alloc] init];
    subL.text = subtitle;
    subL.font = [UIFont systemFontOfSize:11];
    subL.textColor = [UIColor secondaryLabelColor];
    subL.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:subL];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = isOn;
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];

    [NSLayoutConstraint activateConstraints:@[
        [titleL.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [titleL.topAnchor constraintEqualToAnchor:row.topAnchor constant:4],
        [titleL.trailingAnchor constraintEqualToAnchor:sw.leadingAnchor constant:-8],
        [subL.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [subL.topAnchor constraintEqualToAnchor:titleL.bottomAnchor constant:2],
        [subL.trailingAnchor constraintEqualToAnchor:sw.leadingAnchor constant:-8],
        [sw.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [sw.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    return row;
}

- (UIView *)discoveredDeviceRow:(QCLANPeer *)peer {
    UIView *row = [[UIView alloc] init];
    row.backgroundColor = [UIColor tertiarySystemGroupedBackgroundColor];
    row.layer.cornerRadius = 10;
    row.layer.masksToBounds = YES;

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.text = peer.name ?: @"未知设备";
    nameLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    nameLabel.textColor = peer.paired ? [UIColor systemGreenColor] : [UIColor labelColor];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:nameLabel];

    UILabel *addrLabel = [[UILabel alloc] init];
    addrLabel.text = [NSString stringWithFormat:@"%@:%hu", peer.address, peer.port];
    addrLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    addrLabel.textColor = [UIColor secondaryLabelColor];
    addrLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:addrLabel];

    if (peer.paired) {
        UILabel *pairedBadge = [[UILabel alloc] init];
        pairedBadge.text = @"已配对";
        pairedBadge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
        pairedBadge.textColor = [UIColor systemGreenColor];
        pairedBadge.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:pairedBadge];

        [NSLayoutConstraint activateConstraints:@[
            [pairedBadge.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
            [pairedBadge.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        ]];
    } else {
        UIButton *quickPairBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [quickPairBtn setTitle:@"配对" forState:UIControlStateNormal];
        quickPairBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        quickPairBtn.backgroundColor = [UIColor systemGreenColor];
        [quickPairBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        quickPairBtn.layer.cornerRadius = 6;
        quickPairBtn.translatesAutoresizingMaskIntoConstraints = NO;
        quickPairBtn.deviceId = peer.deviceId;
        [quickPairBtn addTarget:self action:@selector(quickPairDiscovered:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:quickPairBtn];

        [NSLayoutConstraint activateConstraints:@[
            [quickPairBtn.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-8],
            [quickPairBtn.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [quickPairBtn.widthAnchor constraintEqualToConstant:48],
            [quickPairBtn.heightAnchor constraintEqualToConstant:26],
        ]];
    }

    [NSLayoutConstraint activateConstraints:@[
        [nameLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10],
        [nameLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:8],
        [nameLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-60],

        [addrLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10],
        [addrLabel.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:2],
        [addrLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-60],
    ]];

    return row;
}

- (UIView *)pairedDeviceRow:(QCLANPeer *)peer {
    UIView *row = [[UIView alloc] init];
    row.backgroundColor = [UIColor tertiarySystemGroupedBackgroundColor];
    row.layer.cornerRadius = 10;
    row.layer.masksToBounds = YES;

    UIView *iconView = [[UIView alloc] init];
    iconView.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.15];
    iconView.layer.cornerRadius = 18;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:iconView];

    UILabel *iconLabel = [[UILabel alloc] init];
    iconLabel.text = @"\U0001f4bb";
    iconLabel.font = [UIFont systemFontOfSize:18];
    iconLabel.textAlignment = NSTextAlignmentCenter;
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [iconView addSubview:iconLabel];

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.text = peer.name ?: @"未知设备";
    nameLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    nameLabel.textColor = [UIColor labelColor];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:nameLabel];

    UILabel *addrLabel = [[UILabel alloc] init];
    addrLabel.text = [NSString stringWithFormat:@"%@:%hu", peer.address, peer.port];
    addrLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    addrLabel.textColor = [UIColor secondaryLabelColor];
    addrLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:addrLabel];

    UILabel *timeLabel = [[UILabel alloc] init];
    // v1.3.7: 增加天级单位 + 异常兜底 (lastSeen 缺失/异常时显示"暂无连接记录",
    // 不再出现 496253小时前 这类从 epoch 0 算出的荒谬数值)
    if (peer.lastSeen) {
        NSTimeInterval ago = -[peer.lastSeen timeIntervalSinceNow];
        if (ago < 60) timeLabel.text = @"刚刚";
        else if (ago < 3600) timeLabel.text = [NSString stringWithFormat:@"%d分钟前", (int)(ago / 60)];
        else if (ago < 86400) timeLabel.text = [NSString stringWithFormat:@"%d小时前", (int)(ago / 3600)];
        else if (ago < 30 * 86400) timeLabel.text = [NSString stringWithFormat:@"%d天前", (int)(ago / 86400)];
        else timeLabel.text = @"暂无连接记录";
    } else {
        timeLabel.text = @"暂无连接记录";
    }
    timeLabel.font = [UIFont systemFontOfSize:10];
    timeLabel.textColor = [UIColor tertiaryLabelColor];
    timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:timeLabel];

    UIButton *pushBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [pushBtn setTitle:@"同步" forState:UIControlStateNormal];
    pushBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    pushBtn.backgroundColor = [UIColor systemBlueColor];
    [pushBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    pushBtn.layer.cornerRadius = 6;
    pushBtn.translatesAutoresizingMaskIntoConstraints = NO;
    pushBtn.deviceId = peer.deviceId;
    [pushBtn addTarget:self action:@selector(pushToDevice:) forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:pushBtn];

    UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [delBtn setTitle:@"删除" forState:UIControlStateNormal];
    delBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    delBtn.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
    [delBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    delBtn.layer.cornerRadius = 6;
    delBtn.translatesAutoresizingMaskIntoConstraints = NO;
    delBtn.deviceId = peer.deviceId;
    [delBtn addTarget:self action:@selector(removeDevice:) forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:delBtn];

    [NSLayoutConstraint activateConstraints:@[
        [iconView.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10],
        [iconView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:36],
        [iconView.heightAnchor constraintEqualToConstant:36],
        [iconLabel.centerXAnchor constraintEqualToAnchor:iconView.centerXAnchor],
        [iconLabel.centerYAnchor constraintEqualToAnchor:iconView.centerYAnchor],

        [nameLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:10],
        [nameLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
        [nameLabel.trailingAnchor constraintEqualToAnchor:pushBtn.leadingAnchor constant:-8],

        [addrLabel.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [addrLabel.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:2],

        [timeLabel.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [timeLabel.topAnchor constraintEqualToAnchor:addrLabel.bottomAnchor constant:2],

        [pushBtn.trailingAnchor constraintEqualToAnchor:delBtn.leadingAnchor constant:-4],
        [pushBtn.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [pushBtn.widthAnchor constraintEqualToConstant:48],
        [pushBtn.heightAnchor constraintEqualToConstant:26],

        [delBtn.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
        [delBtn.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [delBtn.widthAnchor constraintEqualToConstant:48],
        [delBtn.heightAnchor constraintEqualToConstant:26],
    ]];

    return row;
}


#pragma mark - Actions

- (void)serviceToggled:(UISwitch *)sender {
    // The tweak process always runs the server. This toggle is for intent.
    self.httpRunning = sender.on;
    [QCLANPrefs setBool:self.httpRunning forKey:@"lanReceiveEnabled"];
    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"切换服务开关 -> %@", sender.on ? @"开" : @"关"];
    [self buildUI];
}

- (void)togglePairCodeVisibility {
    self.pairCodeVisible = !self.pairCodeVisible;
    self.codeLabel.text = self.pairCodeVisible ? self.pairingCode : @"\u2022\u2022\u2022\u2022\u2022\u2022";
    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"%s配对码", self.pairCodeVisible ? "显示" : "隐藏"];
}

- (void)refreshPairingCode {
    // 由服务端刷新 (重置 TTL 与尝试次数, 与桌面端行为一致)
    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"用户点击: 刷新配对码"];
    [self apiPost:@"/pair-code" body:@{} completion:^(NSDictionary *json, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (json[@"code"]) {
                self.pairingCode = json[@"code"];
                self.codeLabel.text = self.pairCodeVisible ? self.pairingCode : @"\u2022\u2022\u2022\u2022\u2022\u2022";
                [[QCLANLogger sharedLogger] info:@"UI" fmt:@"配对码已刷新: %@", self.pairingCode];
            } else {
                [[QCLANLogger sharedLogger] error:@"UI" fmt:@"刷新配对码失败: %@",
                 error.localizedDescription ?: @"本地服务无响应"];
                [self showAlert:@"刷新失败" message:@"无法连接本地服务，请稍后重试"];
            }
        });
    }];
}

- (void)scanLan {
    if (self.isScanning) return;
    [self performScanViaServer];
}

- (void)pairDevice {
    NSString *addr = [self.peerUrlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *code = [self.peerCodeField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (addr.length == 0 || code.length == 0) {
        [[QCLANLogger sharedLogger] warn:@"UI" fmt:@"手动配对: 地址或配对码为空"];
        [self showAlert:@"错误" message:@"请填写设备 IP 地址和配对码"];
        return;
    }

    [self.peerUrlField resignFirstResponder];
    [self.peerCodeField resignFirstResponder];

    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"用户手动配对: %@", addr];
    [self performPairWithAddress:addr code:code];
}

- (void)quickPairDiscovered:(UIButton *)sender {
    NSString *deviceId = sender.deviceId;
    QCLANPeer *peer = nil;
    for (QCLANPeer *p in self.discoveredDevices) {
        if ([p.deviceId isEqualToString:deviceId]) { peer = p; break; }
    }
    if (!peer) {
        [[QCLANLogger sharedLogger] warn:@"UI" fmt:@"快速配对: 未找到发现设备 %@", deviceId];
        return;
    }

    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"用户点击快速配对: %@ (%@)", peer.name, peer.address];

    // 桌面端协议: 发现包不含配对码, 需用户在对方设备上查看后手动输入
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"输入配对码"
                                                                   message:[NSString stringWithFormat:@"与 %@ (%@) 配对\n请在对方设备上查看配对码并输入", peer.name, peer.address]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"6 位配对码";
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"配对" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *code = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (code.length == 0) {
            [self showAlert:@"错误" message:@"请输入配对码"];
            return;
        }
        [self performPairWithAddress:peer.address code:code];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pushToDevice:(UIButton *)sender {
    NSString *deviceId = sender.deviceId;
    QCLANPeer *peer = [self findPeerByDeviceId:deviceId];
    if (!peer) {
        [[QCLANLogger sharedLogger] warn:@"UI" fmt:@"同步: 未找到设备 %@", deviceId];
        return;
    }

    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"用户点击同步: %@ (%@)", peer.name, peer.baseURL];
    // v1.3.6: 由单向推送改为双向同步 —— 先推后拉, 拉取到的最新内容自动写入手机剪贴板
    [[QCLANServer sharedServer] syncNowWithPeer:peer completion:^(BOOL success, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlert:success ? @"同步完成" : @"同步失败" message:message];
        });
    }];
}

- (void)removeDevice:(UIButton *)sender {
    NSString *deviceId = sender.deviceId;
    if (!deviceId) return;

    QCLANPeer *peer = [self findPeerByDeviceId:deviceId];
    if (!peer) return;

    NSString *deviceName = peer.name ?: @"此设备";
    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"用户点击删除设备: %@", deviceName];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认移除"
                                                                   message:[NSString stringWithFormat:@"确定要移除 %@ 吗？", deviceName]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self performRemovePeer:deviceId];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)sendToggled:(UISwitch *)sender {
    self.sendEnabled = sender.on;
    [QCLANPrefs setBool:self.sendEnabled forKey:@"lanSendEnabled"];
    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"切换自动推送 -> %@", sender.on ? @"开" : @"关"];
}

- (void)receiveToggled:(UISwitch *)sender {
    self.receiveEnabled = sender.on;
    [QCLANPrefs setBool:self.receiveEnabled forKey:@"lanReceiveEnabled"];
    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"切换自动拉取 -> %@", sender.on ? @"开" : @"关"];
    [self buildUI];
}

- (void)notifyToggled:(UISwitch *)sender {
    self.notifyEnabled = sender.on;
    [QCLANPrefs setBool:self.notifyEnabled forKey:@"lanSyncNotifyEnabled"];
    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"切换同步通知 -> %@", sender.on ? @"开" : @"关"];
}


#pragma mark - Helpers

- (NSString *)getLocalIPAddress {
    struct ifaddrs *ifaddr = NULL;
    if (getifaddrs(&ifaddr) != 0) return nil;
    NSString *ip = nil;
    for (struct ifaddrs *ifa = ifaddr; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        if (strncmp(ifa->ifa_name, "en", 2) == 0 || strncmp(ifa->ifa_name, "pdp_ip", 6) == 0) {
            char addrBuf[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr, addrBuf, sizeof(addrBuf));
            ip = [NSString stringWithUTF8String:addrBuf];
            break;
        }
    }
    freeifaddrs(ifaddr);
    return ip;
}

- (NSInteger)clipCount {
    NSArray *items = [[QCStore sharedStore] allItems];
    return items ? items.count : 0;
}

- (QCLANPeer *)findPeerByDeviceId:(NSString *)deviceId {
    if (!deviceId.length) return nil;
    // 优先取共享服务实例中的完整 peer (含 peer_token, 从 peers.plist 加载)
    for (QCLANPeer *p in [[QCLANServer sharedServer] pairedDevices]) {
        if ([p.deviceId isEqualToString:deviceId]) return p;
    }
    // 回退到 HTTP 列表 (仅展示用, 不含 token)
    for (QCLANPeer *p in self.pairedDevices) {
        if ([p.deviceId isEqualToString:deviceId]) return p;
    }
    return nil;
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
