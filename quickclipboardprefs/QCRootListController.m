#import "QCRootListController.h"
#import "QCWebDAVController.h"
#import "QCLANController.h"

@interface QCRootListController ()
@property (nonatomic, strong) UISegmentedControl *segmentedControl;
@property (nonatomic, strong) QCWebDAVController *webDAVController;
@property (nonatomic, strong) QCLANController *lanController;
@end

@implementation QCRootListController

// Return empty specifiers to satisfy PSListController contract
- (id)specifiers {
    return @[];
}

- (void)viewDidLoad {
    self.title = @"QuickClipboard";

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
}

@end
