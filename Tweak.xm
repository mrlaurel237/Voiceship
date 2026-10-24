// VoiceShift 0.5.0 — changeur de voix micro avec bouton flottant.
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <notify.h>
#include <substrate.h>
#include <pthread.h>
#include <stdio.h>
#include "vs_dsp.h"

// ───────────── Réglages partagés entre toutes les apps ─────────────
// Défaut : activé, hauteur +6 demi-tons, timbre +2,5 (voix grave -> voix féminine naturelle).
static volatile int   g_enabled = 1;
static volatile float g_semi    = 6.0f;     // hauteur de la voix (demi-tons)
static volatile float g_form    = 2.5f;     // timbre / formants (demi-tons)
static int  g_token = 0;
static BOOL g_isSpringBoard = NO;
static const char *kNote = "com.local.voiceshift.changed";
static const char *kConf[] = {
    "/var/jb/var/mobile/Library/Preferences/voiceshift.v4.conf",
    "/var/mobile/Library/Preferences/voiceshift.v4.conf" };

static void vs_apply(int en, float semi, float form) {
    if (semi < -12.f) semi = -12.f;
    if (semi >  12.f) semi =  12.f;
    if (form <  -6.f) form =  -6.f;
    if (form >   6.f) form =   6.f;
    g_semi = semi; g_form = form; g_enabled = en ? 1 : 0;
}
static void vs_load_file(void) {
    for (int k = 0; k < 2; k++) {
        FILE *f = fopen(kConf[k], "r");
        if (!f) continue;
        char line[64]; int e = g_enabled; float s = g_semi, fm = g_form;
        while (fgets(line, sizeof line, f)) {
            int ie; float is;
            if (sscanf(line, "enabled=%d", &ie) == 1) e = ie;
            else if (sscanf(line, "semitones=%f", &is) == 1) s = is;
            else if (sscanf(line, "formant=%f", &is) == 1) fm = is;
        }
        fclose(f); vs_apply(e, s, fm); return;
    }
}
static void vs_save_file(void) {          // ne réussit que dans les processus non sandboxés
    for (int k = 0; k < 2; k++) {
        FILE *f = fopen(kConf[k], "w");
        if (!f) continue;
        fprintf(f, "enabled=%d\nsemitones=%.1f\nformant=%.1f\n", g_enabled, g_semi, g_form);
        fclose(f); return;
    }
}
static void vs_pull_state(void) {         // lit l'état global (notifyd)
    uint64_t st = 0;
    if (notify_get_state(g_token, &st) != NOTIFY_STATUS_OK) return;
    if (!(st & (1ULL << 63))) return;
    vs_apply((int)(st & 1), ((float)((int)((st >> 8) & 0xFF) - 120)) / 10.0f,
             ((float)((int)((st >> 16) & 0xFF) - 120)) / 10.0f);
}
static void vs_push_state(void) {         // publie vers toutes les apps
    uint64_t st = (1ULL << 63) | (uint64_t)(g_enabled & 1)
                | ((uint64_t)((int)lroundf(g_semi * 10.f) + 120) << 8)
                | ((uint64_t)((int)lroundf(g_form * 10.f) + 120) << 16);
    notify_set_state(g_token, st);
    notify_post(kNote);
}

// ───────────── Traitement audio ─────────────
#define MAXSLOTS 16
typedef struct { void *key; int ch; VSPitch p; } Slot;
typedef struct { void *unit; int kind; float sr; } UnitInfo;   // kind: 1=float32, 2=s16, 0=non géré
static Slot     g_slots[MAXSLOTS];  static int g_nslots = 0, g_evict = 0;
static UnitInfo g_units[MAXSLOTS];  static int g_nunits = 0;
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;
// compteurs de diagnostic : 0=AudioUnit 1=AudioQueue 2=Capture 3=Tap AVAudioEngine
static volatile uint32_t g_cnt[4] = {0, 0, 0, 0};

