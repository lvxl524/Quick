#import "QCLANController.h"
#import "QCLANServer.h"
#import "QCStore.h"
#import <objc/runtime.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <sys/time.h>

@implementation UIButton (QCLANPeerID)
static const void *kPeerIdKey = &kPeerIdKey;
- (NSString *)peerId { return objc_getAssociatedObject(self, kPeerIdKey); }
- (void)setPeerId:(NSString *)peerId { objc_setAssociatedObject(self, kPeerIdKey, peerId, OBJC_ASSOCIATION_COPY_NONATOMIC); }
@end

// ============================================================
// MARK: - Status Pill Component
// ============================================================
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

// ============================================================
// MARK: - Card Component
// ============================================================
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

// ============================================================
// MARK: - Main Controller
// ============================================================
@interface QCLANController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) NSMutableArray<QCLANPeer *> *pairedDevices;
@property (nonatomic, strong) NSArray<QCLANPeer *> *discoveredDevices;

// UI state
@property (nonatomic, assign) BOOL pairCodeVisible;
@property (nonatomic, assign) BOOL isScanning;
@property (nonatomic, assign) BOOL httpRunning;

// Settings
@property (nonatomic, assign) BOOL sendEnabled;
@property (nonatomic, assign) BOOL receiveEnabled;
@property (nonatomic, assign) BOOL notifyEnabled;

// Local info
@property (nonatomic, copy) NSString *pairingCode;
@property (nonatomic, copy) NSString *localAddress;

// Manual pair inputs
@property (nonatomic, strong) UITextField *peerUrlField;
@property (nonatomic, strong) UITextField *peerCodeField;

// Dynamic views (for updating)
@property (nonatomic, strong) QCLANStatusPill *httpPill;
@property (nonatomic, strong) QCLANStatusPill *pairedPill;
@property (nonatomic, strong) QCLANStatusPill *dataPill;
@property (nonatomic, strong) UILabel *codeLabel;
@property (nonatomic, strong) UILabel *endpointLabel;

// Discovery socket
@property (nonatomic, assign) int discoverySocket;
@property (nonatomic, strong) dispatch_source_t discoverySource;
@property (nonatomic, strong) dispatch_queue_t scanQueue;
@property (nonatomic, strong) NSMutableDictionary<NSString *, QCLANPeer *> *scanResults;
@end

@implementation QCLANController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.defaults = [NSUserDefaults standardUserDefaults];
    self.scanQueue = dispatch_queue_create("com.mosheng.qcprefs.scan", DISPATCH_QUEUE_SERIAL);
    self.scanResults = [NSMutableDictionary dictionary];
    self.pairedDevices = [NSMutableArray array];

    // Load settings
    self.sendEnabled    = [self.defaults boolForKey:@"lanSendEnabled"];
    self.receiveEnabled = [self.defaults objectForKey:@"lanReceiveEnabled"] ? [self.defaults boolForKey:@"lanReceiveEnabled"] : YES;
    self.notifyEnabled  = [self.defaults boolForKey:@"lanSyncNotifyEnabled"];
    self.pairCodeVisible = YES;
    self.httpRunning = self.receiveEnabled;

    // Get pairing code from server/user defaults
    self.pairingCode = [self.defaults stringForKey:@"lanPairingCode"];
    if (!self.pairingCode || self.pairingCode.length == 0) {
        self.pairingCode = [[QCLANServer sharedServer] pairCode] ?: @"------";
    }

    // Get local IP
    self.localAddress = [self getLocalIPAddress] ?: @"未连接";

    // Load paired devices from server
    [self reloadPairedDevices];

    // Setup scroll view
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self.view addSubview:self.scrollView];

    [self buildUI];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopDiscovery];
}

#pragma mark - Data

- (void)reloadPairedDevices {
    NSArray *peers = [[QCLANServer sharedServer] pairedDevices];
    [self.pairedDevices removeAllObjects];
    for (QCLANPeer *p in peers) {
        if (p.paired) [self.pairedDevices addObject:p];
    }
}

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

