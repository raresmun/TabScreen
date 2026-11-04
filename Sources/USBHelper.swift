import Foundation
import CryptoKit

/// Uses Google's adb tool to tunnel the tablet's "localhost:7171" to this Mac over the USB cable.
/// When the tablet is plugged in, it installs (or updates) the TabScreen app on it and opens it.
/// If that doesn't work, it opens the viewer page in Chrome instead.
final class USBHelper: @unchecked Sendable {
    /// (status text for the menu, is the adb helper installed)
    var onStatus: (@Sendable (String, Bool) -> Void)?

    /// The tablet app: Android/TabScreen.apk, copied into TabScreen.app by build.sh.
    static let tabletAppPackage = "local.tabscreen.viewer"
    private static let tabletAppActivity = "local.tabscreen.viewer/.MainActivity"

    private let port: Int
    private let accessKey: String
    private let queue = DispatchQueue(label: "tabscreen.usb")
    private var timer: DispatchSourceTimer?
    private var adbPath: String?
    private var connected: Set<String> = []
    private var usingApp: Set<String> = []
    private var lastForwardRefresh = Date.distantPast
    private var serverStarted = false
    private lazy var bundledApp: (url: URL, sha256: String)? = USBHelper.loadBundledApp()

    static var helperDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabScreen", isDirectory: true)
    }

    init(port: Int, accessKey: String) {
        self.port = port
        self.accessKey = accessKey
    }

    static func findADB() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            helperDirectory.appendingPathComponent("platform-tools/adb").path,
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/.homebrew/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 2.0)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        if adbPath == nil { adbPath = USBHelper.findADB() }
        guard let adb = adbPath else {
            onStatus?("USB: not set up yet", false)
            return
        }
        if !serverStarted {
            runQuietly(adb, ["start-server"])
            serverStarted = true
        }
        let output = run(adb, ["devices"]).output
        var ready: Set<String> = []
        var waitingForApproval = false
        for line in output.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard columns.count >= 2 else { continue }
            switch columns[1] {
            case "device": ready.insert(columns[0])
            case "unauthorized": waitingForApproval = true
            default: break
            }
        }
        let newlyConnected = ready.subtracting(connected)
        for serial in newlyConnected {
            Log.write("Tablet \(serial) plugged in over USB")
            run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"])
            if prepareTabletApp(adb: adb, serial: serial) && openTabletApp(adb: adb, serial: serial) {
                usingApp.insert(serial)
            } else {
                usingApp.remove(serial)
                openBrowserViewer(adb: adb, serial: serial)
            }
        }
        if Date().timeIntervalSince(lastForwardRefresh) > 15 {
            lastForwardRefresh = Date()
            for serial in ready.subtracting(newlyConnected) {
                run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"])
            }
        }
        connected = ready
        usingApp.formIntersection(ready)
        if !ready.isEmpty {
            onStatus?(usingApp.isEmpty ? "USB: connected (Chrome)" : "USB: connected", true)
        } else if waitingForApproval {
            onStatus?("USB: tap “Allow” on the device", true)
        } else {
            onStatus?("USB: plug in your tablet or phone", true)
        }
    }

    // MARK: - The TabScreen app on the tablet

    /// Makes sure the tablet has this exact version of the TabScreen app. Returns false if it couldn't be installed.
    private func prepareTabletApp(adb: String, serial: String) -> Bool {
        guard let app = bundledApp else {
            Log.write("TabScreen.apk isn't inside TabScreen.app – using Chrome on the tablet")
            return false
        }
        if installedAppHash(adb: adb, serial: serial) == app.sha256 { return true }
        onStatus?("USB: installing the TabScreen app on the tablet…", true)
        Log.write("Installing the TabScreen app on the tablet (confirm on the tablet if it asks)")
        var result = run(adb, ["-s", serial, "install", "-r", app.url.path], timeout: 180)
        if !result.output.contains("Success")
            && (result.output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") || result.output.contains("signatures do not match")) {
            // A copy signed with a different key is in the way: replace it.
            run(adb, ["-s", serial, "uninstall", USBHelper.tabletAppPackage], timeout: 60)
            result = run(adb, ["-s", serial, "install", app.url.path], timeout: 180)
        }
        if result.status == 0 && result.output.contains("Success") {
            Log.write("TabScreen app installed on the tablet")
            return true
        }
        let reason = result.output.split(whereSeparator: { $0.isNewline }).last.map(String.init) ?? "no answer from the tablet"
        Log.write("Couldn't install the TabScreen app (\(reason)) – using Chrome on the tablet")
        return false
    }

    /// SHA-256 of the TabScreen app installed on the tablet, or nil if it isn't installed.
    private func installedAppHash(adb: String, serial: String) -> String? {
        let paths = run(adb, ["-s", serial, "shell", "pm", "path", USBHelper.tabletAppPackage]).output
        let lines = paths.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line = lines.first(where: { $0.hasPrefix("package:") && $0.hasSuffix("/base.apk") }) else { return nil }
        let path = String(line.dropFirst("package:".count))
        let output = run(adb, ["-s", serial, "shell", "sha256sum", path]).output
        guard let hash = output.split(whereSeparator: { $0 == " " || $0.isNewline }).first, hash.count == 64 else { return nil }
        return hash.lowercased()
    }

    /// Opens the app. It also gets the Mac's Wi-Fi address and key, so it can connect over Wi-Fi later
    /// (when "Allow Wi-Fi connection" is on) without typing anything.
    private func openTabletApp(adb: String, serial: String) -> Bool {
        var arguments = ["-s", serial, "shell", "am", "start", "-n", USBHelper.tabletAppActivity]
        if let ip = lanIPv4() {
            arguments += ["--es", "wifiHost", ip, "--es", "wifiKey", accessKey]
        }
        let result = run(adb, arguments)
        if result.status == 0 && !result.output.contains("Error") {
            Log.write("Opened the TabScreen app on the tablet")
            return true
        }
        Log.write("Couldn't open the TabScreen app on the tablet")
        return false
    }

    /// Fallback: the viewer page in Chrome.
    private func openBrowserViewer(adb: String, serial: String) {
        let url = "http://localhost:\(port)/"
        // The application id makes Chrome reuse its TabScreen tab instead of opening a new one every time.
        let reuseTab = ["--es", "com.android.browser.application_id", "tabscreen"]
        let chrome = run(adb, ["-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url] + reuseTab + ["com.android.chrome"])
        if chrome.status != 0 || chrome.output.contains("Error") {
            run(adb, ["-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url] + reuseTab)
        }
    }

    private static func loadBundledApp() -> (url: URL, sha256: String)? {
        guard let url = Bundle.main.url(forResource: "TabScreen", withExtension: "apk"),
              let data = try? Data(contentsOf: url) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (url, hash)
    }

    // MARK: - adb

    /// Downloads Google's platform-tools (which contain adb) into ~/Library/Application Support/TabScreen.
    func installHelper(completion: @escaping @Sendable (Bool, String) -> Void) {
        guard let url = URL(string: "https://dl.google.com/android/repository/platform-tools-latest-darwin.zip") else { return }
        Log.write("Downloading adb from Google…")
        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self = self else { return }
            guard let tempURL = tempURL, error == nil else {
                completion(false, error?.localizedDescription ?? "download failed")
                return
            }
            let fileManager = FileManager.default
            let directory = USBHelper.helperDirectory
            let zip = directory.appendingPathComponent("platform-tools.zip")
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: zip.path) { try fileManager.removeItem(at: zip) }
                try fileManager.moveItem(at: tempURL, to: zip)
            } catch {
                completion(false, error.localizedDescription)
                return
            }
            let unzip = self.run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path], timeout: 60)
            try? fileManager.removeItem(at: zip)
            if unzip.status == 0, let path = USBHelper.findADB() {
                Log.write("adb installed at \(path)")
                self.queue.async { self.adbPath = path }
                completion(true, path)
            } else {
                completion(false, unzip.output)
            }
        }.resume()
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func runQuietly(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.write("Could not run \(path): \(error.localizedDescription)")
        }
    }
}
