import Foundation
import CoreGraphics

/// The screen of the device that shows the extra display (an Android tablet or phone), as it described itself when
/// it connected, and everything TabScreen derives from it: the extra display's shape and "looks like" sizes, and the
/// size and frame rate of the video.
struct DeviceScreen: Codable, Equatable {
    struct SizeChoice {
        let title: String
        let pointsWide: Int
        let pointsHigh: Int
    }

    var name: String
    /// Screen pixels in landscape: the longer side is the width.
    var pixelWidth: Int
    var pixelHeight: Int
    var refreshRate: Int
    /// Physical size in millimetres (0 when unknown).
    var widthMM: Int
    var heightMM: Int
    /// The largest video the device's hardware decoder handles (0 when unknown).
    var maxVideoWidth: Int
    var maxVideoHeight: Int
    var maxVideoFPS: Int

    /// Used until a device connects: a 10.9" 16:10 tablet such as the Galaxy Tab S10 FE.
    static let standard = DeviceScreen(name: "Tablet", pixelWidth: 2304, pixelHeight: 1440, refreshRate: 60,
                                       widthMM: 235, heightMM: 147, maxVideoWidth: 0, maxVideoHeight: 0, maxVideoFPS: 0)

    init(name: String, pixelWidth: Int, pixelHeight: Int, refreshRate: Int, widthMM: Int, heightMM: Int,
         maxVideoWidth: Int, maxVideoHeight: Int, maxVideoFPS: Int) {
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.maxVideoWidth = maxVideoWidth
        self.maxVideoHeight = maxVideoHeight
        self.maxVideoFPS = maxVideoFPS
    }

    /// Reads the "hello" a viewer sends when it connects. Nil if it doesn't describe a usable screen.
    init?(hello message: [String: Any]) {
        func number(_ key: String) -> Double {
            let value = (message[key] as? NSNumber)?.doubleValue ?? 0
            return value.isFinite ? min(max(value, 0), 100_000) : 0
        }
        var width = Int(number("w"))
        var height = Int(number("h"))
        if height > width { swap(&width, &height) }
        width &= ~1   // even sizes; browsers sometimes report 2305 for 2304
        height &= ~1
        guard width >= 320, height >= 200, width <= 8192, height <= 8192 else { return nil }
        let isApp = (message["client"] as? String) == "app"
        let givenName = (message["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var widthMM = Int(number("mmW"))
        var heightMM = Int(number("mmH"))
        if !isApp && number("cssW") > 0 && number("cssH") > 0 {
            // Browsers on Android measure in CSS pixels, about 1/160 inch each.
            widthMM = Int(max(number("cssW"), number("cssH")) / 160 * 25.4)
            heightMM = Int(min(number("cssW"), number("cssH")) / 160 * 25.4)
        }
        let diagonalInches = Double(widthMM * widthMM + heightMM * heightMM).squareRoot() / 25.4
        if diagonalInches < 3 || diagonalInches > 40 {
            widthMM = 0
            heightMM = 0
        }
        let refresh = Int(number("refresh").rounded())
        self.init(name: isApp ? (givenName.isEmpty ? "Android device" : String(givenName.prefix(40))) : "Browser",
                  pixelWidth: width, pixelHeight: height,
                  refreshRate: refresh >= 24 && refresh <= 240 ? refresh : 60,
                  widthMM: widthMM, heightMM: heightMM,
                  maxVideoWidth: Int(number("maxW")), maxVideoHeight: Int(number("maxH")), maxVideoFPS: Int(number("maxFps")))
    }

    /// Identifies the device across connections (its size choice, its place in the display arrangement).
    var key: String { "\(name) \(pixelWidth)x\(pixelHeight)" }

    /// macOS remembers where each display sits by vendor, product and serial number, so each device gets its own.
    var serialNumber: UInt32 {
        var hash: UInt32 = 2_166_136_261   // FNV-1a
        for byte in key.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    /// The video: the device's own pixels (sharpest), within what its decoder handles and what H.264 allows.
    var video: (width: Int, height: Int, fps: Int) {
        let width = Double(pixelWidth)
        let height = Double(pixelHeight)
        var scale = min(1, (2880.0 * 1800.0 / (width * height)).squareRoot())   // more pixels than that don't help
        if maxVideoWidth > 0 && maxVideoHeight > 0 {
            scale = min(scale, Double(maxVideoWidth) / width, Double(maxVideoHeight) / height)
        }
        let videoWidth = max(320, Int(width * scale) & ~1)
        let videoHeight = max(200, Int(height * scale) & ~1)
        var fps = refreshRate
        if maxVideoFPS > 0 { fps = min(fps, maxVideoFPS) }
        // H.264 level 5.2 allows 2,073,600 macroblocks (16 x 16 pixels) a second.
        let macroblocks = ((videoWidth + 15) / 16) * ((videoHeight + 15) / 16)
        fps = min(fps, 120, 2_073_600 / macroblocks)
        fps = [120, 90, 75, 60, 50, 30].first { $0 <= fps } ?? 30
        return (videoWidth, videoHeight, fps)
    }

    /// Screen width in inches; estimated from the pixels when the device didn't say (a typical 2x screen).
    var widthInches: Double {
        widthMM > 0 ? Double(widthMM) / 25.4 : Double(pixelWidth) / 2 / 125
    }

    /// Physical size for macOS (it uses it to suggest sizes and to work out the display's resolution).
    var physicalSizeMM: CGSize {
        let width = widthInches * 25.4
        return CGSize(width: width, height: width * Double(pixelHeight) / Double(pixelWidth))
    }

    /// "Looks like" sizes, all drawn sharp (HiDPI). "Same size as your Mac" makes text about as big as on a Mac's
    /// built-in screen (about 125 points per inch); the others trade size for space.
    var sizeChoices: [SizeChoice] {
        var choices: [SizeChoice] = []
        func add(_ title: String, pointsWide: Int) {
            let width = min(max(pointsWide, 480), 2560) / 8 * 8
            let height = Int((Double(width) * Double(pixelHeight) / Double(pixelWidth) / 2).rounded()) * 2
            guard !choices.contains(where: { $0.pointsWide == width }) else { return }
            choices.append(SizeChoice(title: "\(title) (\(width) × \(height))", pointsWide: width, pointsHigh: height))
        }
        let targets: [(title: String, pointsPerInch: Double)] = [
            ("Larger text", 110), ("Same size as your Mac", 125), ("More space", 140), ("Most space", 160),
        ]
        for target in targets {
            add(target.title, pointsWide: Int((widthInches * target.pointsPerInch / 16).rounded()) * 16)
        }
        add("Pixel for pixel", pointsWide: pixelWidth / 2)
        return choices.sorted { $0.pointsWide < $1.pointsWide }
    }

    /// The size used until you pick one: text about as big as on the Mac.
    var defaultPointsWide: Int {
        let target = widthInches * 125
        let closest = sizeChoices.min { abs(Double($0.pointsWide) - target) < abs(Double($1.pointsWide) - target) }
        return closest?.pointsWide ?? pixelWidth / 2
    }

    /// Modes to offer macOS: every size choice in HiDPI pixels and in points.
    var displayModes: [CGSize] {
        var modes: [CGSize] = []
        for choice in sizeChoices {
            modes.append(CGSize(width: choice.pointsWide * 2, height: choice.pointsHigh * 2))
            modes.append(CGSize(width: choice.pointsWide, height: choice.pointsHigh))
        }
        return modes
    }
}