static VSPitch *slot_for(void *key, int ch, float sr) {
    int n = g_nslots;
    for (int i = 0; i < n; i++) if (g_slots[i].key == key && g_slots[i].ch == ch) return &g_slots[i].p;
    pthread_mutex_lock(&g_mx);
    for (int i = 0; i < g_nslots; i++) if (g_slots[i].key == key && g_slots[i].ch == ch) { pthread_mutex_unlock(&g_mx); return &g_slots[i].p; }
    Slot *s;
    if (g_nslots < MAXSLOTS) { s = &g_slots[g_nslots]; }
    else { s = &g_slots[g_evict++ % MAXSLOTS]; }          // plein : on recycle le plus ancien
    s->key = key; s->ch = ch; vs_pitch_init(&s->p, sr);
    __sync_synchronize();
    if (g_nslots < MAXSLOTS && s == &g_slots[g_nslots]) g_nslots++;
    pthread_mutex_unlock(&g_mx);
    return &s->p;
}

// Traite un canal : kind 1 = float32, 2 = int16 ; stride en échantillons
static void vs_process_channel(void *key, int ch, float sr, int kind, void *base, int frames, int stride) {
    float semi = g_semi, form = g_form;
    if (!g_enabled || (fabsf(semi) < 0.05f && fabsf(form) < 0.05f) || !base || frames <= 0 || stride <= 0) return;
    VSPitch *p = slot_for(key, ch, sr);
    if (!p) return;
    float target = exp2f(semi / 12.f), alpha = exp2f(form / 12.f);
    float in[512], out[512];
    int done = 0;
    while (done < frames) {
        int n = (frames - done) > 512 ? 512 : (frames - done);
        if (kind == 1) {
            float *d = (float *)base + (size_t)done * stride;
            for (int i = 0; i < n; i++) in[i] = d[(size_t)i * stride];
            vs_pitch_chunk(p, in, out, n, target, alpha);
            for (int i = 0; i < n; i++) { float v = out[i]; d[(size_t)i * stride] = v > 1.f ? 1.f : (v < -1.f ? -1.f : v); }
        } else {
            int16_t *d = (int16_t *)base + (size_t)done * stride;
            for (int i = 0; i < n; i++) in[i] = d[(size_t)i * stride] * (1.f / 32768.f);
            vs_pitch_chunk(p, in, out, n, target, alpha);
            for (int i = 0; i < n; i++) {
                float v = out[i] * 32768.f; v = v > 32767.f ? 32767.f : (v < -32768.f ? -32768.f : v);
                d[(size_t)i * stride] = (int16_t)v;
            }
        }
        done += n;
    }
}

// Traite un tampon PCM décrit par un ASBD (AudioQueue, CMSampleBuffer…)
static void vs_process_asbd(void *key, const AudioStreamBasicDescription *a, void *data, UInt32 bytes, int src) {
    g_cnt[src]++;
    if (!g_enabled || !data || !a || a->mFormatID != kAudioFormatLinearPCM) return;
    int kind = 0;
    if ((a->mFormatFlags & kAudioFormatFlagIsFloat) && a->mBitsPerChannel == 32) kind = 1;
    else if (!(a->mFormatFlags & kAudioFormatFlagIsFloat) && a->mBitsPerChannel == 16) kind = 2;
    if (!kind) return;
    int nch = a->mChannelsPerFrame ? (int)a->mChannelsPerFrame : 1;
    int bps = (kind == 1) ? 4 : 2;
    int frames = (int)(bytes / (UInt32)(bps * nch));
    float sr = a->mSampleRate > 8000 ? (float)a->mSampleRate : 44100.f;
    BOOL planar = (a->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    for (int c = 0; c < nch && c < 8; c++) {
        if (planar) vs_process_channel(key, c, sr, kind, (char *)data + (size_t)c * frames * bps, frames, 1);
        else        vs_process_channel(key, c, sr, kind, (char *)data + (size_t)c * bps, frames, nch);
    }
}

// ── 1) AudioUnit (RemoteIO / VoiceProcessingIO) ──
static UnitInfo *unit_info(AudioUnit u) {
    for (int i = 0; i < g_nunits; i++) if (g_units[i].unit == (void *)u) return &g_units[i];
    pthread_mutex_lock(&g_mx);
    for (int i = 0; i < g_nunits; i++) if (g_units[i].unit == (void *)u) { pthread_mutex_unlock(&g_mx); return &g_units[i]; }
    UnitInfo *ui = (g_nunits < MAXSLOTS) ? &g_units[g_nunits] : &g_units[g_nunits - 1];
    AudioStreamBasicDescription d; UInt32 sz = sizeof d; int kind = 0;
    memset(&d, 0, sizeof d);
    if (AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &d, &sz) == noErr
        && d.mFormatID == kAudioFormatLinearPCM) {
        if ((d.mFormatFlags & kAudioFormatFlagIsFloat) && d.mBitsPerChannel == 32) kind = 1;
        else if (!(d.mFormatFlags & kAudioFormatFlagIsFloat) && d.mBitsPerChannel == 16) kind = 2;
    }
    ui->unit = (void *)u; ui->kind = kind; ui->sr = d.mSampleRate > 8000 ? (float)d.mSampleRate : 44100.f;
    __sync_synchronize();
    if (g_nunits < MAXSLOTS) g_nunits++;
    pthread_mutex_unlock(&g_mx);
    return ui;
}

