#import "QCWebDAVController.h"

typedef NS_ENUM(NSInteger, QCWebDAVSection) {
    QCWebDAVSectionEnable = 0,
    QCWebDAVSectionConnection,
    QCWebDAVSectionEncryption,
    QCWebDAVSectionSyncCategories,
    QCWebDAVSectionManualActions,
    QCWebDAVSectionAutoPush,
    QCWebDAVSectionPollingPull,
    QCWebDAVSectionCount
};

typedef NS_ENUM(NSInteger, QCConnectionRow) {
    QCConnectionRowURL = 0,
    QCConnectionRowUsername,
    QCConnectionRowPassword,
    QCConnectionRowRootPath,
    QCConnectionRowCount
};

typedef NS_ENUM(NSInteger, QCCategoryRow) {
    QCCategoryRowClipboard = 0,
    QCCategoryRowFavorites,
    QCCategoryRowImages,
    QCCategoryRowCount
};

@interface QCWebDAVController () <UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSUserDefaults *defaults;

// Settings
@property (nonatomic, assign) BOOL webdavEnabled;
@property (nonatomic, copy) NSString *webdavUrl;
@property (nonatomic, copy) NSString *webdavUsername;
@property (nonatomic, copy) NSString *webdavRootPath;
@property (nonatomic, assign) BOOL passwordSaved;
@property (nonatomic, copy) NSString *passwordDraft;
@property (nonatomic, assign) BOOL encryptionPasswordSaved;
@property (nonatomic, copy) NSString *encryptionPasswordDraft;
@property (nonatomic, assign) BOOL syncClipboard;
@property (nonatomic, assign) BOOL syncFavorites;
@property (nonatomic, assign) BOOL syncImages;
@property (nonatomic, assign) BOOL autoPush;
@property (nonatomic, assign) NSInteger pushDelaySecs;
@property (nonatomic, assign) BOOL autoPull;
@property (nonatomic, assign) NSInteger pullIntervalSecs;

// Busy states
@property (nonatomic, copy) NSString *busyAction;
@end

@implementation QCWebDAVController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.defaults = [NSUserDefaults standardUserDefaults];
    [self loadSettings];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self.view addSubview:self.tableView];
}

