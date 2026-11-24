// libWebPornMedia: wpmedia.h over libVLC (MobileVLCKit 3.5.1's C API).
//
// Video goes through libVLC's own iOS output (VideoToolbox decode, OpenGL ES
// into a UIView, frames never touch the CPU): the only path the A6 plays 720p /
// 1080p30 on (the vmem callbacks top out around 20 fps, tests/vlc-smoke.c).
// That UIView sits in a plain CALayer, which is what WebCore puts into the page.
//
// UIKit work happens on the main thread, asynchronously: WebCore calls in on the
// WebThread, often while the main thread waits for the web lock, so a
// dispatch_sync to the main queue could deadlock. For the same reason stopping
// (libVLC's video output closes with a dispatch_sync to the main queue) runs on
// a background queue.

#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <math.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <vlc/vlc.h>
#include "wpmedia.h"

// MARK: - Debug log

// /var/webporn/wpmedia-debug present: events and decisions to wpmedia.log.
static void debugLog(const char* format, ...) __attribute__((format(printf, 1, 2)));
static void debugLog(const char* format, ...)
{
    static FILE* file;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!access("/var/webporn/wpmedia-debug", F_OK))
            file = fopen("/var/mobile/Media/webporn/wpmedia-events.log", "w");
    });
    if (!file)
        return;
    static CFAbsoluteTime start;
    if (!start)
        start = CFAbsoluteTimeGetCurrent();
    fprintf(file, "%7.3f ", CFAbsoluteTimeGetCurrent() - start);
    va_list args;
    va_start(args, format);
    vfprintf(file, format, args);
    va_end(args);
    fputc('\n', file);
    fflush(file);
}

// MARK: - Host layer

// The full-screen window: black, the video turned to landscape when it is wider
// than the portrait screen, and a bar (Done, play/pause) a tap shows for a while.
@interface WPFullscreenWindow : UIWindow
@property (nonatomic, copy) void (^action)(wpmedia_fullscreen_action);
@property (nonatomic, strong) UIView* content;
@property (nonatomic, strong) UIView* bar;
- (instancetype)initWithVideoSize:(CGSize)size;
- (void)showVideoView:(UIView*)view;
@end

@implementation WPFullscreenWindow

- (instancetype)initWithVideoSize:(CGSize)size
{
    CGRect bounds = [UIScreen mainScreen].bounds;
    if (!(self = [super initWithFrame:bounds]))
        return nil;
    self.windowLevel = UIWindowLevelStatusBar + 1;
    self.backgroundColor = [UIColor blackColor];
    BOOL landscape = size.width > size.height && bounds.size.height > bounds.size.width;
    _content = [[UIView alloc] initWithFrame:landscape ? CGRectMake(0, 0, bounds.size.height, bounds.size.width) : bounds];
    _content.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    if (landscape)
        _content.transform = CGAffineTransformMakeRotation(M_PI_2);
    _content.backgroundColor = [UIColor blackColor];
    [self addSubview:_content];

    _bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _content.bounds.size.width, 44)];
    _bar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    _bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIButton* done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.frame = CGRectMake(8, 0, 80, 44);
    done.tintColor = [UIColor whiteColor];
    done.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    [done addTarget:self action:@selector(done) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:done];
    UIButton* playback = [UIButton buttonWithType:UIButtonTypeSystem];
    playback.frame = CGRectMake((_bar.bounds.size.width - 120) / 2, 0, 120, 44);
    playback.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    playback.tintColor = [UIColor whiteColor];
    playback.titleLabel.font = [UIFont systemFontOfSize:22];
    [playback setTitle:@"\u25B6\uFE0E \u275A\u275A" forState:UIControlStateNormal];
    [playback addTarget:self action:@selector(togglePlayback) forControlEvents:UIControlEventTouchUpInside];
    [_bar addSubview:playback];
    [_content addSubview:_bar];

    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)];
    [_content addGestureRecognizer:tap];
    [self hideBarLater];
    return self;
}

- (void)showVideoView:(UIView*)view
{
    view.frame = self.content.bounds;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.content insertSubview:view belowSubview:self.bar];
    for (UIView* subview in view.subviews)
        subview.frame = view.bounds;
}

- (void)tapped:(UITapGestureRecognizer*)tap
{
    CGPoint point = [tap locationInView:self.content];
    debugLog("fullscreen tap at %.0f,%.0f (window %.0f,%.0f), bar %s", point.x, point.y, [tap locationInView:self].x, [tap locationInView:self].y, self.bar.hidden ? "hidden" : "shown");
    if (!self.bar.hidden && CGRectContainsPoint(self.bar.frame, [tap locationInView:self.content]))
        return;
    self.bar.hidden = !self.bar.hidden;
    [self hideBarLater];
}

- (void)hideBarLater
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideBar) object:nil];
    if (!self.bar.hidden)
        [self performSelector:@selector(hideBar) withObject:nil afterDelay:3];
}

- (void)hideBar
{
    self.bar.hidden = YES;
}

- (void)done
{
    debugLog("fullscreen: done");
    if (self.action)
        self.action(WPMEDIA_FULLSCREEN_EXIT);
}

- (void)togglePlayback
{
    debugLog("fullscreen: play/pause");
    if (self.action)
        self.action(WPMEDIA_FULLSCREEN_TOGGLE_PLAYBACK);
    [self hideBarLater];
}

@end

// Keeps libVLC's drawable view the size of the layer WebCore lays out, except
// while it is in the full-screen window.
@interface WPMediaLayer : CALayer
@property (nonatomic, strong) UIView* drawable;
@property (nonatomic, strong) WPFullscreenWindow* fullscreenWindow;
- (void)exitFullscreen;
@end

@implementation WPMediaLayer

- (void)exitFullscreen
{
    WPFullscreenWindow* window = self.fullscreenWindow;
    if (!window)
        return;
    window.action = nil;
    self.fullscreenWindow = nil;
    UIView* drawable = self.drawable;
    if (drawable) {
        [drawable removeFromSuperview];
        drawable.autoresizingMask = UIViewAutoresizingNone;
        [self addSublayer:drawable.layer];
    }
    window.hidden = YES;
    [self setNeedsLayout];
}

- (void)layoutSublayers
{
    [super layoutSublayers];
    CGRect bounds = self.bounds;
    UIView* drawable = self.drawable;
    if (!drawable || self.fullscreenWindow)
        return;
    void (^resize)(void) = ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        drawable.frame = bounds;
        // libVLC sizes its OpenGL view to the screen when the drawable is still
        // empty, and autoresizing only adds the difference afterwards.
        for (UIView* subview in drawable.subviews)
            subview.frame = drawable.bounds;
        [drawable layoutIfNeeded];
        [CATransaction commit];
    };
    if ([NSThread isMainThread])
        resize();
    else
        dispatch_async(dispatch_get_main_queue(), resize);
}

@end

// MARK: - Player

typedef struct wpstream wpstream;

// What the full-screen window's buttons reach: the client, until the player is
// torn down (only touched on the player's queue).
@interface WPClientTarget : NSObject {
@public
    wpmedia_client client;
    BOOL valid;
}
@end

@implementation WPClientTarget
@end

