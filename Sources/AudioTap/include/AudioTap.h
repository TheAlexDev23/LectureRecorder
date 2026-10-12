#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

// AVAudioEngine reports tap and start failures (e.g. a microphone that disappeared) as
// Objective-C exceptions. Swift cannot catch those, and one escaping an async Swift task
// leaves the task stranded and corrupts the concurrency runtime, so they are converted here.
@interface LRAudioTap : NSObject
+ (BOOL)installOnNode:(AVAudioNode *)node bus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)bufferSize format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)block error:(NSError **)error NS_SWIFT_NAME(install(on:bus:bufferSize:format:block:));
+ (BOOL)startEngine:(AVAudioEngine *)engine error:(NSError **)error NS_SWIFT_NAME(start(_:));
@end

NS_ASSUME_NONNULL_END
