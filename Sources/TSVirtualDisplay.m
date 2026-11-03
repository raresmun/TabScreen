#import "TSVirtualDisplay.h"

// ---- Private CoreGraphics classes. Declarations only: the classes are looked up at runtime. ----
@class CGVirtualDisplay;

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) unsigned int width;
@property (readonly, nonatomic) unsigned int height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@implementation TSVirtualDisplay {
    id _display; // Keeps the virtual display alive. Releasing it removes the display from macOS.
}

- (nullable instancetype)initWithName:(NSString *)name
                        maxPixelsWide:(unsigned int)maxPixelsWide
                        maxPixelsHigh:(unsigned int)maxPixelsHigh
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                                modes:(NSArray<NSValue *> *)modes
                                hiDPI:(BOOL)hiDPI
                         refreshRates:(NSArray<NSNumber *> *)refreshRates
                            serialNum:(unsigned int)serialNum {
    self = [super init];
    if (!self) return nil;

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descriptorClass || !displayClass || !settingsClass || !modeClass) {
        NSLog(@"TabScreen: the virtual display API is not available on this macOS version");
        return nil;
    }

    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    [descriptor setDispatchQueue:dispatch_get_main_queue()];
    descriptor.name = name;
    descriptor.maxPixelsWide = maxPixelsWide;
    descriptor.maxPixelsHigh = maxPixelsHigh;
    descriptor.sizeInMillimeters = sizeInMillimeters;
    descriptor.vendorID = 0x5453;   // "TS" – kept constant so macOS remembers where you placed the display
    descriptor.productID = 0x5410;
    descriptor.serialNum = serialNum;

    CGVirtualDisplay *display = [(CGVirtualDisplay *)[displayClass alloc] initWithDescriptor:descriptor];
    if (!display) {
        NSLog(@"TabScreen: macOS refused to create the virtual display");
        return nil;
    }

    NSMutableArray *modeObjects = [NSMutableArray array];
    for (NSValue *value in modes) {
        NSSize size = value.sizeValue;
        for (NSNumber *rate in refreshRates) {
            CGVirtualDisplayMode *mode = [(CGVirtualDisplayMode *)[modeClass alloc] initWithWidth:(unsigned int)size.width
                                                                                           height:(unsigned int)size.height
                                                                                      refreshRate:rate.doubleValue];
            if (mode) [modeObjects addObject:mode];
        }
    }

    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = modeObjects;
    if (![display applySettings:settings]) {
        NSLog(@"TabScreen: applying the display modes failed");
        return nil;
    }

    _display = display;
    _displayID = display.displayID;
    return self;
}

@end
