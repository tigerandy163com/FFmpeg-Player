//
//  FFmpegDecoder.m
//  FFmpegAudioTest
//
//  Created by Pontago on 12/06/17.
//  Copyright (c) 2012年 __MyCompanyName__. All rights reserved.
//

#import "FFAudioDecoder.h"

#define AVCODEC_MAX_AUDIO_FRAME_SIZE 192000

@implementation FFAudioDecoder

@synthesize audioCodecContext_, audioBuffer_;

- (id)init {
    if (self = [super init]) {
        audioStreamIndex_ = -1;
        audioBufferSize_ = AVCODEC_MAX_AUDIO_FRAME_SIZE;
        audioBuffer_ = av_malloc(audioBufferSize_);
        av_init_packet(&packet_);
    }

    return self;
}

- (void)dealloc {
    if (audioCodecContext_) avcodec_close(audioCodecContext_);
    if (inputFormatContext_) avformat_close_input(&inputFormatContext_);
    av_packet_unref(&packet_);
    av_free(audioBuffer_);
}


- (NSInteger)loadFile:(NSString *)filePath {
    // 注册所有解码器
    avcodec_register_all();
    av_register_all();
    avformat_network_init();

    // 打开视频文件
    if (avformat_open_input(&inputFormatContext_, [filePath UTF8String], NULL, NULL) != 0) {
        NSLog(@"打开文件失败");
        goto initError;
    }
    // 检查数据流
    if (avformat_find_stream_info(inputFormatContext_, NULL) < 0) {
        NSLog(@"检查数据流失败");
        goto initError;
    }
    // 根据数据流,找到第一个视频流
    AVCodec *pCodec;
    if ((audioStreamIndex_ = av_find_best_stream(inputFormatContext_, AVMEDIA_TYPE_AUDIO, -1, -1, &pCodec, 0)) < 0) {
        NSLog(@"没有找到第一个音频流");
        goto initError;
    }
    {
        audioStream_ = inputFormatContext_->streams[audioStreamIndex_];
        audioCodecContext_ = avcodec_alloc_context3(pCodec);
        if (!audioCodecContext_)
            return AVERROR(ENOMEM);
        avcodec_parameters_to_context(audioCodecContext_, audioStream_->codecpar);
#if DEBUG
        // 打印视频流的详细信息
        av_dump_format(inputFormatContext_, audioStreamIndex_, [filePath UTF8String], 0);
#endif
        AVCodec *codec = avcodec_find_decoder(audioCodecContext_->codec_id);
        if (codec == NULL) {
            NSLog(@"Not found audio codec.");
            return -4;
        }
        if (avcodec_open2(audioCodecContext_, codec, NULL) < 0) {
            NSLog(@"Could not open audio codec.");
            return -5;
        }
    }

    inputFilePath_ = filePath;

    src_frame = av_frame_alloc();
    m_pAudioSwrContext = swr_alloc_set_opts(NULL,
            av_get_default_channel_layout(_audioChannels),
            AV_SAMPLE_FMT_S16,
            _audioSampleRate,
            av_get_default_channel_layout(audioCodecContext_->channels),
            audioCodecContext_->sample_fmt,
            audioCodecContext_->sample_rate,
            0,
            NULL);
    swr_init(m_pAudioSwrContext);
    return 0;
    initError:
    return NO;
}

- (NSTimeInterval)duration {
    return inputFormatContext_ == NULL ?
            0.0f : (NSTimeInterval) inputFormatContext_->duration / AV_TIME_BASE;
}

- (void)seekTime:(NSTimeInterval)seconds {
    av_packet_unref(&packet_);
    av_seek_frame(inputFormatContext_, -1, seconds * AV_TIME_BASE, 0);
}

- (NSInteger)decode {
    if (inBuffer_) {
        return decodedDataSize_;
    }
    decodedDataSize_ = 0;
    int frameFinished = 0;
    av_packet_unref(&packet_);
    while (!frameFinished && av_read_frame(inputFormatContext_, &packet_) >= 0) {
        if (packet_.stream_index == audioStreamIndex_) {
            if (avcodec_send_packet(audioCodecContext_, &packet_) == 0) {
                if (0 == avcodec_receive_frame(audioCodecContext_, src_frame)) {
                    void **swrbuf = &audioBuffer_;

                    const float sampleRate = _audioSampleRate;
                    const UInt32 channels = _audioChannels;

                    NSInteger samplesPerChannel = 0;
                    if (m_pAudioSwrContext != NULL && swrbuf != NULL) {
                        float sampleRatio = sampleRate / audioCodecContext_->sample_rate;
                        float channelRatio = channels / audioCodecContext_->channels;
                        float ratio = sampleRatio * MAX(1, channelRatio);
                        int samples = src_frame->nb_samples * ratio;
                        int bufsize = av_samples_get_buffer_size(NULL,
                                channels,
                                samples,
                                AV_SAMPLE_FMT_S16,
                                1);
                        if (*swrbuf == NULL || decodedDataSize_ < bufsize) {
                            decodedDataSize_ = bufsize;
                            *swrbuf = realloc(*swrbuf, decodedDataSize_);
                        }

                        Byte *o[2] = {*swrbuf, 0};
                        samplesPerChannel = swr_convert(m_pAudioSwrContext, o, samples, (const uint8_t **) src_frame->data, src_frame->nb_samples);
                        if (samplesPerChannel < 0) {
                            NSLog(@"failed to resample audio");
                            return 0;
                        }
                        inBuffer_ = YES;
                        audioBuffer_ = *swrbuf;

                    }
                    frameFinished = 1;
                }
            }
        } else {
            av_packet_unref(&packet_);
        }
    }

    return decodedDataSize_;
}

- (void)nextPacket {
    inBuffer_ = NO;
}

@end
