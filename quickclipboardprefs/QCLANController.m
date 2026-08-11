#import "QCLANController.h"

// Status pill view similar to desktop app's StatusPill component
@interface QCLANStatusPill : UIView
@property (nonatomic, strong) UILabel *labelLabel;
@property (nonatomic, strong) UILabel *valueLabel;
- (instancetype)initWithLabel:(NSString *)label value:(NSString *)value active:(BOOL)active;
@end

@implementation QCLANStatusPill

- (instancetype)initWithLabel:(NSString *)label value:(NSString *)value active:(BOOL)active {
    self = [super init];
    if (self) {
        self.backgroundColor = active ? [[UIColor systemBlueColor] colorWithAlphaComponent:0.1] : [UIColor tertiarySystemGroupedBackgroundColor];
        self.layer.cornerRadius = 8;
        self.layer.borderWidth = 1;
        self.layer.borderColor = active ? [[UIColor systemBlueColor] colorWithAlphaComponent:0.4].CGColor : [UIColor separatorColor].CGColor;
        self.layer.masksToBounds = YES;

        self.labelLabel = [[UILabel alloc] init];
        self.labelLabel.text = [NSString stringWithFormat:@"%@：", label];
        self.labelLabel.font = [UIFont systemFontOfSize:11];
        self.labelLabel.textColor = [UIColor secondaryLabelColor];
        self.labelLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.labelLabel];

        self.valueLabel = [[UILabel alloc] init];
        self.valueLabel.text = value;
        self.valueLabel.font = [UIFont boldSystemFontOfSize:11];
        self.valueLabel.textColor = active ? [UIColor labelColor] : [UIColor labelColor];
        self.valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.valueLabel];

        [NSLayoutConstraint activateConstraints:@[
            [self.labelLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [self.labelLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.valueLabel.leadingAnchor constraintEqualToAnchor:self.labelLabel.trailingAnchor constant:2],
            [self.valueLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.trailingAnchor constraintEqualToAnchor:self.valueLabel.trailingAnchor constant:10],
            [self.heightAnchor constraintEqualToConstant:28],
        ]];
    }
    return self;
}

@end

// Card container
@interface QCLANCardView : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UIView *contentView;
- (instancetype)initWithTitle:(NSString *)title description:(NSString *)desc;
@end

@implementation QCLANCardView

- (instancetype)initWithTitle:(NSString *)title description:(NSString *)desc {
    self = [super init];
    if (self) {
        self.backgroundColor = [UIColor systemGroupedBackgroundColor];
        self.layer.cornerRadius = 12;
        self.layer.masksToBounds = YES;

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.text = title;
        self.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        self.titleLabel.textColor = [UIColor labelColor];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.titleLabel];

        self.descLabel = [[UILabel alloc] init];
        self.descLabel.text = desc;
        self.descLabel.font = [UIFont systemFontOfSize:12];
        self.descLabel.textColor = [UIColor secondaryLabelColor];
        self.descLabel.numberOfLines = 0;
        self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.descLabel];

        self.contentView = [[UIView alloc] init];
        self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.contentView];

        [NSLayoutConstraint activateConstraints:@[
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
            [self.descLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4],
            [self.descLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [self.descLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
            [self.contentView.topAnchor constraintEqualToAnchor:self.descLabel.bottomAnchor constant:12],
            [self.contentView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [self.contentView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
            [self.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:14],
        ]];
    }
    return self;
}

@end

@interface QCLANController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) NSUserDefaults *defaults;

@property (nonatomic, assign) BOOL lanAutoSync;

// Paired devices mock data
@property (nonatomic, strong) NSMutableArray *pairedDevices;
@property (nonatomic, assign) BOOL pairingCodeVisible;
@property (nonatomic, copy) NSString *pairingCode;
@property (nonatomic, assign) BOOL httpRunning;
@property (nonatomic, assign) NSInteger pairedCount;
@property (nonatomic, assign) NSInteger clipCount;
@property (nonatomic, assign) NSInteger favoriteCount;

@property (nonatomic, assign) BOOL sendEnabled;
@property (nonatomic, assign) BOOL receiveEnabled;

// Pairing inputs
@property (nonatomic, strong) UITextField *peerUrlField;
@property (nonatomic, strong) UITextField *peerCodeField;

@property (nonatomic, assign) BOOL isRefreshing;
@property (nonatomic, assign) BOOL isScanning;
@end

@implementation QCLANController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.defaults = [NSUserDefaults standardUserDefaults];

    self.pairingCode = @"978749";
    self.pairingCodeVisible = YES;
    self.httpRunning = YES;
    self.pairedCount = 1;
    self.clipCount = 42;
    self.favoriteCount = 5;
    self.sendEnabled = YES;
    self.receiveEnabled = YES;

    self.pairedDevices = [NSMutableArray arrayWithArray:@[
        @{@"name": @"My MacBook", @"url": @"http://192.168.1.10:35691", @"lastSeen": @"2分钟前"}
    ]];

    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.alwaysBounceVertical = YES;
    [self.view addSubview:self.scrollView];

    [self buildUI];
}

