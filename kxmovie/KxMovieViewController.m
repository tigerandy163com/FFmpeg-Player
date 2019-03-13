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

#import "KxMovieViewController.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import "KxLogger.h"

static NSString *formatTimeInterval(CGFloat seconds, BOOL isLeft) {
    seconds = MAX(0, seconds);

    NSInteger s = seconds;
    NSInteger m = s / 60;
    NSInteger h = m / 60;

    s = s % 60;
    m = m % 60;

    NSMutableString *format = [(isLeft && seconds >= 0.5 ? @"-" : @"") mutableCopy];
    if (h != 0) [format appendFormat:@"%d:%0.2d", h, m];
    else [format appendFormat:@"%d", m];
    [format appendFormat:@":%0.2d", s];

    return format;
}

////////////////////////////////////////////////////////////////////////////////

enum {

    KxMovieInfoSectionGeneral,
    KxMovieInfoSectionVideo,
    KxMovieInfoSectionAudio,
    KxMovieInfoSectionSubtitles,
    KxMovieInfoSectionMetadata,
    KxMovieInfoSectionCount,
};

enum {

    KxMovieInfoGeneralFormat,
    KxMovieInfoGeneralBitrate,
    KxMovieInfoGeneralCount,
};

////////////////////////////////////////////////////////////////////////////////

static NSMutableDictionary *gHistory;

#define LOCAL_MIN_BUFFERED_DURATION   0.2
#define LOCAL_MAX_BUFFERED_DURATION   0.4
#define NETWORK_MIN_BUFFERED_DURATION 2.0
#define NETWORK_MAX_BUFFERED_DURATION 4.0

@interface KxMovieViewController () {

    KxPlay *_player;
    dispatch_queue_t _dispatchQueue;

    BOOL _disableUpdateHUD;
    BOOL _fullscreen;
    BOOL _hiddenHUD;
    BOOL _fitMode;

    UIView *_topHUD;
    UIToolbar *_topBar;
    UIToolbar *_bottomBar;
    UISlider *_progressSlider;

    UIBarButtonItem *_playBtn;
    UIBarButtonItem *_pauseBtn;
    UIBarButtonItem *_rewindBtn;
    UIBarButtonItem *_fforwardBtn;
    UIBarButtonItem *_spaceItem;
    UIBarButtonItem *_fixedSpaceItem;

    UIButton *_doneButton;
    UILabel *_progressLabel;
    UILabel *_leftLabel;
    UIActivityIndicatorView *_activityIndicatorView;
    UILabel *_subtitlesLabel;

    UITapGestureRecognizer *_tapGestureRecognizer;
    UITapGestureRecognizer *_doubleTapGestureRecognizer;
    UIPanGestureRecognizer *_panGestureRecognizer;

#ifdef DEBUG
    UILabel             *_messageLabel;
    NSTimeInterval      _debugStartTime;
#endif
    BOOL _savedIdleTimer;

    NSDictionary *_parameters;

    NSTimer *_timer;
}

@end

@implementation KxMovieViewController

