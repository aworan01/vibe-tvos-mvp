#include "ClearKey.h"
#include "SourceHTTP.h"

#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>

struct IPTVRelay {
    int listener;
    int client;
    atomic_int cancelled;
    atomic_int failed;
    atomic_int stage;
    atomic_int http_status;
    atomic_int source_error;
    atomic_int network_error;
    const char *manifest_url;
    const char *user_agent;
    void *transport;
};

static int cancelled(void *opaque) {
    IPTVRelay *relay = opaque;
    return atomic_load(&relay->cancelled);
}

IPTVRelay *iptv_relay_create(uint16_t *port) {
    IPTVRelay *relay = calloc(1, sizeof(*relay));
    if (!relay) return NULL;
    atomic_init(&relay->cancelled, 0);
    atomic_init(&relay->failed, 0);
    atomic_init(&relay->stage, IPTVRelayConnectingPlayer);
    atomic_init(&relay->http_status, 0);
    atomic_init(&relay->source_error, 0);
    atomic_init(&relay->network_error, 0);
    relay->client = -1;
    relay->listener = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {
        .sin_len = sizeof(address),
        .sin_family = AF_INET,
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK)
    };
    socklen_t length = sizeof(address);
    if (relay->listener < 0 ||
        bind(relay->listener, (struct sockaddr *)&address, length) < 0 ||
        listen(relay->listener, 1) < 0 ||
        getsockname(relay->listener, (struct sockaddr *)&address, &length) < 0) {
        iptv_relay_destroy(relay);
        return NULL;
    }
    *port = ntohs(address.sin_port);
    return relay;
}

static int ready(IPTVRelay *relay, int fd, short events) {
    struct pollfd descriptor = { .fd = fd, .events = events };
    while (!cancelled(relay)) {
        int result = poll(&descriptor, 1, 200);
        if (result > 0) return (descriptor.revents & events) != 0;
        if (result < 0 && errno != EINTR) return 0;
    }
    return 0;
}

