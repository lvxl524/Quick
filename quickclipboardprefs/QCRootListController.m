#import "QCRootListController.h"
#import "QCWebDAVController.h"
#import "QCLANController.h"
#import "QCLANLogViewController.h"
#import "QCLANLogger.h"
#import "../QuickClipboard.h"

@interface QCRootListController ()
@property (nonatomic, strong) UISegmentedControl *segmentedControl;
@property (nonatomic, strong) QCWebDAVController *webDAVController;
@property (nonatomic, strong) QCLANController *lanController;
@property (nonatomic, strong) UIButton *logButton;   // 右上角感叹号 → 日志面板 (WebDAV/局域网 均可用)
@end

@implementation QCRootListController

- (id)specifiers {
    return @[];
}

- (void)viewDidLoad {
    self.title = @"QuickClipboard";

    // Segmented control in nav bar
    self.segmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"WebDAV", @"局域网"]];
    [self.segmentedControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.segmentedControl.selectedSegmentIndex = 0;
    self.navigationItem.titleView = self.segmentedControl;

    self.webDAVController = [[QCWebDAVController alloc] init];
    self.lanController = [[QCLANController alloc] init];

    [self addChildViewController:self.webDAVController];
    [self addChildViewController:self.lanController];

    [self.view addSubview:self.webDAVController.view];
    self.webDAVController.view.frame = self.view.bounds;
    self.webDAVController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    // 右上角全局日志按钮 (版本号只在日志面板内显示)
    [self setupLogButton];
}

- (void)setupLogButton {
    self.logButton = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImage *icon = [UIImage systemImageNamed:@"exclamationmark.circle.fill"];
    if (icon) {
        [self.logButton setImage:icon forState:UIControlStateNormal];
    } else {
        [self.logButton setTitle:@"!" forState:UIControlStateNormal];
        self.logButton.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    }
    // 无背景色/无外圈, 仅保留图标本身, 内部大小不变
    self.logButton.backgroundColor = [UIColor clearColor];
    self.logButton.tintColor = [UIColor systemBlueColor];
    self.logButton.accessibilityLabel = @"查看局域网日志";
    [self.logButton addTarget:self action:@selector(openLogPanel) forControlEvents:UIControlEventTouchUpInside];
    self.logButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.logButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.logButton.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-6],
        [self.logButton.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:10],
        [self.logButton.widthAnchor constraintEqualToConstant:38],
        [self.logButton.heightAnchor constraintEqualToConstant:38],
    ]];
    [self.view bringSubviewToFront:self.logButton];
}

- (void)openLogPanel {
    [[QCLANLogger sharedLogger] info:@"UI" fmt:@"用户打开日志面板 (v%@)", QC_VERSION];
    QCLANLogViewController *logVC = [[QCLANLogViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:logVC];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    if (sender.selectedSegmentIndex == 0) {
        [self.lanController.view removeFromSuperview];
        [self.view addSubview:self.webDAVController.view];
        self.webDAVController.view.frame = self.view.bounds;
        self.webDAVController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    } else {
        [self.webDAVController.view removeFromSuperview];
        [self.view addSubview:self.lanController.view];
        self.lanController.view.frame = self.view.bounds;
        self.lanController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    // 保持日志按钮在最上层
    [self.view bringSubviewToFront:self.logButton];
}

@end
