#import "QCClipManager.h"
#import "QCStore.h"
#import "QCWebDAVClient.h"
#import "QCLANServer.h"
#import "QCLANLogger.h"
#import <objc/message.h>

static const NSTimeInterval kDeduplicateWindow = 2.0;

@interface QCClipManager () {
    NSString *_lastCheckSum;
    NSDate *_lastCaptureTime;
    // v1.3.11: 所有 UIPasteboard 访问与状态字段读写统一在主线程,
    // 不再使用后台 worker 队列 (后台访问 UIPasteboard 是安全模式崩溃根源)。
    // v1.3.9: 一次性标记改为时间窗口。接收端写回剪贴板会触发多个 hook
    // (如 setString: 内部级联 setItems:), 窗口期内全部忽略, 避免乒乓循环。
    NSDate *_suppressUntil;
    // v1.3.10: 剪贴板 changeCount 轮询兜底。记录上一次看到的 changeCount,
    // 变化即捕获。接收端写回剪贴板后同步更新, 防止轮询误捕获刚收到的内容。
    NSInteger _lastChangeCount;
    NSTimer *_pollTimer;
}
@end

@implementation QCClipManager

+ (instancetype)sharedManager {
    static QCClipManager *manager = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        manager = [[QCClipManager alloc] init];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleLANSyncReceived:) name:QCLANSyncReceivedNotification object:nil];
    }
    return self;
}

- (void)capturePasteboard:(UIPasteboard *)pasteboard {
    // v1.3.11 修复: UIPasteboard 是 UIKit 类, 非线程安全, 必须只在主线程访问。
    // 旧版在 _worker 后台线程读取 UIPasteboard —— v1.3.10 起 SpringBoard 进程
    // 每 2 秒轮询一次, 后台线程访问 UIPasteboard 在 iOS 15+ 极易崩溃
    // (与 pasteboardd 的 XPC 竞争/安全违例), 导致 SpringBoard 崩溃进入安全模式。
    // 现在读取、构建、存储、推送全部在主线程串行执行, 状态字段无竞争。
    dispatch_async(dispatch_get_main_queue(), ^{
        // v1.3.8 修复: 接收端把内容写回剪贴板后, 会同步触发本 hook;
        // 如果继续走自动同步, 会立刻把同一条内容再推回电脑, 造成乒乓循环。
        // v1.3.9: 改为时间窗口抑制 —— 一次接收写入可能级联触发多个
        // hook 方法(setString: 内部可能再调 setItems:), 窗口期内全部忽略,
        // 窗口自动过期, 不消耗状态。
        NSDate *now = [NSDate date];
        if (self->_suppressUntil && [now compare:self->_suppressUntil] == NSOrderedAscending) {
            [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"捕获被抑制(接收回写窗口内), 跳过"];
            return;
        }

        QCClipItem *item = [self buildItemFromPasteboard:pasteboard];
        if (!item) {
            [[QCLANLogger sharedLogger] warn:@"SYNC" fmt:@"捕获剪贴板变化, 但无法解析内容"];
            return;
        }

        NSString *checkSum = item.checkSum ?: [item computeCheckSum];
        item.checkSum = checkSum;

        // Dedup within window: 同一内容 2 秒内只处理一次, 但 2 秒后重新复制仍可触发同步
        if ([checkSum isEqualToString:self->_lastCheckSum]) {
            NSDate *now2 = [NSDate date];
            if ([now2 timeIntervalSinceDate:self->_lastCaptureTime] < kDeduplicateWindow) {
                [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"剪贴板变化与上次相同(2秒去重窗口内), 跳过"];
                return;
            }
        }

        QCClipItem *existing = [[QCStore sharedStore] itemWithCheckSum:checkSum];
        if (existing) {
            existing.updatedAt = [NSDate date];
            existing.deviceID = [self deviceID];
            [[QCStore sharedStore] updateItem:existing];
            self->_lastCheckSum = checkSum;
            self->_lastCaptureTime = [NSDate date];
            // v1.3.8 修复: 用户复制了一条已存在于历史库里的内容(例如刚收到的电脑内容,
            // 或之前复制过的内容)时, 仍应触发自动同步, 否则电脑端收不到。
            [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"剪贴板变化(内容已存在), 触发自动同步"];
            [self triggerAutoSync];
            return;
        }

        item.deviceID = [self deviceID];
        if ([[QCStore sharedStore] saveItem:item]) {
            self->_lastCheckSum = checkSum;
            self->_lastCaptureTime = [NSDate date];
            [[NSNotificationCenter defaultCenter] postNotificationName:QCClipDidChangeNotification object:item];
            [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"捕获剪贴板新内容, 触发自动同步 (%@)",
             item.textRepresentation.length > 20 ? [item.textRepresentation substringToIndex:20] : item.textRepresentation];
            [self triggerAutoSync];
        }
    });
}

