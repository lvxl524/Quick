#import "QCLANLogViewController.h"
#import "QCLANLogger.h"
#import "../QuickClipboard.h"

static NSString * const kLocalBaseURL = @"http://127.0.0.1:35691";

@interface QCLANLogViewController ()
@property (nonatomic, strong) UILabel *headerLabel;   // 版本号
@property (nonatomic, strong) UILabel *metaLabel;     // device_id / 日志行数
@property (nonatomic, strong) UISegmentedControl *filterControl;
@property (nonatomic, strong) UISwitch *autoScrollSwitch;
@property (nonatomic, strong) UISwitch *logSwitch;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *resetButton;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, copy) NSString *deviceIdDisplay;
@end

@implementation QCLANLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 版本号同时放进导航栏标题: 不依赖内容区布局, 确保任何情况下都可见
    self.title = [NSString stringWithFormat:@"局域网日志 · v%@", QC_VERSION];
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(closeTapped)];
    // 右侧: 导出 + 清空 (版本号只显示在面板 header, 不放在按钮标题里)
    UIBarButtonItem *exportItem = [[UIBarButtonItem alloc] initWithTitle:@"导出"
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(exportTapped)];
    UIBarButtonItem *clearItem = [[UIBarButtonItem alloc] initWithTitle:@"清空"
                                                                  style:UIBarButtonItemStylePlain
                                                                 target:self
                                                                 action:@selector(clearTapped)];
    self.navigationItem.rightBarButtonItems = @[clearItem, exportItem];

    [self buildUI];
    [self fetchDeviceInfo];
    [self refreshLog];

    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         target:self
                                                       selector:@selector(refreshLog)
                                                       userInfo:nil
                                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

#pragma mark - UI

