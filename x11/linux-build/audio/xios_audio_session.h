#ifndef XIOS_AUDIO_SESSION_H
#define XIOS_AUDIO_SESSION_H

#include <stddef.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Activate an AVAudioSession Playback category for this process, before
 * opening the RemoteIO unit. Returns 0 on success and writes the current
 * output port type (e.g. "Speaker") into route; returns -1 on failure (already
 * logged to stderr). Silent on success so the caller can log one line per
 * output start. Call after any fork(); safe to call again after deactivate. */
int xios_audio_session_activate(char *route, size_t route_len);

/* Deactivate the session after the RemoteIO unit has been stopped, notifying
 * other audio apps that they may resume. Returns 0 on success, -1 on failure
 * (already logged to stderr). */
int xios_audio_session_deactivate(void);

#ifdef __cplusplus
}
#endif

#endif
