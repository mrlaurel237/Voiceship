// VSPanel.m — bouton flottant 🎙 + panneau (défilant) de VoiceShift.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#include "VSPanel.h"
#include "VSState.h"
#include "VSEngine.h"
#include "VSTest.h"
#include "ai/VSAIEngine.h"
#include "license/VSLicense.h"

extern volatile uint32_t g_vsCnt[4];
extern volatile int g_vsOwner;

static UIColor *vsAccent(void) { return [UIColor colorWithRed:0.62 green:0.36 blue:0.95 alpha:1]; }
static UIColor *vsCard(void)   { return [UIColor colorWithWhite:0.2 alpha:1]; }

@interface VSRootVC : UIViewController
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UISwitch *sw, *swDeess, *swGate, *swEq, *swSilence;
@property (nonatomic, strong) UISegmentedControl *engineSeg;
@property (nonatomic, strong) UILabel *engineInfo, *lSemi, *lForm, *lBreath, *lSmooth, *lVib, *lExpr, *testInfo, *stats, *diag, *licLabel;
@property (nonatomic, strong) UISlider *sSemi, *sForm, *sBreath, *sSmooth, *sVib, *sExpr;
@property (nonatomic, strong) NSArray<UIButton *> *presetBtns;
@property (nonatomic, strong) UIButton *fastModeBtn, *recBtn, *aBtn, *bBtn, *retryBtn;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) CGFloat y;
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
static const CGFloat W = 300, PAD = 14;

@implementation VSRootVC