static OSStatus (*orig_render)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                               UInt32, UInt32, AudioBufferList *);
static OSStatus hook_render(AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                            UInt32 bus, UInt32 frames, AudioBufferList *io) {
    OSStatus r = orig_render(unit, flags, ts, bus, frames, io);
    if (r != noErr || bus != 1 || !io) return r;                    // bus 1 = micro
    g_cnt[0]++;
    if (!g_enabled) return r;
    UnitInfo *ui = unit_info(unit);
    if (!ui || !ui->kind) return r;
    for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
        AudioBuffer *ab = &io->mBuffers[b];
        int nch = ab->mNumberChannels ? (int)ab->mNumberChannels : 1;
        if (!ab->mData) continue;
        for (int c = 0; c < nch && c < 8; c++) {
            int bps = ui->kind == 1 ? 4 : 2;
            vs_process_channel((void *)unit, (int)b * 8 + c, ui->sr, ui->kind,
                               (char *)ab->mData + (size_t)c * bps, (int)frames, nch);
        }
    }
    return r;
}

// ── 2) AudioQueue (beaucoup d'apps d'enregistrement : WhatsApp, etc.) ──
typedef struct { AudioQueueInputCallback cb; void *user; AudioStreamBasicDescription fmt; } AQCtx;
static void aq_cb(void *user, AudioQueueRef q, AudioQueueBufferRef buf, const AudioTimeStamp *ts,
                  UInt32 n, const AudioStreamPacketDescription *d) {
    AQCtx *c = (AQCtx *)user;
    vs_process_asbd((void *)q, &c->fmt, buf->mAudioData, buf->mAudioDataByteSize, 1);
    c->cb(c->user, q, buf, ts, n, d);
}
static OSStatus (*orig_aqNew)(const AudioStreamBasicDescription *, AudioQueueInputCallback, void *,
                              CFRunLoopRef, CFStringRef, UInt32, AudioQueueRef *);
static OSStatus hook_aqNew(const AudioStreamBasicDescription *fmt, AudioQueueInputCallback cb, void *user,
                           CFRunLoopRef rl, CFStringRef mode, UInt32 flags, AudioQueueRef *out) {
    if (fmt && cb && fmt->mFormatID == kAudioFormatLinearPCM) {
        AQCtx *c = (AQCtx *)calloc(1, sizeof(AQCtx));
        c->cb = cb; c->user = user; c->fmt = *fmt;
        return orig_aqNew(fmt, aq_cb, c, rl, mode, flags, out);
    }
    return orig_aqNew(fmt, cb, user, rl, mode, flags, out);
}
static OSStatus (*orig_aqNewQ)(AudioQueueRef *, const AudioStreamBasicDescription *, UInt32,
                               dispatch_queue_t, AudioQueueInputCallbackBlock);