struct wpmedia_player {
    wpmedia_client client;
    wpstream* stream; // wpmedia_open_stream; outlives p until libVLC has stopped
    int live; // the stream is not seekable (MSE): no seeking back after the preroll
    int started; // startMedia ran: the drawable exists
    int pauseOnFirstTime; // a restarted stream plays until its first frame, then pauses
    libvlc_media_player_t* player;
    libvlc_media_t* media;
    void* layer; // WPMediaLayer, retained
    void* target; // WPClientTarget, retained
    dispatch_queue_t queue; // serializes control calls and metadata queries
    int ready; // drawable attached and media set
    int wantsPlaying;
    double pendingSeek; // < 0: none
    double seekTarget; // < 0: none; time updates from before it are dropped
    CFAbsoluteTime seekIssued;
    float volume;
    int muted;
    float rate;
    double duration;
    unsigned width, height;
    int hasVideo, hasAudio;
};

static void vlcLog(void* data, int level, const libvlc_log_t* context, const char* format, va_list args)
{
    static FILE* file;
    static CFAbsoluteTime start;
    if (!file) {
        file = fopen("/var/mobile/Media/webporn/wpmedia-vlc.log", "w");
        start = CFAbsoluteTimeGetCurrent();
    }
    if (!file || level < LIBVLC_NOTICE - 1)
        return;
    const char* module = NULL;
    libvlc_log_get_context(context, &module, NULL, NULL);
    fprintf(file, "%7.3f [%s] ", CFAbsoluteTimeGetCurrent() - start, module ? module : "?");
    vfprintf(file, format, args);
    fputc('\n', file);
    fflush(file);
}

static libvlc_instance_t* sharedInstance(void)
{
    static libvlc_instance_t* instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char* args[] = { "--no-video-title-show", "--network-caching=1000" };
        instance = libvlc_new(sizeof(args) / sizeof(*args), args);
        // Debug mode: libVLC's own messages next to ours (wpmedia-vlc.log).
        if (instance && !access("/var/webporn/wpmedia-debug", F_OK))
            libvlc_log_set(instance, vlcLog, NULL);
    });
    return instance;
}

int wpmedia_abi_version(void)
{
    return WPMEDIA_ABI_VERSION;
}

// MARK: - Types

static int caseInsensitiveIn(const char* value, const char* const* list)
{
    for (; *list; list++) {
        if (!strcasecmp(value, *list))
            return 1;
    }
    return 0;
}

static int knownCodec(const char* codec, size_t length)
{
    // Prefixes of RFC 6381 codec strings libVLC decodes fast enough on an A6.
    static const char* const prefixes[] = { "avc1", "avc3", "mp4a", "hev1", "hvc1", "vp8", "vp08", "vp9", "vp09",
        "opus", "vorbis", "flac", "theora", "mp3", "mp4v", "ac-3", "ec-3", "alac", NULL };
    for (const char* const* prefix = prefixes; *prefix; prefix++) {
        size_t prefixLength = strlen(*prefix);
        if (length >= prefixLength && !strncasecmp(codec, *prefix, prefixLength))
            return 1;
    }
    return 0;
}

wpmedia_support wpmedia_supports(const char* container, const char* codecs)
{
    static const char* const containers[] = { "video/mp4", "video/x-m4v", "video/quicktime", "video/webm", "audio/webm",
        "video/ogg", "audio/ogg", "application/ogg", "audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/aac",
        "audio/aacp", "audio/wav", "audio/x-wav", "audio/wave", "audio/flac", "audio/x-flac", "video/x-matroska",
        "audio/x-matroska", "video/3gpp", "audio/3gpp", "application/vnd.apple.mpegurl", "application/x-mpegurl",
        "audio/mpegurl", "audio/x-mpegurl", NULL };
    if (!container || !caseInsensitiveIn(container, containers))
        return WPMEDIA_NOT_SUPPORTED;
    if (!codecs || !*codecs)
        return WPMEDIA_MAYBE_SUPPORTED;
    for (const char* p = codecs; *p;) {
        while (*p == ' ' || *p == ',' || *p == '"')
            p++;
        const char* end = p;
        while (*end && *end != ',' && *end != '"')
            end++;
        size_t length = end - p;
        while (length && p[length - 1] == ' ')
            length--;
        if (length && !knownCodec(p, length))
            return WPMEDIA_NOT_SUPPORTED;
        p = end;
    }
    return WPMEDIA_SUPPORTED;
}

// MARK: - Events

static void reportMetadata(wpmedia_player* p)
{
    double duration = libvlc_media_player_get_length(p->player) / 1000.0;
    unsigned width = 0, height = 0;
    libvlc_video_get_size(p->player, 0, &width, &height);
    int hasVideo = libvlc_video_get_track_count(p->player) > 0 || width;
    int hasAudio = libvlc_audio_get_track_count(p->player) > 0;
    if (duration < 0)
        duration = 0;
    if (duration == p->duration && width == p->width && height == p->height && hasVideo == p->hasVideo && hasAudio == p->hasAudio)
        return;
    p->duration = duration, p->width = width, p->height = height, p->hasVideo = hasVideo, p->hasAudio = hasAudio;
    if (p->client.metadata_changed)
        p->client.metadata_changed(p->client.context, duration, width, height, hasVideo, hasAudio);
}

static void reportState(wpmedia_player* p, wpmedia_state state)
{
    if (p->client.state_changed)
        p->client.state_changed(p->client.context, state);
}

// Preroll: wpmedia_open starts playing muted, so that the decoder (VideoToolbox
// session) and libVLC's video output (an OpenGL ES view, ~2.5 s to set up on an
// A6) exist before WebCore asks to play. With :start-paused libVLC creates them
// only on play, and the clock runs while the first seconds of video are lost.
// At the first video output (or the first time update, audio only) the player
// pauses back at the start unless asked to play, which also leaves a poster frame.
// libVLC keeps reporting the old position for a while after set_time (it
// reports the target at once, then the old time again, then nothing until the
// demuxer has landed): for 4 s, drop times before the target or further past it
// than the time since the seek allows.
static void seekTo(wpmedia_player* p, double seconds)
{
    debugLog("seek to %.2f", seconds);
    p->seekTarget = seconds;
    p->seekIssued = CFAbsoluteTimeGetCurrent();
    libvlc_media_player_set_time(p->player, (libvlc_time_t)(seconds * 1000));
}

static int isStaleTime(wpmedia_player* p, double seconds)
{
    if (p->seekTarget < 0)
        return 0;
    double elapsed = CFAbsoluteTimeGetCurrent() - p->seekIssued;
    if (elapsed > 4) {
        p->seekTarget = -1;
        return 0;
    }
    return seconds < p->seekTarget - 0.5 || seconds > p->seekTarget + elapsed * p->rate + 1;
}