// ── petits constructeurs ──
- (UILabel *)label:(NSString *)t size:(CGFloat)sz color:(UIColor *)c lines:(int)lines {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(PAD, self.y, W - 2 * PAD, (sz + 4) * lines)];
    l.text = t; l.textColor = c; l.font = [UIFont systemFontOfSize:sz]; l.numberOfLines = lines;
    [self.scroll addSubview:l];
    self.y += (sz + 4) * lines + 2;
    return l;
}
- (UILabel *)section:(NSString *)t {
    self.y += 8;
    UILabel *l = [self label:t size:12 color:[UIColor colorWithWhite:0.55 alpha:1] lines:1];
    l.font = [UIFont boldSystemFontOfSize:12];
    return l;
}
- (UISlider *)slider:(float)mn max:(float)mx action:(SEL)a {
    UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(PAD, self.y, W - 2 * PAD, 28)];
    s.minimumValue = mn; s.maximumValue = mx; s.minimumTrackTintColor = vsAccent();
    [s addTarget:self action:a forControlEvents:UIControlEventValueChanged];
    [self.scroll addSubview:s];
    self.y += 32;
    return s;
}
- (UIButton *)button:(NSString *)t frame:(CGRect)f action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f; b.backgroundColor = vsCard(); b.layer.cornerRadius = 10;
    b.titleLabel.font = [UIFont systemFontOfSize:13]; b.titleLabel.numberOfLines = 2; b.titleLabel.textAlignment = NSTextAlignmentCenter;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    [self.scroll addSubview:b];
    return b;
}
- (UISwitch *)switchAt:(CGFloat)x title:(NSString *)t action:(SEL)a {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(x, self.y + 4, 46, 24)];
    l.text = t; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:12]; l.adjustsFontSizeToFitWidth = YES;
    [self.scroll addSubview:l];
    UISwitch *s = [[UISwitch alloc] initWithFrame:CGRectMake(x + 46, self.y, 51, 31)];
    s.transform = CGAffineTransformMakeScale(0.8, 0.8); s.onTintColor = vsAccent();
    [s addTarget:self action:a forControlEvents:UIControlEventValueChanged];
    [self.scroll addSubview:s];
    return s;
}

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

    UIView *p = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 560)];
    p.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.97];
    p.layer.cornerRadius = 18; p.clipsToBounds = YES; p.hidden = YES;
    self.panel = p;

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(PAD, 10, 200, 28)];
    t.text = @"VoiceShift 0.9"; t.textColor = UIColor.whiteColor; t.font = [UIFont boldSystemFontOfSize:20];
    [p addSubview:t];
    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(W - 44, 6, 36, 36); [x setTitle:@"✕" forState:UIControlStateNormal];
    [x addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [p addSubview:x];

    self.scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 44, W, 516)];
    self.scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [p addSubview:self.scroll];
    self.y = 4;

    // ── activation + moteur ──
    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(PAD, self.y, 200, 31)];
    l1.text = @"Voix modifiée"; l1.textColor = UIColor.whiteColor; l1.font = [UIFont systemFontOfSize:16];
    [self.scroll addSubview:l1];
    self.sw = [[UISwitch alloc] initWithFrame:CGRectMake(W - PAD - 51, self.y, 51, 31)];
    self.sw.onTintColor = vsAccent();
    [self.sw addTarget:self action:@selector(swChanged:) forControlEvents:UIControlEventValueChanged];
    [self.scroll addSubview:self.sw];
    self.y += 40;

    [self section:@"MOTEUR"];
    self.engineSeg = [[UISegmentedControl alloc] initWithItems:@[@"Rapide", @"Naturel", @"IA (expé.)"]];
    self.engineSeg.frame = CGRectMake(PAD, self.y, W - 2 * PAD, 30);
    self.engineSeg.selectedSegmentTintColor = vsAccent();
    [self.engineSeg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
    [self.engineSeg addTarget:self action:@selector(engineChanged:) forControlEvents:UIControlEventValueChanged];
    [self.scroll addSubview:self.engineSeg];
    self.y += 36;
    self.engineInfo = [self label:@"" size:11 color:[UIColor colorWithWhite:0.75 alpha:1] lines:3];

    // ── préréglages ──
    [self section:@"VOIX FÉMININE — PRÉRÉGLAGES"];
    NSMutableArray *pb = [NSMutableArray new];
    CGFloat bw = (W - 2 * PAD - 16) / 3.f;
    for (int i = 0; i < VS_NPRESETS; i++) {
        NSString *ti = [NSString stringWithFormat:@"%s\n%+.0f · %+.0f %%", kVSPresets[i].name, kVSPresets[i].semitones, kVSPresets[i].formantPct];
        UIButton *b = [self button:ti frame:CGRectMake(PAD + i * (bw + 8), self.y, bw, 46) action:@selector(preset:)];
        b.tag = i + 1;
        [pb addObject:b];
    }
    self.presetBtns = pb;
    self.y += 52;

    // ── réglages principaux ──
    [self section:@"RÉGLAGES"];
    self.lSemi = [self label:@"" size:13 color:UIColor.whiteColor lines:1];
    self.sSemi = [self slider:-12 max:16 action:@selector(mainChanged:)];
    self.lForm = [self label:@"" size:13 color:UIColor.whiteColor lines:1];
    self.sForm = [self slider:-20 max:40 action:@selector(mainChanged:)];
    self.lBreath = [self label:@"" size:13 color:UIColor.whiteColor lines:1];
    self.sBreath = [self slider:0 max:100 action:@selector(mainChanged:)];

    [self section:@"RÉGLAGES FINS (moteur Naturel)"];
    self.lSmooth = [self label:@"" size:13 color:UIColor.whiteColor lines:1];
    self.sSmooth = [self slider:0 max:7 action:@selector(mainChanged:)];
    self.lVib = [self label:@"" size:13 color:UIColor.whiteColor lines:1];
    self.sVib = [self slider:0 max:7 action:@selector(mainChanged:)];
    self.lExpr = [self label:@"" size:13 color:UIColor.whiteColor lines:1];
    self.sExpr = [self slider:0 max:7 action:@selector(mainChanged:)];
    self.swDeess = [self switchAt:PAD title:@"De-esser" action:@selector(toggles:)];
    self.swGate = [self switchAt:PAD + 92 title:@"Gate" action:@selector(toggles:)];
    self.swEq = [self switchAt:PAD + 184 title:@"EQ" action:@selector(toggles:)];
    self.y += 36;
    UILabel *ls = [[UILabel alloc] initWithFrame:CGRectMake(PAD, self.y, 210, 31)];
    ls.text = @"Si le moteur échoue : silence"; ls.textColor = UIColor.whiteColor; ls.font = [UIFont systemFontOfSize:13];
    [self.scroll addSubview:ls];
    self.swSilence = [[UISwitch alloc] initWithFrame:CGRectMake(W - PAD - 51, self.y, 51, 31)];
    self.swSilence.onTintColor = vsAccent();
    [self.swSilence addTarget:self action:@selector(toggles:) forControlEvents:UIControlEventValueChanged];
    [self.scroll addSubview:self.swSilence];
    self.y += 34;
    [self label:@"(désactivé : ta vraie voix passe si le moteur s'arrête)" size:10 color:[UIColor colorWithWhite:0.5 alpha:1] lines:1];
    self.fastModeBtn = [self button:@"" frame:CGRectMake(PAD, self.y + 4, W - 2 * PAD, 34) action:@selector(fastModeTap)];
    self.y += 42;

    // ── mode test ──
    [self section:@"MODE TEST — compare ta voix (A) et le résultat (B)"];
    self.recBtn = [self button:@"● Enregistrer" frame:CGRectMake(PAD, self.y, 100, 40) action:@selector(recTap)];
    self.aBtn = [self button:@"▶ A\nma voix" frame:CGRectMake(PAD + 108, self.y, 80, 40) action:@selector(aTap)];
    self.bBtn = [self button:@"▶ B\nmodifiée" frame:CGRectMake(PAD + 196, self.y, 76, 40) action:@selector(bTap)];
    self.y += 46;
    self.testInfo = [self label:@"Parle ~5 s, puis écoute A et B. B utilise les réglages actuels." size:11 color:[UIColor colorWithWhite:0.75 alpha:1] lines:3];

    // ── statistiques ──
    [self section:@"PERFORMANCES (cette app)"];
    self.stats = [self label:@"" size:12 color:UIColor.whiteColor lines:4];
    self.retryBtn = [self button:@"Réessayer le moteur demandé" frame:CGRectMake(PAD, self.y, W - 2 * PAD, 32) action:@selector(retryTap)];
    self.y += 38;
    self.diag = [self label:@"" size:10 color:[UIColor colorWithWhite:0.5 alpha:1] lines:2];
    self.licLabel = [self label:@"" size:10 color:[UIColor colorWithWhite:0.5 alpha:1] lines:1];
    self.y += 10;
    self.scroll.contentSize = CGSizeMake(W, self.y);

    [self.view addSubview:p];

    __weak typeof(self) ws = self;
    VSTester.shared.onUpdate = ^(NSString *st) { ws.testInfo.text = st; [ws refreshTestButtons]; };
    [self refreshFromState];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    CGFloat h = MIN(600.f, b.size.height - 90.f);
    self.panel.frame = CGRectMake((b.size.width - W) / 2.f, (b.size.height - h) / 2.f, W, h);
    self.scroll.frame = CGRectMake(0, 44, W, h - 44);
}