- (nullable QCClipItem *)buildItemFromPasteboard:(UIPasteboard *)pasteboard {
    QCClipItem *item = [[QCClipItem alloc] init];
    
    // URL
    NSURL *url = pasteboard.URL ?: [UIPasteboard generalPasteboard].URL;
    if (url) {
        item.type = QCClipTypeURL;
        item.textRepresentation = url.absoluteString;
        item.payload = [url.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        item.checkSum = [item computeCheckSum];
        return item;
    }
    
    // Image
    UIImage *image = pasteboard.image;
    if (!image) image = [UIPasteboard generalPasteboard].image;
    if (image) {
        item.type = QCClipTypeImage;
        item.payload = UIImagePNGRepresentation(image) ?: UIImageJPEGRepresentation(image, 0.95);
        item.textRepresentation = @"[图片]";
        item.checkSum = [item computeCheckSum];
        return item;
    }
    
    // String
    NSString *string = pasteboard.string;
    if (!string) string = [UIPasteboard generalPasteboard].string;
    if (string.length > 0) {
        item.type = QCClipTypePlainText;
        item.textRepresentation = string;
        item.payload = [string dataUsingEncoding:NSUTF8StringEncoding];
        item.checkSum = [item computeCheckSum];
        return item;
    }
    
    return nil;
}

- (void)writeItemToPasteboard:(QCClipItem *)item {
    [self writeItemToPasteboard:item suppressBroadcast:NO];
}

- (void)writeItemToPasteboard:(QCClipItem *)item suppressBroadcast:(BOOL)suppress {
    // v1.3.11 修复: UIPasteboard 写入强制主线程 (UIKit 非线程安全)。
    // 主线程与 hook 触发的 capturePasteboard 串行执行, 抑制窗口语义保持不变
    // (写回后 hook 在窗口期内看到 → 跳过 → 不会反向推回电脑)。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (suppress) {
            self->_suppressUntil = [NSDate dateWithTimeIntervalSinceNow:0.8];
        }
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        switch (item.type) {
            case QCClipTypeImage:
                if (item.payload) {
                    UIImage *image = [UIImage imageWithData:item.payload];
                    if (image) pb.image = image;
                }
                break;
            case QCClipTypeURL:
                if (item.textRepresentation) pb.URL = [NSURL URLWithString:item.textRepresentation];
                break;
            default:
                if (item.textRepresentation) pb.string = item.textRepresentation;
                break;
        }
        // v1.3.10: 记录本次写入后的 changeCount, 轮询检测到相同值会跳过,
        // 防止把刚收到的内容误当作新复制再推回电脑 (乒乓循环双保险)。
        self->_lastChangeCount = pb.changeCount;
        self->_lastCheckSum = item.checkSum;
        self->_lastCaptureTime = [NSDate date];
    });
}

// v1.3.10: 剪贴板轮询兜底 —— 不依赖 hook 的发送通道。
// 微信等 App 的复制若走 hook 覆盖不到的写入路径, 系统剪贴板 changeCount
// 仍会变化, 轮询能发现并触发完整捕获链路 (保存 + 自动推送)。
// 与 hook 共用同一去重/抑制窗口, 不会重复推送; 仅在 SpringBoard 进程调用。
- (void)startPasteboardPolling {
    // v1.3.11 修复: 读取 changeCount 与创建 timer 统一在主线程
    // (UIPasteboard 非线程安全, 旧版在 _worker 后台读取)。
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_pollTimer) return;
        self->_lastChangeCount = [[UIPasteboard generalPasteboard] changeCount];
        self->_pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                             target:self
                                                           selector:@selector(pollPasteboardChange)
                                                           userInfo:nil
                                                            repeats:YES];
    });
}

