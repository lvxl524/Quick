#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 跨进程共享偏好设置
//
// 背景: 设置页(Preferences 进程)与插件本体(SpringBoard 进程)各自调用
// [NSUserDefaults standardUserDefaults] 时, 读写的是各自进程的偏好文件,
// 互相看不见 -> 设置页"关闭日志"后台照写、推送时设备身份不一致(403) 等
// 问题都源于此。
//
// 本类统一直接读写 QC_PREFS_PATH (com.mosheng.quickclipboard.plist),
// 与 WebDAV 配置(已验证跨进程可用)走同一条路, 保证两个进程看到同一份配置。
@interface QCLANPrefs : NSObject

// 读取整个 plist (不存在时返回空可变字典)
+ (NSMutableDictionary *)load;

+ (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
+ (void)setBool:(BOOL)value forKey:(NSString *)key;

+ (nullable NSString *)stringForKey:(NSString *)key;
+ (void)setString:(nullable NSString *)value forKey:(NSString *)key;

+ (double)doubleForKey:(NSString *)key;
+ (void)setDouble:(double)value forKey:(NSString *)key;

+ (NSInteger)integerForKey:(NSString *)key;
+ (void)setInteger:(NSInteger)value forKey:(NSString *)key;

// 跨进程统一的设备身份 (key 与桌面端一致: sync_transfer_device_id)
// 首次调用会迁移旧的 NSUserDefaults 值, 保证升级后与桌面端已备案身份连续;
// 两个进程始终读到同一个 UUID, 推送/拉取的 X-Device-Id 才能通过桌面端鉴权。
+ (NSString *)deviceId;

@end

NS_ASSUME_NONNULL_END
