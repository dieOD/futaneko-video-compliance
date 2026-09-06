/* 最終アプリにリンクされた実体を監査するための読み取り専用API。 */
#include <stdbool.h>
#include <string.h>

#include <dav1d/dav1d.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavfilter/avfilter.h>
#include <libavutil/error.h>
#include <libavutil/avutil.h>
#include <libplacebo/config.h>
#include <mpv/client.h>

extern const char mpv_version[];
struct demuxer_desc;
extern const struct demuxer_desc *const demuxer_list[];

#ifndef NIJINEKO_VIDEO_PATCHSET
#error "NIJINEKO_VIDEO_PATCHSET must be supplied by the reproducible build"
#endif

const char *nijineko_video_mpv_version(void) { return mpv_version; }
const char *nijineko_video_ffmpeg_version(void) { return av_version_info(); }
const char *nijineko_video_ffmpeg_configuration(void) {
    return avformat_configuration();
}
const char *nijineko_video_ffmpeg_license(void) { return avformat_license(); }
const char *nijineko_video_dav1d_version(void) { return dav1d_version(); }
const char *nijineko_video_libplacebo_version(void) { return pl_version(); }
const char *nijineko_video_patchset(void) { return NIJINEKO_VIDEO_PATCHSET; }

int nijineko_video_has_input_protocol(const char *expected) {
    void *opaque = NULL;
    const char *name;
    while ((name = avio_enum_protocols(&opaque, 0))) {
        if (strcmp(name, expected) == 0)
            return 1;
    }
    return 0;
}

int nijineko_video_input_protocol_count(void) {
    void *opaque = NULL;
    int count = 0;
    while (avio_enum_protocols(&opaque, 0))
        count++;
    return count;
}

int nijineko_video_has_demuxer(const char *name) {
    return av_find_input_format(name) != NULL;
}

int nijineko_video_demuxer_count(void) {
    void *opaque = NULL;
    int count = 0;
    while (av_demuxer_iterate(&opaque))
        count++;
    return count;
}

int nijineko_video_has_decoder(const char *name) {
    return avcodec_find_decoder_by_name(name) != NULL;
}

int nijineko_video_decoder_count(void) {
    void *opaque = NULL;
    const AVCodec *codec;
    int count = 0;
    while ((codec = av_codec_iterate(&opaque))) {
        if (av_codec_is_decoder(codec))
            count++;
    }
    return count;
}

int nijineko_video_encoder_count(void) {
    void *opaque = NULL;
    const AVCodec *codec;
    int count = 0;
    while ((codec = av_codec_iterate(&opaque))) {
        if (av_codec_is_encoder(codec))
            count++;
    }
    return count;
}

int nijineko_video_parser_count(void) {
    void *opaque = NULL;
    int count = 0;
    while (av_parser_iterate(&opaque))
        count++;
    return count;
}

int nijineko_video_has_parser(const char *name) {
    const AVCodecDescriptor *descriptor = avcodec_descriptor_get_by_name(name);
    if (!descriptor)
        return 0;
    AVCodecParserContext *parser = av_parser_init(descriptor->id);
    if (!parser)
        return 0;
    av_parser_close(parser);
    return 1;
}

int nijineko_video_bitstream_filter_count(void) {
    void *opaque = NULL;
    int count = 0;
    while (av_bsf_iterate(&opaque))
        count++;
    return count;
}

int nijineko_video_has_bitstream_filter(const char *name) {
    return av_bsf_get_by_name(name) != NULL;
}

int nijineko_video_filter_count(void) {
    void *opaque = NULL;
    int count = 0;
    while (av_filter_iterate(&opaque))
        count++;
    return count;
}

int nijineko_video_has_filter(const char *name) {
    return avfilter_get_by_name(name) != NULL;
}

int nijineko_video_muxer_count(void) {
    void *opaque = NULL;
    int count = 0;
    while (av_muxer_iterate(&opaque))
        count++;
    return count;
}

int nijineko_video_mpv_demuxer_count(void) {
    int count = 0;
    while (demuxer_list[count])
        count++;
    return count;
}

static const char *node_map_string(const mpv_node *map, const char *key) {
    if (!map || map->format != MPV_FORMAT_NODE_MAP || !map->u.list)
        return NULL;
    for (int index = 0; index < map->u.list->num; index++) {
        if (strcmp(map->u.list->keys[index], key) == 0 &&
            map->u.list->values[index].format == MPV_FORMAT_STRING) {
            return map->u.list->values[index].u.string;
        }
    }
    return NULL;
}

int nijineko_video_command_allowlist_is_exact(void) {
    static const char *const expected[] = {
        "ignore",
        "stop",
        "cycle",
        "seek",
        "loadfile",
        "playlist-clear",
        "playlist-remove",
        "playlist-move",
        "playlist-next",
        "playlist-prev",
        "playlist-play-index",
        "playlist-shuffle",
        "playlist-unshuffle",
    };
    bool found[sizeof(expected) / sizeof(expected[0])] = {false};

    mpv_handle *context = mpv_create();
    if (!context)
        return 0;
    mpv_set_option_string(context, "config", "no");
    mpv_set_option_string(context, "load-scripts", "no");
    mpv_set_option_string(context, "input-default-bindings", "no");
    mpv_set_option_string(context, "vo", "null");
    mpv_set_option_string(context, "ao", "null");
    if (mpv_initialize(context) < 0) {
        mpv_destroy(context);
        return 0;
    }

    mpv_node commands = {0};
    bool exact = false;
    int result = mpv_get_property(context, "command-list", MPV_FORMAT_NODE,
                                  &commands);
    if (result >= 0 && commands.format == MPV_FORMAT_NODE_ARRAY &&
        commands.u.list) {
        exact = commands.u.list->num ==
                (int)(sizeof(expected) / sizeof(expected[0]));
        for (int index = 0; index < commands.u.list->num; index++) {
            const char *name = node_map_string(&commands.u.list->values[index],
                                               "name");
            if (!name) {
                exact = false;
                continue;
            }
            bool known = false;
            for (unsigned int allowed = 0;
                 allowed < sizeof(expected) / sizeof(expected[0]); allowed++) {
                if (strcmp(name, expected[allowed]) == 0) {
                    found[allowed] = true;
                    known = true;
                }
            }
            if (!known)
                exact = false;
        }
    }
    for (unsigned int allowed = 0;
         allowed < sizeof(expected) / sizeof(expected[0]); allowed++) {
        if (!found[allowed])
            exact = false;
    }
    if (result >= 0)
        mpv_free_node_contents(&commands);
    mpv_terminate_destroy(context);
    return result >= 0 && exact;
}

int nijineko_video_external_config_is_blocked(void) {
    mpv_handle *context = mpv_create();
    if (!context)
        return 0;
    int result = mpv_load_config_file(
        context, "/private/tmp/nijineko-must-not-read.conf");
    mpv_destroy(context);
    return result == MPV_ERROR_UNSUPPORTED;
}

/*
 * 設定文字列だけでなく、リンク済みFFmpegがHTTPS入力を実際に開けないことを
 * AVERROR_PROTOCOL_NOT_FOUNDまで確認する負の試験。通信は開始されない。
 */
int nijineko_video_network_open_is_blocked(void) {
    AVIOContext *context = NULL;
    int result = avio_open2(&context, "https://127.0.0.1:9/nijineko-negative-test",
                            AVIO_FLAG_READ, NULL, NULL);
    if (context)
        avio_closep(&context);
    return result == AVERROR_PROTOCOL_NOT_FOUND;
}
