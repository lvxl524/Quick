#import "QCWebDAVController.h"

static NSString * const kWebDAVCell = @"QCWebDAVCell";

@interface QCWebDAVController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISwitch *autoPullSwitch;
@property (nonatomic, strong) UISwitch *autoPushSwitch;
@property (nonatomic, strong) UISwitch *pollPullSwitch;
@property (nonatomic, strong) UITextField *urlField;
@property (nonatomic, strong) UITextField *usernameField;
@property (nonatomic, strong) UITextField *passwordField;
@property (nonatomic, strong) UITextField *rootDirField;
@property (nonatomic, strong) UITextField *encryptField;
@property (nonatomic, strong) UITextField *pushDelayField;
@property (nonatomic, strong) UITextField *pollIntervalField;
@end

@implementation QCWebDAVController

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
    NSDictionary *cfg = prefs[@"webdavConfig"] ?: @{};
    self.urlField.text = cfg[@"url"];
    self.usernameField.text = cfg[@"username"];
    self.passwordField.text = cfg[@"password"];
    self.rootDirField.text = cfg[@"rootDir"] ?: @"quickclipboard";
    self.encryptField.text = cfg[@"encryptionKey"];
    self.autoPullSwitch.on = [cfg[@"autoPullEnabled"] boolValue];
    self.autoPushSwitch.on = [cfg[@"autoPushEnabled"] boolValue];
    self.pollPullSwitch.on = [cfg[@"pollPullEnabled"] boolValue];
    self.pushDelayField.text = cfg[@"pushDelay"] ? [cfg[@"pushDelay"] stringValue] : @"10";
    self.pollIntervalField.text = cfg[@"pollInterval"] ? [cfg[@"pollInterval"] stringValue] : @"30";
}

- (void)saveConfig {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.mosheng.quickclipboard.plist"] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
    cfg[@"url"] = self.urlField.text ?: @"";
    cfg[@"username"] = self.usernameField.text ?: @"";
    cfg[@"password"] = self.passwordField.text ?: @"";
    cfg[@"rootDir"] = self.rootDirField.text.length ? self.rootDirField.text : @"quickclipboard";
    cfg[@"encryptionKey"] = self.encryptField.text ?: @"";
    cfg[@"autoPullEnabled"] = @(self.autoPullSwitch.on);
    cfg[@"autoPushEnabled"] = @(self.autoPushSwitch.on);
    cfg[@"pollPullEnabled"] = @(self.pollPullSwitch.on);
    cfg[@"pushDelay"] = @([self.pushDelayField.text integerValue]);
    cfg[@"pollInterval"] = @([self.pollIntervalField.text integerValue]);
    prefs[@"webdavConfig"] = cfg;
    [prefs writeToFile:@"/var/mobile/Library/Preferences/com.mosheng.quickclipboard.plist" atomically:YES];
    
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.mosheng.quickclipboard.webdavSync"), NULL, NULL, YES);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1; // status header
        case 1: return 6; // connection config
        case 2: return 1; // test button
        case 3: return 5; // auto sync
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1) return @"连接配置";
    if (section == 3) return @"自动同步";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kWebDAVCell];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kWebDAVCell];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.text = nil;
    cell.accessoryView = nil;
    
    if (indexPath.section == 0) {
        cell.textLabel.text = @"WebDAV 同步\n同步未启用\n未配置连接";
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.font = [UIFont systemFontOfSize:14];
    } else if (indexPath.section == 1) {
        NSArray *fields = @[self.urlField, self.usernameField, self.passwordField, self.rootDirField, self.encryptField];
        NSArray *placeholders = @[@"WebDAV 地址", @"用户名", @"密码", @"根目录", @"云端加密密码"];
        if (indexPath.row < fields.count) {
            UITextField *field = fields[indexPath.row];
            field.placeholder = placeholders[indexPath.row];
            field.borderStyle = UITextBorderStyleRoundedRect;
            field.frame = CGRectMake(20, 5, tableView.bounds.size.width - 40, 34);
            field.delegate = self;
            field.secureTextEntry = (indexPath.row == 2 || indexPath.row == 4);
            [cell.contentView addSubview:field];
        }
    } else if (indexPath.section == 2) {
        cell.textLabel.text = @"测试连接";
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.textColor = [UIColor systemBlueColor];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"自动拉取";
            cell.accessoryView = self.autoPullSwitch;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"自动推送";
            cell.accessoryView = self.autoPushSwitch;
        } else if (indexPath.row == 2) {
            self.pushDelayField.placeholder = @"推送延迟（秒）";
            self.pushDelayField.borderStyle = UITextBorderStyleRoundedRect;
            self.pushDelayField.frame = CGRectMake(20, 5, tableView.bounds.size.width - 40, 34);
            self.pushDelayField.keyboardType = UIKeyboardTypeNumberPad;
            [cell.contentView addSubview:self.pushDelayField];
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"轮询拉取";
            cell.accessoryView = self.pollPullSwitch;
        } else if (indexPath.row == 4) {
            self.pollIntervalField.placeholder = @"拉取间隔（秒）";
            self.pollIntervalField.borderStyle = UITextBorderStyleRoundedRect;
            self.pollIntervalField.frame = CGRectMake(20, 5, tableView.bounds.size.width - 40, 34);
            self.pollIntervalField.keyboardType = UIKeyboardTypeNumberPad;
            [cell.contentView addSubview:self.pollIntervalField];
        }
    }
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return 80;
    if (indexPath.section == 1 || indexPath.section == 3) return 44;
    return 44;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2) {
        [self testConnection];
    }
}