+ (void)initialize {
    if (!gHistory)
        gHistory = [NSMutableDictionary dictionary];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

+ (id)movieViewControllerWithContentPath:(NSString *)path
                              parameters:(NSDictionary *)parameters {
    return [[KxMovieViewController alloc] initWithContentPath:path parameters:parameters];
}

- (id)initWithContentPath:(NSString *)path
               parameters:(NSDictionary *)parameters {
    NSAssert(path.length > 0, @"empty path");

    self = [super initWithNibName:nil bundle:nil];
    if (self) {

//        self.wantsFullScreenLayout = YES;

        _parameters = parameters;

        _player = [KxPlay movieViewControllerWithContentPath:path
                                                  parameters:parameters];
        _player.delegate = self;
        [_player readyPlay];
    }
    return self;
}

- (void)dealloc {
    [self pause];
    _player = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    if (_dispatchQueue) {
        // Not needed as of ARC.
//        dispatch_release(_dispatchQueue);
        _dispatchQueue = NULL;
    }

    LoggerStream(1, @"%@ dealloc", self);
}

- (void)loadView {
    // LoggerStream(1, @"loadView");
    CGRect bounds = [[UIScreen mainScreen] applicationFrame];

    self.view = [[UIView alloc] initWithFrame:bounds];
    self.view.backgroundColor = [UIColor blackColor];
    self.view.tintColor = [UIColor blackColor];

    _activityIndicatorView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _activityIndicatorView.center = self.view.center;
    _activityIndicatorView.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;

    [self.view addSubview:_activityIndicatorView];

    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;

#ifdef DEBUG
    _messageLabel = [[UILabel alloc] initWithFrame:CGRectMake(20,40,width-40,40)];
    _messageLabel.backgroundColor = [UIColor clearColor];
    _messageLabel.textColor = [UIColor redColor];
_messageLabel.hidden = YES;
    _messageLabel.font = [UIFont systemFontOfSize:14];
    _messageLabel.numberOfLines = 2;
    _messageLabel.textAlignment = NSTextAlignmentCenter;
    _messageLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_messageLabel];
#endif

    CGFloat topH = 50;
    CGFloat botH = 50;

    _topHUD = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 0)];
    _topBar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, [UIApplication sharedApplication].statusBarFrame.size.height, width, topH)];
    _bottomBar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, height - botH, width, botH)];
    _bottomBar.tintColor = [UIColor blackColor];

    _topHUD.frame = CGRectMake(0, [UIApplication sharedApplication].statusBarFrame.size.height, width, _topBar.frame.size.height);

    _topHUD.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _topBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _bottomBar.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;

    [self.view addSubview:_topBar];
    [self.view addSubview:_topHUD];
    [self.view addSubview:_bottomBar];

    // top hud

    _doneButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _doneButton.frame = CGRectMake(0, 1, 50, topH);
    _doneButton.backgroundColor = [UIColor clearColor];
//    _doneButton.backgroundColor = [UIColor redColor];
    [_doneButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    [_doneButton setTitle:NSLocalizedString(@"OK", nil) forState:UIControlStateNormal];
    _doneButton.titleLabel.font = [UIFont systemFontOfSize:18];
    _doneButton.showsTouchWhenHighlighted = YES;
    [_doneButton addTarget:self action:@selector(doneDidTouch:)
          forControlEvents:UIControlEventTouchUpInside];
//    [_doneButton setContentVerticalAlignment:UIControlContentVerticalAlignmentCenter];

    _progressLabel = [[UILabel alloc] initWithFrame:CGRectMake(46, 1, 50, topH)];
    _progressLabel.backgroundColor = [UIColor clearColor];
    _progressLabel.opaque = NO;
    _progressLabel.adjustsFontSizeToFitWidth = NO;
    _progressLabel.textAlignment = NSTextAlignmentRight;
    _progressLabel.textColor = [UIColor blackColor];
    _progressLabel.text = @"";
    _progressLabel.font = [UIFont systemFontOfSize:12];

    _progressSlider = [[UISlider alloc] initWithFrame:CGRectMake(100, 2, width - 197, topH)];
    _progressSlider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _progressSlider.continuous = NO;
    _progressSlider.value = 0;
//    [_progressSlider setThumbImage:[UIImage imageNamed:@"kxmovie.bundle/sliderthumb"]
//                          forState:UIControlStateNormal];

    _leftLabel = [[UILabel alloc] initWithFrame:CGRectMake(width - 92, 1, 60, topH)];
    _leftLabel.backgroundColor = [UIColor clearColor];
    _leftLabel.opaque = NO;
    _leftLabel.adjustsFontSizeToFitWidth = NO;
    _leftLabel.textAlignment = NSTextAlignmentLeft;
    _leftLabel.textColor = [UIColor blackColor];
    _leftLabel.text = @"";
    _leftLabel.font = [UIFont systemFontOfSize:12];
    _leftLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;

    [_topHUD addSubview:_doneButton];
    [_topHUD addSubview:_progressLabel];
    [_topHUD addSubview:_progressSlider];
    [_topHUD addSubview:_leftLabel];

    // bottom hud

    _spaceItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                               target:nil
                                                               action:nil];

    _fixedSpaceItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFixedSpace
                                                                    target:nil
                                                                    action:nil];
    _fixedSpaceItem.width = 30;

    _rewindBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRewind
                                                               target:self
                                                               action:@selector(rewindDidTouch:)];

    _playBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPlay
                                                             target:self
                                                             action:@selector(playDidTouch:)];
    _playBtn.width = 50;

    _pauseBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPause
                                                              target:self
                                                              action:@selector(playDidTouch:)];
    _pauseBtn.width = 50;

    _fforwardBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFastForward
                                                                 target:self
                                                                 action:@selector(forwardDidTouch:)];

    [self updateBottomBar];

    if (_player.renderView) {

        [self setupPresentView];

    } else {

        _progressLabel.hidden = YES;
        _progressSlider.hidden = YES;
        _leftLabel.hidden = YES;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
}