- (void)buildUI {
    // Remove all subviews from scrollView
    for (UIView *v in self.scrollView.subviews) { [v removeFromSuperview]; }

    CGFloat padding = 16;
    CGFloat width = self.view.bounds.size.width - padding * 2;
    CGFloat y = padding;

    // === Card 1: Service Status ===
    QCLANCardView *serviceCard = [[QCLANCardView alloc] initWithTitle:@"HTTP 服务" description:@"局域网剪贴板同步服务状态"];
    [self.scrollView addSubview:serviceCard];

    // Service toggle row
    UIView *toggleRow = [[UIView alloc] init];
    toggleRow.translatesAutoresizingMaskIntoConstraints = NO;
    [serviceCard.contentView addSubview:toggleRow];

    UILabel *toggleLabel = [[UILabel alloc] init];
    toggleLabel.text = self.receiveEnabled ? @"运行中" : @"已停止";
    toggleLabel.font = [UIFont systemFontOfSize:14];
    toggleLabel.textColor = [UIColor labelColor];
    toggleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [toggleRow addSubview:toggleLabel];

    UILabel *toggleDesc = [[UILabel alloc] init];
    toggleDesc.text = @"启用后其他设备可以发现并同步此设备";
    toggleDesc.font = [UIFont systemFontOfSize:11];
    toggleDesc.textColor = [UIColor secondaryLabelColor];
    toggleDesc.translatesAutoresizingMaskIntoConstraints = NO;
    [toggleRow addSubview:toggleDesc];

    UISwitch *serviceSwitch = [[UISwitch alloc] init];
    serviceSwitch.on = self.receiveEnabled;
    serviceSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [serviceSwitch addTarget:self action:@selector(serviceToggled:) forControlEvents:UIControlEventValueChanged];
    [toggleRow addSubview:serviceSwitch];

    // Status pills
    UIView *pillsRow = [[UIView alloc] init];
    pillsRow.translatesAutoresizingMaskIntoConstraints = NO;
    [serviceCard.contentView addSubview:pillsRow];

    QCLANStatusPill *httpPill = [[QCLANStatusPill alloc] initWithLabel:@"HTTP状态" value:self.httpRunning ? @"运行中" : @"已停止" active:self.httpRunning];
    httpPill.translatesAutoresizingMaskIntoConstraints = NO;
    [pillsRow addSubview:httpPill];

    QCLANStatusPill *pairedPill = [[QCLANStatusPill alloc] initWithLabel:@"已配对" value:[NSString stringWithFormat:@"%ld台", (long)self.pairedCount] active:NO];
    pairedPill.translatesAutoresizingMaskIntoConstraints = NO;
    [pillsRow addSubview:pairedPill];

    QCLANStatusPill *dataPill = [[QCLANStatusPill alloc] initWithLabel:@"数据" value:[NSString stringWithFormat:@"%ld条/收藏%ld", (long)self.clipCount, (long)self.favoriteCount] active:NO];
    dataPill.translatesAutoresizingMaskIntoConstraints = NO;
    [pillsRow addSubview:dataPill];

    [NSLayoutConstraint activateConstraints:@[
        [toggleRow.topAnchor constraintEqualToAnchor:serviceCard.contentView.topAnchor],
        [toggleRow.leadingAnchor constraintEqualToAnchor:serviceCard.contentView.leadingAnchor],
        [toggleRow.trailingAnchor constraintEqualToAnchor:serviceCard.contentView.trailingAnchor],
        [toggleRow.heightAnchor constraintEqualToConstant:44],

        [toggleLabel.leadingAnchor constraintEqualToAnchor:toggleRow.leadingAnchor],
        [toggleLabel.topAnchor constraintEqualToAnchor:toggleRow.topAnchor constant:2],
        [toggleDesc.leadingAnchor constraintEqualToAnchor:toggleRow.leadingAnchor],
        [toggleDesc.topAnchor constraintEqualToAnchor:toggleLabel.bottomAnchor constant:2],
        [serviceSwitch.trailingAnchor constraintEqualToAnchor:toggleRow.trailingAnchor],
        [serviceSwitch.centerYAnchor constraintEqualToAnchor:toggleRow.centerYAnchor],

        [pillsRow.topAnchor constraintEqualToAnchor:toggleRow.bottomAnchor constant:8],
        [pillsRow.leadingAnchor constraintEqualToAnchor:serviceCard.contentView.leadingAnchor],
        [pillsRow.trailingAnchor constraintEqualToAnchor:serviceCard.contentView.trailingAnchor],
        [pillsRow.bottomAnchor constraintEqualToAnchor:serviceCard.contentView.bottomAnchor],
        [pillsRow.heightAnchor constraintEqualToConstant:30],

        [httpPill.leadingAnchor constraintEqualToAnchor:pillsRow.leadingAnchor],
        [httpPill.centerYAnchor constraintEqualToAnchor:pillsRow.centerYAnchor],
        [pairedPill.leadingAnchor constraintEqualToAnchor:httpPill.trailingAnchor constant:6],
        [pairedPill.centerYAnchor constraintEqualToAnchor:pillsRow.centerYAnchor],
        [dataPill.leadingAnchor constraintEqualToAnchor:pairedPill.trailingAnchor constant:6],
        [dataPill.centerYAnchor constraintEqualToAnchor:pillsRow.centerYAnchor],
    ]];

    // Layout service card
    serviceCard.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [serviceCard.topAnchor constraintEqualToAnchor:self.scrollView.topAnchor constant:y],
        [serviceCard.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:padding],
        [serviceCard.widthAnchor constraintEqualToConstant:width],
    ]];

    // Save last Y for next card
    __block UIView *lastView = serviceCard;
    y = 0; // reset for constraint-based offset

    // === Card 2: Local Info (Pairing Code + Endpoints) ===
    QCLANCardView *localCard = [[QCLANCardView alloc] initWithTitle:@"本机信息" description:@""];
    [self.scrollView addSubview:localCard];

    // Pairing code section
    UILabel *pairingTitle = [[UILabel alloc] init];
    pairingTitle.text = @"配对码";
    pairingTitle.font = [UIFont systemFontOfSize:12];
    pairingTitle.textColor = [UIColor secondaryLabelColor];
    pairingTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [localCard.contentView addSubview:pairingTitle];

    // Show/hide + refresh buttons
    UIButton *toggleVisibilityBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [toggleVisibilityBtn setTitle:self.pairingCodeVisible ? @"隐藏" : @"显示" forState:UIControlStateNormal];
    toggleVisibilityBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    toggleVisibilityBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [toggleVisibilityBtn addTarget:self action:@selector(togglePairingCodeVisibility) forControlEvents:UIControlEventTouchUpInside];
    [localCard.contentView addSubview:toggleVisibilityBtn];

    UIButton *refreshBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [refreshBtn setTitle:self.isRefreshing ? @"刷新中..." : @"刷新" forState:UIControlStateNormal];
    refreshBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    refreshBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [refreshBtn addTarget:self action:@selector(refreshPairingCode) forControlEvents:UIControlEventTouchUpInside];
    [localCard.contentView addSubview:refreshBtn];

    UILabel *codeLabel = [[UILabel alloc] init];
    codeLabel.text = self.pairingCodeVisible ? self.pairingCode : @"••••••";
    codeLabel.font = [UIFont monospacedSystemFontOfSize:28 weight:UIFontWeightRegular];
    codeLabel.textAlignment = NSTextAlignmentCenter;
    codeLabel.textColor = [UIColor labelColor];
    codeLabel.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    codeLabel.layer.cornerRadius = 8;
    codeLabel.layer.masksToBounds = YES;
    codeLabel.layer.borderWidth = 1;
    codeLabel.layer.borderColor = [UIColor separatorColor].CGColor;
    codeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    codeLabel.accessibilityIdentifier = @"pairingCodeLabel";
    [localCard.contentView addSubview:codeLabel];

    UILabel *pairingMeta = [[UILabel alloc] init];
    pairingMeta.text = @"剩余尝试次数: 3";
    pairingMeta.font = [UIFont systemFontOfSize:11];
    pairingMeta.textColor = [UIColor secondaryLabelColor];
    pairingMeta.translatesAutoresizingMaskIntoConstraints = NO;
    [localCard.contentView addSubview:pairingMeta];

    // Local endpoints
    UILabel *endpointTitle = [[UILabel alloc] init];
    endpointTitle.text = @"本机地址";
    endpointTitle.font = [UIFont systemFontOfSize:12];
    endpointTitle.textColor = [UIColor secondaryLabelColor];
    endpointTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [localCard.contentView addSubview:endpointTitle];

    UILabel *endpointValue = [[UILabel alloc] init];
    endpointValue.text = @"http://192.168.1.100:35691";
    endpointValue.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    endpointValue.textColor = [UIColor labelColor];
    endpointValue.numberOfLines = 0;
    endpointValue.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    endpointValue.layer.cornerRadius = 8;
    endpointValue.layer.masksToBounds = YES;
    endpointValue.layer.borderWidth = 1;
    endpointValue.layer.borderColor = [UIColor separatorColor].CGColor;
    endpointValue.translatesAutoresizingMaskIntoConstraints = NO;
    [localCard.contentView addSubview:endpointValue];

    [NSLayoutConstraint activateConstraints:@[
        [pairingTitle.topAnchor constraintEqualToAnchor:localCard.contentView.topAnchor],
        [pairingTitle.leadingAnchor constraintEqualToAnchor:localCard.contentView.leadingAnchor],
        [toggleVisibilityBtn.centerYAnchor constraintEqualToAnchor:pairingTitle.centerYAnchor],
        [toggleVisibilityBtn.trailingAnchor constraintEqualToAnchor:refreshBtn.leadingAnchor constant:-4],
        [refreshBtn.centerYAnchor constraintEqualToAnchor:pairingTitle.centerYAnchor],
        [refreshBtn.trailingAnchor constraintEqualToAnchor:localCard.contentView.trailingAnchor],

        [codeLabel.topAnchor constraintEqualToAnchor:pairingTitle.bottomAnchor constant:6],
        [codeLabel.leadingAnchor constraintEqualToAnchor:localCard.contentView.leadingAnchor],
        [codeLabel.trailingAnchor constraintEqualToAnchor:localCard.contentView.trailingAnchor],
        [codeLabel.heightAnchor constraintEqualToConstant:50],
        [pairingMeta.topAnchor constraintEqualToAnchor:codeLabel.bottomAnchor constant:4],
        [pairingMeta.leadingAnchor constraintEqualToAnchor:localCard.contentView.leadingAnchor],
        [pairingMeta.bottomAnchor constraintEqualToAnchor:localCard.contentView.bottomAnchor],
    ]];

    localCard.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [localCard.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:12],
        [localCard.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:padding],
        [localCard.widthAnchor constraintEqualToConstant:width],
    ]];
    lastView = localCard;

    // === Card 3: Connect Device ===
    QCLANCardView *connectCard = [[QCLANCardView alloc] initWithTitle:@"连接其他设备" description:@"扫描局域网或手动输入地址和配对码"];
    [self.scrollView addSubview:connectCard];

    UIButton *scanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [scanBtn setTitle:self.isScanning ? @"扫描中..." : @"📡 扫描局域网" forState:UIControlStateNormal];
    scanBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    scanBtn.backgroundColor = [UIColor systemBlueColor];
    [scanBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    scanBtn.layer.cornerRadius = 8;
    scanBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [scanBtn addTarget:self action:@selector(scanLan) forControlEvents:UIControlEventTouchUpInside];
    [connectCard.contentView addSubview:scanBtn];

    self.peerUrlField = [[UITextField alloc] init];
    self.peerUrlField.placeholder = @"http://192.168.1.10:35691";
    self.peerUrlField.borderStyle = UITextBorderStyleRoundedRect;
    self.peerUrlField.font = [UIFont systemFontOfSize:14];
    self.peerUrlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.peerUrlField.keyboardType = UIKeyboardTypeURL;
    self.peerUrlField.translatesAutoresizingMaskIntoConstraints = NO;
    [connectCard.contentView addSubview:self.peerUrlField];

    self.peerCodeField = [[UITextField alloc] init];
    self.peerCodeField.placeholder = @"配对码";
    self.peerCodeField.borderStyle = UITextBorderStyleRoundedRect;
    self.peerCodeField.font = [UIFont systemFontOfSize:14];
    self.peerCodeField.translatesAutoresizingMaskIntoConstraints = NO;
    [connectCard.contentView addSubview:self.peerCodeField];

    UIButton *pairBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [pairBtn setTitle:@"🔗 配对" forState:UIControlStateNormal];
    pairBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    pairBtn.backgroundColor = [UIColor systemGreenColor];
    [pairBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    pairBtn.layer.cornerRadius = 8;
    pairBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [pairBtn addTarget:self action:@selector(pairDevice) forControlEvents:UIControlEventTouchUpInside];
    [connectCard.contentView addSubview:pairBtn];

    [NSLayoutConstraint activateConstraints:@[
        [scanBtn.topAnchor constraintEqualToAnchor:connectCard.contentView.topAnchor],
        [scanBtn.leadingAnchor constraintEqualToAnchor:connectCard.contentView.leadingAnchor],
        [scanBtn.trailingAnchor constraintEqualToAnchor:connectCard.contentView.trailingAnchor],
        [scanBtn.heightAnchor constraintEqualToConstant:36],

        [self.peerUrlField.topAnchor constraintEqualToAnchor:scanBtn.bottomAnchor constant:10],
        [self.peerUrlField.leadingAnchor constraintEqualToAnchor:connectCard.contentView.leadingAnchor],
        [self.peerUrlField.trailingAnchor constraintEqualToAnchor:self.peerCodeField.leadingAnchor constant:-8],
        [self.peerUrlField.heightAnchor constraintEqualToConstant:36],

        [self.peerCodeField.topAnchor constraintEqualToAnchor:scanBtn.bottomAnchor constant:10],
        [self.peerCodeField.widthAnchor constraintEqualToConstant:80],
        [self.peerCodeField.trailingAnchor constraintEqualToAnchor:pairBtn.leadingAnchor constant:-8],
        [self.peerCodeField.heightAnchor constraintEqualToConstant:36],

        [pairBtn.topAnchor constraintEqualToAnchor:scanBtn.bottomAnchor constant:10],
        [pairBtn.trailingAnchor constraintEqualToAnchor:connectCard.contentView.trailingAnchor],
        [pairBtn.widthAnchor constraintEqualToConstant:70],
        [pairBtn.heightAnchor constraintEqualToConstant:36],
        [pairBtn.bottomAnchor constraintEqualToAnchor:connectCard.contentView.bottomAnchor],
    ]];

    connectCard.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [connectCard.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:12],
        [connectCard.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:padding],
        [connectCard.widthAnchor constraintEqualToConstant:width],
    ]];
    lastView = connectCard;

    // === Card 4: Paired Devices ===
    QCLANCardView *pairedCard = [[QCLANCardView alloc] initWithTitle:@"已配对设备" description:@"已通过局域网配对的可同步设备"];
    [self.scrollView addSubview:pairedCard];

    __block UIView *prevDevice = nil;
    for (NSDictionary *device in self.pairedDevices) {
        UIView *deviceRow = [self createPairedDeviceRow:device];
        deviceRow.translatesAutoresizingMaskIntoConstraints = NO;
        [pairedCard.contentView addSubview:deviceRow];

        [NSLayoutConstraint activateConstraints:@[
            [deviceRow.leadingAnchor constraintEqualToAnchor:pairedCard.contentView.leadingAnchor],
            [deviceRow.trailingAnchor constraintEqualToAnchor:pairedCard.contentView.trailingAnchor],
            [deviceRow.heightAnchor constraintEqualToConstant:64],
        ]];

        if (prevDevice) {
            [deviceRow.topAnchor constraintEqualToAnchor:prevDevice.bottomAnchor constant:6].active = YES;
        } else {
            [deviceRow.topAnchor constraintEqualToAnchor:pairedCard.contentView.topAnchor].active = YES;
        }
        prevDevice = deviceRow;
    }

    if (prevDevice) {
        [pairedCard.contentView.bottomAnchor constraintEqualToAnchor:prevDevice.bottomAnchor].active = YES;
    } else {
        UILabel *emptyLabel = [[UILabel alloc] init];
        emptyLabel.text = @"暂无已配对设备";
        emptyLabel.font = [UIFont systemFontOfSize:14];
        emptyLabel.textColor = [UIColor secondaryLabelColor];
        emptyLabel.textAlignment = NSTextAlignmentCenter;
        emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [pairedCard.contentView addSubview:emptyLabel];
        [NSLayoutConstraint activateConstraints:@[
            [emptyLabel.topAnchor constraintEqualToAnchor:pairedCard.contentView.topAnchor],
            [emptyLabel.leadingAnchor constraintEqualToAnchor:pairedCard.contentView.leadingAnchor],
            [emptyLabel.trailingAnchor constraintEqualToAnchor:pairedCard.contentView.trailingAnchor],
            [emptyLabel.bottomAnchor constraintEqualToAnchor:pairedCard.contentView.bottomAnchor],
            [emptyLabel.heightAnchor constraintEqualToConstant:44],
        ]];
    }

    pairedCard.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [pairedCard.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:12],
        [pairedCard.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:padding],
        [pairedCard.widthAnchor constraintEqualToConstant:width],
    ]];
    lastView = pairedCard;

    // === Card 5: Auto Sync Settings ===
    QCLANCardView *autoSyncCard = [[QCLANCardView alloc] initWithTitle:@"自动同步" description:@"启用后设备间自动推送和接收剪贴板内容"];
    [self.scrollView addSubview:autoSyncCard];

    // Send toggle
    UIView *sendRow = [[UIView alloc] init];
    sendRow.translatesAutoresizingMaskIntoConstraints = NO;
    [autoSyncCard.contentView addSubview:sendRow];

    UILabel *sendLabel = [[UILabel alloc] init];
    sendLabel.text = @"自动推送（发送）";
    sendLabel.font = [UIFont systemFontOfSize:14];
    sendLabel.textColor = [UIColor labelColor];
    sendLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [sendRow addSubview:sendLabel];

    UISwitch *sendSwitch = [[UISwitch alloc] init];
    sendSwitch.on = self.sendEnabled;
    sendSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [sendSwitch addTarget:self action:@selector(sendToggled:) forControlEvents:UIControlEventValueChanged];
    [sendRow addSubview:sendSwitch];

    // Receive toggle
    UIView *receiveRow = [[UIView alloc] init];
    receiveRow.translatesAutoresizingMaskIntoConstraints = NO;
    [autoSyncCard.contentView addSubview:receiveRow];

    UILabel *receiveLabel = [[UILabel alloc] init];
    receiveLabel.text = @"自动拉取（接收）";
    receiveLabel.font = [UIFont systemFontOfSize:14];
    receiveLabel.textColor = [UIColor labelColor];
    receiveLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [receiveRow addSubview:receiveLabel];

    UISwitch *receiveSwitch = [[UISwitch alloc] init];
    receiveSwitch.on = self.receiveEnabled;
    receiveSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [receiveSwitch addTarget:self action:@selector(receiveToggled:) forControlEvents:UIControlEventValueChanged];
    [receiveRow addSubview:receiveSwitch];

    [NSLayoutConstraint activateConstraints:@[
        [sendRow.topAnchor constraintEqualToAnchor:autoSyncCard.contentView.topAnchor],
        [sendRow.leadingAnchor constraintEqualToAnchor:autoSyncCard.contentView.leadingAnchor],
        [sendRow.trailingAnchor constraintEqualToAnchor:autoSyncCard.contentView.trailingAnchor],
        [sendRow.heightAnchor constraintEqualToConstant:44],
        [sendLabel.leadingAnchor constraintEqualToAnchor:sendRow.leadingAnchor],
        [sendLabel.centerYAnchor constraintEqualToAnchor:sendRow.centerYAnchor],
        [sendSwitch.trailingAnchor constraintEqualToAnchor:sendRow.trailingAnchor],
        [sendSwitch.centerYAnchor constraintEqualToAnchor:sendRow.centerYAnchor],

        [receiveRow.topAnchor constraintEqualToAnchor:sendRow.bottomAnchor],
        [receiveRow.leadingAnchor constraintEqualToAnchor:autoSyncCard.contentView.leadingAnchor],
        [receiveRow.trailingAnchor constraintEqualToAnchor:autoSyncCard.contentView.trailingAnchor],
        [receiveRow.heightAnchor constraintEqualToConstant:44],
        [receiveLabel.leadingAnchor constraintEqualToAnchor:receiveRow.leadingAnchor],
        [receiveLabel.centerYAnchor constraintEqualToAnchor:receiveRow.centerYAnchor],
        [receiveSwitch.trailingAnchor constraintEqualToAnchor:receiveRow.trailingAnchor],
        [receiveSwitch.centerYAnchor constraintEqualToAnchor:receiveRow.centerYAnchor],

        [autoSyncCard.contentView.bottomAnchor constraintEqualToAnchor:receiveRow.bottomAnchor],
    ]];

    autoSyncCard.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [autoSyncCard.topAnchor constraintEqualToAnchor:lastView.bottomAnchor constant:12],
        [autoSyncCard.leadingAnchor constraintEqualToAnchor:self.scrollView.leadingAnchor constant:padding],
        [autoSyncCard.widthAnchor constraintEqualToConstant:width],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:autoSyncCard.bottomAnchor constant:20],
    ]];
}

