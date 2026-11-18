#import "MinisWindowPiP.h"
#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <float.h>

@interface MinisWindowPiP () <AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate>
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic, strong) UIView *anchor;
@property(nonatomic, strong) AVSampleBufferDisplayLayer *display;
@property(nonatomic, strong) AVPictureInPictureController *controller;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) void (^releaseAudio)(void);
@property(nonatomic) BOOL requested;
@property(nonatomic) BOOL paused;
@property(nonatomic) NSTimeInterval deadline;
@end

@implementation MinisWindowPiP
static MinisWindowPiP *current;

+ (UIWindow *)activeWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow && !window.hidden && window.rootViewController) return window;
        }
    }
    return nil;
}

+ (void)toggleWithAudioRelease:(void (^)(void))releaseAudio {
    if (current) { [self stop]; return; }
    MinisWindowPiP *pip = [self new];
    pip.window = [self activeWindow];
    pip.releaseAudio = releaseAudio;
    if (!pip.window || !AVPictureInPictureController.isPictureInPictureSupported) {
        [pip finish];
        [pip show:NSLocalizedString(@"Picture in Picture is unavailable.", nil)];
        return;
    }
    current = pip;
    [pip prepare];
}

+ (void)stop {
    MinisWindowPiP *pip = current;
    if (!pip) return;
    [pip.display flushAndRemoveImage];
    [pip.controller stopPictureInPicture];
    [pip finish];
}

- (void)prepare {
    self.anchor = [[UIView alloc] initWithFrame:CGRectMake(2, 2, 24, 32)];
    self.anchor.userInteractionEnabled = NO;
    self.anchor.accessibilityElementsHidden = YES;
    self.display = [AVSampleBufferDisplayLayer layer];
    self.display.frame = self.anchor.bounds;
    self.display.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.anchor.layer addSublayer:self.display];
    [self.window insertSubview:self.anchor atIndex:0];
    AVPictureInPictureControllerContentSource *source = [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:self.display playbackDelegate:self];
    self.controller = [[AVPictureInPictureController alloc] initWithContentSource:source];
    self.controller.delegate = self;
    self.controller.requiresLinearPlayback = YES;
    self.deadline = NSProcessInfo.processInfo.systemUptime + 5;
    self.timer = [NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self tick];
}

- (void)tick {
    if (!self.window || !UIApplication.sharedApplication.protectedDataAvailable) {
        [MinisWindowPiP stop];
        return;
    }
    if (!self.paused) [self pushFrame];
    if (self.controller.isPictureInPictureActive) return;
    if (NSProcessInfo.processInfo.systemUptime >= self.deadline) {
        [MinisWindowPiP stop];
        [self show:NSLocalizedString(@"Picture in Picture could not start. Check that system Picture in Picture is available.", nil)];
        return;
    }
    if (!self.requested && self.controller.isPictureInPicturePossible) {
        self.requested = YES;
        [self.controller startPictureInPicture];
    }
}

- (void)pushFrame {
    UIWindow *window = self.window;
    CGSize size = window.bounds.size;
    if (size.width < 2 || size.height < 2 || !self.display.readyForMoreMediaData) return;
    size_t width = 384, height = MIN(960, MAX(2, (size_t)(width * size.height / size.width)));
    NSDictionary *attributes = @{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVPixelBufferRef pixel = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixel) != noErr) return;
    if (CVPixelBufferLockBaseAddress(pixel, 0) != noErr) { CVPixelBufferRelease(pixel); return; }
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixel), width, height, 8, CVPixelBufferGetBytesPerRow(pixel), color, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(color);
    if (context) {
        CGContextTranslateCTM(context, 0, height);
        CGContextScaleCTM(context, (CGFloat)width / size.width, -(CGFloat)height / size.height);
        UIGraphicsPushContext(context);
        if (![window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO]) [window.layer renderInContext:context];
        UIGraphicsPopContext();
        CGContextRelease(context);
    }
    CVPixelBufferUnlockBaseAddress(pixel, 0);
    if (context) [self enqueuePixel:pixel];
    CVPixelBufferRelease(pixel);
}

- (void)enqueuePixel:(CVPixelBufferRef)pixel {
    CMVideoFormatDescriptionRef format = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixel, &format) != noErr) return;
    CMSampleTimingInfo timing = {CMTimeMake(1, 4), CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
    CMSampleBufferRef sample = NULL;
    if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixel, format, &timing, &sample) == noErr) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
        if (attachments && CFArrayGetCount(attachments)) {
            CFMutableDictionaryRef first = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(first, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
        [self.display enqueueSampleBuffer:sample];
        CFRelease(sample);
    }
    CFRelease(format);
}

- (void)finish {
    [self.timer invalidate];
    self.timer = nil;
    self.controller.delegate = nil;
    [self.anchor removeFromSuperview];
    self.controller = nil;
    self.display = nil;
    self.anchor = nil;
    void (^release)(void) = self.releaseAudio;
    self.releaseAudio = nil;
    if (current == self) current = nil;
    if (release) release();
}

- (void)show:(NSString *)message {
    UIViewController *presenter = self.window.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Picture in Picture", nil) message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil) style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)controller { self.deadline = DBL_MAX; }
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller { [self finish]; }
- (void)pictureInPictureController:(AVPictureInPictureController *)controller failedToStartPictureInPictureWithError:(NSError *)error { [self finish]; [self show:error.localizedDescription]; }
- (void)pictureInPictureController:(AVPictureInPictureController *)controller restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completion { completion(YES); }
- (void)pictureInPictureController:(AVPictureInPictureController *)controller setPlaying:(BOOL)playing { self.paused = !playing; [controller invalidatePlaybackState]; }
- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)controller { return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity); }
- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)controller { return self.paused; }
- (void)pictureInPictureController:(AVPictureInPictureController *)controller didTransitionToRenderSize:(CMVideoDimensions)size {}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller skipByInterval:(CMTime)interval completionHandler:(void (^)(void))completion { completion(); }
@end