static void finishPreroll(wpmedia_player* p)
{
    if (p->ready)
        return;
    debugLog("preroll done, pending seek %.2f, wants playing %d", p->pendingSeek, p->wantsPlaying);
    p->ready = 1;
    if (p->live) {
        p->pendingSeek = -1;
        libvlc_media_player_set_rate(p->player, p->rate);
    } else if (p->pendingSeek >= 0) {
        seekTo(p, p->pendingSeek);
        p->pendingSeek = -1;
    } else if (!p->wantsPlaying)
        seekTo(p, 0);
    libvlc_media_player_set_pause(p->player, !p->wantsPlaying);
    libvlc_audio_set_volume(p->player, p->muted ? 0 : (int)(p->volume * 100));
    reportState(p, p->wantsPlaying ? WPMEDIA_STATE_PLAYING : WPMEDIA_STATE_PAUSED);
}

static int streamInputEnded(wpstream*);

static void handleEvent(const libvlc_event_t* event, void* data)
{
    wpmedia_player* p = data;
    // libVLC calls back with its event lock held: query the player off this thread.
    switch (event->type) {
    case libvlc_MediaPlayerOpening:
        reportState(p, WPMEDIA_STATE_OPENING);
        break;
    case libvlc_MediaPlayerBuffering: {
        float percent = event->u.media_player_buffering.new_cache;
        if (p->client.buffering)
            p->client.buffering(p->client.context, percent);
        break;
    }
    case libvlc_MediaPlayerPlaying:
        dispatch_async(p->queue, ^{
            reportMetadata(p);
            if (p->ready)
                reportState(p, WPMEDIA_STATE_PLAYING);
        });
        break;
    case libvlc_MediaPlayerPaused:
        dispatch_async(p->queue, ^{
            if (!p->ready)
                return;
            // :play-and-pause stops on the last frame: a pause nobody asked for
            // at the end is the end of the media.
            double time = libvlc_media_player_get_time(p->player) / 1000.0;
            // A live (MSE) stream has no duration: its end is the end of the input.
            int inputEnded = p->live && p->stream && streamInputEnded(p->stream);
            debugLog("paused at %.2f, wants playing %d, input ended %d", time, p->wantsPlaying, inputEnded);
            // libVLC's clock trails the last frame (by most of a second for HLS,
            // whose input clock moves by segments): an unrequested pause within
            // the last two seconds is the end too.
            double slack = p->duration > 0 ? MAX(0.5, MIN(2.0, p->duration * 0.2)) : 0;
            if (p->wantsPlaying && (inputEnded || (p->duration > 0 && time >= p->duration - slack))) {
                p->wantsPlaying = 0;
                reportState(p, WPMEDIA_STATE_ENDED);
                return;
            }
            reportState(p, WPMEDIA_STATE_PAUSED);
        });
        break;
    case libvlc_MediaPlayerEndReached:
        reportState(p, WPMEDIA_STATE_ENDED);
        break;
    case libvlc_MediaPlayerEncounteredError:
        reportState(p, WPMEDIA_STATE_ERROR);
        break;
    case libvlc_MediaPlayerTimeChanged: {
        double seconds = event->u.media_player_time_changed.new_time / 1000.0;
        dispatch_async(p->queue, ^{
            static CFAbsoluteTime lastStats;
            if (p->media && CFAbsoluteTimeGetCurrent() - lastStats > 5) {
                lastStats = CFAbsoluteTimeGetCurrent();
                libvlc_media_stats_t stats = { };
                libvlc_media_get_stats(p->media, &stats);
                debugLog("stats: video decoded %d displayed %d lost %d, audio decoded %d played %d lost %d, volume %d",
                    stats.i_decoded_video, stats.i_displayed_pictures, stats.i_lost_pictures, stats.i_decoded_audio,
                    stats.i_played_abuffers, stats.i_lost_abuffers, libvlc_audio_get_volume(p->player));
            }
            debugLog("time %.2f ready %d seekTarget %.2f", seconds, p->ready, p->seekTarget);
            if (p->pauseOnFirstTime) {
                p->pauseOnFirstTime = 0;
                if (!p->wantsPlaying)
                    libvlc_media_player_set_pause(p->player, 1);
            }
            if (!p->ready) {
                // Audio only: no video output will come.
                if (seconds > 0 && !libvlc_video_get_track_count(p->player))
                    finishPreroll(p);
                return;
            }
            if (isStaleTime(p, seconds))
                return;
            if (p->client.time_changed)
                p->client.time_changed(p->client.context, seconds);
        });
        break;
    }
    case libvlc_MediaPlayerLengthChanged:
    case libvlc_MediaPlayerESAdded:
        dispatch_async(p->queue, ^{ reportMetadata(p); });
        break;
    case libvlc_MediaPlayerVout:
        if (event->u.media_player_vout.new_count > 0) {
            // libVLC just added its OpenGL view to the drawable: fit it.
            WPMediaLayer* layer = (__bridge WPMediaLayer*)p->layer;
            dispatch_async(dispatch_get_main_queue(), ^{
                [layer setNeedsLayout];
                [layer layoutIfNeeded];
                if (getenv("WPMEDIA_DEBUG") || !access("/var/webporn/wpmedia-debug", F_OK)) {
                    NSMutableString* dump = [NSMutableString stringWithFormat:@"layer %@ superlayer %@\ndrawable %@ window %@\n", NSStringFromCGRect(layer.frame),
                        layer.superlayer, layer.drawable, layer.drawable.window];
                    for (UIView* view in layer.drawable.subviews)
                        [dump appendFormat:@"  drawable subview %@\n", view];
                    for (UIView* view in [UIApplication sharedApplication].keyWindow.subviews)
                        [dump appendFormat:@"  window subview %@\n", view];
                    [dump writeToFile:@"/var/mobile/Media/webporn/wpmedia.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
            });
            dispatch_async(p->queue, ^{
                reportMetadata(p);
                finishPreroll(p);
                if (p->client.first_frame)
                    p->client.first_frame(p->client.context);
            });
        }
        break;
    default:
        break;
    }
}

static const libvlc_event_type_t handledEvents[] = { libvlc_MediaPlayerOpening, libvlc_MediaPlayerBuffering,
    libvlc_MediaPlayerPlaying, libvlc_MediaPlayerPaused, libvlc_MediaPlayerEndReached, libvlc_MediaPlayerEncounteredError,
    libvlc_MediaPlayerTimeChanged, libvlc_MediaPlayerLengthChanged, libvlc_MediaPlayerESAdded, libvlc_MediaPlayerVout };

// MARK: - Stream input

// What the client delivers for wpmedia_open_stream, read by libVLC's input
// thread through libvlc_media_new_callbacks. One window of the stream is kept:
// up to kStreamAhead bytes past the read position (then the client is told to
// stop and asked to resume later) and kStreamBehind before it, for the small
// backward seeks demuxers make. A seek outside the window starts a new load at
// the target (a new generation: data of older loads is dropped).

enum { kStreamAhead = 8 << 20, kStreamResume = 4 << 20, kStreamBehind = 1 << 20, kStreamGap = 256 << 10 };

struct wpstream {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    void (*request)(void* context, unsigned generation, unsigned long long offset);
    void* context;
    uint8_t* bytes;
    size_t capacity;
    uint64_t base; // stream offset of bytes[0]
    size_t length;
    uint64_t position; // libVLC's read position
    uint64_t size; // 0: unknown
    int seekable;
    unsigned generation;
    int loading; // the load of this generation is running
    int ended; // ... and it reached the end of the stream
    int failed;
    int closed; // wpmedia_destroy: reads fail, no more requests
    FILE* dump; // debug: the bytes of a live (MSE) stream, stream-<n>.mkv
};

// With the lock held. The client only posts the request to its own thread.
static void streamRequest(wpstream* s, uint64_t offset)
{
    if (s->closed || !s->request)
        return;
    s->generation++;
    s->loading = 1;
    s->ended = 0;
    s->failed = 0;
    debugLog("stream request gen %u at %llu", s->generation, (unsigned long long)offset);
    s->request(s->context, s->generation, offset);
}

// The client ended the stream and libVLC has read all of it.
static int streamInputEnded(wpstream* s)
{
    pthread_mutex_lock(&s->lock);
    int ended = s->ended && s->position >= s->base + s->length;
    pthread_mutex_unlock(&s->lock);
    return ended;
}

static int streamOpen(void* opaque, void** data, uint64_t* size)
{
    wpstream* s = opaque;
    pthread_mutex_lock(&s->lock);
    s->position = 0;
    *size = s->size ? s->size : UINT64_MAX;
    pthread_mutex_unlock(&s->lock);
    *data = s;
    return 0;
}

static ssize_t streamRead(void* opaque, unsigned char* buffer, size_t length)
{
    wpstream* s = opaque;
    pthread_mutex_lock(&s->lock);
    ssize_t result;
    for (;;) {
        if (s->closed) {
            result = -1;
            break;
        }
        uint64_t end = s->base + s->length;
        if (s->position >= s->base && s->position < end) {
            size_t count = (size_t)MIN((uint64_t)length, end - s->position);
            memcpy(buffer, s->bytes + (s->position - s->base), count);
            s->position += count;
            // Running low after the client was told to stop: resume.
            if (!s->loading && !s->ended && end - s->position < kStreamResume)
                streamRequest(s, end);
            result = count;
            break;
        }
        if (s->position == end && s->ended) {
            result = 0;
            break;
        }
        if (s->position == end && s->failed) {
            debugLog("stream read at %llu: failed", (unsigned long long)s->position);
            result = -1;
            break;
        }
        if (!s->seekable && s->position > end && !s->ended && !s->failed) {
            // Forward of the data (a live stream): wait for it.
        } else if (s->position < s->base || s->position > end) {
            if (!s->seekable) {
                debugLog("stream read at %llu: outside %llu-%llu", (unsigned long long)s->position, (unsigned long long)s->base, (unsigned long long)end);
                result = -1;
                break;
            }
            s->base = s->position;
            s->length = 0;
            streamRequest(s, s->position);
        } else if (!s->loading)
            streamRequest(s, end);
        pthread_cond_wait(&s->changed, &s->lock);
    }
    pthread_mutex_unlock(&s->lock);
    return result;
}

static int streamSeek(void* opaque, uint64_t offset)
{
    wpstream* s = opaque;
    pthread_mutex_lock(&s->lock);
    uint64_t end = s->base + s->length;
    int result = 0;
    if (!s->seekable) {
        // A live (MSE) stream: libVLC's Matroska demuxer needs a seekable input,
        // but only moves inside what it has read or forward into what is coming.
        if (offset < s->base)
            result = -1;
        debugLog("stream seek to %llu (window %llu-%llu)%s", (unsigned long long)offset, (unsigned long long)s->base, (unsigned long long)end, result ? ": behind" : "");
    } else if (offset < s->base || offset > end + (s->loading ? kStreamGap : 0)) {
        if (s->seekable) {
            // Out of the window: start over at the target.
            s->base = offset;
            s->length = 0;
            streamRequest(s, offset);
        } else
            result = -1;
    }
    if (!result)
        s->position = offset;
    pthread_mutex_unlock(&s->lock);
    return result;
}

static void streamClose(void* opaque)
{
}

int wpmedia_stream_data(wpmedia_player* p, unsigned generation, const void* bytes, unsigned long length)
{
    wpstream* s = p->stream;
    if (!s)
        return 0;
    pthread_mutex_lock(&s->lock);
    int keepLoading = 0;
    if (!s->closed && generation == s->generation && s->loading) {
        // Drop what is too far behind the reader.
        if (s->position > s->base + 2 * kStreamBehind && s->position <= s->base + s->length) {
            size_t drop = (size_t)(s->position - kStreamBehind - s->base);
            memmove(s->bytes, s->bytes + drop, s->length - drop);
            s->base += drop;
            s->length -= drop;
        }
        if (s->length + length > s->capacity) {
            size_t capacity = MAX(s->capacity * 2, s->length + length);
            uint8_t* grown = realloc(s->bytes, capacity);
            if (grown) {
                s->bytes = grown;
                s->capacity = capacity;
            }
        }
        if (s->length + length <= s->capacity) {
            if (s->dump) {
                fwrite(bytes, 1, length, s->dump);
                fflush(s->dump);
            }
            memcpy(s->bytes + s->length, bytes, length);
            s->length += length;
            pthread_cond_broadcast(&s->changed);
            keepLoading = s->base + s->length < s->position + kStreamAhead;
            if (!keepLoading)
                s->loading = 0; // streamRead resumes it
        } else {
            s->failed = 1;
            s->loading = 0;
            pthread_cond_broadcast(&s->changed);
        }
    }
    pthread_mutex_unlock(&s->lock);
    return keepLoading;
}

void wpmedia_stream_end(wpmedia_player* p, unsigned generation, int failed)
{
    wpstream* s = p->stream;
    if (!s)
        return;
    pthread_mutex_lock(&s->lock);
    if (generation == s->generation && s->loading) {
        s->loading = 0;
        if (failed)
            s->failed = 1;
        else
            s->ended = 1;
        debugLog("stream gen %u %s at %llu", generation, failed ? "failed" : "ended", (unsigned long long)(s->base + s->length));
        pthread_cond_broadcast(&s->changed);
    }
    pthread_mutex_unlock(&s->lock);
}

static wpstream* streamCreate(wpmedia_player* p, unsigned long long size, int seekable)
{
    wpstream* s = calloc(1, sizeof(*s));
    pthread_mutex_init(&s->lock, NULL);
    pthread_cond_init(&s->changed, NULL);
    s->request = p->client.stream_request;
    s->context = p->client.context;
    s->size = size;
    s->seekable = seekable && size;
    s->loading = 1; // the client's first load, generation 0
    if (!s->seekable && !access("/var/webporn/wpmedia-debug", F_OK)) {
        static int count;
        char path[128];
        snprintf(path, sizeof(path), "/var/mobile/Media/webporn/stream-%d.mkv", count++ % 4);
        s->dump = fopen(path, "w");
    }
    return s;
}

static void streamDestroy(wpstream* s)
{
    if (s->dump)
        fclose(s->dump);
    pthread_mutex_destroy(&s->lock);
    pthread_cond_destroy(&s->changed);
    free(s->bytes);
    free(s);
}

// MARK: - Proxy

// libVLC fetches HLS itself (its adaptive demuxer has its own HTTP client), so
// cookies, the page's TLS and network stack were not used. The proxy puts the
// page's loader under it: libVLC opens
//   http://127.0.0.1:<port>/<player token>/<scheme>/<host[:port]>/<path>?<query>
// and each request it makes becomes a client.fetch. Relative references in
// playlists resolve inside that layout by themselves; absolute and root-relative
// ones are rewritten into it, so segments on other hosts go through it too.

typedef struct wpfetch {
    struct wpfetch* next;
    unsigned id;
    wpmedia_player* player; // NULL once the player is gone
    pthread_cond_t changed;
    int responded, ended, failed;
    int status;
    long long length;
    char contentType[128];
    char contentRange[96];
    uint8_t* bytes;
    size_t length_, capacity;
} wpfetch;

static pthread_mutex_t proxyLock = PTHREAD_MUTEX_INITIALIZER;
static wpfetch* proxyFetches;
static unsigned proxyNextID = 1;
static int proxyPort;

typedef struct proxyplayer {
    struct proxyplayer* next;
    wpmedia_player* player;
    char token[24];
} proxyplayer;
static proxyplayer* proxyPlayers;

static wpfetch* fetchWithID(unsigned id)
{
    for (wpfetch* fetch = proxyFetches; fetch; fetch = fetch->next) {
        if (fetch->id == id)
            return fetch;
    }
    return NULL;
}

static int writeAll(int fd, const void* bytes, size_t length)
{
    const uint8_t* cursor = bytes;
    while (length) {
        ssize_t written = write(fd, cursor, length);
        if (written <= 0)
            return 0;
        cursor += written;
        length -= (size_t)written;
    }
    return 1;
}

static NSString* proxiedURLString(NSURL* url, const char* token)
{
    NSString* scheme = url.scheme.lowercaseString;
    if (!url.host || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]))
        return url.absoluteString;
    NSString* authority = url.port ? [NSString stringWithFormat:@"%@:%@", url.host, url.port] : url.host;
    NSString* path = url.path.length ? [url.absoluteString substringFromIndex:[url.absoluteString rangeOfString:authority].location + authority.length] : @"/";
    return [NSString stringWithFormat:@"http://127.0.0.1:%d/%s/%@/%@%@", proxyPort, token, scheme, authority, [path hasPrefix:@"/"] ? path : [@"/" stringByAppendingString:path]];
}