- (void)loadSettings {
    self.webdavEnabled = [self.defaults boolForKey:@"webdavEnabled"];
    self.webdavUrl = [self.defaults stringForKey:@"webdavUrl"] ?: @"";
    self.webdavUsername = [self.defaults stringForKey:@"webdavUsername"] ?: @"";
    self.webdavRootPath = [self.defaults stringForKey:@"webdavRootPath"] ?: @"quickclipboard";
    self.syncClipboard = [self.defaults objectForKey:@"webdavSyncClipboard"] ? [self.defaults boolForKey:@"webdavSyncClipboard"] : YES;
    self.syncFavorites = [self.defaults objectForKey:@"webdavSyncFavorites"] ? [self.defaults boolForKey:@"webdavSyncFavorites"] : YES;
    self.syncImages = [self.defaults boolForKey:@"webdavSyncImages"];
    self.autoPush = [self.defaults boolForKey:@"webdavAutoPush"];
    self.pushDelaySecs = [self.defaults integerForKey:@"webdavPushDelaySecs"] ?: 10;
    self.autoPull = [self.defaults boolForKey:@"webdavAutoPull"];
    self.pullIntervalSecs = [self.defaults integerForKey:@"webdavPullIntervalSecs"] ?: 30;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return QCWebDAVSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case QCWebDAVSectionEnable: return 1;
        case QCWebDAVSectionConnection: return QCConnectionRowCount;
        case QCWebDAVSectionEncryption: return 1;
        case QCWebDAVSectionSyncCategories: return QCCategoryRowCount;
        case QCWebDAVSectionManualActions: return 4;
        case QCWebDAVSectionAutoPush: return 2;
        case QCWebDAVSectionPollingPull: return 2;
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case QCWebDAVSectionEnable:       return nil;
        case QCWebDAVSectionConnection:   return @"连接配置";
        case QCWebDAVSectionEncryption:   return @"加密密码";
        case QCWebDAVSectionSyncCategories: return @"同步类别";
        case QCWebDAVSectionManualActions:  return @"手动操作";
        case QCWebDAVSectionAutoPush:     return @"自动推送";
        case QCWebDAVSectionPollingPull:  return @"轮询拉取";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case QCWebDAVSectionEnable:
            return @"启用后，剪贴板数据将通过 WebDAV 协议自动同步到远程服务器";
        case QCWebDAVSectionConnection:
            return @"填写你的 WebDAV 服务器地址与认证信息";
        case QCWebDAVSectionEncryption:
            return @"设置加密密码以保护同步到云端的数据安全";
        case QCWebDAVSectionSyncCategories:
            return @"选择需要通过 WebDAV 同步的内容类型";
        case QCWebDAVSectionManualActions:
            return @"手动触发数据同步或测试服务器连接状态";
        case QCWebDAVSectionAutoPush:
            return [NSString stringWithFormat:@"检测到新剪贴板内容后，延迟 %ld 秒自动推送到服务器", (long)self.pushDelaySecs];
        case QCWebDAVSectionPollingPull:
            return [NSString stringWithFormat:@"每 %ld 秒自动从服务器拉取最新的剪贴板数据", (long)self.pullIntervalSecs];
        default: return nil;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == QCWebDAVSectionManualActions) {
        return 50; // Taller buttons
    }
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case QCWebDAVSectionEnable:         return [self enableCell:tableView];
        case QCWebDAVSectionConnection:     return [self connectionCell:tableView row:indexPath.row];
        case QCWebDAVSectionEncryption:     return [self encryptionCell:tableView];
        case QCWebDAVSectionSyncCategories: return [self categoryCell:tableView row:indexPath.row];
        case QCWebDAVSectionManualActions:  return [self manualActionCell:tableView row:indexPath.row];
        case QCWebDAVSectionAutoPush:       return [self autoPushCell:tableView row:indexPath.row];
        case QCWebDAVSectionPollingPull:    return [self pollingPullCell:tableView row:indexPath.row];
        default: return [[UITableViewCell alloc] init];
    }
}

#pragma mark - Section: Enable

