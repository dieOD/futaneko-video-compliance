/*
 * NijiNekoのローカル動画専用libmpvでは字幕とmpv内蔵OSDを使用しない。
 * Flutter側が操作UIを描画するため、libass依存を外したビルド用の安全な
 * no-op実装を提供する。これはmpv 0.41.0のLGPL部分に対する最小変更。
 */

#include <stddef.h>
#include <string.h>

#include "common/msg.h"
#include "misc/bstr.h"
#include "mpv_talloc.h"
#include "options/m_config.h"
#include "options/options.h"
#include "sub/osd.h"
#include "sub/osd_state.h"
#include "sub/sd.h"

const struct m_sub_options mp_sub_filter_opts = {
    .opts = (const struct m_option[]){{0}},
    .size = sizeof(struct mp_sub_filter_opts),
    .defaults = &(const struct mp_sub_filter_opts){0},
    .change_flags = UPDATE_SUB_FILT,
};

static int no_subtitle_init(struct sd *sd)
{
    MP_VERBOSE(sd, "Subtitle decoding is disabled in the NijiNeko build.\n");
    return -1;
}

const struct sd_functions sd_ass = {
    .name = "ass-disabled",
    .init = no_subtitle_init,
};

int sd_ass_fmt_offset(const char *event_format)
{
    int count = 0;
    while (event_format && (event_format = strchr(event_format, ','))) {
        event_format++;
        count++;
    }
    return count - 1;
}

bstr sd_ass_pkt_text(struct sd_filter *filter, struct demux_packet *packet,
                     int offset)
{
    bstr text = {(char *)packet->buffer, packet->len};
    while (offset-- > 0) {
        int comma = bstrchr(text, ',');
        if (comma < 0) {
            MP_WARN(filter, "Malformed disabled subtitle event.\n");
            return (bstr){NULL, 0};
        }
        text = bstr_cut(text, comma + 1);
    }
    return text;
}

bstr sd_ass_to_plaintext(char **out, const char *in)
{
    if (!in) {
        if (out)
            *out = NULL;
        return (bstr){NULL, 0};
    }
    if (*out != in)
        *out = talloc_strdup(NULL, in);
    return bstr0(*out);
}

struct sub_bitmaps *osd_object_get_bitmaps(struct osd_state *osd,
                                           struct osd_object *object,
                                           int format)
{
    return NULL;
}

void osd_destroy_backend(struct osd_state *osd)
{
}

void osd_set_external(struct osd_state *osd, struct osd_external_ass *overlay)
{
}

void osd_set_external_remove_owner(struct osd_state *osd, void *owner)
{
}

void osd_get_text_size(struct osd_state *osd, int *screen_height,
                       int *font_height)
{
    *screen_height = 0;
    *font_height = 0;
}

void osd_get_function_sym(char *buffer, size_t buffer_size, int function)
{
    if (buffer_size)
        buffer[0] = '\0';
}

void osd_mangle_ass(bstr *destination, const char *source,
                    bool replace_newlines)
{
    if (source)
        bstr_xappend(NULL, destination, bstr0(source));
}
/*
 * ========================================================================
 * FutaNeko追加部品通知（通知版: 1）
 * 追加部品: no_subtitles.c
 * ライセンス: LGPL-2.1-or-later（LGPL2.1+）
 * 作成日: 2026-08-31（20260831）
 * ライセンス根拠: 同梱 LICENSE_SCOPE.ja.md
 * ========================================================================
 */