// Every URI of an HLS playlist (lines and URI="..." attributes) through the proxy.
static NSData* rewritePlaylist(NSData* body, NSURL* base, const char* token)
{
    NSString* text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!text)
        return body;
    NSMutableArray* lines = [NSMutableArray array];
    for (NSString* rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSString* line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length) {
            [lines addObject:line];
            continue;
        }
        if (![line hasPrefix:@"#"]) {
            NSURL* url = [NSURL URLWithString:line relativeToURL:base];
            [lines addObject:url ? proxiedURLString(url.absoluteURL, token) : line];
            continue;
        }
        NSMutableString* tag = [line mutableCopy];
        NSRange search = NSMakeRange(0, tag.length);
        for (;;) {
            NSRange start = [tag rangeOfString:@"URI=\"" options:0 range:search];
            if (start.location == NSNotFound)
                break;
            NSUInteger valueStart = NSMaxRange(start);
            NSRange end = [tag rangeOfString:@"\"" options:0 range:NSMakeRange(valueStart, tag.length - valueStart)];
            if (end.location == NSNotFound)
                break;
            NSString* value = [tag substringWithRange:NSMakeRange(valueStart, end.location - valueStart)];
            NSURL* url = [NSURL URLWithString:value relativeToURL:base];
            NSString* replacement = url ? proxiedURLString(url.absoluteURL, token) : value;
            [tag replaceCharactersInRange:NSMakeRange(valueStart, end.location - valueStart) withString:replacement];
            NSUInteger next = valueStart + replacement.length + 1;
            search = NSMakeRange(next, tag.length - next);
        }
        [lines addObject:tag];
    }
    return [[lines componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
}

static void* proxyConnection(void* argument)
{
    int fd = (int)(intptr_t)argument;
    char request[16384];
    size_t used = 0;
    while (used < sizeof(request) - 1) {
        ssize_t got = read(fd, request + used, sizeof(request) - 1 - used);
        if (got <= 0)
            break;
        used += (size_t)got;
        request[used] = 0;
        if (strstr(request, "\r\n\r\n"))
            break;
    }
    request[used] = 0;
    char method[8] = "", path[8192] = "";
    if (sscanf(request, "%7s %8191s", method, path) != 2 || (strcmp(method, "GET") && strcmp(method, "HEAD"))) {
        close(fd);
        return NULL;
    }
    char range[128] = "";
    for (char* line = strstr(request, "\r\n"); line && line[2]; line = strstr(line + 2, "\r\n")) {
        if (!strncasecmp(line + 2, "Range:", 6)) {
            const char* value = line + 8;
            while (*value == ' ')
                value++;
            size_t length = strcspn(value, "\r\n");
            snprintf(range, sizeof(range), "%.*s", (int)length, value);
        }
    }
    // /<token>/<scheme>/<authority>/<rest>
    char token[24] = "", scheme[8] = "";
    int consumed = 0;
    if (sscanf(path, "/%23[^/]/%7[^/]/%n", token, scheme, &consumed) != 2 || !consumed) {
        writeAll(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", 66);
        close(fd);
        return NULL;
    }
    NSString* target = [NSString stringWithFormat:@"%s://%s", scheme, path + consumed];
    pthread_mutex_lock(&proxyLock);
    wpmedia_player* player = NULL;
    for (proxyplayer* entry = proxyPlayers; entry; entry = entry->next) {
        if (!strcmp(entry->token, token))
            player = entry->player;
    }
    wpfetch* fetch = NULL;
    wpmedia_client client = { };
    if (player) {
        fetch = calloc(1, sizeof(*fetch));
        fetch->id = proxyNextID++;
        fetch->player = player;
        fetch->length = -1;
        pthread_cond_init(&fetch->changed, NULL);
        fetch->next = proxyFetches;
        proxyFetches = fetch;
        client = player->client;
    }
    pthread_mutex_unlock(&proxyLock);
    if (!fetch || !client.fetch) {
        writeAll(fd, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", 66);
        close(fd);
        return NULL;
    }
    unsigned id = fetch->id;
    debugLog("proxy %u: %s %s%s%s", id, method, target.UTF8String, range[0] ? " " : "", range);
    client.fetch(client.context, id, target.UTF8String, range[0] ? range : NULL);

    pthread_mutex_lock(&proxyLock);
    while (!fetch->responded && !fetch->failed && fetch->player)
        pthread_cond_wait(&fetch->changed, &proxyLock);
    int ok = fetch->responded && fetch->player;
    int status = fetch->status ? fetch->status : 502;
    long long length = fetch->length;
    char contentType[128], contentRange[96];
    strcpy(contentType, fetch->contentType);
    strcpy(contentRange, fetch->contentRange);
    pthread_mutex_unlock(&proxyLock);

    int sendBody = strcmp(method, "HEAD") != 0;
    int playlist = strcasestr(contentType, "mpegurl") || [[NSURL URLWithString:target].path.lowercaseString hasSuffix:@".m3u8"];
    int clientWent = 0;
    if (!ok) {
        char header[160];
        int size = snprintf(header, sizeof(header), "HTTP/1.1 %d Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status >= 400 ? status : 502);
        writeAll(fd, header, (size_t)size);
    } else if (playlist && status < 300) {
        // Whole, then rewritten.
        pthread_mutex_lock(&proxyLock);
        while (!fetch->ended && !fetch->failed && fetch->player)
            pthread_cond_wait(&fetch->changed, &proxyLock);
        NSData* body = [NSData dataWithBytes:fetch->bytes length:fetch->length_];
        int complete = fetch->ended && !fetch->failed;
        pthread_mutex_unlock(&proxyLock);
        if (complete) {
            body = rewritePlaylist(body, [NSURL URLWithString:target], token);
            char header[320];
            int size = snprintf(header, sizeof(header), "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
                contentType[0] ? contentType : "application/vnd.apple.mpegurl", (unsigned long)body.length);
            writeAll(fd, header, (size_t)size);
            if (sendBody)
                writeAll(fd, body.bytes, body.length);
        } else
            writeAll(fd, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", 68);
    } else {
        char header[512];
        int size = snprintf(header, sizeof(header), "HTTP/1.1 %d %s\r\n", status, status == 206 ? "Partial Content" : "OK");
        if (contentType[0])
            size += snprintf(header + size, sizeof(header) - (size_t)size, "Content-Type: %s\r\n", contentType);
        if (length >= 0)
            size += snprintf(header + size, sizeof(header) - (size_t)size, "Content-Length: %lld\r\n", length);
        if (contentRange[0])
            size += snprintf(header + size, sizeof(header) - (size_t)size, "Content-Range: %s\r\n", contentRange);
        size += snprintf(header + size, sizeof(header) - (size_t)size, "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n");
        clientWent = !writeAll(fd, header, (size_t)size);
        // Stream as it arrives.
        while (sendBody && !clientWent) {
            pthread_mutex_lock(&proxyLock);
            while (!fetch->length_ && !fetch->ended && !fetch->failed && fetch->player)
                pthread_cond_wait(&fetch->changed, &proxyLock);
            uint8_t* bytes = fetch->bytes;
            size_t count = fetch->length_;
            int done = (fetch->ended || fetch->failed || !fetch->player) && !count;
            fetch->bytes = NULL;
            fetch->length_ = fetch->capacity = 0;
            pthread_mutex_unlock(&proxyLock);
            if (count)
                clientWent = !writeAll(fd, bytes, count);
            free(bytes);
            if (done)
                break;
        }
    }
    close(fd);

    pthread_mutex_lock(&proxyLock);
    int stillLoading = fetch->player && !fetch->ended && !fetch->failed;
    for (wpfetch** link = &proxyFetches; *link; link = &(*link)->next) {
        if (*link == fetch) {
            *link = fetch->next;
            break;
        }
    }
    pthread_mutex_unlock(&proxyLock);
    if (stillLoading && client.fetch_cancel)
        client.fetch_cancel(client.context, id);
    debugLog("proxy %u: done (status %d%s)", id, status, clientWent ? ", libVLC went away" : "");
    pthread_cond_destroy(&fetch->changed);
    free(fetch->bytes);
    free(fetch);
    return NULL;
}

static void* proxyAccept(void* argument)
{
    int listener = (int)(intptr_t)argument;
    for (;;) {
        int fd = accept(listener, NULL, NULL);
        if (fd < 0)
            continue;
        int on = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        pthread_t thread;
        pthread_attr_t attributes;
        pthread_attr_init(&attributes);
        pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&thread, &attributes, proxyConnection, (void*)(intptr_t)fd))
            close(fd);
        pthread_attr_destroy(&attributes);
    }
    return NULL;
}

static int startProxy(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int listener = socket(AF_INET, SOCK_STREAM, 0);
        if (listener < 0)
            return;
        struct sockaddr_in address = { };
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        socklen_t size = sizeof(address);
        if (bind(listener, (struct sockaddr*)&address, sizeof(address)) || listen(listener, 16) || getsockname(listener, (struct sockaddr*)&address, &size)) {
            close(listener);
            return;
        }
        pthread_t thread;
        if (pthread_create(&thread, NULL, proxyAccept, (void*)(intptr_t)listener)) {
            close(listener);
            return;
        }
        pthread_detach(thread);
        proxyPort = ntohs(address.sin_port);
        debugLog("proxy on port %d", proxyPort);
    });
    return proxyPort;
}

int wpmedia_proxy_url(wpmedia_player* p, const char* url, char* buffer, unsigned long size)
{
    if (!p->client.fetch || !startProxy())
        return 0;
    NSURL* target = [NSURL URLWithString:@(url)];
    if (!target)
        return 0;
    pthread_mutex_lock(&proxyLock);
    proxyplayer* entry = NULL;
    for (proxyplayer* candidate = proxyPlayers; candidate; candidate = candidate->next) {
        if (candidate->player == p)
            entry = candidate;
    }
    if (!entry) {
        entry = calloc(1, sizeof(*entry));
        entry->player = p;
        snprintf(entry->token, sizeof(entry->token), "%08x%08x", arc4random(), arc4random());
        entry->next = proxyPlayers;
        proxyPlayers = entry;
    }
    char token[24];
    strcpy(token, entry->token);
    pthread_mutex_unlock(&proxyLock);
    NSString* proxied = proxiedURLString(target, token);
    if ([proxied isEqualToString:target.absoluteString])
        return 0;
    snprintf(buffer, size, "%s", proxied.UTF8String);
    return 1;
}

// The player is going: its requests fail, its token stops working.
static void proxyForget(wpmedia_player* p)
{
    pthread_mutex_lock(&proxyLock);
    for (proxyplayer** link = &proxyPlayers; *link;) {
        if ((*link)->player == p) {
            proxyplayer* gone = *link;
            *link = gone->next;
            free(gone);
        } else
            link = &(*link)->next;
    }
    for (wpfetch* fetch = proxyFetches; fetch; fetch = fetch->next) {
        if (fetch->player == p) {
            fetch->player = NULL;
            pthread_cond_broadcast(&fetch->changed);
        }
    }
    pthread_mutex_unlock(&proxyLock);
}

void wpmedia_fetch_response(wpmedia_player* p, unsigned id, int status, long long length, const char* contentType, const char* contentRange)
{
    pthread_mutex_lock(&proxyLock);
    wpfetch* fetch = fetchWithID(id);
    if (fetch && fetch->player == p && !fetch->responded) {
        fetch->responded = 1;
        fetch->status = status;
        fetch->length = length;
        snprintf(fetch->contentType, sizeof(fetch->contentType), "%s", contentType ? contentType : "");
        snprintf(fetch->contentRange, sizeof(fetch->contentRange), "%s", contentRange ? contentRange : "");
        pthread_cond_broadcast(&fetch->changed);
    }
    pthread_mutex_unlock(&proxyLock);
}

void wpmedia_fetch_data(wpmedia_player* p, unsigned id, const void* bytes, unsigned long length)
{
    pthread_mutex_lock(&proxyLock);
    wpfetch* fetch = fetchWithID(id);
    if (fetch && fetch->player == p) {
        if (fetch->length_ + length > fetch->capacity) {
            size_t capacity = MAX(fetch->capacity * 2, fetch->length_ + length);
            uint8_t* grown = realloc(fetch->bytes, capacity);
            if (grown) {
                fetch->bytes = grown;
                fetch->capacity = capacity;
            }
        }
        if (fetch->length_ + length <= fetch->capacity) {
            memcpy(fetch->bytes + fetch->length_, bytes, length);
            fetch->length_ += length;
        } else
            fetch->failed = 1;
        pthread_cond_broadcast(&fetch->changed);
    }
    pthread_mutex_unlock(&proxyLock);
}

void wpmedia_fetch_end(wpmedia_player* p, unsigned id, int failed)
{
    pthread_mutex_lock(&proxyLock);
    wpfetch* fetch = fetchWithID(id);
    if (fetch && fetch->player == p) {
        if (failed)
            fetch->failed = 1;
        else
            fetch->ended = 1;
        pthread_cond_broadcast(&fetch->changed);
    }
    pthread_mutex_unlock(&proxyLock);
}

// MARK: - Lifetime

wpmedia_player* wpmedia_create(const wpmedia_client* client)
{
    libvlc_instance_t* instance = sharedInstance();
    if (!instance)
        return NULL;
    wpmedia_player* p = calloc(1, sizeof(*p));
    p->client = *client;
    p->player = libvlc_media_player_new(instance);
    p->queue = dispatch_queue_create("net.webporn.media", DISPATCH_QUEUE_SERIAL);
    p->pendingSeek = -1;
    p->seekTarget = -1;
    p->volume = 1;
    p->rate = 1;
    WPMediaLayer* layer = [WPMediaLayer layer];
    layer.masksToBounds = YES;
    p->layer = (__bridge_retained void*)layer;
    WPClientTarget* target = [WPClientTarget new];
    target->client = p->client;
    target->valid = YES;
    p->target = (__bridge_retained void*)target;
    libvlc_event_manager_t* events = libvlc_media_player_event_manager(p->player);
    for (size_t i = 0; i < sizeof(handledEvents) / sizeof(*handledEvents); i++)
        libvlc_event_attach(events, handledEvents[i], handleEvent, p);
    return p;
}

void wpmedia_destroy(wpmedia_player* p)
{
    if (!p)
        return;
    // Detaching waits for a callback in progress; no event callback runs after
    // this, but work already on p->queue does (see client.release).
    libvlc_event_manager_t* events = libvlc_media_player_event_manager(p->player);
    for (size_t i = 0; i < sizeof(handledEvents) / sizeof(*handledEvents); i++)
        libvlc_event_detach(events, handledEvents[i], handleEvent, p);
    proxyForget(p);
    // A stream read in progress fails now, and no request reaches the client
    // after this returns.
    wpstream* stream = p->stream;
    if (stream) {
        pthread_mutex_lock(&stream->lock);
        stream->closed = 1;
        pthread_cond_broadcast(&stream->changed);
        pthread_mutex_unlock(&stream->lock);
    }
    WPMediaLayer* layer = (__bridge_transfer WPMediaLayer*)p->layer;
    WPClientTarget* target = (__bridge_transfer WPClientTarget*)p->target;
    // On p's own (serial, background) queue: a restart still queued there would
    // otherwise set a new input after the player was stopped and play a stream
    // freed here (a crash in libVLC's input thread when YouTube rebuilt its player).
    // Queued work also still uses p and the client: release both at the end.
    dispatch_async(p->queue, ^{
        libvlc_media_player_stop(p->player);
        libvlc_media_player_release(p->player);
        if (p->media)
            libvlc_media_release(p->media);
        if (p->stream)
            streamDestroy(p->stream);
        target->valid = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [layer exitFullscreen];
            [layer.drawable removeFromSuperview];
            [layer.drawable.layer removeFromSuperlayer];
            layer.drawable = nil;
        });
        if (p->client.release)
            p->client.release(p->client.context);
        free(p);
    });
}

