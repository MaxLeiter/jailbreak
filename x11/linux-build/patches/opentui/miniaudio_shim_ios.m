/* iOS Objective-C wrapper for the miniaudio shim.
 *
 * On iOS miniaudio's CoreAudio backend uses AVAudioSession Objective-C APIs,
 * so the implementation must be compiled as Objective-C. Zig's build-lib
 * -cflags path does not reliably honor `-x objective-c`, but the `.m`
 * extension makes clang select the Objective-C frontend automatically.
 */
#include "miniaudio_shim.c"