// ── affichage ──
- (void)refreshFromState {
    if (!self.sw) return;
    VSSettings s; vs_state_snapshot(&s);
    self.sw.on = s.enabled;
    self.engineSeg.selectedSegmentIndex = s.engine;
    for (UIButton *b in self.presetBtns) b.backgroundColor = (b.tag == s.preset) ? vsAccent() : vsCard();
    if (!self.sSemi.isTracking) self.sSemi.value = s.semitones;
    if (!self.sForm.isTracking) self.sForm.value = s.formantPct;
    if (!self.sBreath.isTracking) self.sBreath.value = s.breath * 100.f;
    if (!self.sSmooth.isTracking) self.sSmooth.value = s.smooth;
    if (!self.sVib.isTracking) self.sVib.value = s.vibrato;
    if (!self.sExpr.isTracking) self.sExpr.value = s.expr;
    self.lSemi.text = [NSString stringWithFormat:@"Hauteur : %+.1f demi-tons  (×%.2f)", s.semitones, exp2f(s.semitones / 12.f)];
    self.lForm.text = [NSString stringWithFormat:@"Formants (timbre) : %+.0f %%  %@", s.formantPct,
                       (s.formantPct >= 12 && s.formantPct <= 20) ? @"✓ zone féminine" : @""];
    self.lBreath.text = [NSString stringWithFormat:@"Souffle : %.0f %%", s.breath * 100.f];
    self.lSmooth.text = [NSString stringWithFormat:@"Lissage de la hauteur : %d / 7", s.smooth];
    self.lVib.text = [NSString stringWithFormat:@"Vibrato naturel : %d / 7%@", s.vibrato, s.vibrato ? @"" : @" (aucun)"];
    self.lExpr.text = [NSString stringWithFormat:@"Intonation (mélodie) : ×%.2f", vs_set_expressivity(&s)];
    self.swDeess.on = s.deesser; self.swGate.on = s.gate; self.swEq.on = s.eq; self.swSilence.on = s.failSilence;
    static NSString *fm[4] = {@"A — standard", @"B — naturel", @"C — doux", @"D — très doux"};
    [self.fastModeBtn setTitle:[NSString stringWithFormat:@"Qualité du moteur Rapide : %@", fm[s.fastMode & 3]] forState:UIControlStateNormal];
    self.fastModeBtn.alpha = s.engine == VS_ENGINE_FAST ? 1.0 : 0.45;
    for (UIControl *c in @[self.sSmooth, self.sVib, self.sExpr, self.swDeess, self.swGate, self.swEq])
        c.enabled = s.engine != VS_ENGINE_FAST;
    self.fab.alpha = s.enabled ? 0.92 : 0.45;
    const char *lic = vs_license_label();
    self.licLabel.text = lic[0] ? [NSString stringWithUTF8String:lic] : @"";
    [self refreshStats];
}

