#include "xios_audio_session.h"

#import <AVFoundation/AVFoundation.h>

/*
 * Put the daemon's process audio session into a playback-capable state before we
 * open RemoteIO. Without this, iOS gives a process the SoloAmbient category by
 * default, which is silenced by the hardware mute switch and when the screen
 * locks. Desktop audio should behave like media playback: keep going regardless
 * of the mute switch and survive the screen locking, which is what the Playback
 * category provides.
 */
int xios_audio_session_activate(void) {
    @autoreleasepool {
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *err = nil;

        if (![session setCategory:AVAudioSessionCategoryPlayback error:&err]) {
            fprintf(stderr, "xios-audiod: setCategory(Playback) failed: %s\n",
                    err ? err.localizedDescription.UTF8String : "unknown");
            return -1;
        }
        if (![session setActive:YES error:&err]) {
            fprintf(stderr, "xios-audiod: AVAudioSession setActive failed: %s\n",
                    err ? err.localizedDescription.UTF8String : "unknown");
            return -1;
        }
        fprintf(stderr, "xios-audiod: AVAudioSession active, category=Playback, route=%s\n",
                session.currentRoute.outputs.firstObject.portType.UTF8String);
    }
    return 0;
}