- (void)viewDidAppear:(BOOL)animated {
    // LoggerStream(1, @"viewDidAppear");

    [super viewDidAppear:animated];

    if (self.presentingViewController)
        [self fullscreenMode:YES];

    _savedIdleTimer = [[UIApplication sharedApplication] isIdleTimerDisabled];

    [self showHUD:YES];

    if (_player) {

//        [self restorePlay];

    } else {

        [_activityIndicatorView startAnimating];
    }


    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:[UIApplication sharedApplication]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientChange:) name:UIApplicationDidChangeStatusBarOrientationNotification object:nil];

}

- (void)orientChange:(NSNotification *)notification {
    UIInterfaceOrientation interfaceOritation = [[UIApplication sharedApplication] statusBarOrientation];
    UIView *frameView = [_player renderView];
    if (interfaceOritation == UIInterfaceOrientationLandscapeLeft || interfaceOritation == UIInterfaceOrientationLandscapeRight) {
        frameView.frame = self.view.bounds;
    } else {
        frameView.frame = CGRectMake(0, 0, _player.outputWidth, _player.outputHeight);
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [super viewWillDisappear:animated];

    [_activityIndicatorView stopAnimating];

    if (_player) {

        [self pause];

        if (_player.moviePosition == 0 || _player.state == KxPlayStateEnd)
            [gHistory removeObjectForKey:_player.path];
        else if (!_player.isNetwork)
            [gHistory setValue:[NSNumber numberWithFloat:_player.moviePosition]
                        forKey:_player.path];
    }

    if (_fullscreen)
        [self fullscreenMode:NO];

    [[UIApplication sharedApplication] setIdleTimerDisabled:_savedIdleTimer];

    [_activityIndicatorView stopAnimating];
    _player.interrupted = YES;

    LoggerStream(1, @"viewWillDisappear %@", self);
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation {
    return (interfaceOrientation != UIInterfaceOrientationPortraitUpsideDown);
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [self showHUD:YES];
    [self pause];

    LoggerStream(1, @"applicationWillResignActive");
}

#pragma mark - gesture recognizer

- (void)handleTap:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateEnded) {

        if (sender == _tapGestureRecognizer) {

            [self showHUD:_hiddenHUD];

        } else if (sender == _doubleTapGestureRecognizer) {

            UIView *frameView = [_player renderView];

            if (frameView.contentMode == UIViewContentModeScaleAspectFit)
                frameView.contentMode = UIViewContentModeScaleAspectFill;
            else
                frameView.contentMode = UIViewContentModeScaleAspectFit;

        }
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateEnded) {

        const CGPoint vt = [sender velocityInView:self.view];
        const CGPoint pt = [sender translationInView:self.view];
        const CGFloat sp = MAX(0.1, log10(fabsf(vt.x)) - 1.0);
        const CGFloat sc = fabsf(pt.x) * 0.33 * sp;
        if (sc > 10) {

            const CGFloat ff = pt.x > 0 ? 1.0 : -1.0;
            [self setMoviePosition:_player.moviePosition + ff * MIN(sc, 600.0)];
        }
        //LoggerStream(2, @"pan %.2f %.2f %.2f sec", pt.x, vt.x, sc);
    }
}