void wpmedia_set_fullscreen(wpmedia_player* p, int fullscreen)
{
    WPMediaLayer* layer = (__bridge WPMediaLayer*)p->layer;
    WPClientTarget* target = (__bridge WPClientTarget*)p->target;
    dispatch_queue_t queue = p->queue;
    CGSize size = CGSizeMake(p->width, p->height);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!fullscreen) {
            [layer exitFullscreen];
            return;
        }
        if (layer.fullscreenWindow || !layer.drawable)
            return;
        WPFullscreenWindow* window = [[WPFullscreenWindow alloc] initWithVideoSize:size];
        window.action = ^(wpmedia_fullscreen_action action) {
            dispatch_async(queue, ^{
                if (target->valid && target->client.fullscreen_action)
                    target->client.fullscreen_action(target->client.context, action);
            });
        };
        layer.fullscreenWindow = window;
        [layer.drawable.layer removeFromSuperlayer];
        [window showVideoView:layer.drawable];
        window.hidden = NO;
        debugLog("fullscreen %.0fx%.0f", size.width, size.height);
    });
}

void* wpmedia_layer(wpmedia_player* p)
{
    return p ? p->layer : NULL;
}

// MARK: - Control

// libVLC 3's own mp4 demuxer loses its clock on some files (video-only with an
// edit list: time sticks at 0.25 s, so no timeupdate, no seeking); libavformat's
// does not. "any" falls back to libVLC's demuxers. HLS stays with libVLC's
// adaptive module, which handles it better than libavformat.
static int isMP4Family(const char* url, const char* mimeType)
{
    static const char* const types[] = { "video/mp4", "video/x-m4v", "video/quicktime", "audio/mp4", "audio/x-m4a", "video/3gpp", "audio/3gpp", NULL };
    if (mimeType && *mimeType)
        return caseInsensitiveIn(mimeType, types);
    const char* path = strrchr(url, '/');
    const char* dot = path ? strrchr(path, '.') : NULL;
    if (!dot)
        return 0;
    static const char* const extensions[] = { ".mp4", ".m4v", ".mov", ".m4a", ".3gp", NULL };
    for (const char* const* extension = extensions; *extension; extension++) {
        size_t length = strlen(*extension);
        if (!strncasecmp(dot, *extension, length) && (!dot[length] || dot[length] == '?' || dot[length] == '#'))
            return 1;
    }
    return 0;
}

