#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Minimal declarations adapted from DeskPad/VirtualDisplayKit; see THIRD_PARTY_NOTICES.md.
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int serialNumber;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@property(retain, nonatomic) NSString *name;
@property(retain, nonatomic) dispatch_queue_t queue;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic) unsigned int rotation;
@end
@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

typedef NS_ENUM(int, METZDisplayFailure) {
    METZDisplayFailureNone = 0,
    METZDisplayFailureClasses = 1,
    METZDisplayFailureDisplayInterface = 2,
    METZDisplayFailureDescriptorInterface = 3,
    METZDisplayFailureDescriptorRejected = 4,
    METZDisplayFailureSettingsInterface = 5,
    METZDisplayFailureModeRejected = 6,
    METZDisplayFailureSettingsRejected = 7,
    METZDisplayFailureIdentifier = 8,
    METZDisplayFailureException = 9
};
void * _Nullable METZCreateDisplay(METZDisplayFailure * _Nonnull failure);
void * _Nullable METZCreateDisplayWithMode(unsigned int width, unsigned int height, unsigned int fps, METZDisplayFailure * _Nonnull failure);
#if METZ_DISPLAY_TESTING
// Test doubles only: never resolve or instantiate Apple's private display classes.
void * _Nullable METZCreateDisplayForTesting(Class _Nullable descriptorClass, Class _Nullable displayClass,
    Class _Nullable settingsClass, Class _Nullable modeClass, unsigned int serial, METZDisplayFailure * _Nonnull failure);
void * _Nullable METZCreateDisplayWithModeForTesting(Class _Nullable descriptorClass, Class _Nullable displayClass,
    Class _Nullable settingsClass, Class _Nullable modeClass, unsigned int width, unsigned int height, unsigned int fps,
    METZDisplayFailure * _Nonnull failure);
#endif
CGDirectDisplayID METZDisplayID(void * _Nonnull handle);
void METZReleaseDisplay(void * _Nonnull handle);

NS_ASSUME_NONNULL_END