- (void)pollPasteboardChange {
    // v1.3.11 修复: timer 回调本身在主线程, 直接执行 (UIPasteboard 非线程安全,
    // 旧版 dispatch_async(_worker) 在后台线程访问, 每 2 秒一次高频触发易崩溃)。
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSInteger cc = pb.changeCount;
    if (cc == self->_lastChangeCount) return;  // 无变化, 静默
    self->_lastChangeCount = cc;

    // 抑制窗口: 接收端写回剪贴板触发的变化直接跳过 (防乒乓双保险)
    NSDate *now = [NSDate date];
    if (self->_suppressUntil && [now compare:self->_suppressUntil] == NSOrderedAscending) {
        [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"轮询发现变化但处于接收回写抑制窗口, 跳过"];
        return;
    }

    QCClipItem *item = [self buildItemFromPasteboard:pb];
    if (!item) {
        [[QCLANLogger sharedLogger] warn:@"SYNC" fmt:@"轮询: 剪贴板变化但无法解析内容"];
        return;
    }

    NSString *checkSum = item.checkSum ?: [item computeCheckSum];
    item.checkSum = checkSum;

    // 与 hook 共用同一去重窗口
    if ([checkSum isEqualToString:self->_lastCheckSum]) {
        NSDate *now2 = [NSDate date];
        if ([now2 timeIntervalSinceDate:self->_lastCaptureTime] < kDeduplicateWindow) return;
    }

    QCClipItem *existing = [[QCStore sharedStore] itemWithCheckSum:checkSum];
    if (existing) {
        existing.updatedAt = [NSDate date];
        existing.deviceID = [self deviceID];
        [[QCStore sharedStore] updateItem:existing];
        self->_lastCheckSum = checkSum;
        self->_lastCaptureTime = [NSDate date];
        // 内容已存在 = 其他进程的 hook 已捕获并推送过, 不再重复推送
        [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"轮询: 内容已存在(其他进程已处理), 跳过推送"];
        return;
    }

    item.deviceID = [self deviceID];
    if ([[QCStore sharedStore] saveItem:item]) {
        self->_lastCheckSum = checkSum;
        self->_lastCaptureTime = [NSDate date];
        [[NSNotificationCenter defaultCenter] postNotificationName:QCClipDidChangeNotification object:item];
        [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"轮询捕获剪贴板新内容, 触发自动同步 (%@)",
         item.textRepresentation.length > 20 ? [item.textRepresentation substringToIndex:20] : item.textRepresentation];
        [self triggerAutoSync];
    }
}

- (void)triggerAutoSync {
    [[QCWebDAVClient sharedClient] performAutoSyncIfEnabled];
    [[QCLANServer sharedServer] broadcastChange];
}

// v1.3.10: 真正的系统横幅通知 (UNUserNotificationCenter)。
// 旧版用 UILocalNotification/presentLocalNotificationNow, 在 iOS 10+ 已废弃
// 且不显示任何横幅 → 用户开了"同步通知"开关却毫无效果。
// 注意: Theos SDK 环境下 UserNotifications 头文件方法查找异常,
// 全部用 runtime (NSClassFromString + objc_msgSend) 调用, 无编译期依赖。
static id QCUNCenter(void) {
    Class cls = NSClassFromString(@"UNUserNotificationCenter");
    if (!cls) return nil;
    // v1.3.12 修复: 正确类方法是 currentNotificationCenter, 旧版误写 currentCenter
    // 导致 unrecognized selector sent to class → SpringBoard 崩溃进安全模式。
    // 双保险: respondsToSelector 检查 + performSelector, 任何异常直接返回 nil。
    SEL sel = NSSelectorFromString(@"currentNotificationCenter");
    if (![cls respondsToSelector:sel]) {
        [[QCLANLogger sharedLogger] warn:@"NOTIFY" fmt:@"UNUserNotificationCenter 无 currentNotificationCenter, 跳过"];
        return nil;
    }
    return [cls performSelector:sel];
}

