#ifndef NIJI_VIDEO_EXPORT_H
#define NIJI_VIDEO_EXPORT_H

// 専用変換ジョブだけを公開し、FFmpegの汎用APIや設定文字列は公開しない。
void *nijineko_video_export_create(void);
void nijineko_video_export_cancel(void *job);
void nijineko_video_export_destroy(void *job);
double nijineko_video_export_progress(void *job);
int nijineko_video_export_mp4(void *job, const char *input, const char *output);

#endif