static OSStatus hook_aqNewQ(AudioQueueRef *out, const AudioStreamBasicDescription *fmt, UInt32 flags,
                            dispatch_queue_t q, AudioQueueInputCallbackBlock block) {
    if (fmt && block && fmt->mFormatID == kAudioFormatLinearPCM) {
        AudioStreamBasicDescription f = *fmt;
        AudioQueueInputCallbackBlock w = ^(AudioQueueRef aq, AudioQueueBufferRef buf, const AudioTimeStamp *ts,
                                           UInt32 n, const AudioStreamPacketDescription *d) {
            vs_process_asbd((void *)aq, &f, buf->mAudioData, buf->mAudioDataByteSize, 1);
            block(aq, buf, ts, n, d);
        };
        return orig_aqNewQ(out, fmt, flags, q, w);
    }
    return orig_aqNewQ(out, fmt, flags, q, block);
}

// ── 3) AVCaptureAudioDataOutput (apps caméra / vidéo avec delegate) ──
static NSMutableDictionary *g_capOrig = nil;      // nom de classe -> IMP d'origine
static IMP orig_setDelegate = NULL;
static IMP orig_tap = NULL;

static void vs_process_sample_buffer(void *key, CMSampleBufferRef sb) {
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    if (!fd) return;
    const AudioStreamBasicDescription *a = CMAudioFormatDescriptionGetStreamBasicDescription(fd);
    if (!a || a->mFormatID != kAudioFormatLinearPCM) return;
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    if (!bb) return;
    size_t len = 0, total = 0; char *p = NULL;
    if (CMBlockBufferGetDataPointer(bb, 0, &len, &total, &p) != kCMBlockBufferNoErr || !p || len != total) return;
    vs_process_asbd(key, a, p, (UInt32)len, 2);
}
static void vs_cap_imp(id self, SEL _cmd, AVCaptureOutput *out, CMSampleBufferRef sb, AVCaptureConnection *conn) {
    if ([out isKindOfClass:AVCaptureAudioDataOutput.class]) vs_process_sample_buffer((__bridge void *)out, sb);
    IMP o = NULL;
    for (Class k = object_getClass(self); k && !o; k = class_getSuperclass(k)) {
        NSValue *v = g_capOrig[NSStringFromClass(k)];
        if (v) o = (IMP)[v pointerValue];
    }
    if (o) ((void (*)(id, SEL, id, CMSampleBufferRef, id))o)(self, _cmd, out, sb, conn);
}
static Class vs_owner(Class c, SEL s) {
    for (Class k = c; k; k = class_getSuperclass(k)) {
        unsigned n = 0; Method *l = class_copyMethodList(k, &n); BOOL f = NO;
        for (unsigned i = 0; i < n; i++) if (method_getName(l[i]) == s) { f = YES; break; }
        free(l);
        if (f) return k;
    }
    return Nil;
}
static void vs_swizzle_delegate(id del) {
    if (!del) return;
    SEL s = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Class owner = vs_owner(object_getClass(del), s);
    if (!owner) return;
    @synchronized ([NSProcessInfo processInfo]) {
        if (!g_capOrig) g_capOrig = [NSMutableDictionary new];
        NSString *name = NSStringFromClass(owner);
        if (g_capOrig[name]) return;
        Method m = class_getInstanceMethod(owner, s);
        if (!m) return;
        g_capOrig[name] = [NSValue valueWithPointer:(void *)method_getImplementation(m)];
        method_setImplementation(m, (IMP)vs_cap_imp);
    }
}
static void vs_setdel_imp(id self, SEL _cmd, id delegate, dispatch_queue_t q) {
    vs_swizzle_delegate(delegate);
    ((void (*)(id, SEL, id, dispatch_queue_t))orig_setDelegate)(self, _cmd, delegate, q);
}