static void startMedia(wpmedia_player* p, libvlc_media_t* media, const char* url, const char* mimeType, wpstream* retired);

void wpmedia_open(wpmedia_player* p, const char* url, const char* mimeType, const char* userAgent, const char* referrer)
{
    libvlc_media_t* media = libvlc_media_new_location(sharedInstance(), url);
    if (!media) {
        reportState(p, WPMEDIA_STATE_ERROR);
        return;
    }
    if (userAgent && *userAgent) {
        char option[1024];
        snprintf(option, sizeof(option), ":http-user-agent=%s", userAgent);
        libvlc_media_add_option(media, option);
    }
    if (referrer && *referrer) {
        char option[2048];
        snprintf(option, sizeof(option), ":http-referrer=%s", referrer);
        libvlc_media_add_option(media, option);
    }
    startMedia(p, media, url, mimeType, NULL);
}

void wpmedia_open_stream(wpmedia_player* p, const char* url, const char* mimeType, unsigned long long size, int seekable)
{
    // A stream after a stream (MSE after a seek) replaces it: reads of the old one
    // fail from now on, and it is freed once libVLC has let go of it.
    wpstream* retired = p->stream;
    if (retired) {
        pthread_mutex_lock(&retired->lock);
        retired->closed = 1;
        pthread_cond_broadcast(&retired->changed);
        pthread_mutex_unlock(&retired->lock);
    }
    p->stream = streamCreate(p, size, seekable);
    p->live = !p->stream->seekable;
    debugLog("open stream %s (%s) size %llu seekable %d", url, mimeType ? mimeType : "-", size, p->stream->seekable);
    libvlc_media_t* media = libvlc_media_new_callbacks(sharedInstance(), streamOpen, streamRead, streamSeek, streamClose, p->stream);
    if (!media) {
        reportState(p, WPMEDIA_STATE_ERROR);
        return;
    }
    startMedia(p, media, url, mimeType, retired);
}

