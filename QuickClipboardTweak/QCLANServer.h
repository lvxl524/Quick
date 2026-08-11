#import "QuickClipboard.h"

NS_ASSUME_NONNULL_BEGIN

@interface QCLANPeer : NSObject
@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) NSString *address;
@property (nonatomic, strong) NSString *pairCode;
@property (nonatomic, strong) NSDate *lastSeen;
@end

@interface QCLANServer : NSObject
+ (instancetype)sharedServer;
@property (nonatomic, assign, readonly) uint16_t port;
@property (nonatomic, strong, readonly) NSString *pairCode;
@property (nonatomic, strong, readonly) NSArray<QCLANPeer *> *pairedDevices;
- (void)start;
- (void)stop;
- (void)broadcastChange;
- (void)pairWithAddress:(NSString *)address code:(NSString *)code completion:(void (^)(BOOL success, NSString *message))completion;
- (void)pushToPeer:(QCLANPeer *)peer completion:(void (^)(BOOL success, NSString *message))completion;
- (void)pullFromPeer:(QCLANPeer *)peer completion:(void (^)(BOOL success, NSString *message))completion;
@end

NS_ASSUME_NONNULL_END
