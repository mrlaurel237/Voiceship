// VoiceShift 0.3.0 — changeur de voix micro avec bouton flottant.
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#include <substrate.h>
#include <pthread.h>
#include <stdio.h>
#include "vs_dsp.h"

// ───────────── Réglages partagés entre toutes les apps ─────────────
// Défaut : activé, +5 demi-tons (voix grave -> voix féminine).
static volatile int   g_enabled = 1;
static volatile float g_semi    = 5.0f;
static int  g_token = 0;
static BOOL g_isSpringBoard = NO;
static const char *kNote = "com.local.voiceshift.changed";
static const char *kConf[] = {
    "/var/jb/var/mobile/Library/Preferences/voiceshift.v3.conf",
    "/var/mobile/Library/Preferences/voiceshift.v3.conf" };

static void vs_apply(int en, float semi) {
    if (semi < -12.f) semi = -12.f;
    if (semi >  12.f) semi =  12.f;
    g_semi = semi; g_enabled = en ? 1 : 0;
}
static void vs_load_file(void) {
    for (int k = 0; k < 2; k++) {
        FILE *f = fopen(kConf[k], "r");
        if (!f) continue;
        char line[64]; int e = g_enabled; float s = g_semi;
        while (fgets(line, sizeof line, f)) {
            int ie; float is;
            if (sscanf(line, "enabled=%d", &ie) == 1) e = ie;
            else if (sscanf(line, "semitones=%f", &is) == 1) s = is;
        }
        fclose(f); vs_apply(e, s); return;
    }
}
static void vs_save_file(void) {          // ne réussit que dans les processus non sandboxés
    for (int k = 0; k < 2; k++) {
        FILE *f = fopen(kConf[k], "w");
        if (!f) continue;
        fprintf(f, "enabled=%d\nsemitones=%.1f\n", g_enabled, g_semi);
        fclose(f); return;
    }
}
static void vs_pull_state(void) {         // lit l'état global (notifyd)
    uint64_t st = 0;
    if (notify_get_state(g_token, &st) != NOTIFY_STATUS_OK) return;
    if (!(st & (1ULL << 63))) return;
    vs_apply((int)(st & 1), ((float)((int)((st >> 8) & 0xFF) - 120)) / 10.0f);
}
static void vs_push_state(void) {         // publie vers toutes les apps
    uint64_t st = (1ULL << 63) | (uint64_t)(g_enabled & 1)
                | ((uint64_t)((int)lroundf(g_semi * 10.f) + 120) << 8);
    notify_set_state(g_token, st);
    notify_post(kNote);
}

// ───────────── Traitement audio ─────────────
#define MAXSLOTS 32
typedef struct { void *unit; int ch; VSPitch p; } Slot;
typedef struct { void *unit; int kind; float sr; } UnitInfo;   // kind: 1=float32, 2=s16, 0=non géré
static Slot     g_slots[MAXSLOTS];  static int g_nslots = 0;
static UnitInfo g_units[MAXSLOTS];  static int g_nunits = 0;
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;

static UnitInfo *unit_info(AudioUnit u) {
    for (int i = 0; i < g_nunits; i++) if (g_units[i].unit == (void *)u) return &g_units[i];
    pthread_mutex_lock(&g_mx);
    for (int i = 0; i < g_nunits; i++) if (g_units[i].unit == (void *)u) { pthread_mutex_unlock(&g_mx); return &g_units[i]; }
    if (g_nunits >= MAXSLOTS) { pthread_mutex_unlock(&g_mx); return NULL; }
    AudioStreamBasicDescription d; UInt32 sz = sizeof d; int kind = 0;
    if (AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &d, &sz) == noErr
        && d.mFormatID == kAudioFormatLinearPCM) {
        if ((d.mFormatFlags & kAudioFormatFlagIsFloat) && d.mBitsPerChannel == 32) kind = 1;
        else if (!(d.mFormatFlags & kAudioFormatFlagIsFloat) && d.mBitsPerChannel == 16) kind = 2;
    }
    UnitInfo *ui = &g_units[g_nunits];
    ui->unit = (void *)u; ui->kind = kind; ui->sr = d.mSampleRate > 8000 ? (float)d.mSampleRate : 44100.f;
    __sync_synchronize(); g_nunits++;
    pthread_mutex_unlock(&g_mx);
    return ui;
}
static VSPitch *slot_for(void *unit, int ch, float sr) {
    for (int i = 0; i < g_nslots; i++) if (g_slots[i].unit == unit && g_slots[i].ch == ch) return &g_slots[i].p;
    pthread_mutex_lock(&g_mx);
    for (int i = 0; i < g_nslots; i++) if (g_slots[i].unit == unit && g_slots[i].ch == ch) { pthread_mutex_unlock(&g_mx); return &g_slots[i].p; }
    if (g_nslots >= MAXSLOTS) { pthread_mutex_unlock(&g_mx); return NULL; }
    Slot *s = &g_slots[g_nslots];
    s->unit = unit; s->ch = ch; vs_pitch_init(&s->p, sr);
    __sync_synchronize(); g_nslots++;
    pthread_mutex_unlock(&g_mx);
    return &s->p;
}

