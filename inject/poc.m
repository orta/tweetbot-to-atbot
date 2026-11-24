// poc.m — proof-of-concept injected dylib for Tweetbot.
//
// Loaded via an LC_LOAD_DYLIB command patched into Tweetbot's Mach-O.
// Its only job is to prove we are executing *inside* the Tweetbot process:
//   - write a breadcrumb file with pid + process path + timestamp
//   - NSLog so it shows in Console.app
//
// Build: see scripts/build_poc.sh
#import <Foundation/Foundation.h>

__attribute__((constructor))
static void tweetbot_atproto_poc_init(void) {
    @autoreleasepool {
        NSProcessInfo *pi = [NSProcessInfo processInfo];
        NSString *exe = [[NSBundle mainBundle] executablePath] ?: @"(unknown)";
        NSString *msg = [NSString stringWithFormat:
            @"[tweetbot-atproto-poc] injected OK  pid=%d  proc=%@  exe=%@  time=%@",
            pi.processIdentifier, pi.processName, exe, [NSDate date]];

        NSLog(@"%@", msg);

        // Breadcrumb inside the app's sandbox container (always writable),
        // plus a best-effort copy to a tmp path for easy inspection.
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES);
        if (dirs.count) {
            NSString *path = [dirs[0] stringByAppendingPathComponent:
                              @"tweetbot-atproto-poc.log"];
            NSString *line = [msg stringByAppendingString:@"\n"];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) {
                [line writeToFile:path atomically:YES
                        encoding:NSUTF8StringEncoding error:nil];
            } else {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        }
    }
}
