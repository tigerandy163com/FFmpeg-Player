//
//  ViewController.m
//  kxmovieapp
//
//  Created by Kolyvan on 11.10.12.
//  Copyright (c) 2012 Konstantin Boukreev . All rights reserved.
//
//  https://github.com/kolyvan/kxmovie
//  this file is part of KxMovie
//  KxMovie is licenced under the LGPL v3, see lgpl-3.0.txt

#import "KxPlay.h"
#import <MediaPlayer/MediaPlayer.h>
#import "KxMovieDecoder.h"
#import "KxAudioManager.h"
#import "KxMovieGLView.h"
#import "KxLogger.h"

NSString *const KxMovieParameterMinBufferedDuration = @"KxMovieParameterMinBufferedDuration";
NSString *const KxMovieParameterMaxBufferedDuration = @"KxMovieParameterMaxBufferedDuration";
NSString *const KxMovieParameterDisableDeinterlacing = @"KxMovieParameterDisableDeinterlacing";
NSString *const KxMovieParameterRenderWidth = @"KxMovieParameterRenderWidth";
NSString *const KxMovieParameterRenderHeight = @"KxMovieParameterRenderHeight";
////////////////////////////////////////////////////////////////////////////////
#define LOCAL_MIN_BUFFERED_DURATION   0.5
#define LOCAL_MAX_BUFFERED_DURATION   LOCAL_MIN_BUFFERED_DURATION * 2
#define NETWORK_MIN_BUFFERED_DURATION 2.0
#define NETWORK_MAX_BUFFERED_DURATION NETWORK_MIN_BUFFERED_DURATION * 2

@interface KxPlay () {

    KxMovieDecoder *_decoder;
    dispatch_queue_t _dispatchQueue;
    NSMutableArray *_videoFrames;
    NSMutableArray *_audioFrames;
    NSMutableArray *_subtitles;
    NSData *_currentAudioFrame;
    NSUInteger _currentAudioFramePos;
    NSTimeInterval _tickCorrectionTime;
    NSTimeInterval _tickCorrectionPosition;

    KxMovieGLView *_glView;
    UIImageView *_imageView;
    BOOL _decoding;

#ifdef DEBUG
    NSTimeInterval      _debugStartTime;
    NSUInteger          _debugAudioStatus;
    NSDate              *_debugAudioStatusTS;
#endif

    CGFloat _bufferedDuration;
    CGFloat _minBufferedDuration;
    CGFloat _maxBufferedDuration;

    NSDictionary *_parameters;

    BOOL _needPlay;
}

@property(nonatomic, readwrite) KxArtworkFrame *artworkFrame;
@property(nonatomic, readwrite) KxPlayState state;
@property(nonatomic, readwrite) CGFloat moviePosition;
@property(nonatomic) NSString *currentSubtile;

@end

@implementation KxPlay

+ (id)movieViewControllerWithContentPath:(NSString *)path
                              parameters:(NSDictionary *)parameters {
    return [[KxPlay alloc] initWithContentPath:path parameters:parameters];
}

- (void)readyPlay {
    id <KxAudioManager> audioManager = [KxAudioManager audioManager];
    [audioManager activateAudioSession];
    __weak KxPlay *weakSelf = self;

    KxMovieDecoder *decoder = [[KxMovieDecoder alloc] init];
    decoder.outputWidth = [_parameters[KxMovieParameterRenderWidth] floatValue];
    decoder.outputHeight = [_parameters[KxMovieParameterRenderHeight] floatValue];
    decoder.interruptCallback = ^BOOL() {

        __strong KxPlay *strongSelf = weakSelf;
        return strongSelf ? [strongSelf interruptDecoder] : YES;
    };
    dispatch_async(dispatch_get_global_queue(0, 0), ^{

        NSError * error = nil;
        [decoder openFile:self->_path error:&error];

        __strong KxPlay *strongSelf = weakSelf;
        if (strongSelf) {

            dispatch_sync(dispatch_get_main_queue(), ^{

                [strongSelf setMovieDecoder:decoder withError:error];
            });
        }
    });
}

- (id)initWithContentPath:(NSString *)path
               parameters:(NSDictionary *)parameters {
    NSAssert(path.length > 0, @"empty path");

    self = [super init];
    if (self) {
        _path = path;
        _moviePosition = 0;
        _parameters = parameters;
    }
    return self;
}

