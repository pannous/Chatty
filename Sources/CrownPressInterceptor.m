#import "CrownPressInterceptor.h"
#import <dlfcn.h>
#import <os/log.h>

static NSString *const CAROUSEL_SERVICES_PATH = @"/System/Library/PrivateFrameworks/CarouselServices.framework/CarouselServices";
static NSString *const TAP_ASSERTION_CLASS = @"CSLSButtonTapAssertion";
static const unsigned long long CROWN_BUTTON_MASK = 1;
static NSString *const NAVIGATION_SERVICE_CLASS = @"CSLSNavigationService";
static const unsigned long long WATCH_FACE_LOCATION = 0; // 2 = app grid, 4 = Control Center (probes/navigate.m)
// Carousel itself turns presses < ~0.3 s apart into a "double tap" (app switcher) that the tap assertion never sees,
// so our double press is a deliberate one: second press 0.3–3 s after the first.
// The price: a lone press waits this long before the watch face appears.
static const NSTimeInterval DOUBLE_PRESS_INTERVAL = 3.0;

@interface NSObject (CSLSButtonTapAssertion)
- (instancetype)initWithButtons:(unsigned long long)buttons completion:(void (^)(void))completion;
- (void)activate;
- (void)deactivate;
@end

@interface NSObject (CSLSNavigationService)
+ (instancetype)sharedNavigationService;
- (void)navigateToLocation:(unsigned long long)location animated:(BOOL)animated withCompletion:(nullable id)completion;
@end

@implementation CrownPressInterceptor {
    void (^_doublePressHandler)(void);
    NSObject *_assertion;
    BOOL _running;
    NSUInteger _pressGeneration;
    BOOL _awaitingSecondPress;
}

- (instancetype)initWithDoublePressHandler:(void (^)(void))handler {
    if ((self = [super init])) _doublePressHandler = [handler copy];
    return self;
}

- (BOOL)start {
    dlopen(CAROUSEL_SERVICES_PATH.fileSystemRepresentation, RTLD_LAZY);
    if (!NSClassFromString(TAP_ASSERTION_CLASS)) {
        os_log_error(OS_LOG_DEFAULT, "Chatty: %{public}@ unavailable", TAP_ASSERTION_CLASS);
        return NO;
    }
    _running = YES;
    [self arm];
    return YES;
}

// The assertion is consumed by a tap, so it is re-armed after every press.
- (void)arm {
    __weak CrownPressInterceptor *weakSelf = self;
    _assertion = [[NSClassFromString(TAP_ASSERTION_CLASS) alloc] initWithButtons:CROWN_BUTTON_MASK completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf crownPressed]; });
    }];
    [_assertion activate];
}

- (void)crownPressed {
    if (!_running) return;
    [self arm];
    NSUInteger generation = ++_pressGeneration;
    if (_awaitingSecondPress) {
        _awaitingSecondPress = NO;
        os_log(OS_LOG_DEFAULT, "Chatty: crown double press");
        _doublePressHandler();
        return;
    }
    _awaitingSecondPress = YES;
    __weak CrownPressInterceptor *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(DOUBLE_PRESS_INTERVAL * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf singlePressTimedOut:generation];
    });
}

- (void)singlePressTimedOut:(NSUInteger)generation {
    if (!_awaitingSecondPress || generation != _pressGeneration) return;
    _awaitingSecondPress = NO;
    os_log(OS_LOG_DEFAULT, "Chatty: crown single press passed to system");
    // UIApplication -suspend is ignored by Carousel for the main scene, the navigation service is not
    [[NSClassFromString(NAVIGATION_SERVICE_CLASS) sharedNavigationService] navigateToLocation:WATCH_FACE_LOCATION animated:YES withCompletion:nil];
}

- (void)stop {
    _running = NO;
    [_assertion deactivate];
    _assertion = nil;
}

@end
