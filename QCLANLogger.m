#import "QCLANLogger.h"
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

NSString * const QCLANLogFilePath = @"/var/mobile/Library/QuickClipboard/lan_log.txt";

static const NSUInteger      kMaxMemoryLines = 600;
static const unsigned long long kMaxFileBytes = 512 * 1024;

@implementation QCLANLogger {
    NSMutableArray<NSString *> *_memory;
    dispatch_queue_t _queue;
    NSDateFormatter *_formatter;
}

+ (instancetype)sharedLogger {
    static QCLANLogger *logger = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logger = [[QCLANLogger alloc] init];
    });
    return logger;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.mosheng.quickclipboard.logger", DISPATCH_QUEUE_SERIAL);
        _memory = [NSMutableArray array];
        _formatter = [[NSDateFormatter alloc] init];
        _formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        NSString *dir = [QCLANLogFilePath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return self;
}

#pragma mark - Public API

- (void)logLevel:(QCLANLogLevel)level category:(NSString *)category fmt:(NSString *)fmt, ... {
    if (!fmt) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [self appendLevel:level category:category message:msg];
}

- (void)info:(NSString *)category fmt:(NSString *)fmt, ... {
    if (!fmt) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [self appendLevel:QCLANLogLevelInfo category:category message:msg];
}

- (void)warn:(NSString *)category fmt:(NSString *)fmt, ... {
    if (!fmt) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [self appendLevel:QCLANLogLevelWarn category:category message:msg];
}

- (void)error:(NSString *)category fmt:(NSString *)fmt, ... {
    if (!fmt) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    [self appendLevel:QCLANLogLevelError category:category message:msg];
}

#pragma mark - Display

- (NSArray<NSString *> *)displayLines:(NSUInteger)maxLines {
    NSArray *fileLines = [self fileLines];
    if (fileLines.count == 0) {
        __block NSArray *mem = nil;
        dispatch_sync(_queue, ^{ mem = [self->_memory copy]; });
        if (maxLines > 0 && mem.count > maxLines) {
            mem = [mem subarrayWithRange:NSMakeRange(mem.count - maxLines, maxLines)];
        }
        return mem;
    }
    if (maxLines > 0 && fileLines.count > maxLines) {
        return [fileLines subarrayWithRange:NSMakeRange(fileLines.count - maxLines, maxLines)];
    }
    return fileLines;
}

- (NSUInteger)fileLineCount {
    return [self fileLines].count;
}

- (void)clearLog {
    dispatch_sync(_queue, ^{
        [self->_memory removeAllObjects];
        [[NSFileManager defaultManager] removeItemAtPath:QCLANLogFilePath error:nil];
    });
}

#pragma mark - Internals

- (void)appendLevel:(QCLANLogLevel)level category:(NSString *)category message:(NSString *)message {
    NSString *line = [self makeLine:level category:category message:message];
    dispatch_async(_queue, ^{
        [self->_memory addObject:line];
        if (self->_memory.count > kMaxMemoryLines) {
            [self->_memory removeObjectsInRange:NSMakeRange(0, self->_memory.count - kMaxMemoryLines)];
        }
        [self appendToFile:line];
    });
}

- (NSString *)makeLine:(QCLANLogLevel)level category:(NSString *)category message:(NSString *)message {
    NSString *ts = [_formatter stringFromDate:[NSDate date]];
    NSString *lvl = level == QCLANLogLevelError ? @"ERROR"
                  : level == QCLANLogLevelWarn  ? @"WARN" : @"INFO";
    return [NSString stringWithFormat:@"[%@] [%@] [%@] %@", ts, lvl, category ?: @"-", message ?: @""];
}

// O_APPEND + 单次 write: 跨进程追加安全
- (void)appendToFile:(NSString *)line {
    NSString *full = [line stringByAppendingString:@"\n"];
    NSData *data = [full dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) return;

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:QCLANLogFilePath error:nil];
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    if (size > kMaxFileBytes) {
        [[NSFileManager defaultManager] removeItemAtPath:QCLANLogFilePath error:nil];
    }

    int fd = open(QCLANLogFilePath.UTF8String, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        ssize_t written = write(fd, data.bytes, data.length);
        if (written < 0) {
            NSLog(@"[QuickClipboard] Logger write failed: %s", strerror(errno));
        }
        close(fd);
    } else {
        NSLog(@"[QuickClipboard] Logger cannot open %@: %s", QCLANLogFilePath, strerror(errno));
    }
}

- (NSArray<NSString *> *)fileLines {
    NSData *data = [NSData dataWithContentsOfFile:QCLANLogFilePath];
    if (!data || data.length == 0) return @[];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text || text.length == 0) return @[];
    NSMutableArray *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    while (lines.lastObject.length == 0) [lines removeLastObject];
    return lines;
}

@end