// After the first stream: the same drawable and video output, a new input.
static void restartMedia(wpmedia_player* p, libvlc_media_t* media, wpstream* retired)
{
    dispatch_async(p->queue, ^{
        libvlc_media_t* old = p->media;
        debugLog("restart stream, wants playing %d", p->wantsPlaying);
        // Stops the old input (its reads fail: the stream is closed).
        libvlc_media_player_set_media(p->player, media);
        p->media = media;
        if (old)
            libvlc_media_release(old);
        if (retired)
            streamDestroy(retired);
        p->seekTarget = -1;
        p->pauseOnFirstTime = !p->wantsPlaying;
        libvlc_media_player_set_rate(p->player, p->rate);
        libvlc_media_player_play(p->player);
    });
}

static void startMedia(wpmedia_player* p, libvlc_media_t* media, const char* url, const char* mimeType, wpstream* retired)
{
    // Pause on the last frame instead of stopping: a stopped input closes the video
    // output, and replaying or seeking back would set it up again (~2.5 s).
    libvlc_media_add_option(media, ":play-and-pause");
    // Adaptive streams (HLS, DASH): libVLC picks renditions the A6 cannot decode in
    // time (1080p dropped a third of its frames) and that take longest to fetch
    // after a seek. 720p decodes in real time and is above the iPhone's 640 px width.
    libvlc_media_add_option(media, ":adaptive-maxheight=720");
    if (isMP4Family(url, mimeType))
        libvlc_media_add_option(media, ":demux=avformat,any");
    if (mimeType && !strcasecmp(mimeType, "video/x-matroska"))
        libvlc_media_add_option(media, ":demux=mkv");
    if (p->started) {
        restartMedia(p, media, retired);
        return;
    }
    p->started = 1;
    WPMediaLayer* layer = (__bridge WPMediaLayer*)p->layer;
    libvlc_media_player_t* player = p->player;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView* drawable = [[UIView alloc] initWithFrame:layer.bounds];
        // Transparent: the poster shows through until libVLC's view draws, and
        // nothing black is left when the media never loads.
        drawable.backgroundColor = [UIColor clearColor];
        drawable.userInteractionEnabled = NO;
        drawable.clipsToBounds = YES;
        layer.drawable = drawable;
        [layer addSublayer:drawable.layer];
        [layer setNeedsLayout];
        dispatch_async(p->queue, ^{
            libvlc_media_player_set_nsobject(player, (__bridge void*)drawable);
            libvlc_media_player_set_media(player, media);
            p->media = media;
            libvlc_audio_set_volume(player, 0); // until finishPreroll
            // A live stream cannot go back to the start after the preroll: crawl
            // through it while the video output is set up (2.5 s -> 80 ms).
            libvlc_media_player_set_rate(player, p->live ? 1.0f / 32 : p->rate);
            libvlc_media_player_play(player);
        });
    });
}