- (void)dealloc {
    [self pause];

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (_dispatchQueue) {
        // Not needed as of ARC.
//        dispatch_release(_dispatchQueue);
        _dispatchQueue = NULL;
    }

    LoggerStream(1, @"%@ dealloc", self);
}

- (void)didReceiveMemoryWarning {
    if (self.state == KxPlayStatePlaying) {

        [self _pause];
        [self freeBufferedFrames];

        if (_maxBufferedDuration > 0) {

            _minBufferedDuration = _maxBufferedDuration = 0;
            [self play];

            LoggerStream(0, @"didReceiveMemoryWarning, disable buffering and continue playing");

        } else {

            // force ffmpeg to free allocated memory
            [_decoder closeFile];
            [_decoder openFile:nil error:nil];
            LoggerStream(0, @"didReceiveMemoryWarning, force ffmpeg to free allocated memory");
        }

    } else {

        [self freeBufferedFrames];
        [_decoder closeFile];
        [_decoder openFile:nil error:nil];
    }
}

#pragma mark - public

- (void)startTick {
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void) {
        [self tick];
    });
}

- (void)play {
    _needPlay = YES;
    [self _play];
}

- (void)pause {
    _needPlay = NO;
    [self _pause];
}

- (void)seek:(CGFloat)position {
    [self setMoviePosition:position];
}

- (void)setMoviePosition:(CGFloat)position {
    if (self.state == KxPlayStateLoading) {
        return;
    }
    if (self.state == KxPlayStateEnd) {
        return;
    }
    if (position > self.duration) {
        position = self.duration;
    }
    if (position < 0) {
        position = [_decoder startTime];
    }
    BOOL playMode = NO;

//    self.state = KxPlayStateLoading;
    [self enableAudio:NO];

    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void) {

        [self updatePosition:position playMode:playMode];
    });
}

- (CGFloat)duration {
    return _decoder.duration;
}

- (BOOL)isNetwork {
    return _decoder.isNetwork;
}

- (BOOL)validSubtitles {
    return _decoder.validSubtitles;
}

- (NSDictionary *)info {
    return _decoder.info;
}

- (NSInteger)outputWidth {
    return _decoder.outputWidth;
}

- (NSInteger)outputHeight {
    return _decoder.outputHeight;
}
#pragma mark - private

- (void)_play {
    if (self.state == KxPlayStatePlaying || self.state == KxPlayStateLoading)
        return;

    if (!_decoder.validVideo &&
            !_decoder.validAudio) {

        return;
    }

    if (_interrupted)
        return;

    self.state = KxPlayStatePlaying;
    _interrupted = NO;
    _tickCorrectionTime = 0;

#ifdef DEBUG
    _debugStartTime = -1;
#endif

    [self asyncDecodeFrames];

    [self startTick];

    if (_decoder.validAudio)
        [self enableAudio:YES];

    LoggerStream(1, @"play movie");
}

- (void)_pause {
    if (self.state == KxPlayStatePause)
        return;

    self.state = KxPlayStatePause;
    [self enableAudio:NO];
    LoggerStream(1, @"pause movie");
}

- (void)setState:(KxPlayState)state {
    if (_state != state) {
        _state = state;
        if ([self.delegate respondsToSelector:@selector(KxPlay:stateChanged:)]) {
            [self.delegate KxPlay:self stateChanged:_state];
        }
    }
}

- (void)setCurrentSubtile:(NSString *)currentSubtile {
    if (![_currentSubtile isEqualToString:currentSubtile]) {
        _currentSubtile = currentSubtile;
        if ([self.delegate respondsToSelector:@selector(KxPlay:updateSubtitles: )]) {
             [self.delegate KxPlay:self updateSubtitles:currentSubtile];
        }
    }
}