- (UITableViewCell *)enableCell:(UITableView *)tableView {
    static NSString *cellId = @"EnableCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UISwitch *sw = [[UISwitch alloc] init];
        sw.tag = 100;
        [sw addTarget:self action:@selector(enableSwitched:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }

    UISwitch *sw = (UISwitch *)cell.accessoryView;
    sw.on = self.webdavEnabled;
    cell.textLabel.text = @"启用 WebDAV 同步";
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.detailTextLabel.text = self.webdavEnabled ? @"已启用" : @"已关闭";
    cell.detailTextLabel.textColor = self.webdavEnabled ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
    return cell;
}

- (void)enableSwitched:(UISwitch *)sender {
    self.webdavEnabled = sender.on;
    [self.defaults setBool:self.webdavEnabled forKey:@"webdavEnabled"];
    [self.defaults synchronize];
    // Reload all sections that depend on this state
    [self.tableView reloadData];
}

#pragma mark - Section: Connection

- (UITableViewCell *)connectionCell:(UITableView *)tableView row:(NSInteger)row {
    static NSString *cellId = @"ConnectionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UITextField *tf = [[UITextField alloc] init];
        tf.tag = 200;
        tf.delegate = self;
        tf.textAlignment = NSTextAlignmentRight;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.returnKeyType = UIReturnKeyDone;
        tf.font = [UIFont systemFontOfSize:15];
        tf.textColor = [UIColor labelColor];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:tf];

        [NSLayoutConstraint activateConstraints:@[
            [tf.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [tf.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [tf.widthAnchor constraintEqualToConstant:200],
        ]];
    }

    UITextField *tf = nil;
    for (UIView *v in cell.contentView.subviews) {
        if ([v isKindOfClass:[UITextField class]]) {
            tf = (UITextField *)v;
            break;
        }
    }
    if (!tf) return cell;

    tf.secureTextEntry = NO;
    tf.keyboardType = UIKeyboardTypeDefault;
    tf.enabled = self.webdavEnabled;

    switch (row) {
        case QCConnectionRowURL:
            cell.textLabel.text = @"服务器地址";
            tf.placeholder = @"https://dav.example.com";
            tf.keyboardType = UIKeyboardTypeURL;
            tf.text = self.webdavUrl;
            break;
        case QCConnectionRowUsername:
            cell.textLabel.text = @"用户名";
            tf.placeholder = @"username";
            tf.text = self.webdavUsername;
            break;
        case QCConnectionRowPassword:
            cell.textLabel.text = @"密码";
            tf.placeholder = self.passwordSaved ? @"已保存" : @"输入密码";
            tf.secureTextEntry = YES;
            tf.text = self.passwordDraft;
            break;
        case QCConnectionRowRootPath:
            cell.textLabel.text = @"根路径";
            tf.placeholder = @"quickclipboard";
            tf.text = self.webdavRootPath;
            break;
    }

    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.textColor = self.webdavEnabled ? [UIColor labelColor] : [UIColor tertiaryLabelColor];
    return cell;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    UIView *superview = textField.superview;
    while (superview && ![superview isKindOfClass:[UITableViewCell class]]) {
        superview = superview.superview;
    }
    UITableViewCell *cell = (UITableViewCell *)superview;
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath) return;

    NSString *value = textField.text ?: @"";

    if (indexPath.section == QCWebDAVSectionConnection) {
        switch (indexPath.row) {
            case QCConnectionRowURL:
                self.webdavUrl = value;
                [self.defaults setObject:value forKey:@"webdavUrl"];
                break;
            case QCConnectionRowUsername:
                self.webdavUsername = value;
                [self.defaults setObject:value forKey:@"webdavUsername"];
                break;
            case QCConnectionRowPassword:
                self.passwordDraft = value;
                if (value.length > 0) {
                    self.passwordSaved = YES;
                    [self.defaults setObject:value forKey:@"webdavPassword"];
                }
                break;
            case QCConnectionRowRootPath:
                self.webdavRootPath = value.length > 0 ? value : @"quickclipboard";
                [self.defaults setObject:self.webdavRootPath forKey:@"webdavRootPath"];
                break;
        }
    } else if (indexPath.section == QCWebDAVSectionEncryption) {
        self.encryptionPasswordDraft = value;
        if (value.length > 0) {
            self.encryptionPasswordSaved = YES;
            [self.defaults setObject:value forKey:@"webdavEncryptionPassword"];
        }
    }

    [self.defaults synchronize];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Section: Encryption

- (UITableViewCell *)encryptionCell:(UITableView *)tableView {
    static NSString *cellId = @"EncryptionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UITextField *tf = [[UITextField alloc] init];
        tf.tag = 300;
        tf.delegate = self;
        tf.textAlignment = NSTextAlignmentRight;
        tf.secureTextEntry = YES;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.returnKeyType = UIReturnKeyDone;
        tf.font = [UIFont systemFontOfSize:15];
        tf.textColor = [UIColor labelColor];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:tf];

        [NSLayoutConstraint activateConstraints:@[
            [tf.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [tf.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [tf.widthAnchor constraintEqualToConstant:200],
        ]];
    }

    UITextField *tf = nil;
    for (UIView *v in cell.contentView.subviews) {
        if ([v isKindOfClass:[UITextField class]]) {
            tf = (UITextField *)v;
            break;
        }
    }
    if (!tf) return cell;

    tf.text = self.encryptionPasswordDraft;
    tf.placeholder = self.encryptionPasswordSaved ? @"已设置" : @"输入加密密码";
    tf.enabled = self.webdavEnabled;
    cell.textLabel.text = @"密码";
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.textColor = self.webdavEnabled ? [UIColor labelColor] : [UIColor tertiaryLabelColor];
    return cell;
}

#pragma mark - Section: Sync Categories

- (UITableViewCell *)categoryCell:(UITableView *)tableView row:(NSInteger)row {
    static NSString *cellId = @"CategoryCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UISwitch *sw = [[UISwitch alloc] init];
        sw.tag = 400;
        [sw addTarget:self action:@selector(categorySwitched:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }

    UISwitch *sw = (UISwitch *)cell.accessoryView;
    NSString *label;
    NSString *desc;
    NSString *key;
    BOOL value;

    switch (row) {
        case QCCategoryRowClipboard:
            label = @"剪贴板";
            desc = @"文本和网址内容";
            key = @"webdavSyncClipboard";
            value = self.syncClipboard;
            break;
        case QCCategoryRowFavorites:
            label = @"收藏";
            desc = @"已收藏的剪贴板记录";
            key = @"webdavSyncFavorites";
            value = self.syncFavorites;
            break;
        case QCCategoryRowImages:
            label = @"图片";
            desc = @"截屏和复制的图片";
            key = @"webdavSyncImages";
            value = self.syncImages;
            break;
        default:
            label = @"";
            desc = @"";
            key = @"";
            value = NO;
            break;
    }

    cell.textLabel.text = label;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.detailTextLabel.text = desc;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.textLabel.textColor = self.webdavEnabled ? [UIColor labelColor] : [UIColor tertiaryLabelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    sw.on = value;
    sw.enabled = self.webdavEnabled;
    sw.accessibilityIdentifier = key;

    return cell;
}

- (void)categorySwitched:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    [self.defaults setBool:sender.on forKey:key];
    [self.defaults synchronize];

    if ([key isEqualToString:@"webdavSyncClipboard"]) self.syncClipboard = sender.on;
    else if ([key isEqualToString:@"webdavSyncFavorites"]) self.syncFavorites = sender.on;
    else if ([key isEqualToString:@"webdavSyncImages"]) self.syncImages = sender.on;
}

#pragma mark - Section: Manual Actions

- (UITableViewCell *)manualActionCell:(UITableView *)tableView row:(NSInteger)row {
    static NSString *cellId = @"ManualActionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }

    BOOL busy = NO;
    NSString *busyLabel = nil;
    NSString *normalLabel = nil;
    UIColor *normalColor = nil;

    switch (row) {
        case 0:
            busy = [self.busyAction isEqualToString:@"test"];
            busyLabel = @"测试中...";
            normalLabel = @"测试连接";
            normalColor = [UIColor systemBlueColor];
            break;
        case 1:
            busy = [self.busyAction isEqualToString:@"upload"];
            busyLabel = @"上传中...";
            normalLabel = @"上传（推送）";
            normalColor = [UIColor labelColor];
            break;
        case 2:
            busy = [self.busyAction isEqualToString:@"download"];
            busyLabel = @"下载中...";
            normalLabel = @"下载（拉取）";
            normalColor = [UIColor labelColor];
            break;
        case 3:
            busy = [self.busyAction isEqualToString:@"downloadAll"];
            busyLabel = @"全部下载中...";
            normalLabel = @"全部下载";
            normalColor = [UIColor labelColor];
            break;
    }

    cell.textLabel.text = busy ? busyLabel : normalLabel;
    cell.textLabel.textColor = busy ? [UIColor secondaryLabelColor] : normalColor;
    cell.userInteractionEnabled = !busy;
    cell.accessoryType = busy ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;

    if (!self.webdavEnabled && !busy) {
        cell.textLabel.textColor = [UIColor tertiaryLabelColor];
        cell.userInteractionEnabled = NO;
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == QCWebDAVSectionManualActions) {
        if (!self.webdavEnabled) {
            [self showAlert:@"提示" message:@"请先启用 WebDAV 同步"];
            return;
        }
        [self performManualAction:indexPath.row];
    }
}

- (void)performManualAction:(NSInteger)row {
    NSString *actionName;
    switch (row) {
        case 0: actionName = @"test"; break;
        case 1: actionName = @"upload"; break;
        case 2: actionName = @"download"; break;
        case 3: actionName = @"downloadAll"; break;
        default: return;
    }

    if (self.busyAction) return;
    self.busyAction = actionName;

    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:QCWebDAVSectionManualActions] withRowAnimation:UITableViewRowAnimationFade];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.busyAction = nil;
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:QCWebDAVSectionManualActions] withRowAnimation:UITableViewRowAnimationFade];

        NSString *title;
        switch (row) {
            case 0: title = @"连接成功"; break;
            case 1: title = @"上传完成"; break;
            case 2: title = @"下载完成"; break;
            case 3: title = @"全部下载完成"; break;
            default: title = @"操作完成"; break;
        }

        [self showAlert:title message:nil];
    });
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Section: Auto Push