- (void)buildUI {
    // 版本信息 header
    self.headerLabel = [[UILabel alloc] init];
    self.headerLabel.text = [NSString stringWithFormat:@"QuickClipboard v%@", QC_VERSION];
    self.headerLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    self.headerLabel.textColor = [UIColor labelColor];
    self.headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.headerLabel];

    self.metaLabel = [[UILabel alloc] init];
    self.metaLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.metaLabel.textColor = [UIColor secondaryLabelColor];
    self.metaLabel.numberOfLines = 2;
    self.metaLabel.text = @"device_id: 加载中...";
    self.metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.metaLabel];

    // v1.3.20: 一键初始化按钮 (重置为最初安装默认状态)
    self.resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.resetButton setTitle:@"一键初始化（重置为默认状态）" forState:UIControlStateNormal];
    [self.resetButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.resetButton.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    self.resetButton.backgroundColor = [UIColor systemRedColor];
    self.resetButton.layer.cornerRadius = 10;
    self.resetButton.layer.masksToBounds = YES;
    [self.resetButton addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];
    self.resetButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.resetButton];

    // 工具行: 过滤 + 自动滚动 + 日志开关
    UIView *toolbar = [[UIView alloc] init];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:toolbar];

    self.filterControl = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"警告+错误"]];
    self.filterControl.selectedSegmentIndex = 0;
    [self.filterControl addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
    self.filterControl.translatesAutoresizingMaskIntoConstraints = NO;
    [toolbar addSubview:self.filterControl];

    UILabel *scrollLabel = [[UILabel alloc] init];
    scrollLabel.text = @"自动滚动";
    scrollLabel.font = [UIFont systemFontOfSize:12];
    scrollLabel.textColor = [UIColor secondaryLabelColor];
    scrollLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [toolbar addSubview:scrollLabel];

    self.autoScrollSwitch = [[UISwitch alloc] init];
    self.autoScrollSwitch.on = YES;
    self.autoScrollSwitch.transform = CGAffineTransformMakeScale(0.75, 0.75);
    self.autoScrollSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [toolbar addSubview:self.autoScrollSwitch];

    UILabel *logLabel = [[UILabel alloc] init];
    logLabel.text = @"日志";
    logLabel.font = [UIFont systemFontOfSize:12];
    logLabel.textColor = [UIColor secondaryLabelColor];
    logLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [toolbar addSubview:logLabel];

    self.logSwitch = [[UISwitch alloc] init];
    self.logSwitch.on = [QCLANLogger isLoggingEnabled];
    self.logSwitch.transform = CGAffineTransformMakeScale(0.75, 0.75);
    [self.logSwitch addTarget:self action:@selector(logSwitchChanged) forControlEvents:UIControlEventValueChanged];
    self.logSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [toolbar addSubview:self.logSwitch];

    [NSLayoutConstraint activateConstraints:@[
        [self.filterControl.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor],
        [self.filterControl.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        [scrollLabel.leadingAnchor constraintEqualToAnchor:self.filterControl.trailingAnchor constant:12],
        [scrollLabel.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        [self.autoScrollSwitch.leadingAnchor constraintEqualToAnchor:scrollLabel.trailingAnchor constant:2],
        [self.autoScrollSwitch.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        [logLabel.leadingAnchor constraintEqualToAnchor:self.autoScrollSwitch.trailingAnchor constant:12],
        [logLabel.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        [self.logSwitch.leadingAnchor constraintEqualToAnchor:logLabel.trailingAnchor constant:2],
        [self.logSwitch.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.logSwitch.trailingAnchor],
    ]];

    // 日志文本
    self.textView = [[UITextView alloc] init];
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.textColor = [UIColor labelColor];
    self.textView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.textView.layer.cornerRadius = 10;
    self.textView.layer.masksToBounds = YES;
    self.textView.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    self.textView.alwaysBounceVertical = YES;
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.textView];

    [NSLayoutConstraint activateConstraints:@[
        [self.headerLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10],
        [self.headerLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.headerLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [self.metaLabel.topAnchor constraintEqualToAnchor:self.headerLabel.bottomAnchor constant:4],
        [self.metaLabel.leadingAnchor constraintEqualToAnchor:self.headerLabel.leadingAnchor],
        [self.metaLabel.trailingAnchor constraintEqualToAnchor:self.headerLabel.trailingAnchor],

        // v1.3.20: 一键初始化按钮置于 metaLabel 之下, 工具行在其下方
        [self.resetButton.topAnchor constraintEqualToAnchor:self.metaLabel.bottomAnchor constant:8],
        [self.resetButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.resetButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.resetButton.heightAnchor constraintEqualToConstant:40],

        [toolbar.topAnchor constraintEqualToAnchor:self.resetButton.bottomAnchor constant:8],
        [toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [toolbar.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-16],

        [self.textView.topAnchor constraintEqualToAnchor:toolbar.bottomAnchor constant:8],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
    ]];
}

#pragma mark - Data

- (void)refreshLog {
    NSArray *lines = [[QCLANLogger sharedLogger] displayLines:3000];

    NSMutableString *out = [NSMutableString string];
    NSUInteger warnErr = 0;
    BOOL errorsOnly = self.filterControl.selectedSegmentIndex == 1;
    for (NSString *line in lines) {
        BOOL isErr = [line containsString:@"[ERROR]"] || [line containsString:@"[WARN]"];
        if (isErr) warnErr++;
        if (errorsOnly && !isErr) continue;
        [out appendString:line];
        [out appendString:@"\n"];
    }

    self.textView.text = out.length > 0 ? out : @"(暂无日志)\n\n提示: 请先执行一次扫描或配对操作,\n日志会实时记录用户操作与系统内部动作。";

    NSUInteger total = lines.count;
    self.metaLabel.text = [NSString stringWithFormat:@"device_id: %@\n日志 %lu 行 (警告/错误 %lu 条) | %@",
                           self.deviceIdDisplay ?: @"-",
                           (unsigned long)total, (unsigned long)warnErr,
                           [QCLANLogFilePath lastPathComponent]];

    if (self.autoScrollSwitch.isOn && out.length > 0) {
        [self.textView scrollRangeToVisible:NSMakeRange(out.length - 1, 1)];
    }
}

- (void)fetchDeviceInfo {
    NSURL *url = [NSURL URLWithString:[kLocalBaseURL stringByAppendingString:@"/ping"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:5.0];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSDictionary *json = nil;
        if (data && !err) {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([json isKindOfClass:[NSDictionary class]] && json[@"device_id"]) {
                self.deviceIdDisplay = json[@"device_id"];
            } else {
                self.deviceIdDisplay = @"未获取 (SpringBoard 服务不可达)";
            }
            [self refreshLog];
        });
    }] resume];
}

#pragma mark - Actions

- (void)filterChanged {
    [self refreshLog];
}

- (void)logSwitchChanged {
    BOOL enabled = self.logSwitch.isOn;
    [QCLANLogger setLoggingEnabled:enabled];
    if (enabled) {
        // 开启日志时记一条, 便于确认生效
        [[QCLANLogger sharedLogger] info:@"UI" fmt:@"用户开启日志记录"];
    }
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)clearTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空日志"
                                                                   message:@"确定要清空全部日志吗？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[QCLANLogger sharedLogger] clearLog];
        [self refreshLog];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// v1.3.20: 一键初始化 —— 确认后调用本地服务重置为最初安装默认状态
- (void)resetTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"一键初始化"
                                                                   message:@"将清除所有已配对设备、剪贴板记录与设置，恢复到最初安装状态。确定继续吗？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重置" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kLocalBaseURL stringByAppendingString:@"/control/reset"]]];
        req.HTTPMethod = @"POST";
        req.timeoutInterval = 10.0;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[QCLANLogger sharedLogger] info:@"UI" fmt:@"一键初始化请求完成 (err=%@)", err ? err.localizedDescription : @"无"];
                UIAlertController *done = [UIAlertController alertControllerWithTitle:@"已完成"
                                                                              message:err ? @"初始化请求失败，请稍后重试" : @"已重置为默认状态，请重新扫描配对。"
                                                                       preferredStyle:UIAlertControllerStyleAlert];
                [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction *aa) {
                    [self refreshLog];
                    [self fetchDeviceInfo];
                }]];
                [self presentViewController:done animated:YES completion:nil];
            });
        }] resume];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 导出完整日志: 写入临时文件后用系统分享面板 (可发送到微信/QQ/文件/备忘录等应用)
