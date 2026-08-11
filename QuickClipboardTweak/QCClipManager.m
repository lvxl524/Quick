#import "QCClipManager.h"
#import "QCStore.h"
#import "QCWebDAVClient.h"
#import "QCLANServer.h"

static const NSTimeInterval kDeduplicateWindow = 2.0;

@interface QCClipManager () {
    NSString *_lastCheckSum;
    NSDate *_lastCaptureTime;
    dispatch_queue_t _worker;
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
        QCClipItem *item = [self buildItemFromPasteboard:pasteboard];
        if (!item) return;
        
        NSString *checkSum = item.checkSum ?: [item computeCheckSum];
        item.checkSum = checkSum;
        
        // Dedup within window
        if ([checkSum isEqualToString:self->_lastCheckSum]) {
            NSDate *now = [NSDate date];
            if ([now timeIntervalSinceDate:self->_lastCaptureTime] < kDeduplicateWindow) return;
        }
        
        QCClipItem *existing = [[QCStore sharedStore] itemWithCheckSum:checkSum];
        if (existing) {
            existing.updatedAt = [NSDate date];
            existing.deviceID = [self deviceID];
            [[QCStore sharedStore] updateItem:existing];
            self->_lastCheckSum = checkSum;
            self->_lastCaptureTime = [NSDate date];
            return;
        }
        
        item.deviceID = [self deviceID];
        if ([[QCStore sharedStore] saveItem:item]) {
            self->_lastCheckSum = checkSum;
            self->_lastCaptureTime = [NSDate date];
            [[NSNotificationCenter defaultCenter] postNotificationName:QCClipDidChangeNotification object:item];
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
