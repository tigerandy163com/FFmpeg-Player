//
//  ViewController.m
//  FFmpegAudioTest
//
//  Created by Pontago on 12/06/17.
//  Copyright (c) 2012年 __MyCompanyName__. All rights reserved.
//

#import "AudioManager.h"

@interface AudioManager () {
    NSString *playingFilePath_;
    AudioStreamBasicDescription audioStreamBasicDesc_;
    AudioQueueRef audioQueue_;
    AudioQueueBufferRef audioQueueBuffer_[kNumAQBufs];
    BOOL started_, finished_;
    NSTimeInterval durationTime_, startedTime_;
    NSInteger state_;
    NSTimer *seekTimer_;
    NSLock *decodeLock_;

    FFAudioDecoder *ffmpegDecoder_;
}
- (void)audioQueueOutputCallback:(AudioQueueRef)inAQ inBuffer:(AudioQueueBufferRef)inBuffer;

- (void)audioQueueIsRunningCallback;

@end

void audioQueueOutputCallback(void *inClientData, AudioQueueRef inAQ,
        AudioQueueBufferRef inBuffer);

void audioQueueIsRunningCallback(void *inClientData, AudioQueueRef inAQ,
        AudioQueuePropertyID inID);

void audioQueueOutputCallback(void *inClientData, AudioQueueRef inAQ,
        AudioQueueBufferRef inBuffer) {

    AudioManager *audioManager = (__bridge AudioManager *) inClientData;
    [audioManager audioQueueOutputCallback:inAQ inBuffer:inBuffer];
}

void audioQueueIsRunningCallback(void *inClientData, AudioQueueRef inAQ,
        AudioQueuePropertyID inID) {

    AudioManager *audioManager = (__bridge AudioManager *) inClientData;
    [audioManager audioQueueIsRunningCallback];
}

@implementation AudioManager

- (instancetype)initWith:(NSString *)filePath {
    self = [super init];
    if (self) {
        playingFilePath_ = filePath;
        AVAudioSession *audioSession = [AVAudioSession sharedInstance];
        [audioSession setCategory:AVAudioSessionCategoryPlayback error:nil];
    }
    return self;
}

- (void)dealloc {
    [self removeAudioQueue];
}

- (void)playAudio {
    [self startAudio_];
}

- (void)pauseAudio {
    if (started_) {
        state_ = AUDIO_STATE_PAUSE;

        AudioQueuePause(audioQueue_);
        AudioQueueReset(audioQueue_);
    }
}

- (void)stopAudio {
    [self stopAudio_];
}

- (void)updateSeek:(CGFloat)value {
    if (started_) {
        state_ = AUDIO_STATE_SEEKING;

        AudioQueueStop(audioQueue_, YES);
        [ffmpegDecoder_ seekTime:value];
        startedTime_ = value;

        [self startAudio_];
    }
}

- (void)updatePlaybackTime:(NSTimer *)timer {
    AudioTimeStamp timeStamp;
    OSStatus status = AudioQueueGetCurrentTime(audioQueue_, NULL, &timeStamp, NULL);

    if (status == noErr) {
        SInt64 time = floor(durationTime_);
        NSTimeInterval currentTimeInterval = timeStamp.mSampleTime / audioStreamBasicDesc_.mSampleRate;
        SInt64 currentTime = floor(startedTime_ + currentTimeInterval);
        NSString * text = [NSString stringWithFormat:@"%02llu:%02llu:%02llu / %02llu:%02llu:%02llu",
                                                     ((currentTime / 60) / 60), (currentTime / 60), (currentTime % 60),
                                                     ((time / 60) / 60), (time / 60), (time % 60)];
        NSLog(@"音频播放进度：%@", text);
//      seekSlider_.value = startedTime_ + currentTimeInterval;
    }
}


- (void)startAudio_ {
    if (started_) {
        AudioQueueStart(audioQueue_, NULL);
    } else {
        if (![self createAudioQueue]) {
            abort();
        }
        [self startQueue];

        seekTimer_ = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self selector:@selector(updatePlaybackTime:) userInfo:nil repeats:YES];
    }

    for (NSInteger i = 0; i < kNumAQBufs; ++i) {
        [self enqueueBuffer:audioQueueBuffer_[i]];
    }

    state_ = AUDIO_STATE_PLAYING;
}

- (void)stopAudio_ {
    if (started_) {
        AudioQueueStop(audioQueue_, YES);
        startedTime_ = 0.0;

        [ffmpegDecoder_ seekTime:0.0];

        state_ = AUDIO_STATE_STOP;
        finished_ = NO;
    }
}

#define PREFERRED_SAMPLE_RATE   44100

