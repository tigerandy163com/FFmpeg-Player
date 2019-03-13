//
//  ViewController.h
//  kxmovieapp
//
//  Created by Kolyvan on 11.10.12.
//  Copyright (c) 2012 Konstantin Boukreev . All rights reserved.
//
//  https://github.com/kolyvan/kxmovie
//  this file is part of KxMovie
//  KxMovie is licenced under the LGPL v3, see lgpl-3.0.txt

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSUInteger, KxPlayState) {
    KxPlayStateNone,
    KxPlayStateReadyPlay,
    KxPlayStateLoading,
    KxPlayStatePlaying,
    KxPlayStatePause,
    KxPlayStateEnd,
    KxPlayStateDecodeFailed,
    KxPlayStateDecodeInterrupted,
};

@class KxPlay;
@class KxMovieDecoder;

@protocol KxPlayDelegate <NSObject>

@optional
- (void)KxPlay:(KxPlay *)play stateChanged:(KxPlayState)state;

- (void)KxPlay:(KxPlay *)play updatePosition:(CGFloat)position;

- (void)KxPlay:(KxPlay *)play updateSubtitles:(NSString *)subtitle;

@end

extern NSString *const KxMovieParameterMinBufferedDuration;    // Float
extern NSString *const KxMovieParameterMaxBufferedDuration;    // Float
extern NSString *const KxMovieParameterDisableDeinterlacing;   // BOOL
extern NSString *const KxMovieParameterRenderWidth;
extern NSString *const KxMovieParameterRenderHeight;

@interface KxPlay : NSObject

+ (id)movieViewControllerWithContentPath:(NSString *)path
                              parameters:(NSDictionary *)parameters;

@property(nonatomic) CGRect frame;
@property(nonatomic, weak) id <KxPlayDelegate> delegate;
@property(nonatomic, assign) BOOL interrupted;

@property(nonatomic, copy, readonly) NSString *path;
@property(nonatomic, readonly) KxPlayState state;
@property(nonatomic, readonly) CGFloat duration;
@property(nonatomic, readonly) CGFloat moviePosition;
@property(nonatomic, readonly) BOOL isNetwork;
@property(nonatomic, readonly) NSInteger outputWidth, outputHeight;

@property(readonly, nonatomic, strong) NSDictionary *decoderInfo;
@property(nonatomic, copy, readonly) NSString *currentSubtile;
@property(nonatomic, readonly) BOOL validSubtitles;

- (UIView *)renderView;

- (void)readyPlay;

- (void)play;

- (void)pause;

- (void)seek:(CGFloat)position;

@end
