// Simulator専用の実形式試験。ネットワーク・写真ライブラリへの書き込みなし。
#import <AVFoundation/AVFoundation.h>
#include <fcntl.h>
#include <unistd.h>
extern void *nijineko_video_export_create(void);
extern void nijineko_video_export_cancel(void *);
extern void nijineko_video_export_destroy(void *);
extern int nijineko_video_export_mp4(void *, const char *, const char *);
#ifndef NIJI_EXPORT_LIMIT_TEST
extern int nijineko_video_encoder_count(void);
extern int nijineko_video_muxer_count(void);
extern int nijineko_video_input_protocol_count(void);
extern int nijineko_video_network_open_is_blocked(void);
#endif

static BOOL inspect(NSString *path, BOOL audioExpected) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    NSArray *videos = [asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray *audios = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (videos.count != 1 || audios.count != (audioExpected ? 1 : 0)) return NO;
    double duration = CMTimeGetSeconds(asset.duration);
    if (duration < 0.8 || duration > 1.3) return NO;
    for (AVAssetTrack *track in [videos arrayByAddingObjectsFromArray:audios]) {
        NSError *error = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        BOOL isVideo = [track.mediaType isEqualToString:AVMediaTypeVideo];
        double start = CMTimeGetSeconds(track.timeRange.start);
        double length = CMTimeGetSeconds(track.timeRange.duration);
        if (start < -0.001 || start > 0.1 || length < 0.8 || length > 1.3) return NO;
        CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
        if (!format || CMFormatDescriptionGetMediaSubType(format) !=
            (isVideo ? kCMVideoCodecType_H264 : kAudioFormatMPEG4AAC)) return NO;
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:isVideo
            ? @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}
            : @{AVFormatIDKey:@(kAudioFormatLinearPCM)}];
        [reader addOutput:output];
        if (![reader startReading]) return NO;
        int count = 0;
        CMSampleBufferRef sample;
        while ((sample = [output copyNextSampleBuffer])) { count++; CFRelease(sample); }
        BOOL passed = reader.status == AVAssetReaderStatusCompleted && count > 0;
        [reader release];
        if (!passed) return NO;
    }
    if (audioExpected) {
        AVAssetTrack *video = videos[0], *audio = audios[0];
        double videoEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(video.timeRange));
        double audioEnd = CMTimeGetSeconds(CMTimeRangeGetEnd(audio.timeRange));
        if (fabs(videoEnd - audioEnd) > 0.15) return NO;
    }
    return YES;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 64;
        NSString *input = @(argv[1]), *output = @(argv[2]);
        NSFileManager *fm = NSFileManager.defaultManager;
#ifdef NIJI_EXPORT_LIMIT_TEST
        NSString *limitedOutput = [output stringByAppendingPathComponent:@"limited.mp4"];
        void *limitedJob = nijineko_video_export_create();
        int limitedResult = nijineko_video_export_mp4(limitedJob,
            [[input stringByAppendingPathComponent:@"webm-vp8-vorbis.webm"] fileSystemRepresentation],
            limitedOutput.fileSystemRepresentation);
        nijineko_video_export_destroy(limitedJob);
        BOOL limited = limitedResult == 4 && ![fm fileExistsAtPath:limitedOutput];
        printf("configured limit: status=%d %s\n", limitedResult, limited ? "PASS" : "FAIL");
        return limited ? 0 : 1;
#endif
        int failed = 0;
#ifndef NIJI_EXPORT_LIMIT_TEST
        BOOL foundation = nijineko_video_encoder_count() == 0 &&
            nijineko_video_muxer_count() == 0 &&
            nijineko_video_input_protocol_count() == 1 &&
            nijineko_video_network_open_is_blocked();
        printf("decoder-only/network boundary: %s\n", foundation ? "PASS" : "FAIL");
        if (!foundation) failed++;