- (BOOL)createAudioQueue {
    state_ = AUDIO_STATE_READY;
    finished_ = NO;

    decodeLock_ = [[NSLock alloc] init];
    ffmpegDecoder_ = [[FFAudioDecoder alloc] init];
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    double prefferedSampleRate = PREFERRED_SAMPLE_RATE;
    NSError * rawError = nil;

    if (![audioSession setPreferredSampleRate:prefferedSampleRate error:&rawError]) {
        NSLog(@"setPreferredSampleRate: %.4f, error: %@", prefferedSampleRate, rawError);
    }
    int sample = 44100;
    int nchannles = 2;
    int bits = 16;
    // 16bit PCM LE.
    audioStreamBasicDesc_.mSampleRate = sample;//设置采样率
    audioStreamBasicDesc_.mChannelsPerFrame = nchannles;
    audioStreamBasicDesc_.mBitsPerChannel = bits;
    audioStreamBasicDesc_.mFormatID = kAudioFormatLinearPCM;//设置数据格式
    audioStreamBasicDesc_.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;

    audioStreamBasicDesc_.mFramesPerPacket = 1;
    audioStreamBasicDesc_.mBytesPerFrame = audioStreamBasicDesc_.mBitsPerChannel / 8
            * audioStreamBasicDesc_.mChannelsPerFrame;
    audioStreamBasicDesc_.mBytesPerPacket =
            audioStreamBasicDesc_.mBytesPerFrame * audioStreamBasicDesc_.
                    mFramesPerPacket;
    audioStreamBasicDesc_.mReserved = 0;

    ffmpegDecoder_.audioChannels = audioStreamBasicDesc_.mChannelsPerFrame;
    ffmpegDecoder_.audioSampleRate = audioStreamBasicDesc_.mSampleRate;
    NSInteger retLoaded = [ffmpegDecoder_ loadFile:playingFilePath_];
    if (retLoaded) return NO;

    durationTime_ = [ffmpegDecoder_ duration];
    dispatch_async(dispatch_get_main_queue(), ^{
        //update progress
    });


    OSStatus status = AudioQueueNewOutput(&audioStreamBasicDesc_, audioQueueOutputCallback, (__bridge void *) self,
            NULL, NULL, 0, &audioQueue_);
    if (status != noErr) {
        NSLog(@"Could not create new output.");
        return NO;
    }

    status = AudioQueueAddPropertyListener(audioQueue_, kAudioQueueProperty_IsRunning,
            audioQueueIsRunningCallback, (__bridge void *) self);
    if (status != noErr) {
        NSLog(@"Could not add propery listener. (kAudioQueueProperty_IsRunning)");
        return NO;
    }


//    [ffmpegDecoder_ seekTime:10.0];

    for (NSInteger i = 0; i < kNumAQBufs; ++i) {
        status = AudioQueueAllocateBufferWithPacketDescriptions(audioQueue_,
                ffmpegDecoder_.audioCodecContext_->bit_rate * kAudioBufferSeconds / 8,
                ffmpegDecoder_.audioCodecContext_->sample_rate * kAudioBufferSeconds /
                        ffmpegDecoder_.audioCodecContext_->frame_size + 1,
                audioQueueBuffer_ + i);
        if (status != noErr) {
            NSLog(@"Could not allocate buffer.");
            return NO;
        }
    }

    return YES;
}

- (void)removeAudioQueue {
    [self stopAudio_];
    started_ = NO;

    for (NSInteger i = 0; i < kNumAQBufs; ++i) {
        AudioQueueFreeBuffer(audioQueue_, audioQueueBuffer_[i]);
    }
    AudioQueueDispose(audioQueue_, YES);
}


- (void)audioQueueOutputCallback:(AudioQueueRef)inAQ inBuffer:(AudioQueueBufferRef)inBuffer {
    if (state_ == AUDIO_STATE_PLAYING) {
        [self enqueueBuffer:inBuffer];
    }
}

- (void)audioQueueIsRunningCallback {
    UInt32 isRunning;
    UInt32 size = sizeof(isRunning);
    OSStatus status = AudioQueueGetProperty(audioQueue_, kAudioQueueProperty_IsRunning, &isRunning, &size);

    if (status == noErr && !isRunning && state_ == AUDIO_STATE_PLAYING) {
        state_ = AUDIO_STATE_STOP;

        if (finished_) {
            dispatch_async(dispatch_get_main_queue(), ^{
                //update progress
            });
        }
    }
}


- (OSStatus)enqueueBuffer:(AudioQueueBufferRef)buffer {
    OSStatus status = noErr;
    NSInteger decodedDataSize = 0;
    buffer->mAudioDataByteSize = 0;
    buffer->mPacketDescriptionCount = 0;

    [decodeLock_ lock];

    while (buffer->mPacketDescriptionCount < buffer->mPacketDescriptionCapacity) {
        decodedDataSize = [ffmpegDecoder_ decode];

        if (decodedDataSize && buffer->mAudioDataBytesCapacity - buffer->mAudioDataByteSize >= decodedDataSize) {
            memcpy(buffer->mAudioData + buffer->mAudioDataByteSize,
                    ffmpegDecoder_.audioBuffer_, decodedDataSize);

            buffer->mPacketDescriptions[buffer->mPacketDescriptionCount].mStartOffset = buffer->mAudioDataByteSize;
            buffer->mPacketDescriptions[buffer->mPacketDescriptionCount].mDataByteSize = decodedDataSize;
            buffer->mPacketDescriptions[buffer->mPacketDescriptionCount].mVariableFramesInPacket =
                    audioStreamBasicDesc_.mFramesPerPacket;

            buffer->mAudioDataByteSize += decodedDataSize;
            buffer->mPacketDescriptionCount++;
            [ffmpegDecoder_ nextPacket];
        } else {
            break;
        }
    }


    if (buffer->mPacketDescriptionCount > 0) {
        status = AudioQueueEnqueueBuffer(audioQueue_, buffer, 0, NULL);
        if (status != noErr) {
            NSLog(@"Could not enqueue buffer.");
        }
    } else {
        AudioQueueStop(audioQueue_, NO);
        finished_ = YES;
    }

    [decodeLock_ unlock];

    return status;
}

- (OSStatus)startQueue {
    OSStatus status = noErr;

    if (!started_) {
        status = AudioQueueStart(audioQueue_, NULL);
        if (status == noErr) {
            started_ = YES;
        } else {
            NSLog(@"Could not start audio queue.");
        }
    }

    return status;
}

@end
