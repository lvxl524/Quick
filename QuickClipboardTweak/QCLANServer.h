#import "QuickClipboard.h"

NS_ASSUME_NONNULL_BEGIN

@interface QCLANPeer : NSObject
@property (nonatomic, strong) NSString *peerId;       // unique: address:port
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
@property (nonatomic, strong, readonly) NSArray<QCLANPeer *> *discoveredDevices;

- (void)start;
- (void)stop;
- (void)broadcastChange;

// Scanning
- (void)scanForDevicesWithCompletion:(void (^)(NSArray<QCLANPeer *> *devices))completion;

// Pairing
- (void)pairWithAddress:(NSString *)address code:(NSString *)code completion:(void (^)(BOOL success, NSString *message))completion;

// Device management
- (void)removePeer:(QCLANPeer *)peer;

// Sync
- (void)pushToPeer:(QCLANPeer *)peer completion:(nullable void (^)(BOOL success, NSString *message))completion;
- (void)pullFromPeer:(QCLANPeer *)peer completion:(nullable void (^)(BOOL success, NSString *message))completion;

@end

NS_ASSUME_NONNULL_END