void wpmedia_play(wpmedia_player* p)
{
    dispatch_async(p->queue, ^{
        p->wantsPlaying = 1;
        if (p->ready)
            libvlc_media_player_set_pause(p->player, 0);
    });
}

void wpmedia_pause(wpmedia_player* p)
{
    dispatch_async(p->queue, ^{
        p->wantsPlaying = 0;
        if (p->ready)
            libvlc_media_player_set_pause(p->player, 1);
    });
}

void wpmedia_seek(wpmedia_player* p, double seconds)
{
    dispatch_async(p->queue, ^{
        debugLog("wpmedia_seek %.2f ready %d", seconds, p->ready);
        if (p->ready)
            seekTo(p, seconds);
        else
            p->pendingSeek = seconds;
    });
}

double wpmedia_time(wpmedia_player* p)
{
    if (!p->ready)
        return 0;
    libvlc_time_t time = libvlc_media_player_get_time(p->player);
    return time > 0 ? time / 1000.0 : 0;
}

void wpmedia_set_rate(wpmedia_player* p, float rate)
{
    dispatch_async(p->queue, ^{
        p->rate = rate;
        libvlc_media_player_set_rate(p->player, rate);
    });
}

void wpmedia_set_volume(wpmedia_player* p, float volume)
{
    dispatch_async(p->queue, ^{
        p->volume = volume;
        if (!p->muted && p->ready)
            libvlc_audio_set_volume(p->player, (int)(volume * 100));
    });
}

void wpmedia_set_muted(wpmedia_player* p, int muted)
{
    dispatch_async(p->queue, ^{
        p->muted = muted;
        if (p->ready)
            libvlc_audio_set_volume(p->player, muted ? 0 : (int)(p->volume * 100));
    });
}

// MARK: - Frames

// libVLC has no in-memory snapshot: it converts the displayed picture and writes
// a file, which is read back here. Video output frames live on the GPU, so this
// is the only CPU copy there is (~250 ms on an A6).
void* wpmedia_copy_frame(wpmedia_player* p, unsigned maxWidth)
{
    if (!p->ready || !p->width)
        return NULL;
    unsigned width = p->width < maxWidth || !maxWidth ? p->width : maxWidth;
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"wpmedia-frame-%p.png", p]];
    if (libvlc_video_take_snapshot(p->player, 0, path.fileSystemRepresentation, width, 0))
        return NULL;
    CGImageRef image = NULL;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (source) {
        // Decode now: the file goes away below.
        NSDictionary* options = @{ (__bridge NSString*)kCGImageSourceShouldCacheImmediately: @YES };
        image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        CFRelease(source);
    }
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    debugLog("copy_frame %ux: %s", width, image ? "ok" : "failed");
    return image;
}

void wpmedia_request_frame(wpmedia_player* p, unsigned maxWidth)
{
    // On the player's queue, which wpmedia_destroy waits for before freeing p.
    dispatch_async(p->queue, ^{
        void* image = wpmedia_copy_frame(p, maxWidth);
        if (p->client.frame_ready)
            p->client.frame_ready(p->client.context, image);
        else if (image)
            CFRelease(image);
    });
}

// Test hook (tests/vlcview): the libVLC player behind a wpmedia player.
libvlc_media_player_t* wpmedia_debug_vlc_player(wpmedia_player* p)
{
    return p->player;
}
