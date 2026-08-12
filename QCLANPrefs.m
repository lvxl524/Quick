#import "QCLANPrefs.h"
#import "QuickClipboard.h"

static NSString * const kDeviceIDPrefsKey = @"sync_transfer_device_id"; // 与桌面端一致
static NSString * const kLegacyDeviceIDDefaultsKey = @"sync_transfer_device_id"; // 旧 NSUserDefaults 里的同名 key

@implementation QCLANPrefs

+ (NSMutableDictionary *)load {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:QC_PREFS_PATH];
    return dict ? [dict mutableCopy] : [NSMutableDictionary dictionary];
}

+ (void)setValue:(nullable id)value forKey:(NSString *)key {
    NSMutableDictionary *dict = [self load];
    if (value) {
        dict[key] = value;
    } else {
        [dict removeObjectForKey:key];
    }
    [dict writeToFile:QC_PREFS_PATH atomically:YES];
}

#pragma mark - Typed accessors

+ (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:QC_PREFS_PATH];
    if (!dict) return defaultValue;
    id v = dict[key];
    if (v == nil) return defaultValue;
    return [v boolValue];
}

+ (void)setBool:(BOOL)value forKey:(NSString *)key {
    [self setValue:@(value) forKey:key];
}

+ (nullable NSString *)stringForKey:(NSString *)key {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:QC_PREFS_PATH];
    return dict[key];
}

+ (void)setString:(nullable NSString *)value forKey:(NSString *)key {
    [self setValue:value ?: @"" forKey:key];
}

+ (double)doubleForKey:(NSString *)key {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:QC_PREFS_PATH];
    return dict[key] ? [dict[key] doubleValue] : 0.0;
}

+ (void)setDouble:(double)value forKey:(NSString *)key {
    [self setValue:@(value) forKey:key];
}

+ (NSInteger)integerForKey:(NSString *)key {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:QC_PREFS_PATH];
    return dict[key] ? [dict[key] integerValue] : 0;
}

+ (void)setInteger:(NSInteger)value forKey:(NSString *)key {
    [self setValue:@(value) forKey:key];
}

#pragma mark - Device identity

+ (NSString *)deviceId {
    NSMutableDictionary *dict = [self load];
    NSString *stored = dict[kDeviceIDPrefsKey];
    if (stored.length > 0) return stored;

    // 迁移: 优先沿用本进程 NSUserDefaults 里的旧值 (SpringBoard 进程开机即运行,
    // 几乎总是先写入, 该值正是桌面端配对时备案的身份), 保持升级后身份连续。
    NSString *legacy = [[NSUserDefaults standardUserDefaults] stringForKey:kLegacyDeviceIDDefaultsKey];
    if (legacy.length > 0) {
        dict[kDeviceIDPrefsKey] = legacy;
        [dict writeToFile:QC_PREFS_PATH atomically:YES];
        return legacy;
    }

    NSString *newId = [[NSUUID UUID] UUIDString].lowercaseString;
    dict[kDeviceIDPrefsKey] = newId;
    [dict writeToFile:QC_PREFS_PATH atomically:YES];
    return newId;
}

@end
