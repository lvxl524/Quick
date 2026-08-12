#import "QCStore.h"

static NSString * const kDBPath = @"/var/mobile/Library/QuickClipboard/clipboard.db";

@interface QCStore () {
    sqlite3 *_db;
    dispatch_queue_t _queue;
}
@end

@implementation QCStore

+ (instancetype)sharedStore {
    static QCStore *store = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        store = [[QCStore alloc] init];
    });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.mosheng.quickclipboard.store", DISPATCH_QUEUE_SERIAL);
        [self prepareEnvironment];
        [self openDatabase];
        [self migrate];
    }
    return self;
}

- (void)prepareEnvironment {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [kDBPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFileOwnerAccountName:@"mobile",NSFileGroupOwnerAccountName:@"mobile"} error:nil];
    }
}

- (void)openDatabase {
    int rc = sqlite3_open([kDBPath UTF8String], &_db);
    if (rc != SQLITE_OK) {
        NSLog(@"[QuickClipboard] Failed to open DB: %s", sqlite3_errmsg(_db));
    }
}

- (void)migrate {
    const char *sql =
        "CREATE TABLE IF NOT EXISTS clips ("
        "uuid TEXT PRIMARY KEY, "
        "type INTEGER NOT NULL, "
        "payload BLOB, "
        "textRepresentation TEXT, "
        "createdAt INTEGER NOT NULL, "
        "updatedAt INTEGER NOT NULL, "
        "favorite INTEGER DEFAULT 0, "
        "deleted INTEGER DEFAULT 0, "
        "deviceID TEXT, "
        "checkSum TEXT UNIQUE"
        ");"
        "CREATE INDEX IF NOT EXISTS idx_clips_time ON clips(updatedAt);"
        "CREATE INDEX IF NOT EXISTS idx_clips_checksum ON clips(checkSum);";
    char *err = NULL;
    sqlite3_exec(_db, sql, NULL, NULL, &err);
    if (err) {
        NSLog(@"[QuickClipboard] Migration error: %s", err);
        sqlite3_free(err);
    }
}