- (void)setMovieDecoder:(KxMovieDecoder *)decoder
              withError:(NSError *)error {
    LoggerStream(2, @"setMovieDecoder");

    if (!error && decoder) {

        _decoder = decoder;
        _dispatchQueue = dispatch_queue_create("KxMovie", DISPATCH_QUEUE_SERIAL);
        _videoFrames = [NSMutableArray array];
        _audioFrames = [NSMutableArray array];

        if (_decoder.subtitleStreamsCount) {
            _subtitles = [NSMutableArray array];
        }

        if (_decoder.isNetwork) {

            _minBufferedDuration = NETWORK_MIN_BUFFERED_DURATION;
            _maxBufferedDuration = NETWORK_MAX_BUFFERED_DURATION;

        } else {

            _minBufferedDuration = LOCAL_MIN_BUFFERED_DURATION;
            _maxBufferedDuration = LOCAL_MAX_BUFFERED_DURATION;
        }

        if (!_decoder.validVideo)
            _minBufferedDuration *= 10.0; // increase for audio

        // allow to tweak some parameters at runtime
        if (_parameters.count) {

            id val;

            val = [_parameters valueForKey:KxMovieParameterMinBufferedDuration];
            if ([val isKindOfClass:[NSNumber class]])
                _minBufferedDuration = [val floatValue];

            val = [_parameters valueForKey:KxMovieParameterMaxBufferedDuration];
            if ([val isKindOfClass:[NSNumber class]])
                _maxBufferedDuration = [val floatValue];

            val = [_parameters valueForKey:KxMovieParameterDisableDeinterlacing];
            if ([val isKindOfClass:[NSNumber class]])
                _decoder.disableDeinterlacing = [val boolValue];

            if (_maxBufferedDuration < _minBufferedDuration)
                _maxBufferedDuration = _minBufferedDuration * 2;
        }

        LoggerStream(2, @"buffered limit: %.1f - %.1f", _minBufferedDuration, _maxBufferedDuration);

        [self setupPresentView];

    } else {
        if (!_interrupted)
            self.state = KxPlayStateDecodeFailed;
    }
}

- (void)setupPresentView {
    CGRect bounds = CGRectMake(0, 0, [_parameters[KxMovieParameterRenderWidth] floatValue], [_parameters[KxMovieParameterRenderHeight] floatValue]);

    if (_decoder.validVideo) {
        _glView = [[KxMovieGLView alloc] initWithFrame:bounds decoder:_decoder];
    }

    if (!_glView) {

        LoggerVideo(0, @"fallback to use RGB video frame and UIKit");
        [_decoder setupVideoFrameFormat:KxVideoFrameFormatRGB];
        _imageView = [[UIImageView alloc] initWithFrame:bounds];
        _imageView.backgroundColor = [UIColor blackColor];
    }

    UIView *frameView = [self renderView];
    frameView.contentMode = UIViewContentModeScaleAspectFit;
    frameView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleBottomMargin;

    if (_decoder.validVideo) {

    } else {

        _imageView.image = [UIImage imageNamed:@"kxmovie.bundle/music_icon.png"];
        _imageView.contentMode = UIViewContentModeCenter;
    }
 
    self.state = KxPlayStateReadyPlay;
}
 
- (UIView *)renderView {
    return _glView ? _glView : _imageView;
}

