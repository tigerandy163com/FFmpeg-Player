//
//  FFmpegDecoder.h
//  FFmpegAudioTest
//
//  Created by Pontago on 12/06/17.
//  Copyright (c) 2012年 __MyCompanyName__. All rights reserved.
//

#import <UIKit/UIKit.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
#import <libswscale/swscale.h>
#import <libswresample/swresample.h>

@interface FFAudioDecoder : NSObject {
    AVFormatContext *inputFormatContext_;
    AVCodecContext *audioCodecContext_;
    AVStream *audioStream_;
    AVPacket packet_;
    AVFrame *src_frame;
    SwrContext *m_pAudioSwrContext;

    NSString *inputFilePath_;
    NSInteger decodedDataSize_;
    int audioStreamIndex_;
    void *audioBuffer_;
    NSUInteger audioBufferSize_;
    BOOL inBuffer_;
}
@property(nonatomic) UInt32 audioChannels;
@property(nonatomic) float audioSampleRate;
@property AVCodecContext *audioCodecContext_;
@property uint8_t *audioBuffer_;

- (NSInteger)loadFile:(NSString *)filePath;

- (NSTimeInterval)duration;

- (void)seekTime:(NSTimeInterval)seconds;

- (NSInteger)decode;

- (void)nextPacket;

@end
