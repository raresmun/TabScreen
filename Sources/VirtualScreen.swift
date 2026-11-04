import Foundation
import CoreGraphics

/// The extra monitor macOS sees. It exists as long as this object (and the app) is alive.
final class VirtualScreen {
    struct Preset {
        let title: String
        let pointsWide: Int
    }

    /// "Looks like" sizes for the 10.9" tablet, all rendered sharp (HiDPI).
    static let presets: [Preset] = [
        Preset(title: "Same size as your MacBook (1152 × 720)", pointsWide: 1152),
        Preset(title: "More space (1280 × 800)", pointsWide: 1280),
        Preset(title: "Most space (1440 × 900)", pointsWide: 1440),
    ]

    private var display: TSVirtualDisplay?

    var displayID: CGDirectDisplayID { display?.displayID ?? 0 }

    func create() -> Bool {
        // Try 90 Hz first (the tablet's refresh rate); fall back to 60 Hz if macOS refuses.
        for rates in [[90.0, 60.0], [60.0]] {
            if let newDisplay = makeDisplay(refreshRates: rates) {
                display = newDisplay
                Log.write("Virtual display created (id \(newDisplay.displayID), up to \(Int(rates[0])) Hz)")
                return true
            }
        }
        Log.write("Creating the virtual display failed")
        return false
    }

    private func makeDisplay(refreshRates: [Double]) -> TSVirtualDisplay? {
        // Pixel sizes and point sizes are both listed so macOS can build the sharp (HiDPI) modes.
        let sizes: [NSSize] = [
            NSSize(width: 2880, height: 1800), NSSize(width: 2560, height: 1600), NSSize(width: 2304, height: 1440),
            NSSize(width: 1440, height: 900), NSSize(width: 1280, height: 800), NSSize(width: 1152, height: 720),
        ]
        return TSVirtualDisplay(
            name: "Galaxy Tab",
            maxPixelsWide: 2880,
            maxPixelsHigh: 1800,
            sizeInMillimeters: CGSize(width: 235, height: 147),   // 10.9" 16:10 panel
            modes: sizes.map { NSValue(size: $0) },
            hiDPI: true,
            refreshRates: refreshRates.map { NSNumber(value: $0) },
            serialNum: 1
        )
    }

    func destroy() {
        display = nil
    }

    /// Switches the display to the sharp mode that "looks like" `pointsWide` wide.
    /// Returns false while macOS is still setting the display up.
    func apply(pointsWide: Int) -> Bool {
        let id = displayID
        guard id != 0 else { return false }
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode], !modes.isEmpty else {
            Log.write("Display modes not ready yet")
            return false
        }
        let modeList = modes.map { "\($0.width)x\($0.height)[\($0.pixelWidth)x\($0.pixelHeight)]" }
        Log.write("Available modes: " + modeList.joined(separator: " "))
        let sameWidth = modes.filter { $0.width == pointsWide }
        let closest = modes.min { abs($0.width - pointsWide) < abs($1.width - pointsWide) }
        let sharp = sameWidth.filter { $0.pixelWidth == pointsWide * 2 }
        let candidates = sharp.isEmpty ? sameWidth : sharp
        guard let mode = candidates.max(by: { $0.refreshRate < $1.refreshRate }) ?? closest else {
            return false
        }
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else { return false }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        Log.write("Display mode set to \(mode.width)x\(mode.height) [pixels \(mode.pixelWidth)x\(mode.pixelHeight)] @ \(Int(mode.refreshRate)) Hz, result \(result.rawValue)")
        return result == .success
    }
}
