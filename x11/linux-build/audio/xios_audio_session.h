#ifndef XIOS_AUDIO_SESSION_H
#define XIOS_AUDIO_SESSION_H

#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Activate an AVAudioSession Playback category for this process. Returns 0 on
 * success, -1 on failure (already logged to stderr). Safe to call once at
 * startup, after any fork(), before opening the RemoteIO unit. */
int xios_audio_session_activate(void);

#ifdef __cplusplus
}
#endif

#endif
