// wpmedia: the C ABI between WebCore's MediaPlayerPrivateWebPorn and
// libWebPornMedia.dylib (libVLC). WebCore dlopens the library, so no C++ crosses
// the boundary and the LGPL code stays in its own image. A copy of this header
// lives in Source/WebCore/platform/graphics/webporn/; keep them identical.
//
// Threading: every function may be called from any thread. Client callbacks
// arrive on libVLC's event thread (or the main thread) and must not call back
// into the player synchronously.

#ifndef WPMEDIA_H
#define WPMEDIA_H

#ifdef __cplusplus
extern "C" {
#endif

#define WPMEDIA_ABI_VERSION 5

typedef struct wpmedia_player wpmedia_player;

typedef enum {
    WPMEDIA_STATE_IDLE,
    WPMEDIA_STATE_OPENING,
    WPMEDIA_STATE_BUFFERING,
    WPMEDIA_STATE_PLAYING,
    WPMEDIA_STATE_PAUSED,
    WPMEDIA_STATE_ENDED,
    WPMEDIA_STATE_ERROR,
} wpmedia_state;

typedef enum {
    WPMEDIA_NOT_SUPPORTED,
    WPMEDIA_MAYBE_SUPPORTED,
    WPMEDIA_SUPPORTED,
} wpmedia_support;

typedef enum {
    WPMEDIA_FULLSCREEN_EXIT, // the client should leave full screen (and call wpmedia_set_fullscreen 0)
    WPMEDIA_FULLSCREEN_TOGGLE_PLAYBACK,
    // Seek to wpmedia_fullscreen_seek_time(). Sent only to clients that call
    // wpmedia_set_fullscreen_state (the scrubber and skips are hidden otherwise).
    WPMEDIA_FULLSCREEN_SEEK,
} wpmedia_fullscreen_action;

typedef struct {
    void* context;
    void (*state_changed)(void* context, wpmedia_state);
    // Metadata is known: duration (seconds, 0 when live / unknown), video size
    // (0 x 0 for audio only), whether there are video / audio tracks.
    void (*metadata_changed)(void* context, double duration, unsigned width, unsigned height, int has_video, int has_audio);
    // Current time moved (playback or a finished seek).
    void (*time_changed)(void* context, double seconds);
    // Network cache fill, 0-100.
    void (*buffering)(void* context, float percent);
    // A first video frame is on screen.
    void (*first_frame)(void* context);
    // Answer to wpmedia_request_frame: a CGImageRef (+1, the client releases it)
    // or NULL.
    void (*frame_ready)(void* context, void* image);
    // Stream input (wpmedia_open_stream): load from this byte offset on with this
    // generation, dropping any load in progress. Called from libVLC's threads,
    // never after wpmedia_destroy has returned.
    void (*stream_request)(void* context, unsigned generation, unsigned long long offset);
    // Last call for this client, after every other callback, once the player is
    // torn down (some time after wpmedia_destroy): release the context here.
    void (*release)(void* context);
    // The viewer used the full-screen window's controls (wpmedia_set_fullscreen).
    void (*fullscreen_action)(void* context, wpmedia_fullscreen_action);
    // Proxy (wpmedia_proxy_url): load this URL with the page's loader (cookies,
    // TLS, the page's network stack) and answer through wpmedia_fetch_*. range
    // is the Range header libVLC asked with, or NULL. fetch_cancel: the request
    // went away (libVLC closed its connection); stop loading.
    void (*fetch)(void* context, unsigned id, const char* url, const char* range);
    void (*fetch_cancel)(void* context, unsigned id);
} wpmedia_client;

int wpmedia_abi_version(void);

// container: MIME type without parameters ("video/mp4"); codecs: the codecs
// parameter or NULL / "".
wpmedia_support wpmedia_supports(const char* container, const char* codecs);

// The client is copied. Callbacks may still arrive after wpmedia_destroy returns,
// up to client.release.
wpmedia_player* wpmedia_create(const wpmedia_client*);
void wpmedia_destroy(wpmedia_player*);

// A CALayer (owned by the player) that shows the video scaled to fit, and
// follows its own bounds. Valid until wpmedia_destroy.
void* wpmedia_layer(wpmedia_player*);

// Opens the URL paused: metadata arrives without playing. mime_type (the
// element's or the response's, without parameters), user_agent and referrer may
// be NULL.
void wpmedia_open(wpmedia_player*, const char* url, const char* mime_type, const char* user_agent, const char* referrer);

// The URL libVLC should open instead of url so that everything it fetches for it
// (an HLS playlist, its media playlists and segments, keys) goes through the
// client's fetch callback: a local HTTP proxy. Written to buffer (NUL
// terminated); returns 0 when the proxy is not available (open url directly).
int wpmedia_proxy_url(wpmedia_player*, const char* url, char* buffer, unsigned long size);
// Answers to client.fetch, in this order: the response (status; length -1 when
// unknown; content_type and content_range may be NULL), its bytes, the end.
void wpmedia_fetch_response(wpmedia_player*, unsigned id, int status, long long length, const char* content_type, const char* content_range);
void wpmedia_fetch_data(wpmedia_player*, unsigned id, const void* bytes, unsigned long length);
void wpmedia_fetch_end(wpmedia_player*, unsigned id, int failed);
// Opens a byte stream the client delivers (WebCore's loader, MSE) instead of a
// URL: libVLC reads what arrives through wpmedia_stream_data. The client has
// already started loading from offset 0 with generation 0. size: total bytes,
// 0 when unknown. seekable: the client can load from any offset (HTTP ranges);
// otherwise the library never asks for anything but the next byte.
// url only names the stream (logs, the demuxer's guess from an extension).
void wpmedia_open_stream(wpmedia_player*, const char* url, const char* mime_type, unsigned long long size, int seekable);
// Bytes of the load with this generation, in order. Returns 0 when the client
// should stop that load (the buffer is full or the load is stale); the library
// asks again through stream_request when it needs more.
int wpmedia_stream_data(wpmedia_player*, unsigned generation, const void* bytes, unsigned long length);
// The load with this generation is over: at the end of the stream, or failed.
void wpmedia_stream_end(wpmedia_player*, unsigned generation, int failed);

void wpmedia_play(wpmedia_player*);
void wpmedia_pause(wpmedia_player*);
void wpmedia_seek(wpmedia_player*, double seconds);
double wpmedia_time(wpmedia_player*);
void wpmedia_set_rate(wpmedia_player*, float rate);
void wpmedia_set_volume(wpmedia_player*, float volume); // 0-1
void wpmedia_set_muted(wpmedia_player*, int muted);

// Shows the video in a window of its own over the whole screen (it turns with the
// device; a tap shows Done, play/pause, 10 s skips and a scrubber), or puts it back
// in its layer.
void wpmedia_set_fullscreen(wpmedia_player*, int fullscreen);
// Optional (same ABI version; look them up with dlsym): what the full-screen
// controls show. Call on entering full screen and whenever time, duration (0 when
// unknown / live) or play state change while in it.
void wpmedia_set_fullscreen_state(wpmedia_player*, double time, double duration, int playing);
// The time WPMEDIA_FULLSCREEN_SEEK asks for.
double wpmedia_fullscreen_seek_time(wpmedia_player*);
// The current video frame as a CGImageRef (+1, the caller releases it), at most
// max_width pixels wide, or NULL. Blocks for a few hundred milliseconds
// (libVLC's snapshot: the frame is read back from the GPU); cache it.
void* wpmedia_copy_frame(wpmedia_player*, unsigned max_width);
// The same, without blocking: the frame arrives through frame_ready.
void wpmedia_request_frame(wpmedia_player*, unsigned max_width);

#ifdef __cplusplus
}
#endif

#endif
