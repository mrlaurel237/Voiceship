// VSTest.m — mode test A/B.
// 1. « Enregistrer » : jusqu'à 5 s de micro brut (VoiceShift ne touche pas au micro pendant le test).
// 2. « A » rejoue ta voix telle quelle, « B » la rejoue transformée avec les réglages actuels.
//    B est recalculé à chaque appui : on peut bouger un curseur puis réécouter.
// Le calcul de B sert aussi de mesure : temps de calcul / durée = usage processeur réel sur ton iPhone.
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#include "VSTest.h"
#include "VSState.h"
#include "VSEngine.h"

extern IMP g_vsOrigTap;
#define REC_SECONDS 5.0

@interface VSTester ()
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioPlayerNode *player;
@property (nonatomic, readwrite) BOOL recording, busy, hasRecording;
@property (nonatomic, copy) NSString *savedCategory, *savedMode;
@property (nonatomic) AVAudioSessionCategoryOptions savedOptions;
@property (nonatomic) BOOL sessionTaken;
@property (nonatomic, strong) NSTimer *stopTimer;
@end

@implementation VSTester {
    float *_rec; volatile int _recLen; int _recCap; double _sr;
    float *_proc; int _procLen; BOOL _computing;
}

+ (instancetype)shared { static VSTester *t; static dispatch_once_t o; dispatch_once(&o, ^{ t = [VSTester new]; }); return t; }

- (void)say:(NSString *)s { if (self.onUpdate) self.onUpdate(s); }

- (BOOL)takeSession:(NSString **)err {
    AVAudioSession *as = AVAudioSession.sharedInstance;
    NSString *mode = as.mode;
    if ([mode isEqualToString:AVAudioSessionModeVoiceChat] || [mode isEqualToString:AVAudioSessionModeVideoChat]) {
        *err = @"Un appel semble en cours : termine-le avant de tester."; return NO;
    }
    if (!self.sessionTaken) {
        self.savedCategory = as.category; self.savedMode = as.mode; self.savedOptions = as.categoryOptions;
    }
    NSError *e = nil;
    [as setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault
            options:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetoothA2DP error:&e];
    if (!e) [as setActive:YES error:&e];
    if (e) { *err = [NSString stringWithFormat:@"Audio indisponible ici (%@).", e.localizedDescription]; return NO; }
    self.sessionTaken = YES;
    return YES;
}
- (void)giveBackSession {
    if (!self.sessionTaken) return;
    AVAudioSession *as = AVAudioSession.sharedInstance;
    if (self.savedCategory) [as setCategory:self.savedCategory mode:self.savedMode ?: AVAudioSessionModeDefault options:self.savedOptions error:nil];
    self.sessionTaken = NO;
}

- (void)teardownEngine {
    if (self.engine) {
        @try { [self.engine.inputNode removeTapOnBus:0]; } @catch (NSException *x) {}
        [self.player stop];
        [self.engine stop];
    }
    self.engine = nil; self.player = nil;
}

- (void)stopAll {
    [self.stopTimer invalidate]; self.stopTimer = nil;
    [self teardownEngine];
    self.recording = NO; self.busy = NO;
    g_vsTestActive = 0;
    [self giveBackSession];
}

- (void)toggleRecording {
    if (self.recording) { [self finishRecording]; return; }
    AVAudioSession *as = AVAudioSession.sharedInstance;
    if (as.recordPermission == AVAudioSessionRecordPermissionUndetermined) {
        [as requestRecordPermission:^(BOOL ok) { dispatch_async(dispatch_get_main_queue(), ^{ if (ok) [self toggleRecording]; }); }];
        return;
    }
    if (as.recordPermission != AVAudioSessionRecordPermissionGranted) {
        [self say:@"Cette app n'a pas accès au micro. Fais le test depuis WhatsApp ou TikTok."]; return;
    }
    [self stopAll];
    NSString *err = nil;
    g_vsTestActive = 1;                                    // le micro du test n'est pas transformé
    if (![self takeSession:&err]) { g_vsTestActive = 0; [self say:err]; return; }

    self.engine = [AVAudioEngine new];
    AVAudioInputNode *inNode = self.engine.inputNode;
    AVAudioFormat *fmt = [inNode outputFormatForBus:0];
    if (fmt.sampleRate < 8000 || fmt.channelCount < 1) { [self stopAll]; [self say:@"Micro indisponible."]; return; }
    _sr = fmt.sampleRate;
    int cap = (int)(_sr * REC_SECONDS);
    if (cap > _recCap) { free(_rec); _rec = (float *)calloc((size_t)cap, sizeof(float)); _recCap = _rec ? cap : 0; }
    if (!_rec) { [self stopAll]; [self say:@"Mémoire insuffisante."]; return; }
    _recLen = 0;
    __unsafe_unretained VSTester *ws = self;
    float *rec = _rec; int recCap = _recCap;
    AVAudioNodeTapBlock tap = ^(AVAudioPCMBuffer *b, AVAudioTime *when) {
        if (!b.floatChannelData) return;
        int n = (int)b.frameLength, have = ws->_recLen;
        if (have + n > recCap) n = recCap - have;
        if (n <= 0) return;
        const float *src = b.floatChannelData[0];
        for (int i = 0; i < n; i++) rec[have + i] = src[(size_t)i * b.stride];
        ws->_recLen = have + n;
    };
    // on appelle l'implémentation d'origine : le tap du test ne passe pas par VoiceShift
    if (g_vsOrigTap)
        ((void (*)(id, SEL, AVAudioNodeBus, AVAudioFrameCount, AVAudioFormat *, AVAudioNodeTapBlock))g_vsOrigTap)(inNode, @selector(installTapOnBus:bufferSize:format:block:), 0, 1024, fmt, tap);
    else
        [inNode installTapOnBus:0 bufferSize:1024 format:fmt block:tap];
    NSError *e = nil;
    [self.engine prepare];
    if (![self.engine startAndReturnError:&e]) { [self stopAll]; [self say:@"Impossible de démarrer le micro."]; return; }
    self.recording = YES;
    [self say:@"● Parle maintenant (5 s max)… touche « Stop » pour finir."];
    self.stopTimer = [NSTimer scheduledTimerWithTimeInterval:REC_SECONDS + 0.2 repeats:NO block:^(NSTimer *t) { [ws finishRecording]; }];
}

