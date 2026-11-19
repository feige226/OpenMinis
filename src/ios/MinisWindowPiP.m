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
@property(nonatomic) NSUInteger framesEnqueued;
@property(nonatomic) OSStatus frameError;
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
    CGRect bounds = self.window.bounds;
    CGFloat width = MIN(144, CGRectGetWidth(bounds) * 0.42);
    CGFloat height = width * CGRectGetHeight(bounds) / MAX(1, CGRectGetWidth(bounds));
    CGRect frame = CGRectMake(CGRectGetMaxX(bounds) - self.window.safeAreaInsets.right - width - 12,
                              self.window.safeAreaInsets.top + 52, width, height);
    self.anchor = [[UIView alloc] initWithFrame:frame];
    self.anchor.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.anchor.clipsToBounds = YES;
    self.anchor.layer.cornerRadius = 10;
    self.anchor.backgroundColor = UIColor.blackColor;
    self.anchor.userInteractionEnabled = NO;
    self.anchor.accessibilityElementsHidden = YES;
    self.display = [AVSampleBufferDisplayLayer layer];
    self.display.frame = self.anchor.bounds;
    self.display.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.anchor.layer addSublayer:self.display];
    [self.window addSubview:self.anchor];
    CMTimebaseRef timebase = NULL;
    OSStatus status = CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &timebase);
    if (status != noErr || !timebase) {
        [self finish];
        [self show:[NSString stringWithFormat:@"PiP: playback clock setup failed (%d).", (int)status]];
        return;
    }
    CMTimebaseSetTime(timebase, kCMTimeZero);
    CMTimebaseSetRate(timebase, 1.0);
    self.display.controlTimebase = timebase;
    CFRelease(timebase);
    AVPictureInPictureControllerContentSource *source = [[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:self.display playbackDelegate:self];
    self.controller = [[AVPictureInPictureController alloc] initWithContentSource:source];
    self.controller.delegate = self;
    self.controller.requiresLinearPlayback = YES;
    self.deadline = NSProcessInfo.processInfo.systemUptime + 10;
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
        NSString *stage = self.framesEnqueued == 0 ? @"No video frames enqueued" : self.requested ? @"Start requested; no response" : @"System did not mark PiP possible";
        NSString *detail = [NSString stringWithFormat:@"%@. Frames: %lu; layer: %ld; frame error: %d; audio: %@; renderer: %@.", stage, (unsigned long)self.framesEnqueued, (long)self.display.status, (int)self.frameError, AVAudioSession.sharedInstance.category, self.display.error.localizedDescription ?: @"none"];
        NSLog(@"[MinisWindowPiP] %@", detail);
        [MinisWindowPiP stop];
        [self show:detail];
        return;
    }
    if (!self.requested && self.framesEnqueued > 0 && self.controller.isPictureInPicturePossible) {
        self.requested = YES;
        [self.controller startPictureInPicture];
    }
}

- (void)pushFrame {
    UIWindow *window = self.window;
    // Do not mirror our preview back into itself. Capture only the app root.
    UIView *content = window.rootViewController.view;
    CGSize size = content.bounds.size;
    if (size.width < 2 || size.height < 2 || !self.display.readyForMoreMediaData) return;
    size_t width = 384, height = MIN(960, MAX(2, ((size_t)(width * size.height / size.width) + 1) & ~(size_t)1));
    NSDictionary *attributes = @{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    CVPixelBufferRef pixel = NULL;
    self.frameError = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &pixel);
    if (self.frameError != noErr || !pixel) return;
    self.frameError = CVPixelBufferLockBaseAddress(pixel, 0);
    if (self.frameError != noErr) { CVPixelBufferRelease(pixel); return; }
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixel), width, height, 8, CVPixelBufferGetBytesPerRow(pixel), color, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(color);
    if (context) {
        CGContextTranslateCTM(context, 0, height);
        CGContextScaleCTM(context, (CGFloat)width / size.width, -(CGFloat)height / size.height);
        UIGraphicsPushContext(context);
        if (![content drawViewHierarchyInRect:content.bounds afterScreenUpdates:NO]) [content.layer renderInContext:context];
        UIGraphicsPopContext();
        CGContextRelease(context);
    }
    CVPixelBufferUnlockBaseAddress(pixel, 0);
    if (context) [self enqueuePixel:pixel];
    CVPixelBufferRelease(pixel);
}

- (void)enqueuePixel:(CVPixelBufferRef)pixel {
    CMVideoFormatDescriptionRef format = NULL;
    self.frameError = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixel, &format);
    if (self.frameError != noErr) return;
    CMSampleTimingInfo timing = {CMTimeMake(1, 4), CMTimebaseGetTime(self.display.controlTimebase), kCMTimeInvalid};
    CMSampleBufferRef sample = NULL;
    self.frameError = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixel, format, &timing, &sample);
    if (self.frameError == noErr && sample) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
        if (attachments && CFArrayGetCount(attachments)) {
            CFMutableDictionaryRef first = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            CFDictionarySetValue(first, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        }
        [self.display enqueueSampleBuffer:sample];
        self.framesEnqueued += 1;
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
