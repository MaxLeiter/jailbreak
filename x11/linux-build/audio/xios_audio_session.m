#include "xios_audio_session.h"

#import <AVFoundation/AVFoundation.h>

/*
 * Put the daemon's process audio session into a playback-capable state before we
 * open RemoteIO. Without this, iOS gives a process the SoloAmbient category by
 * default, which is silenced by the hardware mute switch and when the screen
 * locks. Desktop audio should behave like media playback: keep going regardless
 * of the mute switch and survive the screen locking, which is what the Playback
 * category provides.
 *
 * xios-audiod only holds the session while clients are sending audio, and
 * deactivates it once the output has gone idle (see xios-audiod.c).
 */
int xios_audio_session_activate(char *route, size_t route_len) {
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
        if (route && route_len) {
            const char *port = session.currentRoute.outputs.firstObject.portType.UTF8String;
            snprintf(route, route_len, "%s", port ? port : "unknown");
        }
    }
    return 0;
}

int xios_audio_session_deactivate(void) {
    @autoreleasepool {
        NSError *err = nil;
        if (![[AVAudioSession sharedInstance]
                    setActive:NO
                  withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                        error:&err]) {
            fprintf(stderr, "xios-audiod: AVAudioSession deactivate failed: %s\n",
                    err ? err.localizedDescription.UTF8String : "unknown");
            return -1;
        }
    }
    return 0;
}
