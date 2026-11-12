#import "OWCommon.h"
#import <IOKit/IOKitLib.h>
#include <sys/sysctl.h>

#ifndef kIOMainPortDefault
#define kIOMainPortDefault kIOMasterPortDefault
#endif

#pragma mark - OWLogger

static NSString * _Nonnull OWLogDir(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return dirs.firstObject ?: NSTemporaryDirectory();
}

@implementation OWLogger

+ (NSString *)logPath {
    static NSString *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        p = [OWLogDir() stringByAppendingPathComponent:@"ow_debug.log"];
    });
    return p;
}

+ (void)logFile:(const char *)file line:(int)line format:(NSString *)fmt, ... {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSString *line_out = [NSString stringWithFormat:@"[%@] %s:%d %@\n",
                          [NSISO8601DateFormatter stringFromDate:[NSDate date]
                                                        timeZone:[NSTimeZone localTimeZone]
                                                       formatOptions:0],
                          file ? [[NSString stringWithUTF8String:file] lastPathComponent].UTF8String : "?",
                          line, msg];

    NSLog(@"%@", line_out);

    static NSFileHandle *fh;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [self logPath];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSData data] writeToFile:path atomically:YES];
        }
        fh = [NSFileHandle fileHandleForWritingAtPath:path];
        [fh seekToEndOfFile];
    });

    @synchronized (self) {
        if (fh) {
            [fh writeData:[line_out dataUsingEncoding:NSUTF8StringEncoding]];
        }
    }
}

+ (NSData *)tail:(NSUInteger)maxBytes {
    NSData *d = [NSData dataWithContentsOfFile:[self logPath]];
    if (!d) return nil;
    if (d.length <= maxBytes) return d;
    return [d subdataWithRange:NSMakeRange(d.length - maxBytes, maxBytes)];
}

+ (void)purge {
    [[NSFileManager defaultManager] removeItemAtPath:[self logPath] error:nil];
}

@end

#pragma mark - OWState

NSString * const OWStateKeyDone            = @"done";
NSString * const OWStateKeyBootSession     = @"bootSession";
NSString * const OWStateKeyPayloads        = @"payloads";
NSString * const OWStateKeyKernelAttempts  = @"kernelAttempts";
NSString * const OWStateKeyKernelExhausted = @"kernelExhausted";
NSString * const OWStateKeyKeysAcquired    = @"keysAcquired";
NSString * const OWStateKeyLastError       = @"lastError";

@implementation OWState {
    NSMutableDictionary *_store;
    NSString *_path;
    dispatch_queue_t _q;
}

+ (instancetype)shared {
    static OWState *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[OWState alloc] init]; });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _path = [OWLogDir() stringByAppendingPathComponent:@"route_state.plist"];
        _q = dispatch_queue_create("ow.state", DISPATCH_QUEUE_SERIAL);
        NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:_path];
        _store = loaded ? [loaded mutableCopy] : [NSMutableDictionary new];
    }
    return self;
}

- (id)objectForKey:(NSString *)key {
    __block id v;
    dispatch_sync(_q, ^{ v = _store[key]; });
    return v;
}

- (void)setObject:(id)value forKey:(NSString *)key {
    dispatch_sync(_q, ^{
        if (value) _store[key] = value; else [_store removeObjectForKey:key];
        [_store writeToFile:_path atomically:YES];
    });
}

- (void)removeObjectForKey:(NSString *)key {
    dispatch_sync(_q, ^{
        [_store removeObjectForKey:key];
        [_store writeToFile:_path atomically:YES];
    });
}

- (void)synchronize {
    dispatch_sync(_q, ^{ [_store writeToFile:_path atomically:YES]; });
}

- (void)reset {
    dispatch_sync(_q, ^{
        [_store removeAllObjects];
        [_store writeToFile:_path atomically:YES];
    });
}

- (NSMutableDictionary *)_attempts {
    NSMutableDictionary *d = [self objectForKey:OWStateKeyKernelAttempts];
    if (![d isKindOfClass:NSMutableDictionary.class]) d = [NSMutableDictionary new];
    return [d mutableCopy];
}

- (NSUInteger)attemptsForExploit:(NSString *)identifier {
    NSDictionary *d = [self objectForKey:OWStateKeyKernelAttempts];
    return [d[identifier] unsignedIntegerValue];
}

- (void)bumpAttemptForExploit:(NSString *)identifier {
    NSMutableDictionary *d = [self _attempts];
    NSUInteger n = [d[identifier] unsignedIntegerValue] + 1;
    d[identifier] = @(n);
    [self setObject:d forKey:OWStateKeyKernelAttempts];
}

- (void)markExploitExhausted:(NSString *)identifier {
    NSMutableArray *a = [[self objectForKey:OWStateKeyKernelExhausted] mutableCopy] ?: [NSMutableArray new];
    if (![a containsObject:identifier]) [a addObject:identifier];
    [self setObject:a forKey:OWStateKeyKernelExhausted];
}

- (BOOL)isExploitExhausted:(NSString *)identifier {
    NSArray *a = [self objectForKey:OWStateKeyKernelExhausted];
    return [a containsObject:identifier];
}

- (BOOL)isDone {
    return [[self objectForKey:OWStateKeyDone] boolValue];
}

- (BOOL)markDoneIfPayloadValid:(BOOL)valid {
    if (!valid) return NO;
    [self setObject:@YES forKey:OWStateKeyDone];
    return YES;
}

- (void)notePayload:(NSString *)name bytes:(uint64_t)bytes valid:(BOOL)valid {
    NSMutableArray *a = [[self payloads] mutableCopy];
    [a addObject:@{@"name": name, @"bytes": @(bytes), @"valid": @(valid),
                   @"ts": @((uint64_t)[[NSDate date] timeIntervalSince1970])}];
    [self setObject:a forKey:OWStateKeyPayloads];
}

