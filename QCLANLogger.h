#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 跨进程共享的 LAN 调试日志器
// - SpringBoard 进程 (QCLANServer) 与 Preferences 进程 (QCLANController/日志面板) 都写入同一文件
// - 每行以 O_APPEND 单次 write 追加, 原子写入, 跨进程安全
// - 超过 512KB 自动轮转
extern NSString * const QCLANLogFilePath;

typedef NS_ENUM(NSInteger, QCLANLogLevel) {
    QCLANLogLevelInfo  = 0,
    QCLANLogLevelWarn  = 1,
    QCLANLogLevelError = 2,
};

@interface QCLANLogger : NSObject

+ (instancetype)sharedLogger;

// 记录一条日志 (线程安全, 立即落盘 + 内存缓冲)
- (void)logLevel:(QCLANLogLevel)level
        category:(NSString *)category
             fmt:(NSString *)fmt, ... NS_FORMAT_FUNCTION(3,4);

- (void)info:(NSString *)category fmt:(NSString *)fmt, ... NS_FORMAT_FUNCTION(2,3);
- (void)warn:(NSString *)category fmt:(NSString *)fmt, ... NS_FORMAT_FUNCTION(2,3);
- (void)error:(NSString *)category fmt:(NSString *)fmt, ... NS_FORMAT_FUNCTION(2,3);

// 供日志面板展示: 以文件内容为准 (跨进程), 文件为空时回退到本进程内存
// 返回按时间正序的行数组 (最旧在前)
- (NSArray<NSString *> *)displayLines:(NSUInteger)maxLines;

// 清空日志 (同步, truncate 文件 + 清本进程内存)
- (void)clearLog;

// 日志记录总开关 (NSUserDefaults 持久化, Preferences/SpringBoard 两进程同步生效)
+ (BOOL)isLoggingEnabled;
+ (void)setLoggingEnabled:(BOOL)enabled;

// 当前文件行数
- (NSUInteger)fileLineCount;

@end

NS_ASSUME_NONNULL_END
