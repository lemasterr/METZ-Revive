#import "VirtualDisplay.h"
#include <assert.h>

// All objects below are ordinary NSObject doubles. The check never looks up
// CGVirtualDisplay classes, creates an OS display, or uses ScreenCaptureKit.
static int liveDisplays;
static unsigned int expectedWidth = 1280, expectedHeight = 720, expectedFPS = 30;
static BOOL rejectDescriptor, rejectMode, rejectSettings, zeroID, throwDescriptor;
@interface TestDescriptor : NSObject
@property unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property CGSize sizeInMillimeters;
@property CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(strong, nonatomic) NSString *name;
@end
@implementation TestDescriptor
- (void)setName:(NSString *)name {
    if (throwDescriptor) [NSException raise:@"Injected" format:@"Test only"];
    _name = name;
}
@end
@interface ModernDescriptor : TestDescriptor
@property(strong) dispatch_queue_t queue;
@property unsigned int serialNumber;
@end
@implementation ModernDescriptor
@end
@interface LegacyDescriptor : TestDescriptor
@property(strong) dispatch_queue_t storedQueue;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end
@implementation LegacyDescriptor
- (void)setDispatchQueue:(dispatch_queue_t)queue { self.storedQueue = queue; }
@end
@interface TestMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@implementation TestMode
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate {
    assert(width == expectedWidth && height == expectedHeight && rate == expectedFPS);
    if (rejectMode) return nil;
    return [super init];
}
@end
@interface TestSettings : NSObject
@property(strong) NSArray *modes;
@property unsigned int hiDPI, rotation;
@end
@implementation TestSettings
@end
@interface TestDisplay : NSObject
@property unsigned int displayID;
@property BOOL counted;
- (instancetype)initWithDescriptor:(TestDescriptor *)descriptor;
- (BOOL)applySettings:(TestSettings *)settings;
@end
@implementation TestDisplay
- (instancetype)initWithDescriptor:(TestDescriptor *)descriptor {
    assert(descriptor.vendorID != 0 && descriptor.serialNum != 0);
    assert(descriptor.maxPixelsWide == expectedWidth && descriptor.maxPixelsHigh == expectedHeight);
    assert(descriptor.whitePoint.x > 0 && descriptor.redPrimary.x > 0);
    if ([descriptor isKindOfClass:ModernDescriptor.class]) {
        ModernDescriptor *modern = (id)descriptor;
        assert(modern.serialNumber == descriptor.serialNum && modern.queue != nil);
    } else { assert(((LegacyDescriptor *)descriptor).storedQueue != nil); }
    if (rejectDescriptor) return nil;
    self = [super init]; if (self) { liveDisplays++; self.counted = YES; }
    return self;
}
- (BOOL)applySettings:(TestSettings *)settings {
    assert(settings.hiDPI == 0 && settings.rotation == 0 && settings.modes.count == 1);
    if (rejectSettings) return NO;
    self.displayID = zeroID ? 0 : 99;
    return YES;
}
- (void)dealloc { if (_counted) liveDisplays--; }
@end

static void CheckFailure(Class descriptor, Class display, Class settings, Class mode, METZDisplayFailure expected) {
    @autoreleasepool {
        METZDisplayFailure failure = METZDisplayFailureNone;
        void *handle = METZCreateDisplayForTesting(descriptor, display, settings, mode, 2, &failure);
        assert(handle == NULL && failure == expected);
    }
    assert(liveDisplays == 0);
}
int main(void) {
    @autoreleasepool {
        for (Class descriptor in @[ModernDescriptor.class, LegacyDescriptor.class]) {
            @autoreleasepool {
                METZDisplayFailure failure;
                void *handle = METZCreateDisplayForTesting(descriptor, TestDisplay.class, TestSettings.class, TestMode.class, 2, &failure);
                assert(handle != NULL && failure == METZDisplayFailureNone);
                assert(METZDisplayID(handle) == 99 && liveDisplays == 1);
                METZReleaseDisplay(handle);
                assert(liveDisplays == 0);
            }
            assert(liveDisplays == 0);
        }
        expectedWidth = 1366; expectedHeight = 768; expectedFPS = 60;
        METZDisplayFailure modeFailure;
        void *native = METZCreateDisplayWithModeForTesting(ModernDescriptor.class, TestDisplay.class, TestSettings.class, TestMode.class,
            expectedWidth, expectedHeight, expectedFPS, &modeFailure);
        assert(native && modeFailure == METZDisplayFailureNone);
        METZReleaseDisplay(native); assert(liveDisplays == 0);
        expectedWidth = 1280; expectedHeight = 720; expectedFPS = 30;
        CheckFailure(Nil, TestDisplay.class, TestSettings.class, TestMode.class, METZDisplayFailureClasses);
        CheckFailure(ModernDescriptor.class, NSObject.class, TestSettings.class, TestMode.class, METZDisplayFailureDisplayInterface);
        CheckFailure(NSObject.class, TestDisplay.class, TestSettings.class, TestMode.class, METZDisplayFailureDescriptorInterface);
        rejectDescriptor = YES;
        CheckFailure(ModernDescriptor.class, TestDisplay.class, TestSettings.class, TestMode.class, METZDisplayFailureDescriptorRejected);
        rejectDescriptor = NO;
        CheckFailure(ModernDescriptor.class, TestDisplay.class, NSObject.class, TestMode.class, METZDisplayFailureSettingsInterface);
        rejectMode = YES;
        CheckFailure(ModernDescriptor.class, TestDisplay.class, TestSettings.class, TestMode.class, METZDisplayFailureModeRejected);
        rejectMode = NO; rejectSettings = YES;
        CheckFailure(ModernDescriptor.class, TestDisplay.class, TestSettings.class, TestMode.class, METZDisplayFailureSettingsRejected);
        rejectSettings = NO; zeroID = YES;
        METZDisplayFailure pendingFailure;
        void *pending = METZCreateDisplayForTesting(ModernDescriptor.class, TestDisplay.class, TestSettings.class, TestMode.class, 2, &pendingFailure);
        assert(pending && pendingFailure == METZDisplayFailureNone && METZDisplayID(pending) == 0 && liveDisplays == 1);
        METZReleaseDisplay(pending); assert(liveDisplays == 0);
        zeroID = NO; throwDescriptor = YES;
        CheckFailure(ModernDescriptor.class, TestDisplay.class, TestSettings.class, TestMode.class, METZDisplayFailureException);
        puts("Virtual display adapter: modern/legacy descriptor, registration after settings, typed failures and cleanup passed with doubles; no OS display/capture.");
    }
    return 0;
}