- (void)handleLANSyncReceived:(NSNotification *)note {
    NSInteger count = [note.userInfo[@"count"] integerValue];
    id center = QCUNCenter();
    if (!center) {
        [[QCLANLogger sharedLogger] warn:@"SYNC" fmt:@"系统不支持本地通知, 无法弹横幅"];
        return;
    }
    // Theos SDK 下 UserNotifications 头文件方法查找异常, 全部 runtime 调用 (与 Tweak.xm 一致)。
    // v1.3.11 修复: 经 objc_msgSend 函数指针传 block 时编译器不会自动 copy 到堆,
    // 而系统 API 会在异步回调中保存并调用该 block —— 必须显式 copy, 否则栈 block
    // 悬垂 → 回调时 EXC_BAD_ACCESS 崩溃。
    void (^settingsHandler)(id) = [^(id settings) {
        // UNAuthorizationStatus: NotDetermined=0 Denied=1 Authorized=2 Provisional=3
        NSInteger status = -1;
        SEL statusSel = NSSelectorFromString(@"authorizationStatus");
        if ([settings respondsToSelector:statusSel]) {
            typedef NSInteger (*MsgSend0)(id, SEL);
            MsgSend0 msgSend0 = (MsgSend0)objc_msgSend;
            status = msgSend0(settings, statusSel);
        }
        if (status == 0) {
            // 首次请求通知权限 (系统弹窗, 用户允许后显示横幅)
            typedef void (*MsgSend2)(id, SEL, NSUInteger, id);
            MsgSend2 msgSend2 = (MsgSend2)objc_msgSend;
            void (^authHandler)(BOOL, NSError *) = [^(BOOL granted, NSError *error) {
                if (granted) {
                    [self postReceivedLocalNotificationWithCount:count];
                } else {
                    [[QCLANLogger sharedLogger] warn:@"SYNC" fmt:@"通知权限被拒绝, 无法弹横幅提示 (%@)",
                     error ? error.localizedDescription : @"用户拒绝"];
                }
            } copy];
            msgSend2(center, NSSelectorFromString(@"requestAuthorizationWithOptions:completionHandler:"),
                     (1 | 2 | 4),  // Alert|Sound|Badge
                     authHandler);
        } else if (status == 2 || status == 3) {
            [self postReceivedLocalNotificationWithCount:count];
        } else {
            [[QCLANLogger sharedLogger] warn:@"SYNC" fmt:@"通知权限未开启, 无法弹横幅提示 (状态 %ld)", (long)status];
        }
    } copy];
    typedef void (*MsgSend1)(id, SEL, id);
    MsgSend1 msgSend1 = (MsgSend1)objc_msgSend;
    msgSend1(center, NSSelectorFromString(@"getNotificationSettingsWithCompletionHandler:"), settingsHandler);
}

- (void)postReceivedLocalNotificationWithCount:(NSInteger)count {
    id center = QCUNCenter();
    if (!center) return;
    Class contentClass = NSClassFromString(@"UNMutableNotificationContent");
    Class reqClass = NSClassFromString(@"UNNotificationRequest");
    Class soundClass = NSClassFromString(@"UNNotificationSound");
    if (!contentClass || !reqClass || !soundClass) return;

    id content = [[contentClass alloc] init];
    [content setValue:@"QuickClipboard" forKey:@"title"];
    [content setValue:[NSString stringWithFormat:@"已收到 %ld 条剪贴板同步内容, 已写入剪贴板可直接粘贴", (long)count]
               forKey:@"body"];
    id defaultSound = [soundClass performSelector:@selector(defaultSound)];
    if (defaultSound) [content setValue:defaultSound forKey:@"sound"];

    // [UNNotificationRequest requestWithIdentifier:content:trigger:] 类方法 (3 参数), 用 objc_msgSend
    id (*msgSend3)(id, SEL, id, id, id) = (id (*)(id, SEL, id, id, id))objc_msgSend;
    id request = msgSend3(reqClass,
                          NSSelectorFromString(@"requestWithIdentifier:content:trigger:"),
                          [[NSUUID UUID] UUIDString], content, nil);
    if (!request) return;

    // addNotificationRequest:withCompletionHandler: 同样 runtime 调用
    // v1.3.11: block 显式 copy (同 handleLANSyncReceived: 的悬垂修复)
    typedef void (*MsgSend2b)(id, SEL, id, id);
    MsgSend2b msgSend2b = (MsgSend2b)objc_msgSend;
    void (^addHandler)(NSError *) = [^(NSError *error) {
        if (error) {
            [[QCLANLogger sharedLogger] warn:@"SYNC" fmt:@"发送系统通知失败: %@", error.localizedDescription];
        } else {
            [[QCLANLogger sharedLogger] info:@"SYNC" fmt:@"已弹系统横幅通知 (%ld 条)", (long)count];
        }
    } copy];
    msgSend2b(center, NSSelectorFromString(@"addNotificationRequest:withCompletionHandler:"), request,
              addHandler);
}

- (NSString *)deviceID {
    NSString *idfv = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    return idfv ?: @"unknown";
}

@end