- (void)refreshTestButtons {
    VSTester *t = VSTester.shared;
    [self.recBtn setTitle:t.recording ? @"■ Stop" : @"● Enregistrer" forState:UIControlStateNormal];
    self.recBtn.backgroundColor = t.recording ? [UIColor colorWithRed:0.8 green:0.2 blue:0.25 alpha:1] : vsCard();
    self.aBtn.enabled = self.bBtn.enabled = t.hasRecording && !t.recording;
    self.aBtn.alpha = self.bBtn.alpha = self.aBtn.enabled ? 1.0 : 0.4;
}

- (void)refreshStats {
    VSEngineStats st; vs_engine_stats(&st);
    VSSettings s; vs_state_snapshot(&s);
    static NSString *req[3] = {@"Rapide", @"Naturel", @"IA"};
    NSMutableString *info = [NSMutableString new];
    if (s.engine == VS_ENGINE_FAST)
        [info appendString:@"Rapide : moteur de la 0.8 (latence ≈ 150 ms, son plus métallique)."];
    else if (s.engine == VS_ENGINE_NATURAL)
        [info appendString:@"Naturel : source-filtre (hauteur, formants et souffle séparés). Latence ≈ 33 ms."];
    else
        [info appendFormat:@"%s", vs_ai_status_text()];
    if (st.running >= 0 && st.running != VS_RUN_FAILSAFE && st.buffers > 0 &&
        !((s.engine == VS_ENGINE_FAST && st.running == VS_RUN_FAST) || (s.engine == VS_ENGINE_NATURAL && st.running == VS_RUN_NATURAL)))
        [info appendFormat:@"\n→ en ce moment : %s", vs_engine_run_name(st.running)];
    if (st.running == VS_RUN_FAILSAFE)
        [info appendFormat:@"\n⚠ Mode sécurité (%@)", s.failSilence ? @"micro coupé" : @"voix d'origine"];
    const char *why = vs_engine_reason_text(st.reason);
    if (why[0]) [info appendFormat:@"\n⚠ %s", why];
    self.engineInfo.text = info;
    self.retryBtn.hidden = !(st.reason == VS_REASON_OVERLOAD || st.reason == VS_REASON_CRASH ||
                             st.reason == VS_REASON_CRASH_BEFORE || st.reason == VS_REASON_CREATE_FAILED);

    AVAudioSession *as = AVAudioSession.sharedInstance;
    float io = (float)((as.inputLatency + as.IOBufferDuration) * 1000.0);
    if (st.buffers == 0) {
        self.stats.text = [NSString stringWithFormat:@"Micro pas encore utilisé dans cette app.\nMoteur prévu : %@ → %s",
                           req[s.engine], vs_engine_run_name(st.running)];
    } else {
        NSString *f0 = st.f0In > 0 ? [NSString stringWithFormat:@"\nHauteur : %.0f Hz → %.0f Hz", st.f0In, st.f0Out] : @"";
        self.stats.text = [NSString stringWithFormat:@"Moteur actif : %s · %.0f kHz\nLatence ≈ %.0f ms (moteur %.0f + micro %.0f)\nProcesseur : %.1f %% (pic %.0f %%)%@",
                           vs_engine_run_name(st.running), st.sampleRate / 1000.f, st.engineLatencyMs + io, st.engineLatencyMs, io,
                           st.loadPct, st.peakPct, f0];
    }
    static const char *nm[] = {"AU", "AQ", "Cap", "Tap"};
    int o = g_vsOwner;
    self.diag.text = [NSString stringWithFormat:@"Micro vu : AU %u · AQ %u · Cap %u · Tap %u — chemin actif : %s",
                      g_vsCnt[0], g_vsCnt[1], g_vsCnt[2], g_vsCnt[3], (o >= 0 && o < 4) ? nm[o] : "aucun"];
    [self refreshTestButtons];
}

