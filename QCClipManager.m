#import "QCClipManager.h"
#import "QCStore.h"
#import "QCWebDAVClient.h"
#import "QCLANServer.h"
#import "QCLANLogger.h"

static const NSTimeInterval kDeduplicateWindow = 2.0;

@interface QCClipManager () {
    NSString *_lastCheckSum;
    NSDate *_lastCaptureTime;
    dispatch_queue_t _worker;
    // v1.3.9: 一次性标记改为时间窗口。接收端写回剪贴板会触发多个 hook
    // (如 setString: 内部级联 setItems:), 窗口期内全部忽略, 避免乒乓循环。
    NSDate *_suppressUntil;
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
        _worker = dispatch_queue_create("com.mosheng.quickclipboard.manager", DISPATCH_QUEUE_SERIAL);
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleLANSyncReceived:) name:QCLANSyncReceivedNotification object:nil];
    }
    return self;
}

- (void)capturePasteboard:(UIPasteboard *)pasteboard {
    dispatch_async(_worker, ^{
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
    // 设置抑制窗口与写入剪贴板必须在同一条串行 worker 队列里,
    // 确保 hook 触发的 capturePasteboard 在窗口仍有效时看到它。
    // v1.3.9: 窗口 0.8 秒, 覆盖 setString: → setItems: 等级联触发的多个 hook。
    dispatch_sync(_worker, ^{
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
    });
}

- (void)triggerAutoSync {
    [[QCWebDAVClient sharedClient] performAutoSyncIfEnabled];
    [[QCLANServer sharedServer] broadcastChange];
}

- (void)handleLANSyncReceived:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger count = [note.userInfo[@"count"] integerValue];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UILocalNotification *localNotif = [[UILocalNotification alloc] init];
        localNotif.alertTitle = @"QuickClipboard";
        localNotif.alertBody = [NSString stringWithFormat:@"收到 %ld 条剪贴板同步内容", (long)count];
        localNotif.soundName = UILocalNotificationDefaultSoundName;
        [[UIApplication sharedApplication] presentLocalNotificationNow:localNotif];
#pragma clang diagnostic pop
    });
}

- (NSString *)deviceID {
    NSString *idfv = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
    return idfv ?: @"unknown";
}

@end
