#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface MinisWindowPiP : NSObject
+ (void)toggleWithAudioRelease:(void (^)(void))releaseAudio NS_SWIFT_NAME(toggle(releaseAudio:));
+ (void)stop;
@end
NS_ASSUME_NONNULL_END
