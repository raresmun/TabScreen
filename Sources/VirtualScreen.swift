import Foundation
import CoreGraphics

/// The extra monitor macOS sees, shaped like the connected device's screen.
/// It exists as long as this object holds it.
final class VirtualScreen {
    private var display: TSVirtualDisplay?

    var displayID: CGDirectDisplayID { display?.displayID ?? 0 }

    func create(for screen: DeviceScreen) -> Bool {
        // Try the device's refresh rate first; fall back to 60 Hz if macOS refuses.
        let fps = screen.video.fps
        let attempts: [[Double]] = fps == 60 ? [[60]] : [[Double(fps), 60], [60]]
        for refreshRates in attempts {
            if let newDisplay = makeDisplay(for: screen, refreshRates: refreshRates) {
                display = newDisplay
                Log.write("Extra display created for \(screen.name) (id \(newDisplay.displayID), up to \(Int(refreshRates[0])) Hz)")
                return true
            }
        }
        Log.write("Creating the extra display failed")
        return false
    }

    private func makeDisplay(for screen: DeviceScreen, refreshRates: [Double]) -> TSVirtualDisplay? {
        let modes = screen.displayModes
        let maxWidth = modes.map { Int($0.width) }.max() ?? screen.pixelWidth
        let maxHeight = modes.map { Int($0.height) }.max() ?? screen.pixelHeight
        return TSVirtualDisplay(
            name: screen.name,
            maxPixelsWide: UInt32(maxWidth),
            maxPixelsHigh: UInt32(maxHeight),
            sizeInMillimeters: screen.physicalSizeMM,
            modes: modes.map { NSValue(size: $0) },
            hiDPI: true,
            refreshRates: refreshRates.map { NSNumber(value: $0) },
            serialNum: screen.serialNumber
        )
    }

    func destroy() {
        display = nil
    }

    /// Switches the display to the sharp (HiDPI) mode that "looks like" `pointsWide` wide.
    /// Returns false while macOS is still setting the display up.
    func apply(pointsWide: Int) -> Bool {
        let id = displayID
        guard id != 0 else { return false }
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode], !modes.isEmpty else {
            Log.write("Display modes not ready yet")
            return false
        }
        let sameWidth = modes.filter { $0.width == pointsWide }
        let closest = modes.min { abs($0.width - pointsWide) < abs($1.width - pointsWide) }
        let sharp = sameWidth.filter { $0.pixelWidth == pointsWide * 2 }
        let candidates = sharp.isEmpty ? sameWidth : sharp
        guard let mode = candidates.max(by: { $0.refreshRate < $1.refreshRate }) ?? closest else {
            return false
        }
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, mode, nil) == .success else {
            _ = CGCancelDisplayConfiguration(config)
            Log.write("Display mode \(mode.width)x\(mode.height) not accepted yet")
            return false
        }
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        Log.write("Display mode set to \(mode.width)x\(mode.height) [pixels \(mode.pixelWidth)x\(mode.pixelHeight)] @ \(Int(mode.refreshRate)) Hz, result \(result.rawValue)")
        return result == .success
    }
}