- (void)audioCallbackFillData:(float *)outData
                    numFrames:(UInt32)numFrames
                  numChannels:(UInt32)numChannels {
    //fillSignalF(outData,numFrames,numChannels);
    //return;

    if (self.state == KxPlayStateLoading) {
        memset(outData, 0, numFrames * numChannels * sizeof(float));
        return;
    }

    @autoreleasepool {

        while (numFrames > 0) {

            if (!_currentAudioFrame) {

                @synchronized (_audioFrames) {

                    NSUInteger count = _audioFrames.count;

                    if (count > 0) {

                        KxAudioFrame *frame = _audioFrames[0];

#ifdef DUMP_AUDIO_DATA
                        LoggerAudio(2, @"Audio frame position: %f", frame.position);
#endif
                        if (_decoder.validVideo && _videoFrames.count > 0) {

                            const CGFloat delta = _moviePosition - frame.position;

                            if (delta < -0.1) {
                                /**
                                 The voice ahead of current video, wait for next
                                 */
                                memset(outData, 0, numFrames * numChannels * sizeof(float));
#ifdef DEBUG
                                LoggerStream(0, @"desync audio (outrun) wait %.4f %.4f", _moviePosition, frame.position);
                                _debugAudioStatus = 1;
                                _debugAudioStatusTS = [NSDate date];
#endif
                                break; // silence and exit
                            }

                            [_audioFrames removeObjectAtIndex:0];

                            if (delta > 0.1 && count > 1) {
                                /**
                                 The voice behind current video, discarded
                                 */
#ifdef DEBUG
                                LoggerStream(0, @"desync audio (lags) skip %.4f %.4f", _moviePosition, frame.position);
                                _debugAudioStatus = 2;
                                _debugAudioStatusTS = [NSDate date];
#endif
                                continue;
                            }

                        } else {

                            [_audioFrames removeObjectAtIndex:0];
                            _moviePosition = frame.position;
                            _bufferedDuration -= frame.duration;
                        }

                        _currentAudioFramePos = 0;
                        _currentAudioFrame = frame.samples;
                    }
                }
            }

            if (_currentAudioFrame) {

                const void *bytes = (Byte *) _currentAudioFrame.bytes + _currentAudioFramePos;
                const NSUInteger bytesLeft = (_currentAudioFrame.length - _currentAudioFramePos);
                const NSUInteger frameSizeOf = numChannels * sizeof(float);
                const NSUInteger bytesToCopy = MIN(numFrames * frameSizeOf, bytesLeft);
                const NSUInteger framesToCopy = bytesToCopy / frameSizeOf;

                memcpy(outData, bytes, bytesToCopy);
                numFrames -= framesToCopy;
                outData += framesToCopy * numChannels;

                if (bytesToCopy < bytesLeft)
                    _currentAudioFramePos += bytesToCopy;
                else
                    _currentAudioFrame = nil;

            } else {

                memset(outData, 0, numFrames * numChannels * sizeof(float));
                //LoggerStream(1, @"silence audio");
#ifdef DEBUG
                _debugAudioStatus = 3;
                _debugAudioStatusTS = [NSDate date];
#endif
                break;
            }
        }
    }
}

- (void)enableAudio:(BOOL)on {
    id <KxAudioManager> audioManager = [KxAudioManager audioManager];

    if (on && _decoder.validAudio) {

        audioManager.outputBlock = ^(float *outData, UInt32 numFrames, UInt32 numChannels) {

            [self audioCallbackFillData:outData numFrames:numFrames numChannels:numChannels];
        };

        [audioManager play];

        LoggerAudio(2, @"audio device smr: %d fmt: %d chn: %d",
                (int) audioManager.samplingRate,
                (int) audioManager.numBytesPerSample,
                (int) audioManager.numOutputChannels);

    } else {

        [audioManager pause];
        audioManager.outputBlock = nil;
    }
}

- (BOOL)addFrames:(NSArray *)frames {
    if (_decoder.validVideo) {

        @synchronized (_videoFrames) {

            for (KxMovieFrame *frame in frames)
                if (frame.type == KxMovieFrameTypeVideo) {
                    [_videoFrames addObject:frame];
                    _bufferedDuration += frame.duration;
                }
        }
    }

    if (_decoder.validAudio) {

        @synchronized (_audioFrames) {

            for (KxMovieFrame *frame in frames)
                if (frame.type == KxMovieFrameTypeAudio) {
                    [_audioFrames addObject:frame];
                    if (!_decoder.validVideo)
                        _bufferedDuration += frame.duration;
                }
        }

        if (!_decoder.validVideo) {

            for (KxMovieFrame *frame in frames)
                if (frame.type == KxMovieFrameTypeArtwork)
                    self.artworkFrame = (KxArtworkFrame *) frame;
        }
    }

    if (_decoder.validSubtitles) {

        @synchronized (_subtitles) {

            for (KxMovieFrame *frame in frames)
                if (frame.type == KxMovieFrameTypeSubtitle) {
                    [_subtitles addObject:frame];
                }
        }
    }

    return _bufferedDuration > _minBufferedDuration;
}

- (BOOL)decodeFrames {
    //NSAssert(dispatch_get_current_queue() == _dispatchQueue, @"bugcheck");

    NSArray * frames = nil;

    if (_decoder.validVideo ||
            _decoder.validAudio) {

        frames = [_decoder decodeFrames:0];
    }

    if (frames.count) {
        return [self addFrames:frames];
    } else {
        NSLog(@"no frames, may be end");
    }
    return NO;
}