- (void)finishRecording {
    if (!self.recording) return;
    [self.stopTimer invalidate]; self.stopTimer = nil;
    [self teardownEngine];
    self.recording = NO;
    self.hasRecording = _recLen > (int)(_sr * 0.3);
    g_vsTestActive = 0;
    [self giveBackSession];
    [self say:self.hasRecording ? [NSString stringWithFormat:@"Enregistré : %.1f s. Écoute A puis B.", _recLen / _sr]
                                : @"Enregistrement trop court, recommence."];
}

- (void)playBuffer:(const float *)data length:(int)n label:(NSString *)label {
    NSString *err = nil;
    [self teardownEngine];
    g_vsTestActive = 1;
    if (![self takeSession:&err]) { g_vsTestActive = 0; [self say:err]; return; }
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:_sr channels:1 interleaved:NO];
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:(AVAudioFrameCount)n];
    if (!buf) { [self stopAll]; return; }
    memcpy(buf.floatChannelData[0], data, sizeof(float) * (size_t)n);
    buf.frameLength = (AVAudioFrameCount)n;
    self.engine = [AVAudioEngine new];
    self.player = [AVAudioPlayerNode new];
    [self.engine attachNode:self.player];
    [self.engine connect:self.player to:self.engine.mainMixerNode format:fmt];
    NSError *e = nil;
    if (![self.engine startAndReturnError:&e]) { [self stopAll]; [self say:@"Lecture impossible."]; return; }
    self.busy = YES;
    __weak VSTester *ws = self;
    [self.player scheduleBuffer:buf completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack completionHandler:^(AVAudioPlayerNodeCompletionCallbackType t) {
        dispatch_async(dispatch_get_main_queue(), ^{ [ws stopAll]; });
    }];
    [self.player play];
    [self say:label];
}

- (void)playOriginal {
    if (!self.hasRecording || self.recording) return;
    [self playBuffer:_rec length:_recLen label:@"▶ A : ta voix d'origine"];
}

- (void)playProcessed {
    if (!self.hasRecording || self.recording || _computing) return;
    VSSettings s; vs_state_snapshot(&s);
    int n = _recLen; double sr = _sr;
    float *in = (float *)malloc(sizeof(float) * (size_t)n), *out = (float *)malloc(sizeof(float) * (size_t)n);
    if (!in || !out) { free(in); free(out); return; }
    memcpy(in, _rec, sizeof(float) * (size_t)n);
    _computing = YES;
    [self say:@"Calcul de la voix transformée…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        double secs = 0; float lat = 0;
        int run = vs_engine_render_offline(&s, (float)sr, in, out, n, &secs, &lat);
        // on retire la latence du moteur pour que A et B soient alignés
        int shift = (int)(lat * sr / 1000.0);
        if (shift > 0 && shift < n) { memmove(out, out + shift, sizeof(float) * (size_t)(n - shift)); memset(out + n - shift, 0, sizeof(float) * (size_t)shift); }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_computing = NO;
            free(self->_proc); self->_proc = out; self->_procLen = n;
            free(in);
            double cpu = secs / (n / sr) * 100.0;
            NSString *lbl = [NSString stringWithFormat:@"▶ B : moteur %s · calcul %.0f ms pour %.1f s (≈ %.1f %% du processeur) · latence %.0f ms",
                             vs_engine_run_name(run), secs * 1000.0, n / sr, cpu, lat];
            [self playBuffer:self->_proc length:self->_procLen label:lbl];
        });
    });
}
@end
