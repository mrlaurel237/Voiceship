// VSTest.h — mode test : enregistre ~5 s, puis compare A (ta voix) / B (voix transformée).
#import <Foundation/Foundation.h>

@interface VSTester : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL recording;
@property (nonatomic, readonly) BOOL busy;            // lecture ou calcul en cours
@property (nonatomic, readonly) BOOL hasRecording;
@property (nonatomic, copy) void (^onUpdate)(NSString *status);
- (void)toggleRecording;
- (void)playOriginal;                                 // A
- (void)playProcessed;                                // B : recalculé avec les réglages actuels
- (void)stopAll;                                      // arrête tout et rend la session audio à l'app
@end
