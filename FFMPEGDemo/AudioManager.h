//
//  ViewController.h
//  FFmpegAudioTest
//
//  Created by Pontago on 12/06/17.
//  Copyright (c) 2012年 __MyCompanyName__. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import "FFAudioDecoder.h"

#define kNumAQBufs 3
#define kAudioBufferSeconds 3

typedef enum _AUDIO_STATE {
    AUDIO_STATE_READY = 0,
    AUDIO_STATE_STOP = 1,
    AUDIO_STATE_PLAYING = 2,
    AUDIO_STATE_PAUSE = 3,
    AUDIO_STATE_SEEKING = 4
} AUDIO_STATE;

@interface AudioManager : NSObject
- (instancetype)initWith:(NSString *)filePath;

- (void)playAudio;

- (void)stopAudio;

- (void)pauseAudio;

- (void)updateSeek:(CGFloat)value;

- (void)updatePlaybackTime:(NSTimer *)timer;

@end
