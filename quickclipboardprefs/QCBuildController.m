#import "QCBuildController.h"

static NSString * const kBuildCell = @"QCBuildCell";

@interface QCBuildController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextField *tokenField;
@property (nonatomic, strong) UITextField *usernameField;
@property (nonatomic, strong) UISwitch *autoRetrySwitch;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation QCBuildController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
    
    [self loadValues];
}

- (void)loadValues {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.mosheng.quickclipboard.plist"] ?: @{};
    self.tokenField.text = prefs[@"githubAccessToken"];
    self.usernameField.text = prefs[@"githubUsername"];
    self.autoRetrySwitch.on = [prefs[@"autoRetryBuild"] boolValue];
    self.statusLabel.text = prefs[@"lastBuildStatus"] ?: @"未构建";
}

- (void)saveConfig {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.mosheng.quickclipboard.plist"] ?: [NSMutableDictionary dictionary];
    prefs[@"githubAccessToken"] = self.tokenField.text ?: @"";
    prefs[@"githubUsername"] = self.usernameField.text ?: @"";
    prefs[@"autoRetryBuild"] = @(self.autoRetrySwitch.on);
    [prefs writeToFile:@"/var/mobile/Library/Preferences/com.mosheng.quickclipboard.plist" atomically:YES];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 2;
    if (section == 2) return 2;
    if (section == 3) return 1;
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1) return @"GitHub 登录";
    if (section == 2) return @"构建选项";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kBuildCell];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kBuildCell];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.text = nil;
    cell.accessoryView = nil;
    
    if (indexPath.section == 0) {
        cell.textLabel.text = @"构建与发布\n登录 GitHub 后自动创建 Quick 仓库并上传 deb 包。";
        cell.textLabel.numberOfLines = 0;
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            self.tokenField.placeholder = @"GitHub Personal Access Token";
            self.tokenField.borderStyle = UITextBorderStyleRoundedRect;
            self.tokenField.frame = CGRectMake(20, 5, tableView.bounds.size.width - 40, 34);
            self.tokenField.secureTextEntry = YES;
            [cell.contentView addSubview:self.tokenField];
        } else {
            self.usernameField.placeholder = @"GitHub 用户名";
            self.usernameField.borderStyle = UITextBorderStyleRoundedRect;
            self.usernameField.frame = CGRectMake(20, 5, tableView.bounds.size.width - 40, 34);
            [cell.contentView addSubview:self.usernameField];
        }
    } else if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"构建失败自动重试";
            cell.accessoryView = self.autoRetrySwitch;
        } else {
            cell.textLabel.text = @"状态";
            cell.detailTextLabel.text = self.statusLabel.text;
        }
    } else if (indexPath.section == 3) {
        cell.textLabel.text = @"开始构建并发布";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return 80;
    if (indexPath.section == 1) return 44;
    return 44;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 3) {
        [self startBuild];
    }
}

- (void)startBuild {
    [self saveConfig];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"构建" message:@"已触发构建流程。实际构建需要在 macOS 上运行 scripts/build-and-publish.sh。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    [self saveConfig];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (UITextField *)tokenField { if (!_tokenField) _tokenField = [[UITextField alloc] init]; return _tokenField; }
- (UITextField *)usernameField { if (!_usernameField) _usernameField = [[UITextField alloc] init]; return _usernameField; }
- (UISwitch *)autoRetrySwitch { if (!_autoRetrySwitch) _autoRetrySwitch = [[UISwitch alloc] init]; [_autoRetrySwitch addTarget:self action:@selector(saveConfig) forControlEvents:UIControlEventValueChanged]; return _autoRetrySwitch; }
- (UILabel *)statusLabel { if (!_statusLabel) _statusLabel = [[UILabel alloc] init]; return _statusLabel; }

@end