- (void)asyncDecodeFrames {
    if (_decoding)
        return;

    __weak KxPlay *weakSelf = self;
    __weak KxMovieDecoder *weakDecoder = _decoder;

    const CGFloat duration = _decoder.isNetwork ? .0f : 0.1f;

    _decoding = YES;
    dispatch_async(_dispatchQueue, ^{

        {
            __strong KxPlay *strongSelf = weakSelf;
            if (!strongSelf->_decoding)
                return;
        }

        BOOL good = YES;
        while (good) {

            good = NO;

            @autoreleasepool {

                __strong KxMovieDecoder *decoder = weakDecoder;

                if (decoder && (decoder.validVideo || decoder.validAudio)) {

                    NSArray * frames = [decoder decodeFrames:duration];
                    if (frames.count) {

                        __strong KxPlay *strongSelf = weakSelf;
                        if (strongSelf)
                            good = ![strongSelf addFrames:frames];
                    } else {
                        NSLog(@"no frames, may be end");
                    }
                }
            }
        }

        {
            __strong KxPlay *strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf->_decoding = NO;
            }
        }
    });
}

- (NSUInteger)leftFrames {
    NSUInteger leftFrames =
            (_decoder.validVideo ? _videoFrames.count : 0) +
                    (_decoder.validAudio ? _audioFrames.count : 0);
    return leftFrames;
}

- (void)tick {
    if (!_needPlay) {
        return;
    }
    if (self.state == KxPlayStateLoading && ((_bufferedDuration > _minBufferedDuration) || _decoder.isEOF)) {

        _tickCorrectionTime = 0;
        self.state = KxPlayStatePlaying;
        if (_decoder.validAudio)
            [self enableAudio:YES];
    }

    CGFloat interval = 0;
    if (self.state == KxPlayStatePlaying)
        interval = [self presentFrame];

    if (self.state == KxPlayStatePlaying) {

        NSUInteger leftFrames = [self leftFrames];
        if (0 == leftFrames) {

            if (_decoder.isEOF) {

                self.state = KxPlayStateEnd;
                return;
            }

            if (_minBufferedDuration > 0) {

                self.state = KxPlayStateLoading;
            }
        }

        if (!leftFrames ||
                !(_bufferedDuration > _minBufferedDuration)) {

            [self asyncDecodeFrames];
        }
        const NSTimeInterval correction = [self tickCorrection];
        const NSTimeInterval time = MAX(interval + correction, 0.01);
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, time * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void) {
            [self tick];
        });
    } else if (self.state == KxPlayStateLoading) {

        const NSTimeInterval correction = [self tickCorrection];
        const NSTimeInterval time = MAX(interval + correction, 0.01);
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, time * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void) {
            [self tick];
        });
    }
}

- (CGFloat)tickCorrection {
    if (self.state == KxPlayStateLoading)
        return 0;

    const NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (!_tickCorrectionTime) {

        _tickCorrectionTime = now;
        _tickCorrectionPosition = _moviePosition;
        return 0;
    }

    NSTimeInterval dPosition = _moviePosition - _tickCorrectionPosition;
    NSTimeInterval dTime = now - _tickCorrectionTime;
    NSTimeInterval correction = dPosition - dTime;

    //if ((_tickCounter % 200) == 0)
    //    LoggerStream(1, @"tick correction %.4f", correction);

    if (correction > 1.f || correction < -1.f) {

        LoggerStream(1, @"tick correction reset %.2f", correction);
        correction = 0;
        _tickCorrectionTime = 0;
    }

    return correction;
}

- (CGFloat)presentFrame {
    CGFloat interval = 0;

    if (_decoder.validVideo) {

        KxVideoFrame *frame;

        @synchronized (_videoFrames) {

            if (_videoFrames.count > 0) {

                frame = _videoFrames[0];
                [_videoFrames removeObjectAtIndex:0];
                _bufferedDuration -= frame.duration;
            }
        }

        if (frame)
            interval = [self presentVideoFrame:frame];

    } else if (_decoder.validAudio) {

        //interval = _bufferedDuration * 0.5;

        if (self.artworkFrame) {

            _imageView.image = [self.artworkFrame asImage];
            self.artworkFrame = nil;
        }
    }

    if (_decoder.validSubtitles)
        [self presentSubtitles];

#ifdef DEBUG
    if (_needPlay && _debugStartTime < 0)
        _debugStartTime = [NSDate timeIntervalSinceReferenceDate] - _moviePosition;
#endif

    return interval;
}

