import AppKit

/// Port used for the viewer page and the video stream.
let serverPort: UInt16 = 7171

@main
struct TabScreenApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// How much data the video may use, relative to "Balanced".
    private static let qualities: [(title: String, factor: Double)] = [
        ("Lighter – for slow Wi-Fi", 0.5),
        ("Balanced", 1.0),
        ("Sharper – uses more data", 1.6),
    ]

    private var statusItem: NSStatusItem?
    private let virtualScreen = VirtualScreen()
    private var server: StreamServer?
    private var capturer: ScreenCapturer?
    private var usb: USBHelper?
    private var cursor: CursorTracker?

    private var viewerCount = 0
    private var usbStatus = "USB: starting…"
    private var usbHelperInstalled = true
    private var installingUSBHelper = false
    private var problem: String?
    private var wifiEnabled = false   // switched on by hand each time, so Wi-Fi access is never left open by accident
    private var device = AppDelegate.loadDevice()   // the screen the extra display is shaped for
    private var quality = UserDefaults.standard.object(forKey: "quality") as? Int ?? 1
    private var displayGeneration = 0
    private let accessKey = AppDelegate.loadAccessKey()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.reset()
        UserDefaults.standard.removeObject(forKey: "wifiEnabled")   // from an older version
        UserDefaults.standard.removeObject(forKey: "presetIndex")   // from an older version
        Log.write("TabScreen starting")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "ipad.landscape", accessibilityDescription: "TabScreen") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "TabScreen"
        }
        statusItem = item

        if !CGPreflightScreenCaptureAccess() {
            Log.write("Screen Recording permission not granted yet – asking")
            CGRequestScreenCaptureAccess()
            problem = "Allow Screen Recording for TabScreen, then restart it"
        }

        let page = Bundle.main.url(forResource: "viewer", withExtension: "html").flatMap { try? Data(contentsOf: $0) }
            ?? Data("<h1>viewer.html is missing – rebuild TabScreen</h1>".utf8)
        let server = StreamServer(port: serverPort, html: page, accessKey: accessKey, allowNetwork: wifiEnabled)
        let encoder = H264Encoder()
        let jpegEncoder = JPEGEncoder()
        let capturer = ScreenCapturer(encoder: encoder, jpegEncoder: jpegEncoder)
        encoder.sink = server
        jpegEncoder.onFrame = { picture, fullSize in server.broadcastJPEG(picture, fullSize: fullSize) }
        server.onJPEGDemandChange = { [weak capturer] wanted in capturer?.setJPEGWanted(wanted) }
        server.onJPEGNeeded = { [weak capturer] in capturer?.sendJPEGNow() }
        server.onKeyFrameNeeded = { [weak capturer] in
            capturer?.resendLastFrame(asKeyFrame: true)
        }
        server.onViewerCountChange = { [weak capturer] count in
            capturer?.setVideoWanted(count > 0)
            Task { @MainActor in self.viewerCountChanged(count) }
        }
        server.onDeviceScreen = { screen in
            Task { @MainActor in self.deviceConnected(screen) }
        }
        capturer.onError = { message in
            Task { @MainActor in self.showProblem(message) }
        }
        self.server = server
        self.capturer = capturer
        server.start()

        let cursor = CursorTracker(server: server)
        cursor.start()
        self.cursor = cursor

        showExtraDisplay()
        if let ip = lanIPv4() { Log.write("Mac address for the tablet: http://\(ip):\(serverPort)") }

        let usb = USBHelper(port: Int(serverPort), accessKey: accessKey)
        usb.onStatus = { text, installed in
            Task { @MainActor in self.usbStatusChanged(text, installed: installed) }
        }
        usb.start()
        self.usb = usb

        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        capturer?.stop()
        virtualScreen.destroy()
        Log.write("TabScreen quit")
    }

    // MARK: - The extra display

    /// Creates the extra display, shaped for the current device, and starts sending it.
    private func showExtraDisplay(attempt: Int = 0) {
        guard virtualScreen.create(for: device) else {
            if attempt < 2 {
                // macOS may still be taking the previous display away: try again in a moment.
                let generation = displayGeneration
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard generation == self.displayGeneration else { return }
                    self.showExtraDisplay(attempt: attempt + 1)
                }
            } else {
                showProblem("Couldn't create the extra display")
            }
            return
        }
        if CGPreflightScreenCaptureAccess() { problem = nil }   // earlier capture problems are over
        saveDevice()   // only shapes that worked are remembered
        cursor?.displayID = virtualScreen.displayID
        applySize(attempt: 0)
        startCapture()
        rebuildMenu()
    }

    private func startCapture() {
        let video = device.video
        capturer?.start(displayID: virtualScreen.displayID, width: video.width, height: video.height,
                        fps: video.fps, bitrate: bitrate(for: video))
    }

    /// A tablet or phone connected and described its screen. If its screen has another shape, the extra display is
    /// rebuilt for it (macOS moves the windows on it to the main screen meanwhile); otherwise only the video changes.
    private func deviceConnected(_ screen: DeviceScreen) {
        guard screen != device || virtualScreen.displayID == 0 else { return }
        Log.write("Shaping the extra display for \(screen.name): \(screen.pixelWidth)x\(screen.pixelHeight) at \(screen.refreshRate) Hz"
                  + (screen.widthMM > 0 ? ", \(screen.widthMM)x\(screen.heightMM) mm" : ""))
        let sameDisplay = virtualScreen.displayID != 0 && screen.name == device.name
            && screen.displayModes == device.displayModes && screen.physicalSizeMM == device.physicalSizeMM
            && screen.video.fps == device.video.fps
        device = screen
        if sameDisplay {
            saveDevice()
            startCapture()   // same display; only the video's size or limits changed
            rebuildMenu()
            return
        }
        displayGeneration += 1
        let generation = displayGeneration
        capturer?.stop()
        cursor?.displayID = 0
        virtualScreen.destroy()
        rebuildMenu()
        Task { @MainActor in
            // Give macOS a moment to take the old display away before adding the new one.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard generation == self.displayGeneration else { return }
            self.showExtraDisplay()
        }
    }

    private func applySize(attempt: Int) {
        let generation = displayGeneration
        if !virtualScreen.apply(pointsWide: chosenPointsWide()) && attempt < 10 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard generation == self.displayGeneration else { return }
                self.applySize(attempt: attempt + 1)
            }
        }
    }

    /// The "looks like" width picked for this device, or the default (text about as big as on the Mac).
    private func chosenPointsWide() -> Int {
        let saved = UserDefaults.standard.integer(forKey: "pointsWide " + device.key)
        if saved > 0 && device.sizeChoices.contains(where: { $0.pointsWide == saved }) { return saved }
        return device.defaultPointsWide
    }

    /// Video data rate: about 20 Mbit/s for 2304 x 1440 at 90 frames a second, scaled by size, frame rate and quality.
    private func bitrate(for video: (width: Int, height: Int, fps: Int)) -> Int {
        let factor = AppDelegate.qualities[max(0, min(quality, AppDelegate.qualities.count - 1))].factor
        let base = 20_000_000.0 * Double(video.width * video.height * video.fps) / Double(2304 * 1440 * 90)
        return Int(min(max(base * factor, 3_000_000), 60_000_000))
    }

    // MARK: - State updates

    private func viewerCountChanged(_ count: Int) {
        viewerCount = count
        rebuildMenu()
    }

    private func usbStatusChanged(_ text: String, installed: Bool) {
        guard text != usbStatus || installed != usbHelperInstalled else { return }
        usbStatus = text
        usbHelperInstalled = installed
        rebuildMenu()
    }

    private func showProblem(_ message: String) {
        problem = message
        rebuildMenu()
    }

    private func wifiAddress() -> String? {
        guard let ip = lanIPv4() else { return nil }
        return "http://\(ip):\(serverPort)/?k=\(accessKey)"
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func addInfo(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func addAction(_ title: String, _ action: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        func addSubmenu(_ title: String, _ entries: [(title: String, tag: Int, on: Bool)], _ action: Selector) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for entry in entries {
                let entryItem = NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
                entryItem.target = self
                entryItem.tag = entry.tag
                entryItem.state = entry.on ? .on : .off
                submenu.addItem(entryItem)
            }
            item.submenu = submenu
            menu.addItem(item)
        }

        if let problem = problem {
            addAction("⚠️ " + problem, #selector(openScreenRecordingSettings))
            addAction("Restart TabScreen", #selector(relaunch))
            menu.addItem(NSMenuItem.separator())
        }

        addInfo(viewerCount > 0 ? "● \(device.name) is showing the display" : "○ Waiting for a tablet or phone…")
        addInfo(usbStatus)
        if !usbHelperInstalled {
            if installingUSBHelper {
                addInfo("Downloading the USB helper…")
            } else {
                addAction("Set up USB connection…", #selector(installUSBHelper))
            }
        }

        menu.addItem(NSMenuItem.separator())
        let wifiItem = NSMenuItem(title: "Allow Wi-Fi connection", action: #selector(toggleWifi), keyEquivalent: "")
        wifiItem.target = self
        wifiItem.state = wifiEnabled ? .on : .off
        menu.addItem(wifiItem)
        if wifiEnabled {
            if let ip = lanIPv4(), let address = wifiAddress() {
                addInfo("Tablet app: Mac address \(ip), key \(accessKey)")
                addInfo("Browser: \(address)")
                addAction("Copy browser address", #selector(copyWifiAddress))
            } else {
                addInfo("Not connected to a Wi-Fi network")
            }
        }

        menu.addItem(NSMenuItem.separator())
        let video = device.video
        let shapedFor = device == DeviceScreen.standard ? "" : " – \(device.name)"
        addInfo("Extra display: \(video.width) × \(video.height) at \(video.fps) Hz\(shapedFor)")
        let chosen = chosenPointsWide()
        addSubmenu("Screen size", device.sizeChoices.map { (title: $0.title, tag: $0.pointsWide, on: $0.pointsWide == chosen) },
                   #selector(chooseSize(_:)))
        addSubmenu("Picture quality", AppDelegate.qualities.enumerated().map { (title: $0.element.title, tag: $0.offset, on: $0.offset == quality) },
                   #selector(chooseQuality(_:)))
        addAction("Arrange displays…", #selector(openDisplaySettings))

        menu.addItem(NSMenuItem.separator())
        addAction("Quit TabScreen", #selector(quit), key: "q")
        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    @objc private func toggleWifi() {
        wifiEnabled.toggle()
        server?.restart(allowNetwork: wifiEnabled)
        rebuildMenu()
    }

    @objc private func copyWifiAddress() {
        guard let address = wifiAddress() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "pointsWide " + device.key)
        applySize(attempt: 0)
        rebuildMenu()
    }

    @objc private func chooseQuality(_ sender: NSMenuItem) {
        quality = sender.tag
        UserDefaults.standard.set(quality, forKey: "quality")
        capturer?.setBitrate(bitrate(for: device.video))
        rebuildMenu()
    }

    @objc private func installUSBHelper() {
        guard let usb = usb, !installingUSBHelper else { return }
        installingUSBHelper = true
        rebuildMenu()
        usb.installHelper { success, message in
            Task { @MainActor in
                self.installingUSBHelper = false
                if !success { self.showProblem("USB helper download failed: \(message)") }
                self.rebuildMenu()
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Saved settings

    private func saveDevice() {
        if let data = try? JSONEncoder().encode(device) {
            UserDefaults.standard.set(data, forKey: "device")
        }
    }

    nonisolated private static func loadDevice() -> DeviceScreen {
        if let data = UserDefaults.standard.data(forKey: "device"),
           let saved = try? JSONDecoder().decode(DeviceScreen.self, from: data),
           saved.pixelWidth >= 320, saved.pixelHeight >= 200, saved.pixelWidth <= 8192, saved.pixelHeight <= 8192,
           saved.refreshRate > 0 {
            return saved
        }
        return .standard
    }

    nonisolated private static func loadAccessKey() -> String {
        if let saved = UserDefaults.standard.string(forKey: "accessKey"), !saved.isEmpty { return saved }
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let key = String((0..<6).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(key, forKey: "accessKey")
        return key
    }
}
