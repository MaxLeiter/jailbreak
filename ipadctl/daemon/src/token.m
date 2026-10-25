#import "token.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *ipc_token_load_or_create(NSString *dir, NSString **err) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *e = nil;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions : @(0700)} error:&e]) {
        if (err) *err = [NSString stringWithFormat:@"cannot create %@: %@", dir, e.localizedDescription];
        return nil;
    }
    // createDirectoryAtPath only applies the mode when it creates the directory.
    chmod(dir.fileSystemRepresentation, 0700);
    NSString *path = [dir stringByAppendingPathComponent:@"token"];

    NSString *existing = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    existing = [existing stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (existing.length >= 32) {
        chmod(path.fileSystemRepresentation, 0600);  // in case it was copied in with a wider mode
        return existing;
    }

    // Generate 32 random bytes -> 64 hex chars.
    uint8_t raw[32];
    arc4random_buf(raw, sizeof(raw));
    NSMutableString *tok = [NSMutableString stringWithCapacity:64];
    for (size_t i = 0; i < sizeof(raw); i++) [tok appendFormat:@"%02x", raw[i]];

    // Write atomically with 0600 via O_EXCL where possible, else overwrite.
    const char *cpath = path.fileSystemRepresentation;
    int fd = open(cpath, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        if (err) *err = [NSString stringWithFormat:@"cannot write token to %@: %s", path, strerror(errno)];
        return nil;
    }
    const char *bytes = tok.UTF8String;
    ssize_t n = write(fd, bytes, strlen(bytes));
    close(fd);
    chmod(cpath, 0600);
    if (n != (ssize_t)strlen(bytes)) {
        if (err) *err = @"short write persisting token";
        return nil;
    }
    return tok;
}

bool ipc_ct_equal(NSString *a, NSString *b) {
    NSData *da = [a dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSData *db = [b dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    const unsigned char *pa = da.bytes, *pb = db.bytes;
    NSUInteger la = da.length, lb = db.length;
    NSUInteger n = la > lb ? la : lb;
    unsigned char diff = (unsigned char)(la ^ lb);
    for (NSUInteger i = 0; i < n; i++) {
        unsigned char ca = i < la ? pa[i] : 0;
        unsigned char cb = i < lb ? pb[i] : 0;
        diff |= (unsigned char)(ca ^ cb);
    }
    return diff == 0;
}
