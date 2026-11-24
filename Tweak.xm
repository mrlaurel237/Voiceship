// VoiceShift 0.9.0 — changeur de voix micro (moteurs Rapide / Naturel / IA) avec bouton flottant.
// Ce fichier : branchement sur les 4 chemins audio du micro + démarrage.
// Moteurs et sécurité : src/VSEngine.mm · Réglages : src/VSState.m · Interface : src/VSPanel.m
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#include <substrate.h>
#include <pthread.h>
#include <time.h>
#include "src/VSState.h"
#include "src/VSEngine.h"
#include "src/VSPanel.h"
#include "src/license/VSLicense.h"

#define MAXUNITS 16
// compteurs de diagnostic : 0=AudioUnit 1=AudioQueue 2=Capture 3=Tap AVAudioEngine
volatile uint32_t g_vsCnt[4] = {0, 0, 0, 0};
// un seul chemin audio traite le micro à la fois (évite de transformer la voix deux fois)
volatile int g_vsOwner = -1;
static volatile uint64_t g_ownerT = 0;
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;

static BOOL vs_claim(int src) {
    uint64_t t = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    int o = g_vsOwner;
    if (o == src || o < 0 || t - g_ownerT > 1000000000ULL) { g_vsOwner = src; g_ownerT = t; return YES; }
    return NO;
}

static int vs_fmt_of(const AudioStreamBasicDescription *a) {
    if (!a || a->mFormatID != kAudioFormatLinearPCM) return 0;
    if ((a->mFormatFlags & kAudioFormatFlagIsFloat) && a->mBitsPerChannel == 32) return VS_FMT_F32;
    if (!(a->mFormatFlags & kAudioFormatFlagIsFloat) && a->mBitsPerChannel == 16) return VS_FMT_S16;
    return 0;
}

// Tampon PCM décrit par un ASBD (AudioQueue, CMSampleBuffer…)
static void vs_process_asbd(void *key, const AudioStreamBasicDescription *a, void *data, UInt32 bytes, int src) {
    g_vsCnt[src]++;
    if (!g_set.enabled || g_vsTestActive || !data || !a) return;
    int fmt = vs_fmt_of(a);
    if (!fmt || !vs_claim(src)) return;
    int nch = a->mChannelsPerFrame ? (int)a->mChannelsPerFrame : 1;
    if (nch > 8) nch = 8;
    int bps = fmt == VS_FMT_F32 ? 4 : 2;
    BOOL planar = (a->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    int frames = planar ? (int)(bytes / (UInt32)bps) : (int)(bytes / (UInt32)(bps * nch));
    if (planar && nch > 1) frames /= nch;          // CMSampleBuffer planaire : canaux à la suite
    float sr = a->mSampleRate > 7900 ? (float)a->mSampleRate : 44100.f;
    VSChan ch[8];
    for (int c = 0; c < nch; c++) {
        if (planar) { ch[c].base = (char *)data + (size_t)c * frames * bps; ch[c].stride = 1; }
        else        { ch[c].base = (char *)data + (size_t)c * bps; ch[c].stride = nch; }
    }
    vs_engine_process(key, sr, fmt, ch, nch, frames);
}

// ── 1) AudioUnit (RemoteIO / VoiceProcessingIO : appels WhatsApp, lives…) ──
typedef struct { void *unit; int fmt; float sr; int isIO; } UnitInfo;
static UnitInfo g_units[MAXUNITS]; static int g_nunits = 0;

// Lecture du format du micro : faite au démarrage du flux (thread normal), pas dans le callback audio.
static UnitInfo *unit_learn(AudioUnit u) {
    pthread_mutex_lock(&g_mx);
    UnitInfo *ui = NULL;
    for (int i = 0; i < g_nunits; i++) if (g_units[i].unit == (void *)u) { ui = &g_units[i]; break; }
    if (!ui) ui = (g_nunits < MAXUNITS) ? &g_units[g_nunits] : &g_units[(g_nunits++) % MAXUNITS];
    AudioStreamBasicDescription d; UInt32 sz = sizeof d;
    memset(&d, 0, sizeof d);
    int fmt = 0;
    if (AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &d, &sz) == noErr) fmt = vs_fmt_of(&d);
    AudioComponentDescription cd; memset(&cd, 0, sizeof cd);
    AudioComponent comp = AudioComponentInstanceGetComponent(u);
    int isIO = 1;
    if (comp && AudioComponentGetDescription(comp, &cd) == noErr)
        isIO = (cd.componentType == kAudioUnitType_Output) &&
               (cd.componentSubType == kAudioUnitSubType_RemoteIO || cd.componentSubType == kAudioUnitSubType_VoiceProcessingIO);
    ui->fmt = fmt; ui->sr = d.mSampleRate > 7900 ? (float)d.mSampleRate : 44100.f; ui->isIO = isIO;
    __sync_synchronize();
    ui->unit = (void *)u;
    if (g_nunits < MAXUNITS && ui == &g_units[g_nunits]) g_nunits++;
    pthread_mutex_unlock(&g_mx);
    return ui;
}
static UnitInfo *unit_find(AudioUnit u) {
    int n = g_nunits < MAXUNITS ? g_nunits : MAXUNITS;
    for (int i = 0; i < n; i++) if (g_units[i].unit == (void *)u) return &g_units[i];
    return NULL;
}

