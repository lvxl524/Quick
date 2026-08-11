#import "QCRootListController.h"
#import "QCWebDAVController.h"
#import "QCLANController.h"
#import "QCBuildController.h"

@interface QCRootListController ()
@property (nonatomic, strong) UISegmentedControl *segmentedControl;
@property (nonatomic, strong) QCWebDAVController *webDAVController;
@property (nonatomic, strong) QCLANController *lanController;
@property (nonatomic, strong) QCBuildController *buildController;
@end

@implementation QCRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"QuickClipboard";
    
    self.segmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"WebDAV", @"局域网", @"构建"]];
    [self.segmentedControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.segmentedControl.selectedSegmentIndex = 0;
    self.navigationItem.titleView = self.segmentedControl;
    
    self.webDAVController = [[QCWebDAVController alloc] init];
    self.lanController = [[QCLANController alloc] init];
    self.buildController = [[QCBuildController alloc] init];
    
    [self addChildViewController:self.webDAVController];
    [self addChildViewController:self.lanController];
    [self addChildViewController:self.buildController];
    
    [self.view addSubview:self.webDAVController.view];
    self.webDAVController.view.frame = self.view.bounds;
    self.webDAVController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    [self.segmentedControl sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    UIViewController *toShow = nil;
    UIViewController *toHide1 = nil;
    UIViewController *toHide2 = nil;
    
    if (sender.selectedSegmentIndex == 0) {
        toShow = self.webDAVController;
        toHide1 = self.lanController;
        toHide2 = self.buildController;
    } else if (sender.selectedSegmentIndex == 1) {
        toShow = self.lanController;
        toHide1 = self.webDAVController;
        toHide2 = self.buildController;
    } else {
        toShow = self.buildController;
        toHide1 = self.webDAVController;
        toHide2 = self.lanController;
    }
    
    [toHide1.view removeFromSuperview];
    [toHide2.view removeFromSuperview];
    [self.view addSubview:toShow.view];
    toShow.view.frame = self.view.bounds;
    toShow.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
}

@end
