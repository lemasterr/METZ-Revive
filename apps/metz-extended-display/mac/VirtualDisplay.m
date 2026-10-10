#import "VirtualDisplay.h"

static void *CreateDisplay(Class descriptorClass, Class displayClass, Class settingsClass,
    Class modeClass, unsigned int serial, unsigned int width, unsigned int height, unsigned int fps, METZDisplayFailure *failure) {
    *failure = METZDisplayFailureClasses;
    if (!descriptorClass || !displayClass || !settingsClass || !modeClass) return NULL;
    // Swift Tasks do not necessarily drain an autorelease pool between start
    // and stop. Keep temporary framework references inside this creation call.
    @autoreleasepool {
    @try {
        *failure = METZDisplayFailureDisplayInterface;
        if (![displayClass instancesRespondToSelector:@selector(initWithDescriptor:)] ||
            ![displayClass instancesRespondToSelector:@selector(applySettings:)] ||
            ![displayClass instancesRespondToSelector:@selector(displayID)] ||
            ![modeClass instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)]) return NULL;
        CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
        *failure = METZDisplayFailureDescriptorInterface;
        if (!descriptor ||
            (![descriptor respondsToSelector:@selector(setQueue:)] && ![descriptor respondsToSelector:@selector(setDispatchQueue:)]) ||
            ![descriptor respondsToSelector:@selector(setMaxPixelsWide:)] ||
            ![descriptor respondsToSelector:@selector(setMaxPixelsHigh:)] ||
            ![descriptor respondsToSelector:@selector(setName:)] ||
            ![descriptor respondsToSelector:@selector(setVendorID:)] ||
            ![descriptor respondsToSelector:@selector(setProductID:)] ||
            (![descriptor respondsToSelector:@selector(setSerialNum:)] && ![descriptor respondsToSelector:@selector(setSerialNumber:)]) ||
            ![descriptor respondsToSelector:@selector(setSizeInMillimeters:)]) return NULL;
        if ([descriptor respondsToSelector:@selector(setQueue:)]) descriptor.queue = dispatch_get_main_queue();
        else [descriptor setDispatchQueue:dispatch_get_main_queue()];
        descriptor.name = @"METZ Extended Display";
        descriptor.maxPixelsWide = width;
        descriptor.maxPixelsHigh = height;
        descriptor.vendorID = 0x4d45;
        descriptor.productID = 0x545a;
        // Modern macOS exposes both fields. Keep them equal and non-zero; use
        // a stable synthetic ID per mode so WindowServer does not reuse another resolution.
        if ([descriptor respondsToSelector:@selector(setSerialNum:)]) descriptor.serialNum = serial;
        if ([descriptor respondsToSelector:@selector(setSerialNumber:)]) descriptor.serialNumber = serial;
        descriptor.sizeInMillimeters = CGSizeMake(600, 338);
        if ([descriptor respondsToSelector:@selector(setRedPrimary:)]) descriptor.redPrimary = CGPointMake(0.64, 0.33);
        if ([descriptor respondsToSelector:@selector(setGreenPrimary:)]) descriptor.greenPrimary = CGPointMake(0.30, 0.60);
        if ([descriptor respondsToSelector:@selector(setBluePrimary:)]) descriptor.bluePrimary = CGPointMake(0.15, 0.06);
        if ([descriptor respondsToSelector:@selector(setWhitePoint:)]) descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
        *failure = METZDisplayFailureDescriptorRejected;
        CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
        if (!display) return NULL;
        CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
        *failure = METZDisplayFailureSettingsInterface;
        if (![settings respondsToSelector:@selector(setHiDPI:)] || ![settings respondsToSelector:@selector(setModes:)]) return NULL;
        settings.hiDPI = 0;
        if ([settings respondsToSelector:@selector(setRotation:)]) settings.rotation = 0;
        *failure = METZDisplayFailureModeRejected;
        id mode = [[modeClass alloc] initWithWidth:width height:height refreshRate:fps];
        if (!mode) return NULL;
        settings.modes = @[mode];
        *failure = METZDisplayFailureSettingsRejected;
        if (![display applySettings:settings]) return NULL;
        // Keep the accepted object alive while WindowServer registers it.
        // A temporarily zero identifier is resolved asynchronously by the caller.
        // Dropping this object here can cancel registration for a newly selected mode.
        *failure = METZDisplayFailureNone;
        return (void *)CFBridgingRetain(display);
    } @catch (NSException *exception) {
        // Do not surface exception details, which can include private OS data.
        *failure = METZDisplayFailureException;
        return NULL;
    }
    }
}

void *METZCreateDisplay(METZDisplayFailure *failure) {
    return METZCreateDisplayWithMode(1280, 720, 30, failure);
}
void *METZCreateDisplayWithMode(unsigned int width, unsigned int height, unsigned int fps, METZDisplayFailure *failure) {
    *failure = METZDisplayFailureModeRejected;
    if (!((width == 854 && height == 480) || (width == 960 && height == 540) ||
        (width == 1280 && height == 720) || (width == 1366 && height == 768)) || (fps != 30 && fps != 60)) return NULL;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    unsigned int base = [bundle isEqualToString:@"com.metzrevive.manager"] ? 0x10000000 : 0x20000000;
    unsigned int serial = base | (width << 12) | (height << 1) | (fps == 60 ? 1 : 0);
    return CreateDisplay(NSClassFromString(@"CGVirtualDisplayDescriptor"), NSClassFromString(@"CGVirtualDisplay"),
        NSClassFromString(@"CGVirtualDisplaySettings"), NSClassFromString(@"CGVirtualDisplayMode"), serial, width, height, fps, failure);
}
#if METZ_DISPLAY_TESTING
void *METZCreateDisplayForTesting(Class descriptorClass, Class displayClass, Class settingsClass,
    Class modeClass, unsigned int serial, METZDisplayFailure *failure) {
    return CreateDisplay(descriptorClass, displayClass, settingsClass, modeClass, serial, 1280, 720, 30, failure);
}
void *METZCreateDisplayWithModeForTesting(Class descriptorClass, Class displayClass, Class settingsClass,
    Class modeClass, unsigned int width, unsigned int height, unsigned int fps, METZDisplayFailure *failure) {
    return CreateDisplay(descriptorClass, displayClass, settingsClass, modeClass, 2, width, height, fps, failure);
}
#endif
CGDirectDisplayID METZDisplayID(void *handle) { return [(__bridge CGVirtualDisplay *)handle displayID]; }
void METZReleaseDisplay(void *handle) { CFRelease(handle); }
