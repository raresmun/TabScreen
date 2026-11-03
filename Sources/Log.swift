import Foundation

/// Writes TabScreen.log next to TabScreen.app (handy when something goes wrong).
enum Log {
    private static let queue = DispatchQueue(label: "tabscreen.log")
    private static let fileURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("TabScreen.log")
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