- (NSArray<NSDictionary *> *)payloads {
    NSArray *a = [self objectForKey:OWStateKeyPayloads];
    return a ?: @[];
}

@end

#pragma mark - OWDeviceProfile

static int ow_sysctl_string(const char *name, char *buf, size_t sz) {
    size_t len = sz;
    return sysctlbyname(name, buf, &len, NULL, 0) == 0 ? 0 : -1;
}

@implementation OWDeviceProfile

// 手写了 bootManifestHash 的 getter，clang 不会再自动合成 ivar，
// 必须显式声明，否则 _bootManifestHash 未定义（CI 实测报错）。
@synthesize bootManifestHash = _bootManifestHash;

+ (instancetype)current {
    static OWDeviceProfile *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [[OWDeviceProfile alloc] init]; });
    return p;
}

- (instancetype)init {
    if (self = [super init]) {
        NSString *v = [UIDevice currentDevice].systemVersion ?: @"0.0";
        _osVersion = v;
        NSArray *parts = [v componentsSeparatedByString:@"."];
        _major = parts.count > 0 ? [parts[0] integerValue] : 0;
        _minor = parts.count > 1 ? [parts[1] integerValue] : 0;
        _patch = parts.count > 2 ? [parts[2] integerValue] : 0;

        // 系统 build：exploit 的 DPSupportInclude.Builds 白名单靠它匹配
        char build[64] = {0};
        if (ow_sysctl_string("kern.osversion", build, sizeof(build)) == 0) {
            _osBuild = [NSString stringWithUTF8String:build] ?: @"";
        } else {
            _osBuild = @"";
        }

        char machine[128] = {0};
        if (ow_sysctl_string("hw.machine", machine, sizeof(machine)) == 0) {
            _machine = [NSString stringWithUTF8String:machine] ?: @"unknown";
        } else {
            _machine = @"unknown";
        }

        _isArm64e = [self _detectArm64e];
        _socTier = [self _classifySoc:_machine];
    }
    return self;
}

- (BOOL)_detectArm64e {
#if __has_feature(ptrauth_calls)
    return YES;
#else
    return NO;
#endif
}

// 机型 → SoC 档。仅用于日志/投放统计；是否可用以 exploit 自带 Info.plist 的
// DPExploitSupportedDevices / DPSupportExclude 为准，不要拿这张表做硬判定。
- (OWSocTier)_classifySoc:(NSString *)machine {
    if (![machine hasPrefix:@"iPhone"] && ![machine hasPrefix:@"iPad"]) return OWSocTierUnknown;

    NSInteger num = 0;
    NSScanner *sc = [NSScanner scannerWithString:machine];
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    [sc scanUpToCharactersFromSet:digits intoString:NULL];
    [sc scanInteger:&num];

    if (num <= 10) return OWSocTierPreA12;      // iPhone X 及更早
    if (num == 11) return OWSocTierA12A13;      // XS/XR/11 系列
    if (num == 12) return OWSocTierA12A13;
    if (num == 13) return OWSocTierA14M1;       // 12 系列
    if (num == 14) return OWSocTierA15A16M2;    // 13/14 系列
    if (num == 15) return OWSocTierA15A16M2;
    if (num == 16) return OWSocTierA17Pro;
    if (num >= 17) return OWSocTierA18Plus;
    return OWSocTierUnknown;
}

- (NSString *)socTierName {
    switch (_socTier) {
        case OWSocTierPreA12:    return @"pre-A12(arm64)";
        case OWSocTierA12A13:    return @"A12/A13";
        case OWSocTierA14M1:     return @"A14/M1";
        case OWSocTierA15A16M2:  return @"A15/A16/M2";
        case OWSocTierA17Pro:    return @"A17 Pro";
        case OWSocTierA18Plus:   return @"A18+";
        default:                 return @"unknown";
    }
}

- (NSString *)bootManifestHash {
    if (_bootManifestHash) return _bootManifestHash;

    io_registry_entry_t entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen");
    if (!entry) {
        OWLog(@"boot-manifest-hash: registry entry 获取失败");
        return nil;
    }
    CFDataRef data = IORegistryEntryCreateCFProperty(entry, CFSTR("boot-manifest-hash"), kCFAllocatorDefault, 0);
    IOObjectRelease(entry);
    if (!data) {
        OWLog(@"boot-manifest-hash: 属性缺失");
        return nil;
    }
    const uint8_t *p = CFDataGetBytePtr(data);
    CFIndex len = CFDataGetLength(data);
    NSMutableString *hex = [NSMutableString stringWithCapacity:(NSUInteger)len * 2];
    for (CFIndex i = 0; i < len; i++) [hex appendFormat:@"%02x", p[i]];
    CFRelease(data);

    _bootManifestHash = [hex copy];
    OWLog(@"boot-manifest-hash = %@", _bootManifestHash);
    return _bootManifestHash;
}

- (BOOL)protectedDataAvailable {
    if (![NSThread isMainThread]) {
        __block BOOL v = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            v = [UIApplication sharedApplication].isProtectedDataAvailable;
        });
        return v;
    }
    return [UIApplication sharedApplication].isProtectedDataAvailable;
}

- (BOOL)isAtLeastMajor:(NSInteger)maj minor:(NSInteger)min patch:(NSInteger)pat {
    if (_major != maj) return _major > maj;
    if (_minor != min) return _minor > min;
    return _patch >= pat;
}

- (BOOL)isLessOrEqualMajor:(NSInteger)maj minor:(NSInteger)min patch:(NSInteger)pat {
    if (_major != maj) return _major < maj;
    if (_minor != min) return _minor < min;
    return _patch <= pat;
}

@end
