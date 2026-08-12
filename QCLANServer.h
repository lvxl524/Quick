#import "QuickClipboard.h"

NS_ASSUME_NONNULL_BEGIN

// 与桌面端 (Rust/Tauri) QuickClipboard 完全兼容的 LAN 协议模型
// - UDP 发现: 端口 35692, JSON 包 (quickclipboard-sync-transfer-lan-discovery)
// - HTTP: 端口 35691, /qc-sync/* 端点, Bearer peer-token 授权

@interface QCLANPeer : NSObject
// 桌面端 device_id (UUID4)
@property (nonatomic, strong) NSString *deviceId;
// 显示名
@property (nonatomic, strong) NSString *name;
// IP 地址
@property (nonatomic, strong) NSString *address;
// HTTP 端口 (桌面端 35691)
@property (nonatomic, assign) uint16_t port;
// 配对后服务端下发的 peer_token (UUID4)
@property (nonatomic, strong, nullable) NSString *peerToken;
// 完整 base URL, 如 http://192.168.3.9:35691
@property (nonatomic, strong) NSString *baseURL;
// 兼容旧字段: 本地端展示/校验用
@property (nonatomic, strong, nullable) NSString *pairCode;
@property (nonatomic, strong, nullable) NSDate *lastSeen;
@property (nonatomic, strong, nullable) NSDate *pairedAt;
@property (nonatomic, assign) BOOL paired;
@end

@interface QCLANServer : NSObject

+ (instancetype)sharedServer;

@property (nonatomic, assign, readonly) uint16_t port;
@property (nonatomic, strong, readonly) NSString *pairCode;
@property (nonatomic, strong, readonly) NSArray<QCLANPeer *> *pairedDevices;
@property (nonatomic, assign, readonly) BOOL isRunning;

// 本机稳定 device_id (UUID4, 持久化, key: sync_transfer_device_id, 与桌面端一致)
- (NSString *)deviceId;

- (void)start;
- (void)stop;

#pragma mark - Scanning (UDP 35692, JSON discovery protocol)

- (void)scanForDevicesWithCompletion:(void (^)(NSArray<QCLANPeer *> *devices))completion;

#pragma mark - Pairing (走 /qc-sync/hello + /qc-sync/pairing/confirm)

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
- (void)syncNowWithPeer:(QCLANPeer *)peer completion:(nullable void (^)(BOOL success, NSString *message))completion;

@end

NS_ASSUME_NONNULL_END
