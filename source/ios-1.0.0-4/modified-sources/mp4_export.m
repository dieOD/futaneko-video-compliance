// 検査済みのローカル動画だけをAppleのH.264/AAC MP4へ変換する。
// FFmpegは既存の復号専用構成のまま。CLI・任意オプション・ネットワークなし。
#import <AVFoundation/AVFoundation.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#ifndef NIJI_EXPORT_MAX_SECONDS
#define NIJI_EXPORT_MAX_SECONDS 1200
#endif
#ifndef NIJI_EXPORT_MAX_DIMENSION
#define NIJI_EXPORT_MAX_DIMENSION 4096
#endif
#ifndef NIJI_EXPORT_MAX_OUTPUT_BYTES
#define NIJI_EXPORT_MAX_OUTPUT_BYTES (500LL * 1024 * 1024)
#endif

typedef struct {
    atomic_bool cancelled;
    atomic_uint progress;
    double deadline;
} ExportJob;

void *nijineko_video_export_create(void) {
    ExportJob *job = calloc(1, sizeof(*job));
    if (job) { atomic_init(&job->cancelled, false); atomic_init(&job->progress, 0); }
    return job;
}
void nijineko_video_export_cancel(void *opaque) {
    if (opaque) atomic_store(&((ExportJob *)opaque)->cancelled, true);
}
double nijineko_video_export_progress(void *opaque) {
    return opaque ? atomic_load(&((ExportJob *)opaque)->progress) / 10000.0 : 0;
}
void nijineko_video_export_destroy(void *opaque) { free(opaque); }
static int interrupted(void *opaque) {
    ExportJob *job = opaque;
    return atomic_load(&job->cancelled) ||
           [NSDate timeIntervalSinceReferenceDate] > job->deadline;
}
static BOOL ready(AVAssetWriterInput *input, AVAssetWriter *writer, ExportJob *job) {
    while (!input.readyForMoreMediaData) {
        if (interrupted(job) || writer.status != AVAssetWriterStatusWriting) return NO;
        usleep(2000);
    }
    return !interrupted(job);
}
static AVCodecContext *decoder(AVStream *stream) {
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) return NULL;
    AVCodecContext *context = avcodec_alloc_context3(codec);
    if (!context) return NULL;
    context->max_pixels = 4096 * 4096;
    context->thread_count = 2;
    if (avcodec_parameters_to_context(context, stream->codecpar) < 0 ||
        avcodec_open2(context, codec, NULL) < 0) avcodec_free_context(&context);
    return context;
}
static BOOL video_frame(AVFrame *frame, AVStream *stream,
                        AVAssetWriterInput *input,
                        AVAssetWriterInputPixelBufferAdaptor *adaptor,
                        AVAssetWriter *writer, ExportJob *job,
                        struct SwsContext **scale, double origin,
                        double *last, int width, int height) {
    if (frame->width != width || frame->height != height ||
        frame->best_effort_timestamp == AV_NOPTS_VALUE) return NO;
    double time = frame->best_effort_timestamp * av_q2d(stream->time_base) - origin;
    if (!isfinite(time) || time < -0.1 || time > NIJI_EXPORT_MAX_SECONDS || time <= *last) return NO;
    time = MAX(time, 0);
    if (!ready(input, writer, job)) return NO;
    CVPixelBufferRef pixel = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &pixel) != kCVReturnSuccess) return NO;
    CVPixelBufferLockBaseAddress(pixel, 0);
    *scale = sws_getCachedContext(*scale, width, height, frame->format,
                                width, height, AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL);
    uint8_t *planes[] = {CVPixelBufferGetBaseAddress(pixel), NULL, NULL, NULL};
    int strides[] = {(int)CVPixelBufferGetBytesPerRow(pixel), 0, 0, 0};
    BOOL success = *scale && sws_scale(*scale, (const uint8_t *const *)frame->data,
                                     frame->linesize, 0, height, planes, strides) == height;
    CVPixelBufferUnlockBaseAddress(pixel, 0);
    if (success) success = [adaptor appendPixelBuffer:pixel withPresentationTime:CMTimeMakeWithSeconds(time, 1000000)];
    CVPixelBufferRelease(pixel);
    *last = time;
    return success;
}
static BOOL audio_frame(AVFrame *frame, AVStream *stream,
                        AVAssetWriterInput *input, AVAssetWriter *writer,
                        ExportJob *job, SwrContext **resampler, double origin,
                        double *last, int sampleRate, int channels,
                        int *sampleFormat, AVChannelLayout *sampleLayout) {
    if (frame->sample_rate != sampleRate || frame->ch_layout.nb_channels != channels ||
        frame->nb_samples <= 0 || frame->nb_samples > 65536 ||
        frame->best_effort_timestamp == AV_NOPTS_VALUE) return NO;
    double time = frame->best_effort_timestamp * av_q2d(stream->time_base) - origin;
    // Opusのcodec delay等による先頭の負の時刻は0へ揃える。
    time = MAX(time, 0);
    if (!isfinite(time) || time > NIJI_EXPORT_MAX_SECONDS || time < *last) return NO;
    if (*sampleFormat >= 0 && (*sampleFormat != frame->format ||
        av_channel_layout_compare(sampleLayout, &frame->ch_layout) != 0)) return NO;
    if (!*resampler) {
        AVChannelLayout output;
        av_channel_layout_default(&output, channels);
        int result = swr_alloc_set_opts2(resampler, &output, AV_SAMPLE_FMT_FLT,
                                        sampleRate, &frame->ch_layout, frame->format,
                                        sampleRate, 0, NULL);
        av_channel_layout_uninit(&output);
        if (result < 0 || swr_init(*resampler) < 0) return NO;
        if (av_channel_layout_copy(sampleLayout, &frame->ch_layout) < 0) return NO;
        *sampleFormat = frame->format;
    }
    size_t size = (size_t)frame->nb_samples * channels * sizeof(float);
    CMBlockBufferRef block = NULL;
    CMAudioFormatDescriptionRef description = NULL;
    CMSampleBufferRef sample = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(NULL, NULL, size, NULL, NULL, 0, size,
                                         kCMBlockBufferAssureMemoryNowFlag, &block)) return NO;
    char *data = NULL;
    BOOL success = CMBlockBufferGetDataPointer(block, 0, NULL, NULL, &data) == noErr;
    uint8_t *output[] = {(uint8_t *)data};
    int count = success ? swr_convert(*resampler, output, frame->nb_samples,
                                      (const uint8_t **)frame->extended_data,
                                      frame->nb_samples) : -1;
    if (count != frame->nb_samples) success = NO;
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = format.mBytesPerFrame = channels * sizeof(float);
    format.mFramesPerPacket = 1; format.mChannelsPerFrame = channels; format.mBitsPerChannel = 32;
    if (success) success = CMAudioFormatDescriptionCreate(NULL, &format, 0, NULL, 0, NULL, NULL, &description) == noErr;
    if (success) success = CMAudioSampleBufferCreateReadyWithPacketDescriptions(NULL, block,
        description, count, CMTimeMakeWithSeconds(time, sampleRate), NULL, &sample) == noErr;
    if (success) success = ready(input, writer, job) && [input appendSampleBuffer:sample];
    if (sample) CFRelease(sample);
    if (description) CFRelease(description);
    CFRelease(block);
    *last = time;
    return success;
}

