import AppKit
import ApplicationServices

/// Turns touches on the tablet into clicks, drags and scrolling on the extra display. The tablet app works out the
/// gestures (tap, drag, long press, two-finger scroll) and sends plain mouse actions, with positions from 0 to 1 across
/// the display. macOS only accepts them from apps allowed under Privacy & Security → Accessibility.
final class TouchInput: @unchecked Sendable {
    private let lock = NSLock()
    private var currentDisplayID: CGDirectDisplayID = 0
    private var enabled = false
    private var clickInterval: TimeInterval = 0.5

    // Only used on the server's queue, one message at a time.
    private var pressed: CGMouseButton?
    private var dragged = false
    private var lastPoint = CGPoint.zero
    private var clickCount: Int64 = 1
    private var lastDownTime: TimeInterval = 0
    private var lastDownPoint = CGPoint.zero
    private var lastDownButton = CGMouseButton.left
    private var scrollRest = CGPoint.zero

    /// How quickly two taps must follow each other to make a double-click (the Mac's own setting).
    var doubleClickInterval: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return clickInterval }
        set { lock.lock(); clickInterval = min(max(newValue, 0.2), 2); lock.unlock() }
    }

    /// The extra display; 0 while there is none.
    var displayID: CGDirectDisplayID {
        get { lock.lock(); defer { lock.unlock() }; return currentDisplayID }
        set { lock.lock(); currentDisplayID = newValue; lock.unlock() }
    }

    /// Touch control is on in the menu and macOS allows it.
    var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enabled }
        set { lock.lock(); enabled = newValue; lock.unlock() }
    }

    /// Whether macOS lets TabScreen click and scroll (Privacy & Security → Accessibility).
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows macOS's request to allow TabScreen under Accessibility.
    static func askForPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// A "mouse" or "scroll" message from the tablet app. Called on the server's queue.
    func handle(_ message: [String: Any]) {
        let display = displayID
        guard isEnabled, display != 0 else {
            reset()
            return
        }
        let bounds = CGDisplayBounds(display)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = position(in: message, bounds: bounds)
        let type = message["type"] as? String ?? ""
        if type == "scroll" {
            scroll(message, at: point, bounds: bounds)
            return
        }
        guard type == "mouse" else { return }
        switch message["a"] as? String ?? "" {
        case "move":
            guard let point = point else { return }
            lastPoint = point
            if let button = pressed {
                dragged = true
                post(button == .right ? .rightMouseDragged : .leftMouseDragged, at: point, button: button)
            } else {
                post(.mouseMoved, at: point, button: .left)
            }
        case "down":
            guard let point = point else { return }
            if pressed != nil { release(at: lastPoint) }
            let button: CGMouseButton = (message["b"] as? Int) == 1 ? .right : .left
            let now = ProcessInfo.processInfo.systemUptime
            var spot = point
            let dx = point.x - lastDownPoint.x
            let dy = point.y - lastDownPoint.y
            if button == lastDownButton, now - lastDownTime < doubleClickInterval, dx * dx + dy * dy < 144 {
                clickCount = min(clickCount + 1, 3)
                spot = lastDownPoint   // a finger lands a little off: keep a double-click on the same spot
            } else {
                clickCount = 1
            }
            lastDownTime = now
            lastDownPoint = spot
            lastDownButton = button
            lastPoint = spot
            pressed = button
            dragged = false
            post(button == .right ? .rightMouseDown : .leftMouseDown, at: spot, button: button)
        case "up":
            // A tap lets go where it pressed; a drag where the finger is now.
            release(at: dragged ? (point ?? lastPoint) : lastPoint)
        default:
            break
        }
    }

    /// Lets go of a button still held down (the tablet went away in the middle of a drag).
    func reset() {
        if pressed != nil { release(at: lastPoint) }
        scrollRest = .zero
    }

    private func release(at point: CGPoint) {
        guard let button = pressed else { return }
        pressed = nil
        dragged = false
        lastPoint = point
        post(button == .right ? .rightMouseUp : .leftMouseUp, at: point, button: button)
    }

    /// Scrolls by the fingers' movement, as a share of the display's size. Content follows the fingers.
    private func scroll(_ message: [String: Any], at point: CGPoint?, bounds: CGRect) {
        guard let dx = message["dx"] as? Double, let dy = message["dy"] as? Double, dx.isFinite, dy.isFinite else { return }
        if let point = point, pressed == nil {
            // The first scroll of a gesture says where the fingers are: scroll the window under them.
            lastPoint = point
            post(.mouseMoved, at: point, button: .left)
        }
        let x = CGFloat(min(max(dx, -1), 1)) * bounds.width + scrollRest.x
        let y = CGFloat(min(max(dy, -1), 1)) * bounds.height + scrollRest.y
        let wholeX = x.rounded(.towardZero)
        let wholeY = y.rounded(.towardZero)
        scrollRest = CGPoint(x: x - wholeX, y: y - wholeY)
        guard wholeX != 0 || wholeY != 0,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(wholeY), wheel2: Int32(wholeX), wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        else { return }
        if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: clickCount) }
        event.post(tap: .cghidEventTap)
    }

    /// The message's position on the display, kept a hair inside it so the pointer doesn't slip onto the next screen.
    private func position(in message: [String: Any], bounds: CGRect) -> CGPoint? {
        guard let x = message["x"] as? Double, let y = message["y"] as? Double, x.isFinite, y.isFinite else { return nil }
        let across = min(max(x, 0), 0.9995)
        let down = min(max(y, 0), 0.9995)
        return CGPoint(x: bounds.minX + CGFloat(across) * bounds.width, y: bounds.minY + CGFloat(down) * bounds.height)
    }
}