#pragma mark - public

- (BOOL)playing {
    return _player.state == KxPlayStatePlaying;
}

- (void)play {
    [_player play];
    _disableUpdateHUD = NO;

#ifdef DEBUG
    _debugStartTime = -1;
#endif

    [self updatePlayButton];
    LoggerStream(1, @"play movie");
}

- (void)pause {
    [_player pause];
    [self updatePlayButton];
    LoggerStream(1, @"pause movie");
}

- (void)setMoviePosition:(CGFloat)position {
    _disableUpdateHUD = YES;
    [_player seek:position];
}

#pragma mark - actions

- (void)doneDidTouch:(id)sender {
    if (self.presentingViewController || !self.navigationController)
        [self dismissViewControllerAnimated:YES completion:nil];
    else
        [self.navigationController popViewControllerAnimated:YES];
}

- (void)infoDidTouch:(id)sender {

}

- (void)playDidTouch:(id)sender {
    if (self.playing)
        [self pause];
    else
        [self play];
}

- (void)forwardDidTouch:(id)sender {
    [self setMoviePosition:_player.moviePosition + 10];
}

- (void)rewindDidTouch:(id)sender {
    [self setMoviePosition:_player.moviePosition - 10];
}

- (void)progressDidChange:(id)sender {
    NSAssert(_player.duration != MAXFLOAT, @"bugcheck");
    UISlider *slider = sender;
    [self setMoviePosition:slider.value * _player.duration];
}

#pragma mark - private

- (void)restorePlay {
    NSNumber *n = [gHistory valueForKey:_player.path];
    if (n)
        [self setMoviePosition:n.floatValue];
    else
        [self play];
}

- (void)setupPresentView {
    UIView *frameView = [_player renderView];
    frameView.contentMode = UIViewContentModeScaleAspectFit;
//    frameView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleBottomMargin;
//    frameView.frame = self.view.bounds;
    frameView.frame = CGRectMake(0, 0, _player.outputWidth, _player.outputHeight);
    [self.view insertSubview:frameView atIndex:0];

    [self setupUserInteraction];

    if (_player.duration == MAXFLOAT) {

        _leftLabel.text = @"\u221E"; // infinity
        _leftLabel.font = [UIFont systemFontOfSize:14];

        CGRect frame;

        frame = _leftLabel.frame;
        frame.origin.x += 40;
        frame.size.width -= 40;
        _leftLabel.frame = frame;

        frame = _progressSlider.frame;
        frame.size.width += 40;
        _progressSlider.frame = frame;

    } else {

        [_progressSlider addTarget:self
                            action:@selector(progressDidChange:)
                  forControlEvents:UIControlEventValueChanged];
    }

    if (_player.validSubtitles) {

        CGSize size = self.view.bounds.size;

        _subtitlesLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, size.height, size.width, 0)];
        _subtitlesLabel.numberOfLines = 0;
        _subtitlesLabel.backgroundColor = [UIColor clearColor];
        _subtitlesLabel.opaque = NO;
        _subtitlesLabel.adjustsFontSizeToFitWidth = NO;
        _subtitlesLabel.textAlignment = NSTextAlignmentCenter;
        _subtitlesLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        _subtitlesLabel.textColor = [UIColor whiteColor];
        _subtitlesLabel.font = [UIFont systemFontOfSize:16];
        _subtitlesLabel.hidden = YES;

        [self.view addSubview:_subtitlesLabel];
    }
}

- (void)setupUserInteraction {
    UIView *view = [_player renderView];
    view.userInteractionEnabled = YES;

    _tapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    _tapGestureRecognizer.numberOfTapsRequired = 1;

    _doubleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    _doubleTapGestureRecognizer.numberOfTapsRequired = 2;

    [_tapGestureRecognizer requireGestureRecognizerToFail:_doubleTapGestureRecognizer];

    [view addGestureRecognizer:_doubleTapGestureRecognizer];
    [view addGestureRecognizer:_tapGestureRecognizer];

//    _panGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
//    _panGestureRecognizer.enabled = NO;
//    
//    [view addGestureRecognizer:_panGestureRecognizer];
}

