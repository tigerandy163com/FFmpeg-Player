//
//  FFMovie.m
//  FFMPEGDemo
//
//  Created by mm-cy on 2018/9/6.
//  Copyright © 2018年 mm-cy. All rights reserved.
//

#import "FFMovie.h"

@interface FFMovie ()
@property(nonatomic, copy) NSString *currentPath;
@property(nonatomic, strong) UIImage *currentImage;
@property(nonatomic, assign) double currentTime;

@end

@implementation FFMovie {
    AVFormatContext *SJFormatCtx;
    AVCodecContext *SJCodecCtx;
    AVFrame *src_frame;
    AVFrame *dst_frame;
    AVStream *stream;
    AVPacket packet;
    int videoStream;
    double fps;
    BOOL isReleaseResources;
    BOOL inBuffer_;
}

#pragma mark ------------------------------------
#pragma mark  初始化

- (instancetype)initWithVideo:(NSString *)moviePath {

    if (!(self = [super init])) return nil;
    if ([self initializeResources:[moviePath UTF8String]]) {
        self.currentPath = [moviePath copy];
        return self;
    } else {
        return nil;
    }
}

- (BOOL)initializeResources:(const char *)filePath {
    inBuffer_ = NO;
    _currentImage = nil;
    isReleaseResources = NO;
    AVCodec *pCodec;
    // 注册所有解码器
    avcodec_register_all();
    av_register_all();
    avformat_network_init();
    // 打开视频文件
    if (avformat_open_input(&SJFormatCtx, filePath, NULL, NULL) != 0) {
        NSLog(@"打开文件失败");
        goto initError;
    }
    // 检查数据流
    if (avformat_find_stream_info(SJFormatCtx, NULL) < 0) {
        NSLog(@"检查数据流失败");
        goto initError;
    }
    // 根据数据流,找到第一个视频流
    if ((videoStream = av_find_best_stream(SJFormatCtx, AVMEDIA_TYPE_VIDEO, -1, -1, &pCodec, 0)) < 0) {
        NSLog(@"没有找到第一个视频流");
        goto initError;
    }
    // 获取视频流的编解码上下文的指针
    stream = SJFormatCtx->streams[videoStream];
    SJCodecCtx = avcodec_alloc_context3(NULL);
    if (!SJCodecCtx)
        return AVERROR(ENOMEM);
    avcodec_parameters_to_context(SJCodecCtx, stream->codecpar);
#if DEBUG
    // 打印视频流的详细信息
    av_dump_format(SJFormatCtx, videoStream, filePath, 0);
#endif
    if (stream->avg_frame_rate.den && stream->avg_frame_rate.num) {
        fps = av_q2d(stream->avg_frame_rate);
    } else {fps = 30;}
    // 查找解码器
    pCodec = avcodec_find_decoder(SJCodecCtx->codec_id);
    if (pCodec == NULL) {
        NSLog(@"没有找到解码器");
        goto initError;
    }
    // 打开解码器
    if (avcodec_open2(SJCodecCtx, pCodec, NULL) < 0) {
        NSLog(@"打开解码器失败");
        goto initError;
    }
    // 分配视频帧
    src_frame = av_frame_alloc();
    _outputWidth = SJCodecCtx->width;
    _outputHeight = SJCodecCtx->height;
    dst_frame = av_frame_alloc();
    dst_frame->format = AV_PIX_FMT_RGB24;
    dst_frame->width = _outputWidth;
    dst_frame->height = _outputHeight;

    return YES;
    initError:
    return NO;
}

- (void)seekTime:(double)seconds {
    if (isReleaseResources) {
        return;
    }
    AVRational timeBase = SJFormatCtx->streams[videoStream]->time_base;
    int64_t targetFrame = (int64_t) ((double) timeBase.den / timeBase.num * seconds);
    avformat_seek_file(SJFormatCtx,
            videoStream,
            0,
            targetFrame,
            targetFrame,
            AVSEEK_FLAG_FRAME);
    avcodec_flush_buffers(SJCodecCtx);
}