// 0=成功、1=中止、2=入力/形式、3=出力、4=上限。元ファイルは変更しない。
int nijineko_video_export_mp4(void *opaque, const char *source, const char *destination) {
    if (!opaque || !source || !destination) return 2;
    ExportJob *job = opaque;
    job->deadline = [NSDate timeIntervalSinceReferenceDate] + 300;
    struct stat info;
    if (lstat(source, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0 ||
        info.st_size > 100 * 1024 * 1024 || lstat(destination, &info) == 0) return 2;
    @autoreleasepool {
        int result = 2;
        AVFormatContext *format = avformat_alloc_context();
        AVCodecContext *video = NULL, *audio = NULL;
        AVPacket *packet = NULL; AVFrame *frame = NULL;
        struct SwsContext *scale = NULL; SwrContext *resampler = NULL;
        AVAssetWriter *writer = nil;
        AVAssetWriterInput *videoInput = nil, *audioInput = nil;
        AVAssetWriterInputPixelBufferAdaptor *adaptor = nil;
        dispatch_semaphore_t finished = NULL;
        int sampleFormat = -1;
        AVChannelLayout sampleLayout = {0};
        if (!format) return 2;
        format->interrupt_callback = (AVIOInterruptCB){interrupted, job};
        format->probesize = 4 * 1024 * 1024;
        format->max_streams = 16;
        format->max_analyze_duration = 5 * AV_TIME_BASE;
        AVDictionary *options = NULL;
        av_dict_set(&options, "protocol_whitelist", "file", 0);
        av_dict_set(&options, "format_whitelist", "matroska,mov", 0);
        int opened = avformat_open_input(&format, source, NULL, &options);
        av_dict_free(&options);
        if (opened < 0) goto cleanup;
        AVDictionary **probeOptions = calloc(format->nb_streams, sizeof(*probeOptions));
        unsigned int probeStreams = format->nb_streams;
        if (!probeOptions) goto cleanup;
        for (unsigned int index = 0; index < probeStreams; index++) {
            av_dict_set(&probeOptions[index], "max_pixels", "16777216", 0);
            av_dict_set(&probeOptions[index], "threads", "2", 0);
        }
        int probed = avformat_find_stream_info(format, probeOptions);
        for (unsigned int index = 0; index < probeStreams; index++) av_dict_free(&probeOptions[index]);
        free(probeOptions);
        if (probed < 0) goto cleanup;
        if (format->duration > NIJI_EXPORT_MAX_SECONDS * (double)AV_TIME_BASE || format->nb_streams > 16) { result = 4; goto cleanup; }
        int vi = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
        int ai = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
        if (vi < 0 || !(video = decoder(format->streams[vi]))) goto cleanup;
        if (ai >= 0 && !(audio = decoder(format->streams[ai]))) goto cleanup;
        int width = video->width, height = video->height;
        const int sampleRate = audio ? audio->sample_rate : 0;
        const int channels = audio ? audio->ch_layout.nb_channels : 0;
        if (width <= 0 || height <= 0 || width > NIJI_EXPORT_MAX_DIMENSION || height > NIJI_EXPORT_MAX_DIMENSION ||
            (audio && (audio->sample_rate < 8000 || audio->sample_rate > 96000 ||
                       audio->ch_layout.nb_channels < 1 || audio->ch_layout.nb_channels > 2))) { result = 4; goto cleanup; }
        NSError *error = nil;
        writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:@(destination)]
                                          fileType:AVFileTypeMPEG4 error:&error];
        if (!writer) { result = 3; goto cleanup; }
        writer.shouldOptimizeForNetworkUse = YES;
        videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
            AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @(width), AVVideoHeightKey: @(height),
            AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(MIN(12000000, MAX(1000000, width * height * 4)))} }];
        // 回転情報を持つ入力はAVAssetWriter側へ引き継ぐ。
        const AVPacketSideData *rotation = av_packet_side_data_get(format->streams[vi]->codecpar->coded_side_data,
            format->streams[vi]->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
        if (rotation && rotation->size >= 9 * sizeof(int32_t)) {
            double angle = av_display_rotation_get((const int32_t *)rotation->data);
            if (isfinite(angle)) videoInput.transform = CGAffineTransformMakeRotation(-angle * M_PI / 180.0);
        }
        if (![writer canAddInput:videoInput]) { result = 3; goto cleanup; }
        [writer addInput:videoInput];
        adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:videoInput
            sourcePixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferWidthKey:@(width), (id)kCVPixelBufferHeightKey:@(height),
                (id)kCVPixelBufferIOSurfacePropertiesKey:@{}}];
        if (audio) {
            audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:@{
                AVFormatIDKey:@(kAudioFormatMPEG4AAC), AVSampleRateKey:@(audio->sample_rate),
                AVNumberOfChannelsKey:@(audio->ch_layout.nb_channels), AVEncoderBitRateKey:@(128000)}];
            if (![writer canAddInput:audioInput]) { result = 3; goto cleanup; }
            [writer addInput:audioInput];
        }
        if (![writer startWriting]) { result = 3; goto cleanup; }
        [writer startSessionAtSourceTime:kCMTimeZero];
        packet = av_packet_alloc(); frame = av_frame_alloc();
        if (!packet || !frame) goto cleanup;
        double origin = format->start_time == AV_NOPTS_VALUE ? 0 : format->start_time / (double)AV_TIME_BASE;
        double lastVideo = -1, lastAudio = -1;
        int readResult;
        while (!interrupted(job) && (readResult = av_read_frame(format, packet)) >= 0) {
            AVCodecContext *codec = packet->stream_index == vi ? video : packet->stream_index == ai ? audio : NULL;
            int index = packet->stream_index;
            if (codec) {
                if (avcodec_send_packet(codec, packet) < 0) goto cleanup;
                int decoded;
                while ((decoded = avcodec_receive_frame(codec, frame)) >= 0) {
                    BOOL ok = index == vi ? video_frame(frame, format->streams[vi], videoInput, adaptor, writer,
                        job, &scale, origin, &lastVideo, width, height) : audio_frame(frame, format->streams[ai],
                        audioInput, writer, job, &resampler, origin, &lastAudio, sampleRate, channels, &sampleFormat, &sampleLayout);
                    av_frame_unref(frame);
                    if (!ok) { result = 3; goto cleanup; }
                }
                if (decoded != AVERROR(EAGAIN) && decoded != AVERROR_EOF) goto cleanup;
            }
            av_packet_unref(packet);
            if (format->duration > 0) atomic_store(&job->progress, (unsigned int)MIN(9900, MAX(0, lastVideo * AV_TIME_BASE / format->duration * 10000)));
            if (!stat(destination, &info) && info.st_size > NIJI_EXPORT_MAX_OUTPUT_BYTES) { result = 4; goto cleanup; }
        }
        if (interrupted(job)) { result = atomic_load(&job->cancelled) ? 1 : 4; goto cleanup; }
        if (readResult != AVERROR_EOF) goto cleanup;
        for (int track = 0; track < (audio ? 2 : 1); track++) {
            AVCodecContext *codec = track ? audio : video;
            if (avcodec_send_packet(codec, NULL) < 0) goto cleanup;
            int decoded;
            while ((decoded = avcodec_receive_frame(codec, frame)) >= 0) {
                BOOL ok = !track ? video_frame(frame, format->streams[vi], videoInput, adaptor, writer,
                    job, &scale, origin, &lastVideo, width, height) : audio_frame(frame, format->streams[ai],
                    audioInput, writer, job, &resampler, origin, &lastAudio, sampleRate, channels, &sampleFormat, &sampleLayout);
                av_frame_unref(frame);
                if (!ok) { result = 3; goto cleanup; }
            }
            if (decoded != AVERROR_EOF) goto cleanup;
        }
        if (lastVideo < 0) goto cleanup;
        [videoInput markAsFinished]; [audioInput markAsFinished];
        finished = dispatch_semaphore_create(0);
        [writer finishWritingWithCompletionHandler:^{dispatch_semaphore_signal(finished);}];
        while (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC))) {
            if (interrupted(job)) { [writer cancelWriting]; result = atomic_load(&job->cancelled) ? 1 : 4; goto cleanup; }
        }
        if (writer.status != AVAssetWriterStatusCompleted || stat(destination, &info) ||
            info.st_size <= 0) { result = 3; goto cleanup; }
        if (info.st_size > NIJI_EXPORT_MAX_OUTPUT_BYTES) { result = 4; goto cleanup; }
        result = 0;
        atomic_store(&job->progress, 10000);
cleanup:
        if (atomic_load(&job->cancelled)) result = 1;
        if (result != 0) { [writer cancelWriting]; unlink(destination); }
        sws_freeContext(scale); swr_free(&resampler);
        av_channel_layout_uninit(&sampleLayout);
        av_frame_free(&frame); av_packet_free(&packet);
        avcodec_free_context(&video); avcodec_free_context(&audio);
        avformat_close_input(&format);
        [writer release];
        if (finished) dispatch_release(finished);
        return result;
    }
}
/*
 * ========================================================================
 * FutaNeko追加部品通知（通知版: 1）
 * 追加部品: mp4_export.m
 * ライセンス: LGPL-2.1-or-later（LGPL2.1+）
 * 作成日: 2026-09-06（20260906）
 * ライセンス根拠: 同梱 LICENSE_SCOPE.ja.md
 * ========================================================================
 */