// ── 4) AVAudioEngine : tap sur le micro (inputNode) ──
static void vs_process_pcmbuffer(void *key, AVAudioPCMBuffer *buf) {
    g_cnt[3]++;
    if (!g_enabled) return;
    int n = (int)buf.frameLength, nch = (int)buf.format.channelCount, st = (int)buf.stride;
    float sr = (float)buf.format.sampleRate;
    if (buf.floatChannelData) {
        for (int c = 0; c < nch && c < 8; c++) vs_process_channel(key, c, sr, 1, buf.floatChannelData[c], n, st);
    } else if (buf.int16ChannelData) {
        for (int c = 0; c < nch && c < 8; c++) vs_process_channel(key, c, sr, 2, buf.int16ChannelData[c], n, st);
    }
}
static void vs_tap_imp(id self, SEL _cmd, AVAudioNodeBus bus, AVAudioFrameCount size, AVAudioFormat *fmt, AVAudioNodeTapBlock block) {
    AVAudioNodeTapBlock w = block;
    if (block && [self isKindOfClass:NSClassFromString(@"AVAudioInputNode")]) {
        void *key = (__bridge void *)self;
        w = ^(AVAudioPCMBuffer *buf, AVAudioTime *when) { vs_process_pcmbuffer(key, buf); block(buf, when); };
    }
    ((void (*)(id, SEL, AVAudioNodeBus, AVAudioFrameCount, AVAudioFormat *, AVAudioNodeTapBlock))orig_tap)(self, _cmd, bus, size, fmt, w);
}

static void vs_install_objc_hooks(void) {
    static BOOL tapDone = NO, capDone = NO;
    if (!tapDone) {
        Class c = NSClassFromString(@"AVAudioNode");
        Method m = c ? class_getInstanceMethod(c, @selector(installTapOnBus:bufferSize:format:block:)) : NULL;
        if (m) { orig_tap = method_setImplementation(m, (IMP)vs_tap_imp); tapDone = YES; }
    }
    if (!capDone) {
        Class c = NSClassFromString(@"AVCaptureAudioDataOutput");
        Method m = c ? class_getInstanceMethod(c, @selector(setSampleBufferDelegate:queue:)) : NULL;
        if (m) { orig_setDelegate = method_setImplementation(m, (IMP)vs_setdel_imp); capDone = YES; }
    }
}

// ───────────── Interface : bouton flottant + panneau ─────────────
@interface VSRootVC : UIViewController
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UISwitch *sw;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UISlider *fslider;
@property (nonatomic, strong) UILabel *fLabel;
@property (nonatomic, strong) UILabel *valueLabel;
@property (nonatomic, strong) UILabel *diag;
@property (nonatomic, strong) NSTimer *timer;
- (void)refreshFromState;
@end

@interface VSWindow : UIWindow @end
@implementation VSWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (v == self || v == self.rootViewController.view) return nil;   // laisse passer les touches vers l'app
    return v;
}
@end

static VSWindow *g_win = nil;
static VSRootVC *g_vc = nil;