static OSStatus (*orig_render)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                               UInt32, UInt32, AudioBufferList *);

static OSStatus hook_render(AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                            UInt32 bus, UInt32 frames, AudioBufferList *io) {
    OSStatus r = orig_render(unit, flags, ts, bus, frames, io);
    if (r != noErr || bus != 1 || !io || !g_enabled) return r;       // bus 1 = micro
    float semi = g_semi;
    if (fabsf(semi) < 0.05f) return r;
    UnitInfo *ui = unit_info(unit);
    if (!ui || !ui->kind) return r;
    float target = exp2f(semi / 12.f);
    for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
        AudioBuffer *ab = &io->mBuffers[b];
        int nch = ab->mNumberChannels ? (int)ab->mNumberChannels : 1;
        if (!ab->mData) continue;
        for (int c = 0; c < nch; c++) {
            VSPitch *p = slot_for(unit, (int)b * 8 + c, ui->sr);
            if (!p) continue;
            float in[512], out[512];
            UInt32 done = 0;
            while (done < frames) {
                int n = (int)((frames - done) > 512 ? 512 : (frames - done));
                if (ui->kind == 1) {
                    float *d = (float *)ab->mData + (size_t)done * nch + c;
                    for (int i = 0; i < n; i++) in[i] = d[(size_t)i * nch];
                    vs_pitch_chunk(p, in, out, n, target);
                    for (int i = 0; i < n; i++) { float v = out[i]; d[(size_t)i * nch] = v > 1.f ? 1.f : (v < -1.f ? -1.f : v); }
                } else {
                    int16_t *d = (int16_t *)ab->mData + (size_t)done * nch + c;
                    for (int i = 0; i < n; i++) in[i] = d[(size_t)i * nch] * (1.f / 32768.f);
                    vs_pitch_chunk(p, in, out, n, target);
                    for (int i = 0; i < n; i++) {
                        float v = out[i] * 32768.f; v = v > 32767.f ? 32767.f : (v < -32768.f ? -32768.f : v);
                        d[(size_t)i * nch] = (int16_t)v;
                    }
                }
                done += (UInt32)n;
            }
        }
    }
    return r;
}

// ───────────── Interface : bouton flottant + panneau ─────────────
@interface VSRootVC : UIViewController
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UISwitch *sw;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *valueLabel;
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

    UIView *p = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 270)];
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

    NSArray *titles = @[@"Homme → Femme", @"Femme → Homme", @"Original"];
    for (int i = 0; i < 3; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(12 + i * 93, 190, 90, 40);
        b.titleLabel.font = [UIFont systemFontOfSize:12]; b.titleLabel.numberOfLines = 2; b.titleLabel.textAlignment = NSTextAlignmentCenter;
        b.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1]; b.layer.cornerRadius = 10;
        [b setTitle:titles[i] forState:UIControlStateNormal]; b.tag = i;
        [b addTarget:self action:@selector(preset:) forControlEvents:UIControlEventTouchUpInside];
        [p addSubview:b];
    }
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(16, 236, 268, 28)];
    hint.text = @"Valeur par défaut : +5 (voix grave → voix féminine)";
    hint.textColor = [UIColor colorWithWhite:0.55 alpha:1]; hint.font = [UIFont systemFontOfSize:11]; hint.numberOfLines = 2;
    [p addSubview:hint];

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
    float s = g_semi;
    NSString *d = s > 0.05f ? @"plus aigu" : (s < -0.05f ? @"plus grave" : @"voix d'origine");
    self.valueLabel.text = [NSString stringWithFormat:@"%+.1f demi-tons — %@", s, d];
    self.fab.alpha = g_enabled ? 0.92 : 0.45;
}
- (void)togglePanel { self.panel.hidden = !self.panel.hidden; [self refreshFromState]; }
- (void)dragFab:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    CGPoint c = CGPointMake(self.fab.center.x + t.x, self.fab.center.y + t.y);
    CGRect b = self.view.bounds;
    c.x = MAX(26, MIN(b.size.width - 26, c.x)); c.y = MAX(60, MIN(b.size.height - 60, c.y));
    self.fab.center = c; [g setTranslation:CGPointZero inView:self.view];
}
- (void)swChanged:(UISwitch *)s { vs_apply(s.on, g_semi); vs_push_state(); [self refreshFromState]; if (g_isSpringBoard) vs_save_file(); }
- (void)slChanged:(UISlider *)s {
    float v = roundf(s.value * 2.f) / 2.f;          // pas de 0,5 demi-ton
    vs_apply(g_enabled, v); vs_push_state(); [self refreshFromState];
}
- (void)slDone:(UISlider *)s { if (g_isSpringBoard) vs_save_file(); }
- (void)preset:(UIButton *)b {
    float v = b.tag == 0 ? 5.f : (b.tag == 1 ? -5.f : 0.f);
    vs_apply(1, v); vs_push_state(); [self refreshFromState]; if (g_isSpringBoard) vs_save_file();
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

        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { vs_show_ui(); }];
    }
}
