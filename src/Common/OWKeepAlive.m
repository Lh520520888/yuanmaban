#import "OWKeepAlive.h"
#import "OWCommon.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

#pragma mark - 静音 WAV

static void ow_put_u32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF),
                     (uint8_t)((v >> 16) & 0xFF), (uint8_t)((v >> 24) & 0xFF) };
    [d appendBytes:b length:4];
}

static void ow_put_u16(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v & 0xFF), (uint8_t)((v >> 8) & 0xFF) };
    [d appendBytes:b length:2];
}

/// 生成 1 秒 8kHz 单声道 16bit 全零 PCM 的 WAV（约 16KB），不依赖任何包内资源。
static NSData *ow_silence_wav(void) {
    const uint32_t sampleRate = 8000;
    const uint32_t frames     = sampleRate;          // 1 秒
    const uint32_t dataSize   = frames * 2;          // 16bit 单声道

    NSMutableData *d = [NSMutableData dataWithCapacity:44 + dataSize];
    [d appendBytes:"RIFF" length:4];
    ow_put_u32(d, 36 + dataSize);
    [d appendBytes:"WAVE" length:4];

    [d appendBytes:"fmt " length:4];
    ow_put_u32(d, 16);            // fmt chunk size
    ow_put_u16(d, 1);             // PCM
    ow_put_u16(d, 1);             // mono
    ow_put_u32(d, sampleRate);
    ow_put_u32(d, sampleRate * 2); // byte rate
    ow_put_u16(d, 2);             // block align
    ow_put_u16(d, 16);            // bits per sample

    [d appendBytes:"data" length:4];
    ow_put_u32(d, dataSize);
    [d appendData:[NSMutableData dataWithLength:dataSize]];   // 全零
    return d;
}

#pragma mark -

@interface OWKeepAlive ()
@property (nonatomic, strong, nullable) AVAudioPlayer *player;
@property (nonatomic, strong, nullable) NSTimer *renewTimer;
@property (nonatomic, strong, nullable) NSTimer *heartbeatTimer;
@property (nonatomic, assign, readwrite) BOOL running;
@property (nonatomic, assign, readwrite) NSUInteger restarts;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, assign) NSUInteger tick;
@property (nonatomic, assign) BOOL observing;
@end

@implementation OWKeepAlive

+ (instancetype)shared {
    static OWKeepAlive *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [OWKeepAlive new]; });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _bgTask = UIBackgroundTaskInvalid;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_renewTimer invalidate];
    [_heartbeatTimer invalidate];
}

#pragma mark 生命周期

- (BOOL)start {
    if (self.running) {
        [self ensureRunning];
        return self.player.isPlaying;
    }
    self.running = YES;
    self.tick = 0;

    [self observeSession];
    BOOL audio = [self startAudio];
    [self armTimers];
    [self renewBackgroundTask];

    OWLog(@"保活: 启动 audio=%@ (restarts=%lu)", audio ? @"OK" : @"FAIL",
          (unsigned long)self.restarts);
    return audio;
}

- (void)stop {
    if (!self.running) return;
    self.running = NO;

    [_renewTimer invalidate];    _renewTimer = nil;
    [_heartbeatTimer invalidate]; _heartbeatTimer = nil;

    [self.player stop];
    self.player = nil;

    if (self.bgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:nil];

    OWLog(@"保活: 已停止（累计重启 %lu 次）", (unsigned long)self.restarts);
}

- (void)ensureRunning {
    if (!self.running) { [self start]; return; }

    // 会话失活 / 音频被暂停 → 重新拉起
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (!session.isOtherAudioPlaying) {
        NSError *err = nil;
        if (![session setActive:YES error:&err]) {
            OWLog(@"保活: 会话激活失败 %@", err.localizedDescription ?: @"?");
        }
    }
    if (!self.player || !self.player.isPlaying) {
        [self startAudio];
        self.restarts++;
        OWLog(@"保活: 音频不在播，已重启（第 %lu 次）", (unsigned long)self.restarts);
    }
    [self renewBackgroundTask];
}

#pragma mark 音频