- (BOOL)bindItem:(QCClipItem *)item toStatement:(sqlite3_stmt *)stmt isInsert:(BOOL)isInsert {
    int idx = 1;
    sqlite3_bind_text(stmt, idx++, [item.uuid UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(stmt, idx++, (int)item.type);
    sqlite3_bind_blob(stmt, idx++, item.payload.bytes, (int)item.payload.length, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, idx++, [item.textRepresentation UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, idx++, (sqlite3_int64)[item.createdAt timeIntervalSince1970]);
    sqlite3_bind_int64(stmt, idx++, (sqlite3_int64)[item.updatedAt timeIntervalSince1970]);
    sqlite3_bind_int(stmt, idx++, item.favorite ? 1 : 0);
    sqlite3_bind_int(stmt, idx++, item.deleted ? 1 : 0);
    sqlite3_bind_text(stmt, idx++, [item.deviceID UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, idx++, [item.checkSum UTF8String], -1, SQLITE_TRANSIENT);
    return YES;
}

- (QCClipItem *)itemFromStatement:(sqlite3_stmt *)stmt {
    QCClipItem *item = [[QCClipItem alloc] init];
    int idx = 0;
    item.uuid = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, idx++)];
    item.type = sqlite3_column_int(stmt, idx++);
    int payloadLen = sqlite3_column_bytes(stmt, idx);
    item.payload = payloadLen > 0 ? [NSData dataWithBytes:sqlite3_column_blob(stmt, idx) length:payloadLen] : nil;
    idx++;
    const char *text = (const char *)sqlite3_column_text(stmt, idx++);
    item.textRepresentation = text ? [NSString stringWithUTF8String:text] : nil;
    item.createdAt = [NSDate dateWithTimeIntervalSince1970:sqlite3_column_int64(stmt, idx++)];
    item.updatedAt = [NSDate dateWithTimeIntervalSince1970:sqlite3_column_int64(stmt, idx++)];
    item.favorite = sqlite3_column_int(stmt, idx++) == 1;
    item.deleted = sqlite3_column_int(stmt, idx++) == 1;
    const char *device = (const char *)sqlite3_column_text(stmt, idx++);
    item.deviceID = device ? [NSString stringWithUTF8String:device] : nil;
    const char *cs = (const char *)sqlite3_column_text(stmt, idx++);
    item.checkSum = cs ? [NSString stringWithUTF8String:cs] : nil;
    return item;
}

- (NSArray<QCClipItem *> *)allItems {
    return [self runQuery:@"SELECT * FROM clips WHERE deleted = 0 ORDER BY updatedAt DESC" args:nil];
}

- (NSArray<QCClipItem *> *)itemsWithType:(QCClipType)type {
    return [self runQuery:@"SELECT * FROM clips WHERE deleted = 0 AND type = ? ORDER BY updatedAt DESC" args:@[@(type)]];
}

- (NSArray<QCClipItem *> *)favoriteItems {
    return [self runQuery:@"SELECT * FROM clips WHERE deleted = 0 AND favorite = 1 ORDER BY updatedAt DESC" args:nil];
}

- (nullable QCClipItem *)itemWithCheckSum:(NSString *)checkSum {
    NSArray *items = [self runQuery:@"SELECT * FROM clips WHERE checkSum = ? LIMIT 1" args:@[checkSum]];
    return items.firstObject;
}

// v1.3.16: 本地库最新一条记录的更新时间 (写回剪贴板门槛的相对新旧判断)
- (nullable NSDate *)latestItemUpdatedAt {
    NSArray *items = [self runQuery:@"SELECT * FROM clips WHERE deleted = 0 ORDER BY updatedAt DESC LIMIT 1" args:nil];
    return items.firstObject ? ((QCClipItem *)items.firstObject).updatedAt : nil;
}

- (NSArray<QCClipItem *> *)runQuery:(NSString *)sql args:(nullable NSArray *)args {
    __block NSMutableArray *results = [NSMutableArray array];
    dispatch_sync(_queue, ^{
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
            for (NSUInteger i = 0; i < args.count; i++) {
                id arg = args[i];
                if ([arg isKindOfClass:[NSNumber class]]) {
                    sqlite3_bind_int64(stmt, (int)(i + 1), [arg longLongValue]);
                } else {
                    sqlite3_bind_text(stmt, (int)(i + 1), [[arg description] UTF8String], -1, SQLITE_TRANSIENT);
                }
            }
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                [results addObject:[self itemFromStatement:stmt]];
            }
            sqlite3_finalize(stmt);
        }
    });
    return results;
}

- (BOOL)saveItem:(QCClipItem *)item {
    if (!item.checkSum) item.checkSum = [item computeCheckSum];
    __block BOOL ok = NO;
    dispatch_sync(_queue, ^{
        const char *sql = "INSERT OR REPLACE INTO clips (uuid,type,payload,textRepresentation,createdAt,updatedAt,favorite,deleted,deviceID,checkSum) VALUES (?,?,?,?,?,?,?,?,?,?)";
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            [self bindItem:item toStatement:stmt isInsert:YES];
            ok = sqlite3_step(stmt) == SQLITE_DONE;
            sqlite3_finalize(stmt);
        }
    });
    return ok;
}

- (BOOL)updateItem:(QCClipItem *)item {
    item.updatedAt = [NSDate date];
    return [self saveItem:item];
}

- (BOOL)deleteItem:(QCClipItem *)item {
    __block BOOL ok = NO;
    dispatch_sync(_queue, ^{
        const char *sql = "DELETE FROM clips WHERE uuid = ?";
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, [item.uuid UTF8String], -1, SQLITE_TRANSIENT);
            ok = sqlite3_step(stmt) == SQLITE_DONE;
            sqlite3_finalize(stmt);
        }
    });
    return ok;
}

- (BOOL)markDeleted:(QCClipItem *)item {
    item.deleted = YES;
    item.updatedAt = [NSDate date];
    return [self saveItem:item];
}

- (BOOL)cleanupDeletedBefore:(NSDate *)date {
    __block BOOL ok = NO;
    dispatch_sync(_queue, ^{
        const char *sql = "DELETE FROM clips WHERE deleted = 1 AND updatedAt < ?";
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(stmt, 1, (sqlite3_int64)[date timeIntervalSince1970]);
            ok = sqlite3_step(stmt) == SQLITE_DONE;
            sqlite3_finalize(stmt);
        }
    });
    return ok;
}

@end
