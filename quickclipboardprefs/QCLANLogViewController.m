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
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, copy) NSString *deviceIdDisplay;
@end

@implementation QCLANLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"局域网日志";
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

        [toolbar.topAnchor constraintEqualToAnchor:self.metaLabel.bottomAnchor constant:8],
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

// 导出完整日志: 复制到剪贴板 + 写入 /var/mobile/Media/QuickClipboard/ 便于取出
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

    // 1. 复制到剪贴板 (可直接粘贴发送)
    [UIPasteboard generalPasteboard].string = log;

    // 2. 写文件 (便于通过文件管理器取出)
    NSString *dir = @"/var/mobile/Media/QuickClipboard";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *path = [dir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"lan_export_%@.txt", [fmt stringFromDate:[NSDate date]]]];
    NSError *writeError = nil;
    BOOL wrote = [log writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    if (!wrote) {
        path = [NSString stringWithFormat:@"写入失败: %@", writeError.localizedDescription ?: @"未知错误"];
    }

    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"用户导出日志 (%lu 行)", (unsigned long)lines.count];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"日志已导出"
                                                                   message:[NSString stringWithFormat:@"已复制 %lu 行日志到剪贴板，可直接粘贴发送。\n\n文件: %@", (unsigned long)lines.count, path]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
