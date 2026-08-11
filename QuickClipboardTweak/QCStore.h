#import "QuickClipboard.h"
#import <sqlite3.h>

NS_ASSUME_NONNULL_BEGIN

@interface QCStore : NSObject
+ (instancetype)sharedStore;
- (NSArray<QCClipItem *> *)allItems;
- (NSArray<QCClipItem *> *)itemsWithType:(QCClipType)type;
- (NSArray<QCClipItem *> *)favoriteItems;
- (nullable QCClipItem *)itemWithCheckSum:(NSString *)checkSum;
- (BOOL)saveItem:(QCClipItem *)item;
- (BOOL)deleteItem:(QCClipItem *)item;
- (BOOL)updateItem:(QCClipItem *)item;
- (BOOL)markDeleted:(QCClipItem *)item;
- (BOOL)cleanupDeletedBefore:(NSDate *)date;
@end

NS_ASSUME_NONNULL_END