#endif
        NSArray *names = @[@"webm-vp8-vorbis.webm", @"webm-vp9-opus.webm", @"webm-av1-opus.webm", @"mov-h264-aac.mov", @"webm-vp8-silent.webm"];
        for (NSString *name in names) {
            NSString *destination = [output stringByAppendingPathComponent:[name stringByAppendingString:@".mp4"]];
            void *job = nijineko_video_export_create();
            int result = nijineko_video_export_mp4(job, [[input stringByAppendingPathComponent:name] fileSystemRepresentation], destination.fileSystemRepresentation);
            nijineko_video_export_destroy(job);
            BOOL passed = result == 0 && inspect(destination, ![name containsString:@"silent"]);
            printf("%s: status=%d %s\n", name.UTF8String, result, passed ? "PASS" : "FAIL");
            if (!passed) failed++;
        }
        for (NSString *name in @[@"truncated.webm", @"spoofed.mp4", @"external-url.m3u"]) {
            NSString *destination = [output stringByAppendingPathComponent:[name stringByAppendingString:@".mp4"]];
            void *job = nijineko_video_export_create();
            int result = nijineko_video_export_mp4(job, [[input stringByAppendingPathComponent:name] fileSystemRepresentation], destination.fileSystemRepresentation);
            nijineko_video_export_destroy(job);
            BOOL passed = result != 0 && ![fm fileExistsAtPath:destination];
            printf("%s rejection: %s\n", name.UTF8String, passed ? "PASS" : "FAIL");
            if (!passed) failed++;
        }
        NSString *destination = [output stringByAppendingPathComponent:@"cancelled.mp4"];
        void *job = nijineko_video_export_create();
        nijineko_video_export_cancel(job);
        int result = nijineko_video_export_mp4(job, [[input stringByAppendingPathComponent:names[0]] fileSystemRepresentation], destination.fileSystemRepresentation);
        nijineko_video_export_destroy(job);
        BOOL cancelled = result == 1 && ![fm fileExistsAtPath:destination];
        printf("cancel: %s\n", cancelled ? "PASS" : "FAIL");
        if (!cancelled) failed++;
        NSString *activeOutput = [output stringByAppendingPathComponent:@"active-cancel.mp4"];
        void *activeJob = nijineko_video_export_create();
        dispatch_semaphore_t activeDone = dispatch_semaphore_create(0);
        __block int activeResult = -1;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            activeResult = nijineko_video_export_mp4(activeJob,
                [[input stringByAppendingPathComponent:names[0]] fileSystemRepresentation], activeOutput.fileSystemRepresentation);
            dispatch_semaphore_signal(activeDone);
        });
        usleep(5000);
        nijineko_video_export_cancel(activeJob);
        dispatch_semaphore_wait(activeDone, DISPATCH_TIME_FOREVER);
        nijineko_video_export_destroy(activeJob);
        dispatch_release(activeDone);
        BOOL activeCancelled = activeResult == 1 && ![fm fileExistsAtPath:activeOutput];
        printf("active cancel: %s\n", activeCancelled ? "PASS" : "FAIL");
        if (!activeCancelled) failed++;
        NSString *oversized = [output stringByAppendingPathComponent:@"oversized.webm"];
        int fd = open(oversized.fileSystemRepresentation, O_WRONLY|O_CREAT|O_EXCL, 0600);
        if (fd < 0 || ftruncate(fd, 101LL * 1024 * 1024)) return 65;
        close(fd);
        job = nijineko_video_export_create();
        result = nijineko_video_export_mp4(job, oversized.fileSystemRepresentation, destination.fileSystemRepresentation);
        nijineko_video_export_destroy(job);
        BOOL bounded = result != 0 && ![fm fileExistsAtPath:destination];
        printf("size limit: %s\n", bounded ? "PASS" : "FAIL");
        [fm removeItemAtPath:oversized error:nil];
        if (!bounded) failed++;
        return failed ? 1 : 0;
    }
}
