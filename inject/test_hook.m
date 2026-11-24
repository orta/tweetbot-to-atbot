// test_hook.m — deterministic unit test for the redirector.
// Links libtweetbot-atproto.dylib (whose constructor installs the NSURLSession
// hooks), then makes a real NSURLSession request to api.twitter.com exactly the
// way Tweetbot does. If interception works, the request is redirected to the
// local bridge and returns the atproto-backed Twitter JSON.
//
// Build: see scripts/test-hook.sh
#import <Foundation/Foundation.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *path = argc > 1 ? argv[1]
            : "https://api.twitter.com/1.1/account/verify_credentials.json";
        NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:path]];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        [req setHTTPMethod:@"GET"];
        // Tweetbot would add an OAuth1 Authorization header here; the bridge ignores it.
        [req setValue:@"OAuth oauth_consumer_key=\"x\", oauth_signature=\"y\"" forHTTPHeaderField:@"Authorization"];

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        __block NSString *result = @"(no response)";
        NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithRequest:req
              completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                if (err) result = [NSString stringWithFormat:@"ERROR: %@", err.localizedDescription];
                else {
                    NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
                    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    result = [NSString stringWithFormat:@"HTTP %ld from %@\n%@",
                              (long)h.statusCode, resp.URL.absoluteString,
                              body.length > 400 ? [body substringToIndex:400] : body];
                }
                dispatch_semaphore_signal(sem);
              }];
        [task resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15LL * NSEC_PER_SEC));
        printf("%s\n", result.UTF8String);
    }
    return 0;
}
