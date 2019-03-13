//
//  ViewController.m
//  FFMPEGDemo
//
//  Created by mm-cy on 2018/9/6.
//  Copyright © 2018年 mm-cy. All rights reserved.
//

#import "ViewController.h"
#import "FFMovie.h"
#import "AudioManager.h"
#import "KxMovieViewController.h"

#import <AVFoundation/AVFoundation.h>

#define LERP(A,B,C) ((A)*(1.0-C)+(B)*C)

@interface ViewController ()<KxPlayDelegate>
@property (weak, nonatomic) IBOutlet UIImageView *playImageView;
@property (weak, nonatomic) IBOutlet UILabel *fps;
@property (weak, nonatomic) IBOutlet UIButton *playBtn;
@property (weak, nonatomic) IBOutlet UIButton *replayBtn;
@property (weak, nonatomic) IBOutlet UILabel *currentTimeLabel;
@property (weak, nonatomic) IBOutlet UILabel *durationLabel;
@property (weak, nonatomic) IBOutlet UISlider *slider;

@property (nonatomic, strong) FFMovie *video;
@property (nonatomic, strong) AudioManager *audioManager;

@property (nonatomic) NSTimer *timer;
@property (nonatomic, assign) float lastFrameTime;

@property (nonatomic) KxMovieViewController *play;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSString *path = [[NSBundle mainBundle] pathForResource:@"2" ofType:@"mkv"];

    self.video = [[FFMovie alloc] initWithVideo:path];
    self.video.outputWidth = 800;
    self.video.outputHeight = 600;
    NSLog(@"视频总时长>>>video duration: %f",self.video.duration);
    NSLog(@"源尺寸>>>video size: %d x %d",self.video.sourceWidth, self.video.sourceHeight);
    NSLog(@"输出尺寸>>>video size: %d x %d", self.video.outputWidth, self.video.outputHeight);
    self.durationLabel.text = [self dealTime:self.video.duration];
    self.slider.minimumValue = 0;
    self.slider.maximumValue = self.video.duration;
    self.slider.value = 0;
}

- (IBAction)PlayClick:(UIButton *)sender {
    _lastFrameTime = -1;
 
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval: 1 / self.video.fps
                                     target:self
                                   selector:@selector(displayNextFrame:)
                                   userInfo:nil
                                    repeats:YES];
}

- (IBAction)replay:(id)sender {
    [self.video redialPlay];
    [self PlayClick:_playBtn];
}

- (IBAction)kxmovie:(id)sender {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"2" ofType:@"mkv"];
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    // increase buffering for .wmv, it solves problem with delaying audio frames
    if ([path.pathExtension isEqualToString:@"wmv"])
        parameters[KxMovieParameterMinBufferedDuration] = @(5.0);
    
    // disable deinterlacing for iPhone, because it's complex operation can cause stuttering
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone)
        parameters[KxMovieParameterDisableDeinterlacing] = @(YES);
    
    // disable buffering
    //parameters[KxMovieParameterMinBufferedDuration] = @(0.0f);
    //parameters[KxMovieParameterMaxBufferedDuration] = @(0.0f);
    CGFloat w = self.view.frame.size.width;
    parameters[KxMovieParameterRenderWidth] = @(w);
    parameters[KxMovieParameterRenderHeight] = @(w * 9/16);

    self.play = [KxMovieViewController movieViewControllerWithContentPath:path
                                                                               parameters:parameters];
    [self presentViewController:self.play animated:YES completion:^{
        
    }];
}

-(void)displayNextFrame:(NSTimer *)timer {
    NSTimeInterval startTime = [NSDate timeIntervalSinceReferenceDate];

    if (![self.video stepFrame]) {
        [timer invalidate];
        return;
    }
    self.currentTimeLabel.text  = [self dealTime:self.video.currentTime];
    self.slider.value = self.video.currentTime;
    self.playImageView.image = self.video.currentImage;
    float frameTime = 1.0 / ([NSDate timeIntervalSinceReferenceDate] - startTime);
    if (_lastFrameTime < 0) {
        _lastFrameTime = frameTime;
    } else {
        _lastFrameTime = LERP(frameTime, _lastFrameTime, 0.8);
    }
    [self.fps setText:[NSString stringWithFormat:@"fps %.0f",_lastFrameTime]];
}

- (NSString *)dealTime:(double)time {
    return [NSString stringWithFormat:@"%.1f", time];

    int tns, thh, tmm, tss;
    tns = time;
    thh = tns / 3600;
    tmm = (tns % 3600) / 60;
    tss = tns % 60;
    return [NSString stringWithFormat:@"%02d:%02d:%02d",thh,tmm,tss];
}

- (IBAction)valueChanged:(id)sender {
    [self.video seekTime:self.slider.value];
}

- (IBAction)playAudio:(id)sender {
    if (!_audioManager) {
        NSString *path = [[NSBundle mainBundle] pathForResource:@"2" ofType:@"mkv"];
        self.audioManager = [[AudioManager alloc] initWith:path];
    }
    [self.audioManager playAudio];
}

@end