static int write_bytes(void *opaque, const uint8_t *data, int size) {
    IPTVRelay *relay = opaque;
    int offset = 0;
    while (offset < size && ready(relay, relay->client, POLLOUT)) {
        ssize_t count = send(relay->client, data + offset, size - offset, MSG_DONTWAIT);
        if (count < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        if (count <= 0) break;
        offset += (int)count;
    }
    return offset == size ? size : AVERROR(EIO);
}

static int open_client(IPTVRelay *relay, const char *route) {
    if (!ready(relay, relay->listener, POLLIN)) return 0;
    relay->client = accept(relay->listener, NULL, NULL);
    if (relay->client < 0) return 0;
    int one = 1;
    if (setsockopt(relay->client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)) < 0) return 0;

    char request[8192] = {0};
    char expected[128];
    int expected_size = snprintf(expected, sizeof(expected), "GET %s ", route);
    if (expected_size < 0 || expected_size >= sizeof(expected)) return 0;
    size_t size = 0;
    while (size < sizeof(request) - 1 && ready(relay, relay->client, POLLIN)) {
        ssize_t count = recv(relay->client, request + size, sizeof(request) - 1 - size, MSG_DONTWAIT);
        if (count < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        if (count <= 0) return 0;
        size += (size_t)count;
        if (strstr(request, "\r\n\r\n")) return strncmp(request, expected, (size_t)expected_size) == 0;
    }
    return 0;
}

typedef struct {
    const AVClass *class;
    char *location;
    IPTVHTTPResponse response;
    int64_t position;
} SourceBuffer;

static const AVOption source_options[] = {
    { "location", "Effective HTTP URL", offsetof(SourceBuffer, location), AV_OPT_TYPE_STRING, { .str = NULL } },
    { NULL }
};

static const AVClass source_class = {
    .class_name = "IPTV HTTP response",
    .item_name = av_default_item_name,
    .option = source_options,
    .version = LIBAVUTIL_VERSION_INT
};

static void *source_child(void *object, void *previous) {
    return previous ? NULL : ((AVIOContext *)object)->opaque;
}

static const AVClass source_io_class = {
    .class_name = "IPTV HTTP input",
    .item_name = av_default_item_name,
    .version = LIBAVUTIL_VERSION_INT,
    .child_next = source_child
};

static int read_source(void *opaque, uint8_t *buffer, int size) {
    SourceBuffer *source = opaque;
    int64_t remaining = (int64_t)source->response.length - source->position;
    if (remaining <= 0) return AVERROR_EOF;
    if (remaining < size) size = (int)remaining;
    memcpy(buffer, source->response.bytes + source->position, size);
    source->position += size;
    return size;
}

static int64_t seek_source(void *opaque, int64_t offset, int whence) {
    SourceBuffer *source = opaque;
    int64_t length = (int64_t)source->response.length;
    if (whence == AVSEEK_SIZE) return length;
    if (whence != SEEK_SET || offset < 0 || offset > length) return AVERROR(EINVAL);
    return source->position = offset;
}

static int close_source(AVFormatContext *context, AVIOContext *io) {
    (void)context;
    SourceBuffer *source = io->opaque;
    iptv_http_release(&source->response);
    av_free(source);
    av_freep(&io->buffer);
    avio_context_free(&io);
    return 0;
}

static int open_source(AVFormatContext *context, AVIOContext **io, const char *url,
                       int flags, AVDictionary **options) {
    IPTVRelay *relay = context->opaque;
    if (!(flags & AVIO_FLAG_READ) || (strncasecmp(url, "https://", 8) && strncasecmp(url, "http://", 7))) {
        return AVERROR(EINVAL);
    }
    const AVDictionaryEntry *offset = av_dict_get(*options, "offset", NULL, 0);
    const AVDictionaryEntry *end = av_dict_get(*options, "end_offset", NULL, 0);
    IPTVHTTPResponse response = iptv_http_fetch(relay->transport, url, relay->user_agent,
        offset ? strtoll(offset->value, NULL, 10) : 0, end ? strtoll(end->value, NULL, 10) : 0,
        cancelled, relay);
    if (!response.body) {
        atomic_store(&relay->stage, strcmp(url, relay->manifest_url) == 0
                     ? IPTVRelayOpeningManifest : IPTVRelayReadingMedia);
        atomic_store(&relay->http_status, response.status >= 300 ? response.status : 0);
        atomic_store(&relay->network_error, response.error);
        atomic_store(&relay->source_error, 1);
        return AVERROR(EIO);
    }
    SourceBuffer *source = av_mallocz(sizeof(*source));
    uint8_t *buffer = av_malloc(32768);
    if (source && buffer) {
        source->class = &source_class;
        source->location = response.location;
        source->response = response;
        *io = avio_alloc_context(buffer, 32768, 0, source, read_source, NULL, seek_source);
        if (*io) {
            (*io)->av_class = &source_io_class;
            return 0;
        }
    }
    av_free(buffer);
    av_free(source);
    iptv_http_release(&response);
    return AVERROR(ENOMEM);
}

static void begin_stage(IPTVRelay *relay, IPTVRelayStage stage) {
    atomic_store(&relay->http_status, 0);
    atomic_store(&relay->source_error, 0);
    atomic_store(&relay->network_error, 0);
    atomic_store(&relay->stage, stage);
}

static int validate_video(AVCodecContext *decoder, AVFrame *frame, const AVPacket *packet) {
    if (avcodec_send_packet(decoder, packet) < 0) return -1;
    int result = avcodec_receive_frame(decoder, frame);
    if (result == AVERROR(EAGAIN)) return 0;
    if (result < 0 || frame->decode_error_flags || (frame->flags & AV_FRAME_FLAG_CORRUPT)) return -1;
    return 1;
}

static int write_packet(AVFormatContext *input, AVFormatContext *output,
                        AVPacket *packet, int video, int audio) {
    int source = packet->stream_index;
    int destination = source == video ? 0 : source == audio ? 1 : -1;
    if (destination < 0) return 0;
    av_packet_rescale_ts(packet, input->streams[source]->time_base,
                         output->streams[destination]->time_base);
    packet->stream_index = destination;
    packet->pos = -1;
    return av_interleaved_write_frame(output, packet);
}

void iptv_relay_run(IPTVRelay *relay, const char *route, const char *path, const char *keys, const char *user_agent) {
    AVFormatContext *input = NULL, *output = NULL;
    AVCodecContext *decoder = NULL;
    AVFrame *frame = NULL;
    AVPacket *packet = NULL;
    AVDictionary *options = NULL;
    AVIOContext *io = NULL;
    enum { max_pending = 128 };
    AVPacket *pending[max_pending] = {0};
    int queued = 0, verified = 0, ok = 0;
    int video, audio;
    const AVCodec *codec = NULL;
    av_log_set_level(AV_LOG_QUIET);
    if (!open_client(relay, route)) goto cleanup;

    input = avformat_alloc_context();
    if (!input) goto cleanup;
    relay->manifest_url = path;
    relay->user_agent = user_agent;
    relay->transport = iptv_http_create();
    if (!relay->transport) goto cleanup;
    input->opaque = relay;
    input->io_open = open_source;
    input->io_close2 = close_source;
    input->interrupt_callback = (AVIOInterruptCB){ cancelled, relay };
    av_dict_set(&options, "protocol_whitelist", "http,https,tcp,tls", 0);
    av_dict_set(&options, "cenc_decryption_keys", keys, 0);
    const AVInputFormat *dash = av_find_input_format("dash");
    begin_stage(relay, IPTVRelayOpeningManifest);
    if (!dash || avformat_open_input(&input, path, dash, &options) < 0 ||
        av_dict_get(options, "cenc_decryption_keys", NULL, 0)) goto cleanup;
    begin_stage(relay, IPTVRelayReadingMedia);
    if (avformat_find_stream_info(input, NULL) < 0) goto cleanup;

    if (!atomic_load(&relay->source_error)) begin_stage(relay, IPTVRelaySelectingVideo);
    video = av_find_best_stream(input, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (video < 0 || !codec) goto cleanup;
    audio = av_find_best_stream(input, AVMEDIA_TYPE_AUDIO, -1, video, NULL, 0);
    decoder = avcodec_alloc_context3(codec);
    frame = av_frame_alloc();
    packet = av_packet_alloc();
    if (!decoder || !frame || !packet ||
        avcodec_parameters_to_context(decoder, input->streams[video]->codecpar) < 0) goto cleanup;
    decoder->err_recognition = AV_EF_EXPLODE | AV_EF_BITSTREAM;
    decoder->thread_count = 1;
    if (avcodec_open2(decoder, codec, NULL) < 0) goto cleanup;

    // Validate decoded video before telling the player this stream opened.
    if (!atomic_load(&relay->source_error)) begin_stage(relay, IPTVRelayCheckingVideo);
    while (!cancelled(relay) && queued < max_pending && av_read_frame(input, packet) >= 0) {
        if (packet->stream_index == video || packet->stream_index == audio) {
            int result = packet->stream_index == video ? validate_video(decoder, frame, packet) : 0;
            if (result < 0) goto cleanup;
            pending[queued] = av_packet_clone(packet);
            if (!pending[queued++]) goto cleanup;
            verified = result > 0;
        }
        av_packet_unref(packet);
        if (verified) break;
    }
    if (!verified) goto cleanup;

    begin_stage(relay, IPTVRelaySendingVideo);
    if (avformat_alloc_output_context2(&output, NULL, "mpegts", NULL) < 0) goto cleanup;
    int selected[] = { video, audio };
    for (int i = 0; i < 2 && selected[i] >= 0; i++) {
        AVStream *stream = avformat_new_stream(output, NULL);
        AVStream *source = input->streams[selected[i]];
        if (!stream || avcodec_parameters_copy(stream->codecpar, source->codecpar) < 0) goto cleanup;
        stream->codecpar->codec_tag = 0;
        stream->time_base = source->time_base;
    }
    const int buffer_size = 32768;
    uint8_t *buffer = av_malloc(buffer_size);
    if (!buffer) goto cleanup;
    io = avio_alloc_context(buffer, buffer_size, 1, relay, NULL, write_bytes, NULL);
    if (!io) { av_free(buffer); goto cleanup; }
    output->pb = io;
    output->flags |= AVFMT_FLAG_CUSTOM_IO;

    const char response[] = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
    if (write_bytes(relay, (const uint8_t *)response, sizeof(response) - 1) < 0) goto cleanup;
    if (avformat_write_header(output, NULL) < 0) goto cleanup;
    for (int i = 0; i < queued; i++) {
        if (write_packet(input, output, pending[i], video, audio) < 0) goto cleanup;
    }
    int read_result = AVERROR_EOF;
    while (!cancelled(relay) && (read_result = av_read_frame(input, packet)) >= 0) {
        if (write_packet(input, output, packet, video, audio) < 0) goto cleanup;
        av_packet_unref(packet);
    }
    if (cancelled(relay) || read_result == AVERROR_EOF) ok = av_write_trailer(output) >= 0;

cleanup:
    if (!ok && !cancelled(relay)) atomic_store(&relay->failed, 1);
    if (relay->client >= 0) {
        close(relay->client);
        relay->client = -1;
    }
    for (int i = 0; i < queued; i++) av_packet_free(&pending[i]);
    av_dict_free(&options);
    av_packet_free(&packet);
    av_frame_free(&frame);
    avcodec_free_context(&decoder);
    avformat_close_input(&input);
    if (relay->transport) iptv_http_destroy(relay->transport);
    avformat_free_context(output);
    if (io) {
        av_freep(&io->buffer);
        avio_context_free(&io);
    }
}

IPTVRelayStatus iptv_relay_status(IPTVRelay *relay) {
    int failed = atomic_load(&relay->failed);
    return (IPTVRelayStatus) {
        .stage = atomic_load(&relay->stage),
        .failed = failed,
        .http_status = atomic_load(&relay->http_status),
        .source_error = atomic_load(&relay->source_error),
        .network_error = atomic_load(&relay->network_error)
    };
}
void iptv_relay_cancel(IPTVRelay *relay) { atomic_store(&relay->cancelled, 1); }

void iptv_relay_destroy(IPTVRelay *relay) {
    if (relay->client >= 0) close(relay->client);
    if (relay->listener >= 0) close(relay->listener);
    free(relay);
}