- (void)testConnection {
    [self saveConfig];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"测试连接" message:@"正在连接 WebDAV..." preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    // In real implementation, call into tweak's WebDAV client via IPC/lib or reload SpringBoard to pick up prefs.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:^{
            UIAlertController *result = [UIAlertController alertControllerWithTitle:@"连接结果" message:@"配置已保存，请确保 WebDAV 服务端可访问。" preferredStyle:UIAlertControllerStyleAlert];
            [result addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:result animated:YES completion:nil];
        }];
    });
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    [self saveConfig];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (UISwitch *)autoPullSwitch {
    if (!_autoPullSwitch) _autoPullSwitch = [[UISwitch alloc] init];
    [_autoPullSwitch addTarget:self action:@selector(saveConfig) forControlEvents:UIControlEventValueChanged];
    return _autoPullSwitch;
}
- (UISwitch *)autoPushSwitch {
    if (!_autoPushSwitch) _autoPushSwitch = [[UISwitch alloc] init];
    [_autoPushSwitch addTarget:self action:@selector(saveConfig) forControlEvents:UIControlEventValueChanged];
    return _autoPushSwitch;
}
- (UISwitch *)pollPullSwitch {
    if (!_pollPullSwitch) _pollPullSwitch = [[UISwitch alloc] init];
    [_pollPullSwitch addTarget:self action:@selector(saveConfig) forControlEvents:UIControlEventValueChanged];
    return _pollPullSwitch;
}
- (UITextField *)urlField { if (!_urlField) _urlField = [[UITextField alloc] init]; return _urlField; }
- (UITextField *)usernameField { if (!_usernameField) _usernameField = [[UITextField alloc] init]; return _usernameField; }
- (UITextField *)passwordField { if (!_passwordField) _passwordField = [[UITextField alloc] init]; return _passwordField; }
- (UITextField *)rootDirField { if (!_rootDirField) _rootDirField = [[UITextField alloc] init]; return _rootDirField; }
- (UITextField *)encryptField { if (!_encryptField) _encryptField = [[UITextField alloc] init]; return _encryptField; }
- (UITextField *)pushDelayField { if (!_pushDelayField) _pushDelayField = [[UITextField alloc] init]; return _pushDelayField; }
- (UITextField *)pollIntervalField { if (!_pollIntervalField) _pollIntervalField = [[UITextField alloc] init]; return _pollIntervalField; }

@end
