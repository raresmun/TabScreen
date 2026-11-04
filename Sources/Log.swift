import Foundation

/// Writes TabScreen.log (handy when something goes wrong): next to TabScreen.app when it was built in the project
/// folder, otherwise in ~/Library/Logs/TabScreen.
enum Log {
    private static let queue = DispatchQueue(label: "tabscreen.log")
    static let fileURL: URL = {
        let appFolder = Bundle.main.bundleURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: appFolder.appendingPathComponent("build.sh").path) {
            return appFolder.appendingPathComponent("TabScreen.log")
        }
        let logFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TabScreen", isDirectory: true)
        try? FileManager.default.createDirectory(at: logFolder, withIntermediateDirectories: true)
        return logFolder.appendingPathComponent("TabScreen.log")
    }()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func reset() {
        queue.async { try? Data().write(to: fileURL) }
    }

    static func write(_ message: String) {
        NSLog("TabScreen: %@", message)
        queue.async {
            let line = "\(formatter.string(from: Date()))  \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
