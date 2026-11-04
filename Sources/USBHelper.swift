import Foundation

/// Uses Google's adb tool to tunnel the tablet's "localhost:7171" to this Mac over the USB cable,
/// and opens the viewer in Chrome on the tablet as soon as it's plugged in.
final class USBHelper: @unchecked Sendable {
    /// (status text for the menu, is the adb helper installed)
    var onStatus: (@Sendable (String, Bool) -> Void)?

    private let port: Int
    private let queue = DispatchQueue(label: "tabscreen.usb")
    private var timer: DispatchSourceTimer?
    private var adbPath: String?
    private var connected: Set<String> = []
    private var lastForwardRefresh = Date.distantPast
    private var serverStarted = false

    static var helperDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabScreen", isDirectory: true)
    }

    init(port: Int) {
        self.port = port
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
            run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"])
            openViewer(adb: adb, serial: serial)
            Log.write("Tablet \(serial) plugged in over USB")
        }
        if Date().timeIntervalSince(lastForwardRefresh) > 15 {
            lastForwardRefresh = Date()
            for serial in ready.subtracting(newlyConnected) {
                run(adb, ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"])
            }
        }
        connected = ready
        if !ready.isEmpty {
            onStatus?("USB: tablet plugged in", true)
        } else if waitingForApproval {
            onStatus?("USB: tap “Allow” on the tablet", true)
        } else {
            onStatus?("USB: plug in the tablet", true)
        }
    }

    private func openViewer(adb: String, serial: String) {
        let url = "http://localhost:\(port)/"
        // The application id makes Chrome reuse its TabScreen tab instead of opening a new one every time.
        let reuseTab = ["--es", "com.android.browser.application_id", "tabscreen"]
        let chrome = run(adb, ["-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url] + reuseTab + ["com.android.chrome"])
        if chrome.status != 0 || chrome.output.contains("Error") {
            run(adb, ["-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url] + reuseTab)
        }
    }

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
