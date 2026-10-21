// dock2's Now Playing reader: MediaRemote answers only entitled processes and platform binaries, so this
// library runs inside /usr/bin/perl (nowplaying.pl) and streams one JSON object per line to dock2,
// exiting when dock2 closes stdin. Commands dock2 sends itself (NowPlaying.swift).

#import <Foundation/Foundation.h>
#include <dlfcn.h>

static void *gMR;
static NSData *gLastArtwork;

static void *sym(const char *name) { return dlsym(gMR, name); }

static id jsonValue(id value) { return value ?: NSNull.null; }

/// One line: the track, whether it plays, where it is, the app; the artwork only when it changed.
static void report(void) {
    void (*getInfo)(dispatch_queue_t, void (^)(NSDictionary *)) = sym("MRMediaRemoteGetNowPlayingInfo");
    void (*isPlaying)(dispatch_queue_t, void (^)(Boolean)) = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    void (*client)(dispatch_queue_t, void (^)(id)) = sym("MRMediaRemoteGetNowPlayingClient");
    if (!getInfo || !isPlaying || !client) return;
    dispatch_queue_t main = dispatch_get_main_queue();
    getInfo(main, ^(NSDictionary *info) {
        isPlaying(main, ^(Boolean playing) {
            client(main, ^(id c) {
                NSMutableDictionary *line = [NSMutableDictionary dictionary];
                NSString *app = [c respondsToSelector:@selector(bundleIdentifier)] ? [c performSelector:@selector(bundleIdentifier)] : nil;
                if (info.count == 0) {
                    line[@"empty"] = @YES;
                } else {
                    line[@"title"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                    line[@"artist"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
                    line[@"album"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
                    line[@"duration"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
                    line[@"elapsed"] = jsonValue(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
                    NSDate *at = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                    if ([at isKindOfClass:NSDate.class]) line[@"timestamp"] = @(at.timeIntervalSince1970 * 1000);
                    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    if (![artwork isKindOfClass:NSData.class]) artwork = nil;
                    // Sent when it changes, null when it goes: the reader keeps the last one meanwhile.
                    if (!(artwork == gLastArtwork || [artwork isEqualToData:gLastArtwork])) {
                        gLastArtwork = artwork;
                        line[@"artwork"] = artwork ? [artwork base64EncodedStringWithOptions:0] : NSNull.null;
                    }
                }
                line[@"playing"] = playing ? @YES : @NO;
                line[@"app"] = jsonValue(app);
                NSData *json = [NSJSONSerialization dataWithJSONObject:line options:0 error:nil];
                if (!json) return;
                fwrite(json.bytes, 1, json.length, stdout);
                fputc('\n', stdout);
                fflush(stdout);
            });
        });
    });
}

/// The XSUB nowplaying.pl installs and calls: never returns.
__attribute__((visibility("default"))) void dock2_nowplaying_stream(void *interpreter, void *cv) {
    @autoreleasepool {
        gMR = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!gMR) {
            fprintf(stderr, "dock2-nowplaying: no MediaRemote: %s\n", dlerror());
            exit(1);
        }
        void (*registerForNotifications)(dispatch_queue_t) = sym("MRMediaRemoteRegisterForNowPlayingNotifications");
        if (registerForNotifications) registerForNotifications(dispatch_get_main_queue());
        for (NSString *name in @[ @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                  @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                  @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification" ]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n) { report(); }];
        }
        // dock2 gone, stdin closed: so is this.
        dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(input, ^{
            char buffer[64];
            if (read(STDIN_FILENO, buffer, sizeof buffer) <= 0) exit(0);
        });
        dispatch_resume(input);
        report();
        [[NSRunLoop currentRunLoop] run];
    }
}
