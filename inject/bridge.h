// bridge.h — entry point for the in-process fake-Twitter bridge (bridge.m).
#import <Foundation/Foundation.h>

// Start the loopback HTTP server + log in to atproto. Returns the bound port on
// 127.0.0.1 (0 on failure). Non-blocking: work runs on background queues.
int bridge_start(void);

// The OAuth callback URL for the current in-flight auth, i.e.
// atbot:///request_token?oauth_token=...&oauth_verifier=...&uuid=<lastOAuthUuid>.
// The redirector delivers this to the app directly so the authorize step completes
// in-process instead of bouncing through the external browser. Returns nil if there
// is no pending auth.
NSString *bridge_oauth_callback_url(void);

// Web (bsky.app) permalinks, replacing Tweetbot's twitter.com URLs for Copy Link /
// Open in Browser / share. `statusId` is the numeric id the bridge handed out.
// bridge_post_web_url falls back to the author's profile URL on a registry miss.
NSString *bridge_profile_web_url(NSString *handle);
NSString *bridge_post_web_url(NSString *statusId, NSString *handle);
