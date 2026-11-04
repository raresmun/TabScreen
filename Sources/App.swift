import AppKit

/// Galaxy Tab S10 FE screen size in pixels (landscape). The video is sent at this size.
let tabletPixelWidth = 2304
let tabletPixelHeight = 1440
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
    private var statusItem: NSStatusItem?
    private let virtualScreen = VirtualScreen()
    private var server: StreamServer?
    private var encoder: H264Encoder?
    private var capturer: ScreenCapturer?
    private var usb: USBHelper?
    private var cursor: CursorTracker?

    private var viewerCount = 0
    private var usbStatus = "USB: starting…"
    private var usbHelperInstalled = true
    private var installingUSBHelper = false
    private var problem: String?
    private var wifiEnabled = false   // switched on by hand each time, so Wi-Fi access is never left open by accident
    private var presetIndex = UserDefaults.standard.integer(forKey: "presetIndex")
    private let accessKey = AppDelegate.loadAccessKey()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.reset()
        UserDefaults.standard.removeObject(forKey: "wifiEnabled")   // from an older version
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

        guard virtualScreen.create() else {
            problem = "Couldn't create the extra display"
            rebuildMenu()
            return
        }
        applyPreset(attempt: 0)

        let page = Bundle.main.url(forResource: "viewer", withExtension: "html").flatMap { try? Data(contentsOf: $0) }
            ?? Data("<h1>viewer.html is missing – rebuild TabScreen</h1>".utf8)
        let server = StreamServer(port: serverPort, html: page, accessKey: accessKey, allowNetwork: wifiEnabled)
        let encoder = H264Encoder(width: tabletPixelWidth, height: tabletPixelHeight)
        let jpegEncoder = JPEGEncoder()
        let capturer = ScreenCapturer(encoder: encoder, jpegEncoder: jpegEncoder)
        encoder.sink = server
        jpegEncoder.onFrame = { picture, fullSize in server.broadcastJPEG(picture, fullSize: fullSize) }
        server.onJPEGDemandChange = { [weak capturer] wanted in capturer?.setJPEGWanted(wanted) }
        server.onJPEGNeeded = { [weak capturer] in capturer?.sendJPEGNow() }
        server.onKeyFrameNeeded = { [weak capturer] in
            capturer?.resendLastFrame(asKeyFrame: true)
        }
        server.onViewerCountChange = { count in
            Task { @MainActor in self.viewerCountChanged(count) }
        }
        capturer.onError = { message in
            Task { @MainActor in self.showProblem(message) }
        }
        self.server = server
        self.encoder = encoder
        self.capturer = capturer

        server.start()
        if encoder.start() {
            capturer.start(displayID: virtualScreen.displayID, width: tabletPixelWidth, height: tabletPixelHeight)
        } else {
            problem = "The video encoder failed to start"
        }

        let cursor = CursorTracker(displayID: virtualScreen.displayID, server: server)
        cursor.start()
        self.cursor = cursor
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

    private func applyPreset(attempt: Int) {
        let index = max(0, min(presetIndex, VirtualScreen.presets.count - 1))
        let pointsWide = VirtualScreen.presets[index].pointsWide
        if !virtualScreen.apply(pointsWide: pointsWide) && attempt < 10 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.applyPreset(attempt: attempt + 1)
            }
        }
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

        if let problem = problem {
            addAction("⚠️ " + problem, #selector(openScreenRecordingSettings))
            addAction("Restart TabScreen", #selector(relaunch))
            menu.addItem(NSMenuItem.separator())
        }

        addInfo(viewerCount > 0 ? "● Tablet is showing the display" : "○ Waiting for the tablet…")
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
        let sizeItem = NSMenuItem(title: "Screen size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        sizeMenu.autoenablesItems = false
        for (index, preset) in VirtualScreen.presets.enumerated() {
            let item = NSMenuItem(title: preset.title, action: #selector(choosePreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == presetIndex ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
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

    @objc private func choosePreset(_ sender: NSMenuItem) {
        presetIndex = sender.tag
        UserDefaults.standard.set(presetIndex, forKey: "presetIndex")
        applyPreset(attempt: 0)
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

    nonisolated private static func loadAccessKey() -> String {
        if let saved = UserDefaults.standard.string(forKey: "accessKey"), !saved.isEmpty { return saved }
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let key = String((0..<6).map { _ in alphabet.randomElement()! })
        UserDefaults.standard.set(key, forKey: "accessKey")
        return key
    }
}