@implementation VSRootVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    self.fab = [UIButton buttonWithType:UIButtonTypeCustom];
    self.fab.frame = CGRectMake(16, 140, 52, 52);
    self.fab.backgroundColor = [UIColor colorWithRed:0.35 green:0.25 blue:0.85 alpha:0.92];
    self.fab.layer.cornerRadius = 26;
    self.fab.layer.shadowOpacity = 0.35; self.fab.layer.shadowRadius = 5; self.fab.layer.shadowOffset = CGSizeMake(0, 2);
    [self.fab setTitle:@"🎙" forState:UIControlStateNormal];
    self.fab.titleLabel.font = [UIFont systemFontOfSize:24];
    [self.fab addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.fab addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragFab:)]];
    [self.view addSubview:self.fab];

    UIView *p = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 346)];
    p.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.96];
    p.layer.cornerRadius = 18; p.hidden = YES;
    self.panel = p;

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 200, 28)];
    t.text = @"VoiceShift"; t.textColor = UIColor.whiteColor; t.font = [UIFont boldSystemFontOfSize:20];
    [p addSubview:t];
    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(256, 8, 36, 36); [x setTitle:@"✕" forState:UIControlStateNormal];
    [x addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [p addSubview:x];

    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(16, 56, 180, 31)];
    l1.text = @"Activer la voix modifiée"; l1.textColor = UIColor.whiteColor; l1.font = [UIFont systemFontOfSize:15];
    [p addSubview:l1];
    self.sw = [[UISwitch alloc] initWithFrame:CGRectMake(235, 56, 51, 31)];
    [self.sw addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged];
    [p addSubview:self.sw];

    self.valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 100, 268, 22)];
    self.valueLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1]; self.valueLabel.font = [UIFont systemFontOfSize:14];
    [p addSubview:self.valueLabel];

    UILabel *lo = [[UILabel alloc] initWithFrame:CGRectMake(16, 126, 60, 18)];
    lo.text = @"♂ grave"; lo.textColor = [UIColor colorWithWhite:0.6 alpha:1]; lo.font = [UIFont systemFontOfSize:11];
    [p addSubview:lo];
    UILabel *hi = [[UILabel alloc] initWithFrame:CGRectMake(224, 126, 60, 18)];
    hi.text = @"aigu ♀"; hi.textAlignment = NSTextAlignmentRight;
    hi.textColor = [UIColor colorWithWhite:0.6 alpha:1]; hi.font = [UIFont systemFontOfSize:11];
    [p addSubview:hi];

    self.slider = [[UISlider alloc] initWithFrame:CGRectMake(16, 144, 268, 30)];
    self.slider.minimumValue = -12; self.slider.maximumValue = 12;
    [self.slider addTarget:self action:@selector(slChanged:) forControlEvents:UIControlEventValueChanged];
    [self.slider addTarget:self action:@selector(slDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [p addSubview:self.slider];

    self.fLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 182, 268, 22)];
    self.fLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1]; self.fLabel.font = [UIFont systemFontOfSize:14];
    [p addSubview:self.fLabel];
    UILabel *flo = [[UILabel alloc] initWithFrame:CGRectMake(16, 206, 90, 18)];
    flo.text = @"timbre ♂"; flo.textColor = [UIColor colorWithWhite:0.6 alpha:1]; flo.font = [UIFont systemFontOfSize:11];
    [p addSubview:flo];
    UILabel *fhi = [[UILabel alloc] initWithFrame:CGRectMake(194, 206, 90, 18)];
    fhi.text = @"timbre ♀"; fhi.textAlignment = NSTextAlignmentRight;
    fhi.textColor = [UIColor colorWithWhite:0.6 alpha:1]; fhi.font = [UIFont systemFontOfSize:11];
    [p addSubview:fhi];
    self.fslider = [[UISlider alloc] initWithFrame:CGRectMake(16, 224, 268, 30)];
    self.fslider.minimumValue = -6; self.fslider.maximumValue = 6;
    [self.fslider addTarget:self action:@selector(fmChanged:) forControlEvents:UIControlEventValueChanged];
    [self.fslider addTarget:self action:@selector(slDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [p addSubview:self.fslider];

    NSArray *titles = @[@"Homme → Femme", @"Femme → Homme", @"Original"];
    for (int i = 0; i < 3; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(12 + i * 93, 264, 90, 40);
        b.titleLabel.font = [UIFont systemFontOfSize:12]; b.titleLabel.numberOfLines = 2; b.titleLabel.textAlignment = NSTextAlignmentCenter;
        b.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1]; b.layer.cornerRadius = 10;
        [b setTitle:titles[i] forState:UIControlStateNormal]; b.tag = i;
        [b addTarget:self action:@selector(preset:) forControlEvents:UIControlEventTouchUpInside];
        [p addSubview:b];
    }
    self.diag = [[UILabel alloc] initWithFrame:CGRectMake(16, 308, 268, 32)];
    self.diag.textColor = [UIColor colorWithWhite:0.6 alpha:1]; self.diag.font = [UIFont systemFontOfSize:11];
    self.diag.numberOfLines = 2;
    [p addSubview:self.diag];

    [self.view addSubview:p];
    [self refreshFromState];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.panel.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
}
- (void)refreshFromState {
    if (!self.sw) return;
    self.sw.on = g_enabled;
    self.slider.value = g_semi;
    self.slider.enabled = g_enabled;
    self.fslider.value = g_form;
    self.fslider.enabled = g_enabled;
    float s = g_semi;
    NSString *d = s > 0.05f ? @"plus aigu" : (s < -0.05f ? @"plus grave" : @"voix d'origine");
    self.valueLabel.text = [NSString stringWithFormat:@"Hauteur : %+.1f demi-tons — %@", s, d];
    self.fLabel.text = [NSString stringWithFormat:@"Timbre : %+.1f (%@)", g_form, g_form > 0.05f ? @"plus clair" : (g_form < -0.05f ? @"plus sombre" : @"d'origine")];
    self.fab.alpha = g_enabled ? 0.92 : 0.45;
}
- (void)updateDiag {
    self.diag.text = [NSString stringWithFormat:@"Audio micro vu dans cette app :\nAU %u · AQ %u · Cap %u · Tap %u",
                      g_cnt[0], g_cnt[1], g_cnt[2], g_cnt[3]];
}
- (void)togglePanel {
    self.panel.hidden = !self.panel.hidden;
    [self refreshFromState];
    [self.timer invalidate]; self.timer = nil;
    if (!self.panel.hidden) {
        [self updateDiag];
        __weak typeof(self) ws = self;
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { [ws updateDiag]; }];
    }
}
- (void)dragFab:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    CGPoint c = CGPointMake(self.fab.center.x + t.x, self.fab.center.y + t.y);
    CGRect b = self.view.bounds;
    c.x = MAX(26, MIN(b.size.width - 26, c.x)); c.y = MAX(60, MIN(b.size.height - 60, c.y));
    self.fab.center = c; [g setTranslation:CGPointZero inView:self.view];
}
- (void)swChanged:(UISwitch *)s { vs_apply(s.on, g_semi, g_form); vs_push_state(); [self refreshFromState]; if (g_isSpringBoard) vs_save_file(); }
- (void)slChanged:(UISlider *)s {
    float v = roundf(s.value * 2.f) / 2.f;          // pas de 0,5 demi-ton
    vs_apply(g_enabled, v, g_form); vs_push_state(); [self refreshFromState];
}
- (void)fmChanged:(UISlider *)s {
    float v = roundf(s.value * 2.f) / 2.f;
    vs_apply(g_enabled, g_semi, v); vs_push_state(); [self refreshFromState];
}
- (void)slDone:(UISlider *)s { if (g_isSpringBoard) vs_save_file(); }
- (void)preset:(UIButton *)b {
    float v  = b.tag == 0 ?  6.f : (b.tag == 1 ? -6.f : 0.f);
    float fm = b.tag == 0 ? 2.5f : (b.tag == 1 ? -2.5f : 0.f);
    vs_apply(1, v, fm); vs_push_state(); [self refreshFromState]; if (g_isSpringBoard) vs_save_file();
}
@end