- (void)tick {
    [self updateHUD];
}

- (void)presentSubtitles {
    NSString * ms = _player.currentSubtile;
    if (![_subtitlesLabel.text isEqualToString:ms]) {

        CGSize viewSize = self.view.bounds.size;
        CGSize size = [ms sizeWithFont:_subtitlesLabel.font
                     constrainedToSize:CGSizeMake(viewSize.width, viewSize.height * 0.5)
                         lineBreakMode:NSLineBreakByTruncatingTail];
        _subtitlesLabel.text = ms;
        _subtitlesLabel.frame = CGRectMake(0, viewSize.height - size.height - _bottomBar.frame.size.height,
                viewSize.width, size.height);
        _subtitlesLabel.hidden = NO;
    }
}

- (void)updateBottomBar {
    UIBarButtonItem *playPauseBtn = self.playing ? _pauseBtn : _playBtn;
    [_bottomBar                                        setItems:@[_spaceItem, _rewindBtn, _fixedSpaceItem, playPauseBtn,
            _fixedSpaceItem, _fforwardBtn, _spaceItem] animated:NO];
}

- (void)updatePlayButton {
    [self updateBottomBar];
}

- (void)updateHUD {
    if (_disableUpdateHUD)
        return;

    const CGFloat duration = _player.duration;
    const CGFloat position = _player.moviePosition;

    if (_progressSlider.state == UIControlStateNormal)
        _progressSlider.value = position / duration;
    _progressLabel.text = formatTimeInterval(position, NO);

    if (duration != MAXFLOAT)
        _leftLabel.text = formatTimeInterval(duration - position, YES);
}

- (void)showHUD:(BOOL)show {
    _hiddenHUD = !show;
    _panGestureRecognizer.enabled = _hiddenHUD;

    [[UIApplication sharedApplication] setIdleTimerDisabled:_hiddenHUD];

    [UIView animateWithDuration:0.2
                          delay:0.0
                        options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionTransitionNone
                     animations:^{

                         CGFloat alpha = _hiddenHUD ? 0 : 1;
                         _topBar.alpha = alpha;
                         _topHUD.alpha = alpha;
                         _bottomBar.alpha = alpha;
                     }
                     completion:nil];

}

- (void)fullscreenMode:(BOOL)on {
    _fullscreen = on;
    UIApplication *app = [UIApplication sharedApplication];
    [app setStatusBarHidden:on withAnimation:UIStatusBarAnimationNone];
    // if (!self.presentingViewController) {
    //[self.navigationController setNavigationBarHidden:on animated:YES];
    //[self.tabBarController setTabBarHidden:on animated:YES];
    // }
}

- (void)startLoading {
    if (_player.state == KxPlayStateLoading) {
        [_activityIndicatorView startAnimating];
    }
}

- (void)KxPlay:(KxPlay *)play stateChanged:(KxPlayState)state {
    if (state == KxPlayStateReadyPlay) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setupPresentView];
        });
        [_player play];
        if (!_timer) {
            _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *_Nonnull timer) {
                [self tick];
            }];
        }

    } else if (state == KxPlayStateLoading) {
        [self performSelector:@selector(startLoading) withObject:nil afterDelay:1];
    } else if (state == KxPlayStatePlaying) {
        [_activityIndicatorView stopAnimating];
        _disableUpdateHUD = NO;
    } else if (state == KxPlayStateEnd || state == KxPlayStateDecodeFailed || state == KxPlayStateDecodeInterrupted) {
        [_activityIndicatorView stopAnimating];
        [_timer invalidate];
        _timer = nil;
    }
    [self updatePlayButton];
}

- (void)KxPlay:(KxPlay *)play updateSubtitles:(NSString *)subtitle {
    [self presentSubtitles];
}

- (void)handleDecoderMovieError:(NSError *)error {
    UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:NSLocalizedString(@"Failure", nil)
                                                        message:[error localizedDescription]
                                                       delegate:nil
                                              cancelButtonTitle:NSLocalizedString(@"Close", nil)
                                              otherButtonTitles:nil];

    [alertView show];
}

@end

