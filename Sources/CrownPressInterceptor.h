#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Routes Digital Crown presses to the app while it is frontmost, via Carousel's private
/// CSLSButtonTapAssertion (the mechanism PepperUICore menus use; no entitlement required).
/// A double press calls the handler; a single press is passed on by suspending the app (like going home).
/// Long presses never reach the assertion, so Siri keeps working.
@interface CrownPressInterceptor : NSObject
- (instancetype)initWithDoublePressHandler:(void (^)(void))handler;
/// Returns NO when the private class is unavailable on this watchOS version.
- (BOOL)start;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