- (UITableViewCell *)autoPushCell:(UITableView *)tableView row:(NSInteger)row {
    if (row == 0) {
        return [self switchCell:tableView label:@"自动推送" subtitle:@"检测到新内容时自动上传" value:self.autoPush key:@"webdavAutoPush" tag:500];
    } else {
        return [self stepperCell:tableView label:@"推送延迟" value:self.pushDelaySecs suffix:@"秒" key:@"webdavPushDelaySecs" tag:501 min:1 max:120];
    }
}

#pragma mark - Section: Polling Pull

- (UITableViewCell *)pollingPullCell:(UITableView *)tableView row:(NSInteger)row {
    if (row == 0) {
        return [self switchCell:tableView label:@"轮询拉取" subtitle:@"定时从服务器获取最新内容" value:self.autoPull key:@"webdavAutoPull" tag:600];
    } else {
        return [self stepperCell:tableView label:@"拉取间隔" value:self.pullIntervalSecs suffix:@"秒" key:@"webdavPullIntervalSecs" tag:601 min:5 max:600];
    }
}

#pragma mark - Reusable Cell Builders

- (UITableViewCell *)switchCell:(UITableView *)tableView label:(NSString *)label subtitle:(NSString *)subtitle value:(BOOL)value key:(NSString *)key tag:(NSInteger)tag {
    static NSString *cellId = @"SwitchCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    cell.textLabel.text = label;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.detailTextLabel.text = subtitle;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.textLabel.textColor = self.webdavEnabled ? [UIColor labelColor] : [UIColor tertiaryLabelColor];

    UISwitch *sw = (UISwitch *)[cell.contentView viewWithTag:tag];
    if (!sw) {
        sw = [[UISwitch alloc] init];
        sw.tag = tag;
        sw.accessibilityIdentifier = key;
        [sw addTarget:self action:@selector(genericSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }
    sw.on = value;
    sw.enabled = self.webdavEnabled;
    return cell;
}

- (UITableViewCell *)stepperCell:(UITableView *)tableView label:(NSString *)label value:(NSInteger)value suffix:(NSString *)suffix key:(NSString *)key tag:(NSInteger)tag min:(NSInteger)min max:(NSInteger)max {
    static NSString *cellId = @"StepperCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    cell.textLabel.text = label;
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.textColor = self.webdavEnabled ? [UIColor labelColor] : [UIColor tertiaryLabelColor];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld %@", (long)value, suffix];
    cell.detailTextLabel.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium];
    cell.detailTextLabel.textColor = [UIColor systemBlueColor];

    UIStepper *stepper = (UIStepper *)[cell.contentView viewWithTag:tag];
    if (!stepper) {
        stepper = [[UIStepper alloc] init];
        stepper.tag = tag;
        stepper.accessibilityIdentifier = key;
        stepper.minimumValue = min;
        stepper.maximumValue = max;
        stepper.stepValue = 1;
        [stepper addTarget:self action:@selector(stepperChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = stepper;
    }
    stepper.value = value;
    stepper.enabled = self.webdavEnabled;
    return cell;
}

- (void)genericSwitchChanged:(UISwitch *)sender {
    NSString *key = sender.accessibilityIdentifier;
    [self.defaults setBool:sender.on forKey:key];
    [self.defaults synchronize];

    if ([key isEqualToString:@"webdavAutoPush"]) self.autoPush = sender.on;
    else if ([key isEqualToString:@"webdavAutoPull"]) self.autoPull = sender.on;
}

- (void)stepperChanged:(UIStepper *)sender {
    NSString *key = sender.accessibilityIdentifier;
    NSInteger val = (NSInteger)sender.value;
    [self.defaults setInteger:val forKey:key];
    [self.defaults synchronize];

    if ([key isEqualToString:@"webdavPushDelaySecs"]) self.pushDelaySecs = val;
    else if ([key isEqualToString:@"webdavPullIntervalSecs"]) self.pullIntervalSecs = val;

    // Update footer text with new values
    [self.tableView reloadData];
}

@end
