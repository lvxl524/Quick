#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define QC_PREFS_PATH @"/var/mobile/Library/Preferences/com.mosheng.quickclipboard.plist"
// v1.3.19: 已配对设备清单迁移到 Preferences 目录 (与 QC_PREFS_PATH 同目录, 沙箱 Preferences.app 可正常读写)。
// 旧路径 /var/mobile/Library/QuickClipboard/peers.plist 在沙箱下被拦截, 导致设置页"已配对设备"始终为空。
#define QC_PEERS_PATH @"/var/mobile/Library/Preferences/com.mosheng.quickclipboard.peers.plist"
#define QC_DB_PATH @"/var/mobile/Library/QuickClipboard/clipboard.db"
#define QC_SYNC_DIR @"/var/mobile/Library/QuickClipboard/sync"
#define QC_CLOUD_ENCRYPTION_KEY_PREF @"cloudEncryptionKey"
#define QC_VERSION @"1.3.19"

extern NSString * const QCClipDidChangeNotification;
extern NSString * const QCWebDAVSyncRequestNotification;
extern NSString * const QCLANDevicePairedNotification;
extern NSString * const QCLANSyncReceivedNotification;

typedef NS_ENUM(NSInteger, QCClipType) {
    QCClipTypePlainText = 0,
    QCClipTypeRichText,
    QCClipTypeImage,
    QCClipTypeURL,
    QCClipTypeFile
};

@interface QCClipItem : NSObject <NSSecureCoding>
@property (nonatomic, strong) NSString *uuid;
@property (nonatomic, assign) QCClipType type;
@property (nonatomic, strong) NSData *payload;
@property (nonatomic, strong) NSString *textRepresentation;
@property (nonatomic, strong) NSDate *createdAt;
@property (nonatomic, strong) NSDate *updatedAt;
@property (nonatomic, assign) BOOL favorite;
@property (nonatomic, assign) BOOL deleted;
@property (nonatomic, strong) NSString *deviceID;
@property (nonatomic, strong) NSString *checkSum;
- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;
- (NSString *)computeCheckSum;
@end
