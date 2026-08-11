#import "QCLANController.h"

static NSString * const kLANCell = @"QCLANCell";

@interface QCLANController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISwitch *eventSyncSwitch;
@property (nonatomic, strong) UISwitch *sendSwitch;
@property (nonatomic, strong) UISwitch *receiveSwitch;
@property (nonatomic, strong) UITextField *addressField;
@property (nonatomic, strong) UITextField *codeField;
@property (nonatomic, strong) UILabel *pairCodeLabel;
@property (nonatomic, strong) UILabel *portLabel;
@end

@implementation QCLANController

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
    NSDictionary *cfg = prefs[@"lanConfig"] ?: @{};
    self.eventSyncSwitch.on = [cfg[@"eventSyncEnabled"] boolValue];
    self.sendSwitch.on = [cfg[@"sendEnabled"] boolValue];
    self.receiveSwitch.on = [cfg[@"receiveEnabled"] boolValue];
    self.addressField.text = cfg[@"lastAddress"];
    self.codeField.text = cfg[@"lastCode"];
    self.portLabel.text = @"HTTP 端口 35691";
    self.pairCodeLabel.text = @"978749"; // In production read from QCLANServer
}

- (void)saveConfig {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.mosheng.quickclipboard.plist"] ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
    cfg[@"eventSyncEnabled"] = @(self.eventSyncSwitch.on);
    cfg[@"sendEnabled"] = @(self.sendSwitch.on);
    cfg[@"receiveEnabled"] = @(self.receiveSwitch.on);
    cfg[@"lastAddress"] = self.addressField.text ?: @"";
    cfg[@"lastCode"] = self.codeField.text ?: @"";
    prefs[@"lanConfig"] = cfg;
    [prefs writeToFile:@"/var/mobile/Library/Preferences/com.mosheng.quickclipboard.plist" atomically:YES];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1; // status
        case 1: return 4; // connect device
        case 2: return 1; // event sync header
        case 3: return 3; // event sync toggles
        case 4: return 1; // paired devices
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 1) return @"连接设备";
    if (section == 2) return @"事件同步";
    if (section == 4) return @"已配对设备";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kLANCell];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kLANCell];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.accessoryView = nil;
    
    if (indexPath.section == 0) {
        cell.textLabel.text = @"局域网同步\nHTTP 端口 35691\n已配对设备可向本机推送数据和文件";
        cell.textLabel.numberOfLines = 0;
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = [NSString stringWithFormat:@"本机配对码\n%@", self.pairCodeLabel.text];
            cell.textLabel.numberOfLines = 0;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (indexPath.row == 1) {
            self.addressField.placeholder = @"设备地址";
            self.addressField.borderStyle = UITextBorderStyleRoundedRect;
            self.addressField.frame = CGRectMake(20, 5, tableView.bounds.size.width - 40, 34);
            [cell.contentView addSubview:self.addressField];
        } else if (indexPath.row == 2) {
            self.codeField.placeholder = @"对方配对码";
            self.codeField.borderStyle = UITextBorderStyleRoundedRect;
            self.codeField.frame = CGRectMake(20, 5, tableView.bounds.size.width - 40, 34);
            [cell.contentView addSubview:self.codeField];
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"配对设备";
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (indexPath.section == 2) {
        cell.textLabel.text = @"启用事件同步\n本机内容变化后，会按发送/接收设置与已配对设备同步。";
        cell.textLabel.numberOfLines = 0;
        cell.accessoryView = self.eventSyncSwitch;
    } else if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"发送\n本机新增、修改、删除时发送给已配对设备";
            cell.textLabel.numberOfLines = 0;
            cell.accessoryView = self.sendSwitch;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"接收\n允许已配对设备的变化写入本机";
            cell.textLabel.numberOfLines = 0;
            cell.accessoryView = self.receiveSwitch;
        }
    } else if (indexPath.section == 4) {
        cell.textLabel.text = @"XSZ-20240531ULA\nhttp://192.168.3.9:35691";
        cell.textLabel.numberOfLines = 0;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0 || indexPath.section == 2) return 80;
    if (indexPath.section == 1 && (indexPath.row == 1 || indexPath.row == 2)) return 44;
    return 60;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == 3) {
        [self pairDevice];
    }
}

- (void)pairDevice {
    [self saveConfig];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"配对" message:@"已保存配置。实际配对需要 SpringBoard 进程中的 LAN 服务响应。" preferredStyle:UIAlertControllerStyleAlert];
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

- (UISwitch *)eventSyncSwitch { if (!_eventSyncSwitch) _eventSyncSwitch = [[UISwitch alloc] init]; [_eventSyncSwitch addTarget:self action:@selector(saveConfig) forControlEvents:UIControlEventValueChanged]; return _eventSyncSwitch; }
- (UISwitch *)sendSwitch { if (!_sendSwitch) _sendSwitch = [[UISwitch alloc] init]; [_sendSwitch addTarget:self action:@selector(saveConfig) forControlEvents:UIControlEventValueChanged]; return _sendSwitch; }
- (UISwitch *)receiveSwitch { if (!_receiveSwitch) _receiveSwitch = [[UISwitch alloc] init]; [_receiveSwitch addTarget:self action:@selector(saveConfig) forControlEvents:UIControlEventValueChanged]; return _receiveSwitch; }
- (UITextField *)addressField { if (!_addressField) _addressField = [[UITextField alloc] init]; return _addressField; }
- (UITextField *)codeField { if (!_codeField) _codeField = [[UITextField alloc] init]; return _codeField; }
- (UILabel *)pairCodeLabel { if (!_pairCodeLabel) _pairCodeLabel = [[UILabel alloc] init]; return _pairCodeLabel; }
- (UILabel *)portLabel { if (!_portLabel) _portLabel = [[UILabel alloc] init]; return _portLabel; }

@end