// ── actions ──
- (void)togglePanel {
    self.panel.hidden = !self.panel.hidden;
    [self.timer invalidate]; self.timer = nil;
    if (!self.panel.hidden) {
        [self refreshFromState];
        __weak typeof(self) ws = self;
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { [ws refreshStats]; }];
    } else {
        [VSTester.shared stopAll];
    }
}
- (void)dragFab:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    CGPoint c = CGPointMake(self.fab.center.x + t.x, self.fab.center.y + t.y);
    CGRect b = self.view.bounds;
    c.x = MAX(26, MIN(b.size.width - 26, c.x)); c.y = MAX(60, MIN(b.size.height - 60, c.y));
    self.fab.center = c; [g setTranslation:CGPointZero inView:self.view];
}
- (void)commit { vs_state_publish(); [self refreshFromState]; }
- (void)swChanged:(UISwitch *)s { g_set.enabled = s.on; [self commit]; }
- (void)engineChanged:(UISegmentedControl *)c {
    g_set.engine = (int)c.selectedSegmentIndex;
    vs_engine_retry();                       // changer de moteur efface les rétrogradations
    [self commit];
}
- (void)preset:(UIButton *)b { vs_state_apply_preset((int)b.tag); [self commit]; }
- (void)mainChanged:(UISlider *)sl {
    VSSettings s = g_set;
    if (sl == self.sSemi) s.semitones = roundf(sl.value * 2.f) / 2.f;
    else if (sl == self.sForm) s.formantPct = roundf(sl.value);
    else if (sl == self.sBreath) s.breath = roundf(sl.value / 5.f) * 0.05f;
    else if (sl == self.sSmooth) s.smooth = (int)lroundf(sl.value);
    else if (sl == self.sVib) s.vibrato = (int)lroundf(sl.value);
    else if (sl == self.sExpr) s.expr = (int)lroundf(sl.value);
    s.preset = 0;                            // réglage personnalisé
    g_set = s;
    [self commit];
}
- (void)toggles:(UISwitch *)sw {
    if (sw == self.swDeess) g_set.deesser = sw.on;
    else if (sw == self.swGate) g_set.gate = sw.on;
    else if (sw == self.swEq) g_set.eq = sw.on;
    else if (sw == self.swSilence) g_set.failSilence = sw.on;
    [self commit];
}
- (void)fastModeTap { g_set.fastMode = (g_set.fastMode + 1) & 3; [self commit]; }
- (void)recTap { [VSTester.shared toggleRecording]; [self refreshTestButtons]; }
- (void)aTap { [VSTester.shared playOriginal]; }
- (void)bTap { [VSTester.shared playProcessed]; }
- (void)retryTap { vs_engine_retry(); [self refreshStats]; }
@end

void vs_panel_show(void) {
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

void vs_panel_refresh(void) { [g_vc refreshFromState]; }