- (BOOL)startAudio {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *err = nil;

    // MixWithOthers：不打断用户正在放的音乐；Playback + audio 后台模式才能后台常驻
    if (![session setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:&err]) {
        OWLog(@"保活: setCategory 失败 %@", err.localizedDescription ?: @"?");
        return NO;
    }
    if (![session setActive:YES error:&err]) {
        OWLog(@"保活: setActive 失败 %@", err.localizedDescription ?: @"?");
        return NO;
    }

    [self.player stop];
    NSData *wav = ow_silence_wav();
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithData:wav error:&err];
    if (!p) {
        OWLog(@"保活: AVAudioPlayer 创建失败 %@", err.localizedDescription ?: @"?");
        self.player = nil;
        return NO;
    }
    p.numberOfLoops = -1;   // 无限循环
    p.volume = 0.0;         // 完全静音（系统音量也不出声）
    p.meteringEnabled = NO;
    if (![p prepareToPlay] || ![p play]) {
        OWLog(@"保活: play 失败");
        self.player = nil;
        return NO;
    }
    self.player = p;
    return YES;
}

- (void)observeSession {
    if (self.observing) return;
    self.observing = YES;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(onInterruption:)
               name:AVAudioSessionInterruptionNotification object:nil];
    [nc addObserver:self selector:@selector(onRouteChange:)
               name:AVAudioSessionRouteChangeNotification object:nil];
    [nc addObserver:self selector:@selector(onMediaServicesReset:)
               name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    [nc addObserver:self selector:@selector(onAppBackground)
               name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(onAppForeground)
               name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (void)onInterruption:(NSNotification *)note {
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
        OWLog(@"保活: 音频被打断（来电/其他 App）");
        return;
    }
    // 打断结束：立刻重启，别等系统回调
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self startAudio];
        self.restarts++;
    });
}

- (void)onRouteChange:(NSNotification *)note {
    NSNumber *reason = note.userInfo[AVAudioSessionRouteChangeReasonKey];
    if (reason.unsignedIntegerValue == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        OWLog(@"保活: 输出设备被拔掉，重启音频");
        [self startAudio];
        self.restarts++;
    }
}

- (void)onMediaServicesReset:(NSNotification *)note {
    OWLog(@"保活: media services 重置，重建播放器");
    self.player = nil;
    [self startAudio];
    self.restarts++;
}

- (void)onAppBackground {
    OWLog(@"保活: 进入后台，确保音频与后台任务在跑");
    [self ensureRunning];
}

- (void)onAppForeground {
    OWLog(@"保活: 回到前台（心跳 %lu）", (unsigned long)self.tick);
    [self ensureRunning];
}

#pragma mark 定时器

- (void)armTimers {
    if (!self.renewTimer) {
        self.renewTimer = [NSTimer timerWithTimeInterval:20.0
                                                  target:self
                                                selector:@selector(onRenewTick)
                                                userInfo:nil
                                                 repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.renewTimer forMode:NSRunLoopCommonModes];
    }
    if (!self.heartbeatTimer) {
        self.heartbeatTimer = [NSTimer timerWithTimeInterval:30.0
                                                      target:self
                                                    selector:@selector(onHeartbeat)
                                                    userInfo:nil
                                                     repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:self.heartbeatTimer forMode:NSRunLoopCommonModes];
    }
}

- (void)onRenewTick {
    [self renewBackgroundTask];
    // 顺带检查播放器，处理"play 返回 YES 但实际停了"的情况
    if (self.running && (!self.player || !self.player.isPlaying)) {
        [self startAudio];
        self.restarts++;
    }
}

- (void)onHeartbeat {
    self.tick++;
    OWLog(@"保活: 心跳 #%lu state=%s audio=%d restarts=%lu",
          (unsigned long)self.tick,
          [UIApplication sharedApplication].applicationState == UIApplicationStateBackground
              ? "background" : "foreground",
          self.player.isPlaying ? 1 : 0,
          (unsigned long)self.restarts);
}

#pragma mark 后台任务

/// 后台任务只有约 30s，必须滚动续期：每次新建一个，旧的结束掉。
/// 过期回调里再补一个 —— 只要进程还在跑，就能一直续。
- (void)renewBackgroundTask {
    UIApplication *app = [UIApplication sharedApplication];
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [app endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }

    __weak typeof(self) weakSelf = self;
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    task = [app beginBackgroundTaskWithName:@"ow.keepalive"
                          expirationHandler:^{
        // 过期时系统只给几秒：先 end 掉这一个，再补一个新的
        if (task != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        }
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        OWLog(@"保活: 后台任务过期，立即续一个");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self2 = weakSelf;
            if (self2 && self2.running) [self2 renewBackgroundTask];
        });
    }];
    self.bgTask = task;
}

@end