static void vs_show_ui(void) {
    if (g_win) return;
    UIWindowScene *scene = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:UIWindowScene.class] && sc.activationState == UISceneActivationStateForegroundActive) { scene = (UIWindowScene *)sc; break; }
    if (scene) g_win = [[VSWindow alloc] initWithWindowScene:scene];
    else       g_win = [[VSWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    g_win.windowLevel = UIWindowLevelAlert + 100;
    g_win.backgroundColor = UIColor.clearColor;
    g_vc = [VSRootVC new];
    g_win.rootViewController = g_vc;
    g_win.hidden = NO;
}

// ───────────── Initialisation ─────────────
%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *path = NSBundle.mainBundle.bundlePath ?: @"";
        g_isSpringBoard = [bid isEqualToString:@"com.apple.springboard"];
        BOOL isApp = g_isSpringBoard || [path hasSuffix:@".app"];
        if (!isApp) return;                         // pas d'extensions ni de daemons

        vs_load_file();                             // défaut +5 si le fichier est absent/illisible
        notify_register_dispatch(kNote, &g_token, dispatch_get_main_queue(), ^(int t) {
            vs_pull_state();
            if (g_isSpringBoard) vs_save_file();    // SpringBoard fait la sauvegarde sur disque
            [g_vc refreshFromState];
        });
        if (g_isSpringBoard) vs_push_state();       // au démarrage : sème l'état pour toutes les apps
        else vs_pull_state();

        MSHookFunction((void *)AudioUnitRender, (void *)hook_render, (void **)&orig_render);
        MSHookFunction((void *)AudioQueueNewInput, (void *)hook_aqNew, (void **)&orig_aqNew);
        MSHookFunction((void *)AudioQueueNewInputWithDispatchQueue, (void *)hook_aqNewQ, (void **)&orig_aqNewQ);
        vs_install_objc_hooks();

        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { vs_install_objc_hooks(); vs_show_ui(); }];
    }
}
