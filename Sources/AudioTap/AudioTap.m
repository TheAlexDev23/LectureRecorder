#import "AudioTap.h"

static BOOL LRFail(NSException *exception, NSError **error) {
    if (error) {
        NSString *reason = exception.reason ?: exception.name;
        *error = [NSError errorWithDomain:@"LectureRecorder.AudioEngine" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"The microphone could not be started (%@).", reason]}];
    }
    return NO;
}

@implementation LRAudioTap
+ (BOOL)installOnNode:(AVAudioNode *)node bus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)bufferSize format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)block error:(NSError **)error {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        return LRFail(exception, error);
    }
}
+ (BOOL)startEngine:(AVAudioEngine *)engine error:(NSError **)error {
    @try {
        [engine prepare];
        return [engine startAndReturnError:error];
    } @catch (NSException *exception) {
        return LRFail(exception, error);
    }
}
@end
