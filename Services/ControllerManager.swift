import GameController
import Combine
import SwiftUI

/// High-level, layout-independent navigation intents emitted by the controller.
enum NavAction: Hashable {
    case left, right, up, down
    case confirm, cancel
    case menu          // ≡ / + button
    case options       // Y button (top face button)
    case pageLeft, pageRight   // shoulder buttons
}

/// Physical face-button positions. GameController reports buttons by *position*
/// (buttonA = bottom, buttonB = right), so "Nintendo layout" simply swaps which
/// position means Confirm.
enum ButtonPosition { case bottom, right, left, top }

enum ControllerStyle {
    case xbox, playstation, nintendo, generic

    init(_ controller: GCController?) {
        let id = ((controller?.productCategory ?? "") + " " + (controller?.vendorName ?? "")).lowercased()
        if id.contains("nintendo") || id.contains("switch") || id.contains("joy-con") || id.contains("pro controller") {
            self = .nintendo
        } else if id.contains("dualsense") || id.contains("dualshock") || id.contains("playstation") {
            self = .playstation
        } else if id.contains("xbox") {
            self = .xbox
        } else {
            self = .generic
        }
    }

    /// Label + colour printed on the physical button at `position`.
    func glyph(at position: ButtonPosition) -> (text: String, color: Color) {
        switch self {
        case .playstation:
            switch position {
            case .bottom: return ("✕", Color(red: 0.35, green: 0.55, blue: 1.0))
            case .right:  return ("○", Color(red: 1.0, green: 0.35, blue: 0.40))
            case .left:   return ("□", Color(red: 0.95, green: 0.50, blue: 0.80))
            case .top:    return ("△", Color(red: 0.30, green: 0.80, blue: 0.60))
            }
        case .nintendo:
            let c = Color(white: 0.42)
            switch position {
            case .bottom: return ("B", c)
            case .right:  return ("A", c)
            case .left:   return ("Y", c)
            case .top:    return ("X", c)
            }
        case .xbox, .generic:
            switch position {
            case .bottom: return ("A", Color(red: 0.25, green: 0.70, blue: 0.35))
            case .right:  return ("B", Color(red: 0.90, green: 0.25, blue: 0.25))
            case .left:   return ("X", Color(red: 0.25, green: 0.50, blue: 0.95))
            case .top:    return ("Y", Color(red: 0.95, green: 0.75, blue: 0.20))
            }
        }
    }
}

@MainActor
final class ControllerManager: ObservableObject {
    @Published private(set) var controller: GCController?
    @Published private(set) var style: ControllerStyle = .generic

    /// Stream of navigation intents. ContentView subscribes to this.
    let actions = PassthroughSubject<NavAction, Never>()

    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()

    private var dpad = CGPoint.zero
    private var stick = CGPoint.zero
    private var heldDirection: NavAction?
    private var repeatTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings

        NotificationCenter.default.publisher(for: .GCControllerDidConnect)
            .compactMap { $0.object as? GCController }
            .sink { [weak self] in self?.attach($0) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)
            .compactMap { $0.object as? GCController }
            .sink { [weak self] in self?.detach($0) }
            .store(in: &cancellables)

        // Button-release events are not delivered in the background, so drop any held direction when we
        // lose focus; otherwise the auto-repeat keeps firing and the carousel runs away when we come back.
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.releaseAll() }
            .store(in: &cancellables)

        // Only listen while the launcher is frontmost, so a running game keeps exclusive input.
        GCController.shouldMonitorBackgroundEvents = false
        GCController.controllers().forEach(attach)
    }

    var isConnected: Bool { controller != nil }
    var displayName: String { controller?.vendorName ?? controller?.productCategory ?? "Controller" }
    var confirmPosition: ButtonPosition { settings.swapConfirmCancel ? .right : .bottom }
    var cancelPosition: ButtonPosition { settings.swapConfirmCancel ? .bottom : .right }

    // MARK: - Wiring

    private func attach(_ c: GCController) {
        controller = c
        style = ControllerStyle(c)
        guard let pad = c.extendedGamepad else { return }

        pad.dpad.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated {
                self?.dpad = CGPoint(x: CGFloat(x), y: CGFloat(y))
                self?.updateDirection()
            }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated {
                self?.stick = CGPoint(x: CGFloat(x), y: CGFloat(y))
                self?.updateDirection()
            }
        }

        onPress(pad.buttonA) { $0.facePressed(.bottom) }
        onPress(pad.buttonB) { $0.facePressed(.right) }
        onPress(pad.buttonY) { $0.actions.send(.options) }
        onPress(pad.leftShoulder) { $0.actions.send(.pageLeft) }
        onPress(pad.rightShoulder) { $0.actions.send(.pageRight) }
        onPress(pad.buttonMenu) { $0.actions.send(.menu) }
        if let options = pad.buttonOptions { onPress(options) { $0.actions.send(.menu) } }
    }

    private func releaseAll() {
        dpad = .zero
        stick = .zero
        updateDirection()
    }

    private func detach(_ c: GCController) {
        if controller === c { controller = GCController.controllers().first { $0 !== c } }
        style = ControllerStyle(controller)
        dpad = .zero
        stick = .zero
        updateDirection()
    }

    private func onPress(_ button: GCControllerButtonInput, _ handler: @escaping (ControllerManager) -> Void) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated { if let self { handler(self) } }
        }
    }

    private func facePressed(_ position: ButtonPosition) {
        if position == confirmPosition { actions.send(.confirm) }
        else if position == cancelPosition { actions.send(.cancel) }
    }

    // MARK: - D-pad / stick with auto-repeat

    private func updateDirection() {
        let v = (abs(dpad.x) + abs(dpad.y)) > 0.01 ? dpad : stick   // D-pad wins over stick
        let threshold: CGFloat = 0.55
        var next: NavAction?
        if abs(v.x) >= abs(v.y), abs(v.x) > threshold {
            next = v.x > 0 ? .right : .left
        } else if abs(v.y) > threshold {
            next = v.y > 0 ? .up : .down
        }

        guard next != heldDirection else { return }
        heldDirection = next
        repeatTask?.cancel()
        guard let direction = next else { return }

        actions.send(direction)
        repeatTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))      // initial delay
            while !Task.isCancelled {
                guard let self else { return }
                self.actions.send(direction)
                try? await Task.sleep(for: .milliseconds(120))  // repeat rate
            }
        }
    }
}
