#import "QCRootListController.h"
#import "QCWebDAVController.h"
#import "QCLANController.h"
#import "../QuickClipboard.h"

@interface QCRootListController ()
@property (nonatomic, strong) UISegmentedControl *segmentedControl;
@property (nonatomic, strong) QCWebDAVController *webDAVController;
@property (nonatomic, strong) QCLANController *lanController;
@property (nonatomic, strong) UILabel *versionLabel;
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

    // Version label at the bottom
    [self setupVersionLabel];
}

- (void)setupVersionLabel {
    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.text = [NSString stringWithFormat:@"QuickClipboard v%@", QC_VERSION];
    self.versionLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.versionLabel.textColor = [UIColor grayColor];
    self.versionLabel.textAlignment = NSTextAlignmentCenter;
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.versionLabel];

    // Pin to bottom with a safe area inset
    [NSLayoutConstraint activateConstraints:@[
        [self.versionLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.versionLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [self.versionLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.versionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-16]
    ]];
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
    // Bring version label to front
    [self.view bringSubviewToFront:self.versionLabel];
}

@end