- (void)exportTapped {
    NSArray *lines = [[QCLANLogger sharedLogger] displayLines:3000];
    NSMutableString *log = [NSMutableString string];
    [log appendFormat:@"QuickClipboard v%@ 日志导出\n", QC_VERSION];
    [log appendFormat:@"device_id: %@\n", self.deviceIdDisplay ?: @"-"];
    [log appendFormat:@"时间: %@\n", [NSDate date]];
    [log appendString:@"========================================\n"];
    for (NSString *line in lines) {
        [log appendString:line];
        [log appendString:@"\n"];
    }
    if (lines.count == 0) {
        [log appendString:@"(暂无日志)\n"];
    }

    // 写临时文件, 供分享面板作为文件附件发送
    NSString *dir = @"/var/mobile/Media/QuickClipboard";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *path = [dir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"lan_export_%@.txt", [fmt stringFromDate:[NSDate date]]]];
    [log writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"用户导出日志 (%lu 行, 打开分享面板)", (unsigned long)lines.count];

    // 系统分享面板: 文本 + 文件 URL, 可选择微信/QQ/文件/备忘录/隔空投送等
    UIActivityViewController *avc = [[UIActivityViewController alloc]
                                     initWithActivityItems:@[log, [NSURL fileURLWithPath:path]]
                                     applicationActivities:nil];
    // iPad 必须指定弹出锚点, 否则会崩溃
    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.sourceView = self.view;
        avc.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                                  CGRectGetMidY(self.view.bounds), 0, 0);
        avc.popoverPresentationController.permittedArrowDirections = 0;
    }
    // 同时保留剪贴板副本, 兼容旧习惯
    [UIPasteboard generalPasteboard].string = log;
    [self presentViewController:avc animated:YES completion:nil];
}

@end