- (NSInteger)favoriteCount {
    NSArray *items = [[QCStore sharedStore] favoriteItems];
    return items ? items.count : 0;
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

    // Toggle row
    UIView *toggleRow = [self toggleRowWithLabel:self.httpRunning ? @"运行中" : @"已停止"
                                        subtitle:@"局域网剪贴板同步服务"
                                           isOn:self.httpRunning
                                         action:@selector(serviceToggled:)];

    // Status pills
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
    // Card 2: Local Info (Pairing Code + Endpoints)
    // ==========================================
    QCLANCardView *localCard = [[QCLANCardView alloc] initWithTitle:@"本机信息"];
    [self.scrollView addSubview:localCard];

    // Pairing code header
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

    // Code display
    self.codeLabel = [[UILabel alloc] init];
    self.codeLabel.text = self.pairCodeVisible ? self.pairingCode : @"••••••";
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

    // Endpoints
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
        [self.endpointLabel.bottomAnchor constraintEqualToAnchor:localCard.contentView.bottomAnchor],
    ]];

    localCard.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [localCard.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:12],
        [localCard.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:pad],
        [localCard.widthAnchor constraintEqualToConstant:w],
    ]];
    lastView = localCard;

    // ==========================================
    // Card 3: Connect Device (Scan + Manual Pair)
    // ==========================================
    QCLANCardView *connectCard = [[QCLANCardView alloc] initWithTitle:@"连接设备"];
    [self.scrollView addSubview:connectCard];

    // Scan button
    UIButton *scanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [scanBtn setTitle:self.isScanning ? @"⏳ 扫描中..." : @"📡 扫描局域网" forState:UIControlStateNormal];
    scanBtn.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    scanBtn.backgroundColor = [UIColor systemBlueColor];
    [scanBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    scanBtn.layer.cornerRadius = 10;
    scanBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [scanBtn addTarget:self action:@selector(scanLan) forControlEvents:UIControlEventTouchUpInside];
    [connectCard.contentView addSubview:scanBtn];

    // Discovered devices list (shown after scan)
    UIView *discoveredContainer = [[UIView alloc] init];
    discoveredContainer.tag = 700; // for finding later
    discoveredContainer.translatesAutoresizingMaskIntoConstraints = NO;
    discoveredContainer.hidden = YES;
    [connectCard.contentView addSubview:discoveredContainer];

    // Divider line
    UIView *divider = [[UIView alloc] init];
    divider.backgroundColor = [UIColor separatorColor];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.tag = 701;
    [connectCard.contentView addSubview:divider];

    // Manual pair fields
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
        [pairBtn.bottomAnchor constraintEqualToAnchor:connectCard.contentView.bottomAnchor],
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
            UIView *row = [self deviceRowForPeer:peer];
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
        emptyLabel.text = @"暂无已配对设备\n扫描局域网或手动输入地址进行配对";
        emptyLabel.font = [UIFont systemFontOfSize:13];
        emptyLabel.textColor = [UIColor tertiaryLabelColor];
        emptyLabel.textAlignment = NSTextAlignmentCenter;
        emptyLabel.numberOfLines = 2;
        emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [pairedCard.contentView addSubview:emptyLabel];
        [NSLayoutConstraint activateConstraints:@[
            [emptyLabel.topAnchor constraintEqualToAnchor:pairedCard.contentView.topAnchor constant:8],
            [emptyLabel.leadingAnchor constraintEqualToAnchor:pairedCard.contentView.leadingAnchor],
            [emptyLabel.trailingAnchor constraintEqualToAnchor:pairedCard.contentView.trailingAnchor],
            [emptyLabel.bottomAnchor constraintEqualToAnchor:pairedCard.contentView.bottomAnchor constant:-8],
        ]];
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

- (UIView *)deviceRowForPeer:(QCLANPeer *)peer {
    UIView *row = [[UIView alloc] init];
    row.backgroundColor = [UIColor tertiarySystemGroupedBackgroundColor];
    row.layer.cornerRadius = 10;
    row.layer.masksToBounds = YES;

    // Icon placeholder
    UIView *iconView = [[UIView alloc] init];
    iconView.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.15];
    iconView.layer.cornerRadius = 18;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:iconView];

    UILabel *iconLabel = [[UILabel alloc] init];
    iconLabel.text = @"🖥";
    iconLabel.font = [UIFont systemFontOfSize:18];
    iconLabel.textAlignment = NSTextAlignmentCenter;
    iconLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [iconView addSubview:iconLabel];

    // Name
    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.text = peer.name ?: @"未知设备";
    nameLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    nameLabel.textColor = [UIColor labelColor];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:nameLabel];

    // Address
    UILabel *addrLabel = [[UILabel alloc] init];
    addrLabel.text = [NSString stringWithFormat:@"%@:%hu", peer.address, peer.port];
    addrLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    addrLabel.textColor = [UIColor secondaryLabelColor];
    addrLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:addrLabel];

    // Time
    UILabel *timeLabel = [[UILabel alloc] init];
    if (peer.lastSeen) {
        NSTimeInterval ago = -[peer.lastSeen timeIntervalSinceNow];
        if (ago < 60) timeLabel.text = @"刚刚";
        else if (ago < 3600) timeLabel.text = [NSString stringWithFormat:@"%d分钟前", (int)(ago / 60)];
        else timeLabel.text = [NSString stringWithFormat:@"%d小时前", (int)(ago / 3600)];
    } else {
        timeLabel.text = @"";
    }
    timeLabel.font = [UIFont systemFontOfSize:10];
    timeLabel.textColor = [UIColor tertiaryLabelColor];
    timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:timeLabel];

    // Push button
    UIButton *pushBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [pushBtn setTitle:@"推送" forState:UIControlStateNormal];
    pushBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    pushBtn.backgroundColor = [UIColor systemBlueColor];
    [pushBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    pushBtn.layer.cornerRadius = 6;
    pushBtn.translatesAutoresizingMaskIntoConstraints = NO;
    pushBtn.peerId = peer.peerId; // Store peer ID
    [pushBtn addTarget:self action:@selector(pushToDevice:) forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:pushBtn];

    // Delete button
    UIButton *delBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [delBtn setTitle:@"删除" forState:UIControlStateNormal];
    delBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    delBtn.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
    [delBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    delBtn.layer.cornerRadius = 6;
    delBtn.translatesAutoresizingMaskIntoConstraints = NO;
    delBtn.peerId = peer.peerId; // Store peer ID
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

#pragma mark - Discovery (UDP Scan)

- (void)startDiscoveryListener {
    [self stopDiscovery];

    dispatch_async(self.scanQueue, ^{
        self.discoverySocket = socket(AF_INET, SOCK_DGRAM, 0);
        if (self.discoverySocket < 0) return;

        int on = 1;
        setsockopt(self.discoverySocket, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
        setsockopt(self.discoverySocket, SOL_SOCKET, SO_BROADCAST, &on, sizeof(on));

        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(35694); // Different port from server to avoid conflict
        addr.sin_addr.s_addr = INADDR_ANY;

        if (bind(self.discoverySocket, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            close(self.discoverySocket);
            self.discoverySocket = 0;
            return;
        }

        // Set timeout for the scan
        struct timeval tv;
        tv.tv_sec = 3;
        tv.tv_usec = 0;
        setsockopt(self.discoverySocket, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        // Send discovery broadcast
        [self sendDiscoveryBroadcast];

        // Listen for replies
        char buffer[1024];
        struct timeval start, now;
        gettimeofday(&start, NULL);

        while (1) {
            gettimeofday(&now, NULL);
            double elapsed = (now.tv_sec - start.tv_sec) + (now.tv_usec - start.tv_usec) / 1000000.0;
            if (elapsed > 2.5) break;

            struct sockaddr_in senderAddr;
            socklen_t senderLen = sizeof(senderAddr);
            ssize_t len = recvfrom(self.discoverySocket, buffer, sizeof(buffer) - 1, 0,
                                   (struct sockaddr *)&senderAddr, &senderLen);
            if (len <= 0) continue;
            buffer[len] = '\0';
            NSString *msg = [NSString stringWithUTF8String:buffer];

            // Format: QC_HERE|DeviceName|Port|PairCode
            if ([msg hasPrefix:@"QC_HERE"]) {
                NSArray *parts = [msg componentsSeparatedByString:@"|"];
                if (parts.count >= 4) {
                    NSString *name = parts[1];
                    uint16_t port = (uint16_t)[parts[2] intValue];
                    NSString *code = parts[3];
                    NSString *ip = [NSString stringWithUTF8String:inet_ntoa(senderAddr.sin_addr)];

                    QCLANPeer *peer = [[QCLANPeer alloc] init];
                    peer.name     = name;
                    peer.address  = ip;
                    peer.port     = port;
                    peer.pairCode = code;
                    peer.peerId   = [NSString stringWithFormat:@"%@:%hu", ip, port];
                    peer.lastSeen = [NSDate date];
                    // Check if already paired
                    for (QCLANPeer *p in self.pairedDevices) {
                        if ([p.peerId isEqualToString:peer.peerId]) {
                            peer.paired = YES;
                            peer.name = p.name;
                            break;
                        }
                    }
                    self.scanResults[peer.peerId] = peer;
                }
            }

            // Resend broadcast periodically
            if (elapsed > 0.5 && elapsed < 0.6) {
                [self sendDiscoveryBroadcast];
            }
        }

        close(self.discoverySocket);
        self.discoverySocket = 0;

        NSArray *results = [self.scanResults.allValues sortedArrayUsingComparator:^NSComparisonResult(QCLANPeer *a, QCLANPeer *b) {
            return [a.name compare:b.name];
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self onScanComplete:results];
        });
    });
}

- (void)sendDiscoveryBroadcast {
    if (self.discoverySocket <= 0) return;
    NSData *data = [@"QC_DISCOVER" dataUsingEncoding:NSUTF8StringEncoding];

    struct sockaddr_in broadAddr;
    memset(&broadAddr, 0, sizeof(broadAddr));
    broadAddr.sin_family = AF_INET;
    broadAddr.sin_port = htons(35693);
    broadAddr.sin_addr.s_addr = inet_addr("255.255.255.255");
    sendto(self.discoverySocket, data.bytes, data.length, 0,
           (struct sockaddr *)&broadAddr, sizeof(broadAddr));
}

- (void)stopDiscovery {
    if (self.discoverySocket > 0) {
        close(self.discoverySocket);
        self.discoverySocket = 0;
    }
}

- (void)onScanComplete:(NSArray<QCLANPeer *> *)results {
    self.isScanning = NO;
    self.discoveredDevices = results;
    [self buildUI];

    if (results.count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描完成"
                                                                       message:@"未发现局域网设备。请确认：\n1. 电脑端 QuickClipboard 已启动且开启 HTTP 服务\n2. 手机和电脑在同一局域网\n3. 防火墙未阻止端口 35691/35693"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - Actions

- (void)serviceToggled:(UISwitch *)sender {
    self.receiveEnabled = sender.on;
    self.httpRunning = sender.on;
    [self.defaults setBool:self.receiveEnabled forKey:@"lanReceiveEnabled"];
    [self.defaults synchronize];
    [self buildUI];
}

- (void)togglePairCodeVisibility {
    self.pairCodeVisible = !self.pairCodeVisible;
    self.codeLabel.text = self.pairCodeVisible ? self.pairingCode : @"••••••";
}

- (void)refreshPairingCode {
    uint32_t code = arc4random_uniform(900000) + 100000;
    self.pairingCode = [NSString stringWithFormat:@"%06u", code];
    self.codeLabel.text = self.pairCodeVisible ? self.pairingCode : @"••••••";
    [self.defaults setObject:self.pairingCode forKey:@"lanPairingCode"];
    [self.defaults synchronize];
}

- (void)scanLan {
    if (self.isScanning) return;
    self.isScanning = YES;
    self.discoveredDevices = nil;
    [self.scanResults removeAllObjects];
    [self buildUI];

    // Show scanning feedback
    dispatch_async(dispatch_get_main_queue(), ^{
        [self startDiscoveryListener];
    });
}

- (void)pairDevice {
    NSString *addr = [self.peerUrlField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *code = [self.peerCodeField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (addr.length == 0 || code.length == 0) {
        [self showAlert:@"错误" message:@"请填写设备 IP 地址和配对码"];
        return;
    }

    [self.peerUrlField resignFirstResponder];
    [self.peerCodeField resignFirstResponder];

    [[QCLANServer sharedServer] pairWithAddress:addr code:code completion:^(BOOL success, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [self reloadPairedDevices];
                [self buildUI];
                self.peerUrlField.text = @"";
                self.peerCodeField.text = @"";
            }
            [self showAlert:success ? @"配对成功" : @"配对失败" message:message];
        });
    }];
}

- (void)pushToDevice:(UIButton *)sender {
    NSString *peerId = sender.peerId;
    QCLANPeer *peer = [self findPeerById:peerId];
    if (!peer) return;

    [[QCLANServer sharedServer] pushToPeer:peer completion:^(BOOL success, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlert:success ? @"推送完成" : @"推送失败" message:message];
        });
    }];
}

- (void)removeDevice:(UIButton *)sender {
    NSString *peerId = sender.peerId;
    if (!peerId) return;

    QCLANPeer *peer = [self findPeerById:peerId];
    if (!peer) return;

    NSString *deviceName = peer.name ?: @"此设备";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认移除"
                                                                   message:[NSString stringWithFormat:@"确定要移除 %@ 吗？", deviceName]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        // Delete the correct peer from the server
        [[QCLANServer sharedServer] removePeer:peer];
        [self reloadPairedDevices];
        [self buildUI];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)sendToggled:(UISwitch *)sender {
    self.sendEnabled = sender.on;
    [self.defaults setBool:self.sendEnabled forKey:@"lanSendEnabled"];
    [self.defaults synchronize];
}

- (void)receiveToggled:(UISwitch *)sender {
    self.receiveEnabled = sender.on;
    [self.defaults setBool:self.receiveEnabled forKey:@"lanReceiveEnabled"];
    [self.defaults synchronize];
    [self buildUI];
}

- (void)notifyToggled:(UISwitch *)sender {
    self.notifyEnabled = sender.on;
    [self.defaults setBool:self.notifyEnabled forKey:@"lanSyncNotifyEnabled"];
    [self.defaults synchronize];
}

#pragma mark - Helpers

- (QCLANPeer *)findPeerById:(NSString *)peerId {
    for (QCLANPeer *p in self.pairedDevices) {
        if ([p.peerId isEqualToString:peerId]) return p;
    }
    return nil;
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