- (BOOL)stepFrame {
    int frameFinished = 0;
    inBuffer_ = NO;
    av_packet_unref(&packet);

    while (!frameFinished && av_read_frame(SJFormatCtx, &packet) >= 0) {
        if (packet.stream_index == videoStream) {
            if (avcodec_send_packet(SJCodecCtx, &packet) == 0) {
                if (0 == avcodec_receive_frame(SJCodecCtx, src_frame)) {
                    frameFinished = 1;
                    [self imageFromAVPicture];
                    inBuffer_ = YES;
                }
            }
        } else {
            av_packet_unref(&packet);
        }
    }
    if (frameFinished == 0 && isReleaseResources == NO) {
        [self releaseResources];
    }
    return frameFinished != 0;
}

- (void)replaceTheResources:(NSString *)moviePath {
    if (!isReleaseResources) {
        [self releaseResources];
    }
    self.currentPath = [moviePath copy];
    [self initializeResources:[moviePath UTF8String]];
}

- (void)redialPlay {
    if (!isReleaseResources) {
        [self releaseResources];
    }
    [self initializeResources:[self.currentPath UTF8String]];
}

#pragma mark ------------------------------------
#pragma mark  重写属性访问方法

- (void)setOutputWidth:(int)newValue {
    if (_outputWidth == newValue) return;
    _outputWidth = newValue;
    dst_frame->width = _outputWidth;
}

- (void)setOutputHeight:(int)newValue {
    if (_outputHeight == newValue) return;
    _outputHeight = newValue;
    dst_frame->height = _outputHeight;
}

- (double)duration {
    return (double) SJFormatCtx->duration / AV_TIME_BASE;
}

- (double)currentTime {
    AVRational timeBase = SJFormatCtx->streams[videoStream]->time_base;
    return packet.pts * timeBase.num / timeBase.den;
}

- (int)sourceWidth {
    return SJCodecCtx->width;
}

- (int)sourceHeight {
    return SJCodecCtx->height;
}

- (double)fps {
    return fps;
}

#pragma mark --------------------------
#pragma mark - 内部方法

- (void)imageFromAVPicture {
    if (_currentImage && inBuffer_) {
        return;
    }
    _currentImage = nil;
    av_freep(dst_frame->data);
    av_image_alloc(dst_frame->data, dst_frame->linesize, dst_frame->width, dst_frame->height, dst_frame->format, 1);
    struct SwsContext *imgConvertCtx = sws_getContext(src_frame->width,
            src_frame->height,
            src_frame->format,
            dst_frame->width,
            dst_frame->height,
            dst_frame->format,
            SWS_FAST_BILINEAR,
            NULL,
            NULL,
            NULL);
    if (imgConvertCtx == nil) return;
    sws_scale(imgConvertCtx,
            (const uint8_t *const *) src_frame->data,
            src_frame->linesize,
            0,
            src_frame->height,
            dst_frame->data,
            dst_frame->linesize);

    sws_freeContext(imgConvertCtx);

    CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault;
    CFDataRef data = CFDataCreate(kCFAllocatorDefault,
            dst_frame->data[0],
            dst_frame->linesize[0] * dst_frame->height);

    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGImageRef cgImage = CGImageCreate(dst_frame->width,
            dst_frame->height,
            8,
            24,
            dst_frame->linesize[0],
            colorSpace,
            bitmapInfo,
            provider,
            NULL,
            NO,
            kCGRenderingIntentDefault);
    UIImage * image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    CFRelease(data);
    _currentImage = image;
}

#pragma mark --------------------------
#pragma mark - 释放资源

- (void)releaseResources {
    NSLog(@"释放资源");
    isReleaseResources = YES;

    // 释放frame
    av_packet_unref(&packet);
    // 释放YUV frame
    av_free(src_frame);
    av_free(dst_frame);

    // 关闭解码器
    if (SJCodecCtx) avcodec_close(SJCodecCtx);
    // 关闭文件
    if (SJFormatCtx) avformat_close_input(&SJFormatCtx);
    avformat_network_deinit();
}

@end
