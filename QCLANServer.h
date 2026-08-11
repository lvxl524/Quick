#import "QuickClipboard.h"

NS_ASSUME_NONNULL_BEGIN

@interface QCLANPeer : NSObject
@property (nonatomic, strong) NSString *peerId;
@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) NSString *address;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, strong) NSString *pairCode;
@property (nonatomic, strong) NSDate *lastSeen;
@property (nonatomic, assign) BOOL paired;
@end

@interface QCLANServer : NSObject

+ (instancetype)sharedServer;

@property (nonatomic, assign, readonly) uint16_t port;
@property (nonatomic, strong, readonly) NSString *pairCode;
@property (nonatomic, strong, readonly) NSArray<QCLANPeer *> *pairedDevices;
@property (nonatomic, assign, readonly) BOOL isRunning;

- (void)start;
- (void)stop;

#pragma mark - Scanning (runs UDP discovery, returns discovered devices)

- (void)scanForDevicesWithCompletion:(void (^)(NSArray<QCLANPeer *> *devices))completion;

#pragma mark - Pairing (validates pair code)

- (void)pairWithAddress:(NSString *)address
                 port:(uint16_t)port
                 code:(NSString *)code
           completion:(void (^)(BOOL success, NSString * _Nullable message))completion;

#pragma mark - Peer management

- (void)reloadPeers;
- (void)removePeer:(QCLANPeer *)peer;

#pragma mark - Sync

- (void)broadcastChange;
- (void)pushToPeer:(QCLANPeer *)peer completion:(nullable void (^)(BOOL success, NSString *message))completion;
- (void)pullFromPeer:(QCLANPeer *)peer completion:(nullable void (^)(BOOL success, NSString *message))completion;

@end

NS_ASSUME_NONNULL_END
