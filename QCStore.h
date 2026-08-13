#import "QuickClipboard.h"
#import <sqlite3.h>

NS_ASSUME_NONNULL_BEGIN

@interface QCStore : NSObject
+ (instancetype)sharedStore;
- (NSArray<QCClipItem *> *)allItems;
- (NSArray<QCClipItem *> *)itemsWithType:(QCClipType)type;
- (NSArray<QCClipItem *> *)favoriteItems;
- (nullable QCClipItem *)itemWithCheckSum:(NSString *)checkSum;
// v1.3.16: 本地库最新一条记录的更新时间 (写回剪贴板门槛的相对新旧判断)
- (nullable NSDate *)latestItemUpdatedAt;
- (BOOL)saveItem:(QCClipItem *)item;
- (BOOL)deleteItem:(QCClipItem *)item;
- (BOOL)updateItem:(QCClipItem *)item;
- (BOOL)markDeleted:(QCClipItem *)item;
- (BOOL)cleanupDeletedBefore:(NSDate *)date;
// v1.3.20: 清空全部剪贴板记录 (一键初始化用)
- (BOOL)clearAll;
@end

NS_ASSUME_NONNULL_END