static OSStatus (*orig_start)(AudioUnit);
static OSStatus hook_start(AudioUnit u) {
    OSStatus r = orig_start(u);
    if (r == noErr) { unit_learn(u); vs_engine_prepare(); }
    return r;
}

static OSStatus (*orig_render)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                               UInt32, UInt32, AudioBufferList *);
static OSStatus hook_render(AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                            UInt32 bus, UInt32 frames, AudioBufferList *io) {
    OSStatus r = orig_render(unit, flags, ts, bus, frames, io);
    if (r != noErr || bus != 1 || !io) return r;                    // bus 1 = micro
    g_vsCnt[0]++;
    if (!g_set.enabled || g_vsTestActive || !vs_claim(0)) return r;
    UnitInfo *ui = unit_find(unit);
    if (!ui) ui = unit_learn(unit);                                 // flux démarré avant le chargement du tweak (rare)
    if (!ui || !ui->fmt || !ui->isIO) return r;
    int bps = ui->fmt == VS_FMT_F32 ? 4 : 2;
    VSChan ch[8]; int nch = 0;
    for (UInt32 b = 0; b < io->mNumberBuffers && nch < 8; b++) {
        AudioBuffer *ab = &io->mBuffers[b];
        int bn = ab->mNumberChannels ? (int)ab->mNumberChannels : 1;
        if (!ab->mData) continue;
        int fr = (int)(ab->mDataByteSize / (UInt32)(bps * bn));
        if (fr < (int)frames) continue;                            // tampon incohérent : on n'y touche pas
        for (int c = 0; c < bn && nch < 8; c++) { ch[nch].base = (char *)ab->mData + (size_t)c * bps; ch[nch].stride = bn; nch++; }
    }
    if (nch) vs_engine_process((void *)unit, ui->sr, ui->fmt, ch, nch, (int)frames);
    return r;
}

// ── 2) AudioQueue (messages vocaux WhatsApp, apps d'enregistrement) ──
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
        if (c) {
            c->cb = cb; c->user = user; c->fmt = *fmt;
            vs_engine_prepare();
            return orig_aqNew(fmt, aq_cb, c, rl, mode, flags, out);
        }
    }
    return orig_aqNew(fmt, cb, user, rl, mode, flags, out);
}
static OSStatus (*orig_aqNewQ)(AudioQueueRef *, const AudioStreamBasicDescription *, UInt32,
                               dispatch_queue_t, AudioQueueInputCallbackBlock);
static OSStatus hook_aqNewQ(AudioQueueRef *out, const AudioStreamBasicDescription *fmt, UInt32 flags,
                            dispatch_queue_t q, AudioQueueInputCallbackBlock block) {
    if (fmt && block && fmt->mFormatID == kAudioFormatLinearPCM) {
        AudioStreamBasicDescription f = *fmt;
        vs_engine_prepare();
        AudioQueueInputCallbackBlock w = ^(AudioQueueRef aq, AudioQueueBufferRef buf, const AudioTimeStamp *ts,
                                           UInt32 n, const AudioStreamPacketDescription *d) {
            vs_process_asbd((void *)aq, &f, buf->mAudioData, buf->mAudioDataByteSize, 1);
            block(aq, buf, ts, n, d);
        };
        return orig_aqNewQ(out, fmt, flags, q, w);
    }
    return orig_aqNewQ(out, fmt, flags, q, block);
}