- (UIView *)createPairedDeviceRow:(NSDictionary *)device {
    UIView *row = [[UIView alloc] init];
    row.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    row.layer.cornerRadius = 8;
    row.layer.masksToBounds = YES;

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.text = device[@"name"];
    nameLabel.font = [UIFont boldSystemFontOfSize:14];
    nameLabel.textColor = [UIColor labelColor];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:nameLabel];

    UILabel *urlLabel = [[UILabel alloc] init];
    urlLabel.text = device[@"url"];
    urlLabel.font = [UIFont systemFontOfSize:11];
    urlLabel.textColor = [UIColor secondaryLabelColor];
    urlLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:urlLabel];

    UILabel *timeLabel = [[UILabel alloc] init];
    timeLabel.text = [NSString stringWithFormat:@"最后活跃: %@", device[@"lastSeen"]];
    timeLabel.font = [UIFont systemFontOfSize:10];
    timeLabel.textColor = [UIColor tertiaryLabelColor];
    timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:timeLabel];

    UIButton *pushBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [pushBtn setTitle:@"推送" forState:UIControlStateNormal];
    pushBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    pushBtn.backgroundColor = [UIColor systemBlueColor];
    [pushBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    pushBtn.layer.cornerRadius = 6;
    pushBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [pushBtn addTarget:self action:@selector(pushToDevice) forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:pushBtn];

    UIButton *deleteBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [deleteBtn setTitle:@"删除" forState:UIControlStateNormal];
    deleteBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    deleteBtn.backgroundColor = [UIColor systemRedColor];
    [deleteBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    deleteBtn.layer.cornerRadius = 6;
    deleteBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [deleteBtn addTarget:self action:@selector(removeDevice) forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:deleteBtn];

    [NSLayoutConstraint activateConstraints:@[
        [nameLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:8],
        [nameLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10],
        [nameLabel.trailingAnchor constraintEqualToAnchor:pushBtn.leadingAnchor constant:-8],
        [urlLabel.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:2],
        [urlLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10],
        [urlLabel.trailingAnchor constraintEqualToAnchor:pushBtn.leadingAnchor constant:-8],
        [timeLabel.topAnchor constraintEqualToAnchor:urlLabel.bottomAnchor constant:2],
        [timeLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:10],

        [pushBtn.trailingAnchor constraintEqualToAnchor:deleteBtn.leadingAnchor constant:-4],
        [pushBtn.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [pushBtn.widthAnchor constraintEqualToConstant:50],
        [pushBtn.heightAnchor constraintEqualToConstant:28],

        [deleteBtn.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
        [deleteBtn.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [deleteBtn.widthAnchor constraintEqualToConstant:50],
        [deleteBtn.heightAnchor constraintEqualToConstant:28],
    ]];

    return row;
}

#pragma mark - Actions

- (void)serviceToggled:(UISwitch *)sender {
    self.receiveEnabled = sender.on;
    self.httpRunning = sender.on;
    [self.defaults setBool:self.receiveEnabled forKey:@"lanReceiveEnabled"];
    [self.defaults synchronize];
    [self buildUI];
}

- (void)togglePairingCodeVisibility {
    self.pairingCodeVisible = !self.pairingCodeVisible;
    [self buildUI];
}

- (void)refreshPairingCode {
    self.isRefreshing = YES;
    [self buildUI];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.isRefreshing = NO;
        // Generate a random 6-digit code
        self.pairingCode = [NSString stringWithFormat:@"%06d", arc4random_uniform(1000000)];
        [self buildUI];
    });
}

- (void)scanLan {
    self.isScanning = YES;
    [self buildUI];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.isScanning = NO;
        [self buildUI];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描完成" message:@"未发现新的局域网设备" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)pairDevice {
    NSString *url = self.peerUrlField.text ?: @"";
    NSString *code = self.peerCodeField.text ?: @"";
    if (url.length == 0 || code.length == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误" message:@"请填写设备地址和配对码" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self.peerUrlField resignFirstResponder];
    [self.peerCodeField resignFirstResponder];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"配对请求" message:[NSString stringWithFormat:@"正在尝试与 %@ 配对...", url] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        self.pairedCount++;
        [self buildUI];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pushToDevice {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"推送" message:@"正在推送剪贴板内容..." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)removeDevice {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"确认" message:@"确定要移除该设备吗？" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"移除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        self.pairedCount--;
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

@end
