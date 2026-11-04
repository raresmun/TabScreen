import AppKit

/// Follows the mouse while it is on the extra display and tells the tablet where to draw the pointer.
/// The tablet draws the pointer itself, so it moves right away instead of waiting for new screen pictures.
final class CursorTracker: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let server: StreamServer
    private var timer: DispatchSourceTimer?
    private var lastPosition: String?
    private var lastImage: Data?
    private var ticks = 0

    init(displayID: CGDirectDisplayID, server: StreamServer) {
        self.displayID = displayID
        self.server = server
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: 1.0 / 120)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        ticks += 1
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0, let location = CGEvent(source: nil)?.location else { return }
        let x = (location.x - bounds.minX) / bounds.width
        let y = (location.y - bounds.minY) / bounds.height
        let visible = x >= 0 && x < 1 && y >= 0 && y < 1
        let position = visible
            ? String(format: "{\"type\":\"cursor\",\"x\":%.5f,\"y\":%.5f,\"v\":1,\"dw\":%.1f}", Double(x), Double(y), Double(bounds.width))
            : "{\"type\":\"cursor\",\"v\":0}"
        if position != lastPosition {
            lastPosition = position
            server.broadcastCursor(Data(position.utf8), isImage: false)
        }
        if visible && ticks % 12 == 0 { sendImageIfChanged() }
    }

    /// Sends the pointer's look (arrow, text cursor, resize arrows …) when it changes.
    private func sendImageIfChanged() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let png = rep.representation(using: .png, properties: [:]), png != lastImage else { return }
        lastImage = png
        let message: [String: Any] = [
            "type": "cursorImage",
            "png": png.base64EncodedString(),
            "hx": Double(cursor.hotSpot.x), "hy": Double(cursor.hotSpot.y),
            "w": Double(image.size.width), "h": Double(image.size.height),
        ]
        if let json = try? JSONSerialization.data(withJSONObject: message) {
            server.broadcastCursor(json, isImage: true)
        }
    }
}
