#import "log.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static int gFd = -1;

void ipc_log_open(NSString *path) {
    if (gFd >= 0) return;
    gFd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (gFd >= 0) fchmod(gFd, 0600);
}

static NSString *ts(void) {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZ";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [fmt stringFromDate:[NSDate date]];
}

static NSString *clean(NSString *s) {
    if (s.length == 0) return @"-";
    // Keep the log one-line and tab-delimited.
    return [[s stringByReplacingOccurrencesOfString:@"\t" withString:@" "]
        stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
}

static void write_line(NSString *line) {
    if (gFd < 0) return;
    NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (d) write(gFd, d.bytes, d.length);
}

void ipc_log_action(NSString *type, NSString *detail, NSString *app,
                    NSString *target, NSString *why, NSString *result) {
    write_line([NSString stringWithFormat:@"%@\taction\ttype=%@\tat=%@\tapp=%@\ttarget=%@\twhy=%@\tresult=%@",
                                          ts(), clean(type), clean(detail), clean(app), clean(target),
                                          clean(why), clean(result)]);
}

void ipc_log_note(NSString *message) {
    write_line([NSString stringWithFormat:@"%@\tnote\t%@", ts(), clean(message)]);
}