// ── 3) AVCaptureAudioDataOutput (apps caméra / live avec delegate) ──
static NSMutableDictionary *g_capOrig = nil;      // nom de classe -> IMP d'origine
static IMP orig_setDelegate = NULL;
IMP g_vsOrigTap = NULL;                           // utilisé aussi par le mode test (contourne le hook)

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
static Class vs_owner_class(Class c, SEL s) {
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
    Class owner = vs_owner_class(object_getClass(del), s);
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
    vs_engine_prepare();
    ((void (*)(id, SEL, id, dispatch_queue_t))orig_setDelegate)(self, _cmd, delegate, q);
}

// ── 4) AVAudioEngine : tap sur le micro (inputNode) ──
static void vs_process_pcmbuffer(void *key, AVAudioPCMBuffer *buf) {
    g_vsCnt[3]++;
    if (!g_set.enabled || g_vsTestActive || !vs_claim(3)) return;
    int n = (int)buf.frameLength, nch = (int)buf.format.channelCount, st = (int)buf.stride;
    if (nch > 8) nch = 8;
    float sr = (float)buf.format.sampleRate;
    VSChan ch[8];
    if (buf.floatChannelData) {
        for (int c = 0; c < nch; c++) { ch[c].base = buf.floatChannelData[c]; ch[c].stride = st; }
        vs_engine_process(key, sr, VS_FMT_F32, ch, nch, n);
    } else if (buf.int16ChannelData) {
        for (int c = 0; c < nch; c++) { ch[c].base = buf.int16ChannelData[c]; ch[c].stride = st; }
        vs_engine_process(key, sr, VS_FMT_S16, ch, nch, n);
    }
}
static void vs_tap_imp(id self, SEL _cmd, AVAudioNodeBus bus, AVAudioFrameCount size, AVAudioFormat *fmt, AVAudioNodeTapBlock block) {
    AVAudioNodeTapBlock w = block;
    if (block && [self isKindOfClass:NSClassFromString(@"AVAudioInputNode")]) {
        void *key = (__bridge void *)self;
        vs_engine_prepare();
        w = ^(AVAudioPCMBuffer *buf, AVAudioTime *when) { vs_process_pcmbuffer(key, buf); block(buf, when); };
    }
    ((void (*)(id, SEL, AVAudioNodeBus, AVAudioFrameCount, AVAudioFormat *, AVAudioNodeTapBlock))g_vsOrigTap)(self, _cmd, bus, size, fmt, w);
}

static void vs_install_objc_hooks(void) {
    static BOOL tapDone = NO, capDone = NO;
    if (!tapDone) {
        Class c = NSClassFromString(@"AVAudioNode");
        Method m = c ? class_getInstanceMethod(c, @selector(installTapOnBus:bufferSize:format:block:)) : NULL;
        if (m) { g_vsOrigTap = method_setImplementation(m, (IMP)vs_tap_imp); tapDone = YES; }
    }
    if (!capDone) {
        Class c = NSClassFromString(@"AVCaptureAudioDataOutput");
        Method m = c ? class_getInstanceMethod(c, @selector(setSampleBufferDelegate:queue:)) : NULL;
        if (m) { orig_setDelegate = method_setImplementation(m, (IMP)vs_setdel_imp); capDone = YES; }
    }
}

// ───────────── Initialisation ─────────────
%ctor {
    @autoreleasepool {
        NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *path = NSBundle.mainBundle.bundlePath ?: @"";
        g_isSpringBoard = [bid isEqualToString:@"com.apple.springboard"];
        BOOL isApp = g_isSpringBoard || [path hasSuffix:@".app"];
        if (!isApp) return;                         // pas d'extensions ni de daemons

        vs_license_init();
        vs_engine_init();
        vs_state_init(^{ vs_panel_refresh(); });

        MSHookFunction((void *)AudioUnitRender, (void *)hook_render, (void **)&orig_render);
        MSHookFunction((void *)AudioOutputUnitStart, (void *)hook_start, (void **)&orig_start);
        MSHookFunction((void *)AudioQueueNewInput, (void *)hook_aqNew, (void **)&orig_aqNew);
        MSHookFunction((void *)AudioQueueNewInputWithDispatchQueue, (void *)hook_aqNewQ, (void **)&orig_aqNewQ);
        vs_install_objc_hooks();

        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { vs_install_objc_hooks(); vs_panel_show(); }];
    }
}
