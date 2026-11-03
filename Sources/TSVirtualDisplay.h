// TabScreen – small Objective-C wrapper around macOS's virtual display API (CGVirtualDisplay).
// The same (undocumented) API is used by DeskPad, BetterDisplay and Chromium's test tools.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSVirtualDisplay : NSObject

@property (nonatomic, readonly) CGDirectDisplayID displayID;

- (nullable instancetype)initWithName:(NSString *)name
                        maxPixelsWide:(unsigned int)maxPixelsWide
                        maxPixelsHigh:(unsigned int)maxPixelsHigh
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                                modes:(NSArray<NSValue *> *)modes
                                hiDPI:(BOOL)hiDPI
                         refreshRates:(NSArray<NSNumber *> *)refreshRates
                            serialNum:(unsigned int)serialNum;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