- (CGFloat)presentVideoFrame:(KxVideoFrame *)frame {
    if (_glView) {

        [_glView render:frame];

    } else {

        KxVideoFrameRGB *rgbFrame = (KxVideoFrameRGB *) frame;
        _imageView.image = [rgbFrame asImage];
    }

    _moviePosition = frame.position;

    return frame.duration;
}

- (void)presentSubtitles {
    NSArray * actual, *outdated;

    if ([self subtitleForPosition:_moviePosition
                           actual:&actual
                         outdated:&outdated]) {

        if (outdated.count) {
            @synchronized (_subtitles) {
                [_subtitles removeObjectsInArray:outdated];
            }
        }

        if (actual.count) {

            NSMutableString *ms = [NSMutableString string];
            for (KxSubtitleFrame *subtitle in actual.reverseObjectEnumerator) {
                if (ms.length) [ms appendString:@"\n"];
                [ms appendString:subtitle.text];
            }
            self.currentSubtile = ms;
        }
    }
}

- (BOOL)subtitleForPosition:(CGFloat)position
                     actual:(NSArray **)pActual
                   outdated:(NSArray **)pOutdated {
    if (!_subtitles.count)
        return NO;

    NSMutableArray *actual = nil;
    NSMutableArray *outdated = nil;

    for (KxSubtitleFrame *subtitle in _subtitles) {

        if (subtitle.position - position > 0.1) {

            break; // assume what subtitles sorted by position

        } else if (position - (subtitle.position + subtitle.duration) > 0.1) {

            if (pOutdated) {
                if (!outdated)
                    outdated = [NSMutableArray array];
                [outdated addObject:subtitle];
            }

        } else {

            if (pActual) {
                if (!actual)
                    actual = [NSMutableArray array];
                [actual addObject:subtitle];
            }
        }
    }

    if (pActual) *pActual = actual;
    if (pOutdated) *pOutdated = outdated;

    return actual.count || outdated.count;
}

- (void)setMoviePositionFromDecoder {
    _moviePosition = _decoder.position;
    if ([self.delegate respondsToSelector:@selector(KxPlay:updatePosition:)]) {
        [self.delegate KxPlay:self updatePosition:_moviePosition];
    }
}

- (void)setDecoderPosition:(CGFloat)position {
    _decoder.position = position;
}

- (void)updatePosition:(CGFloat)position
              playMode:(BOOL)playMode {
    [self freeBufferedFrames];

    position = MIN(_decoder.duration - 1, MAX(0, position));

    __weak KxPlay *weakSelf = self;

    dispatch_async(_dispatchQueue, ^{

        if (playMode) {

            {
                __strong KxPlay *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf setDecoderPosition:position];
            }

            dispatch_async(dispatch_get_main_queue(), ^{

                __strong KxPlay *strongSelf = weakSelf;
                if (strongSelf) {
                    [strongSelf setMoviePositionFromDecoder];
//                    [strongSelf _play];
                }
            });

        } else {

            {
                __strong KxPlay *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf setDecoderPosition:position];
                [strongSelf decodeFrames];
            }

            dispatch_async(dispatch_get_main_queue(), ^{

                __strong KxPlay *strongSelf = weakSelf;
                if (strongSelf) {
                    [strongSelf setMoviePositionFromDecoder];
                    [strongSelf presentFrame];
                }
            });
        }
    });
}

- (void)freeBufferedFrames {
    @synchronized (_videoFrames) {
        [_videoFrames removeAllObjects];
    }

    @synchronized (_audioFrames) {

        [_audioFrames removeAllObjects];
        _currentAudioFrame = nil;
    }

    if (_subtitles) {
        @synchronized (_subtitles) {
            [_subtitles removeAllObjects];
        }
    }

    _bufferedDuration = 0;
}

- (BOOL)interruptDecoder {
    return _interrupted;
}

- (void)setInterrupted:(BOOL)interrupted {
    _interrupted = interrupted;
    if (_interrupted) {
        self.state = KxPlayStateDecodeInterrupted;
    }
}

@end

