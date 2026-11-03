// BatteryAlertBar: screen overlay for battery-alert.
// Reads the status that battery_check.sh writes at every check and draws on
// every screen a border, a red tint that grows as the shutdown approaches,
// and in the last minutes a full-screen banner on the main screen.
//
// Usage:
//   BatteryAlertBar                                 run as login agent
//   BatteryAlertBar --demo LEVEL MINUTES PERCENT    show the overlay for 20 s
//                                                   (MINUTES -1 = no forecast)

import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
let configPath = home + "/.config/battery-alert/config"
let statusPath = home + "/.local/share/battery-alert/status"
let staleSeconds = 300

struct Config {
    var screenBorder = true
    var screenTint = true
    var finalBanner = true
    var borderWidth: CGFloat = 12
    var tintMin = 4
    var tintMax = 12
    var criticalMinutes = 8
    var criticalPercent = 7
    var finalMinutes = 3
    var finalPercent = 3
    var language = "it"

    static func load(_ path: String) -> Config {
        var config = Config()
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return config }
        for line in text.split(separator: "\n") {
            let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = body.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let value = parts[1]
            switch parts[0] {
            case "SCREEN_BORDER": config.screenBorder = value == "1"
            case "SCREEN_TINT": config.screenTint = value == "1"
            case "FINAL_BANNER": config.finalBanner = value == "1"
            case "BORDER_WIDTH": config.borderWidth = CGFloat(Double(value) ?? 12)
            case "TINT_MIN": config.tintMin = Int(value) ?? 4
            case "TINT_MAX": config.tintMax = Int(value) ?? 12
            case "CRITICAL_MINUTES": config.criticalMinutes = Int(value) ?? 8
            case "CRITICAL_PERCENT": config.criticalPercent = Int(value) ?? 7
            case "FINAL_MINUTES": config.finalMinutes = Int(value) ?? 3
            case "FINAL_PERCENT": config.finalPercent = Int(value) ?? 3
            case "LANGUAGE": config.language = value
            default: break
            }
        }
        return config
    }
}

// One line written by battery_check.sh: "epoch level minutes percent charger".
struct Status {
    var timestamp: Int
    var level: String
    var minutes: Int?
    var percent: Int
    var charger: Bool

    static func read(_ path: String) -> Status? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard fields.count == 5, let timestamp = Int(fields[0]),
              let minutes = Int(fields[2]), let percent = Int(fields[3]) else { return nil }
        return Status(timestamp: timestamp, level: String(fields[1]),
                      minutes: minutes < 0 ? nil : minutes, percent: percent, charger: fields[4] == "1")
    }
}

struct Look: Equatable {
    var border: NSColor? = nil
    var borderWidth: CGFloat = 0
    var pulse = false
    var tint: CGFloat = 0
    var banner = false

    var visible: Bool { border != nil || tint > 0 }

    static func of(_ status: Status?, _ config: Config) -> Look {
        guard let status, !status.charger else { return Look() }
        switch status.level {
        case "warn":
            guard config.screenBorder else { return Look() }
            return Look(border: .systemOrange, borderWidth: max(config.borderWidth / 3, 4))
        case "critical":
            // 1 at the critical threshold, 0 at shutdown.
            let ratio: Double
            if let minutes = status.minutes {
                ratio = Double(minutes) / Double(max(config.criticalMinutes, 1))
            } else {
                ratio = Double(status.percent) / Double(max(config.criticalPercent, 1))
            }
            let closeness = 1 - min(max(ratio, 0), 1)
            let final = (status.minutes.map { $0 <= config.finalMinutes } ?? false)
                || status.percent <= config.finalPercent
            return Look(border: config.screenBorder ? .systemRed : nil,
                        borderWidth: config.borderWidth,
                        pulse: config.screenBorder,
                        tint: config.screenTint
                            ? CGFloat(Double(config.tintMin) + Double(config.tintMax - config.tintMin) * closeness) / 100
                            : 0,
                        banner: config.finalBanner && final)
        default:
            return Look()
        }
    }
}

func overlayWindow(_ screen: NSScreen, _ window: NSWindow) {
    window.isOpaque = false
    window.hasShadow = false
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    window.setFrame(screen.frame, display: false)
}

// Border and tint on one screen. Ignores the mouse: work goes on under it.
final class ScreenOverlay {
    let window: NSWindow
    let tint = CALayer()
    let border = CAShapeLayer()

    init(screen: NSScreen) {
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        overlayWindow(screen, window)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        tint.frame = view.bounds
        border.frame = view.bounds
        border.fillColor = nil
        view.layer!.addSublayer(tint)
        view.layer!.addSublayer(border)
        window.contentView = view
    }

    func apply(_ look: Look) {
        tint.backgroundColor = NSColor.systemRed.withAlphaComponent(look.tint).cgColor
        border.removeAnimation(forKey: "pulse")
        if let color = look.border {
            let inset = look.borderWidth / 2
            border.lineWidth = look.borderWidth
            border.strokeColor = color.cgColor
            border.path = CGPath(rect: border.bounds.insetBy(dx: inset, dy: inset), transform: nil)
            border.isHidden = false
        } else {
            border.isHidden = true
        }
        if look.pulse {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.2
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            border.add(pulse, forKey: "pulse")
        }
        if look.visible { window.orderFrontRegardless() } else { window.orderOut(nil) }
    }

    func close() { window.orderOut(nil) }
}

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// Full-screen banner on the main screen; OK hides it until the next check.
final class Banner: NSObject {
    let window: KeyWindow
    let label = NSTextField(labelWithString: "")
    let onDismiss: () -> Void

    init(screen: NSScreen, language: String, onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        window = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        overlayWindow(screen, window)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.backgroundColor = NSColor(calibratedRed: 0.45, green: 0, blue: 0, alpha: 0.88)
        label.font = .systemFont(ofSize: 56, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 0
        let button = NSButton(title: "OK", target: self, action: #selector(dismiss))
        button.keyEquivalent = "\r"
        button.controlSize = .large
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.spacing = 40
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
        ])
        window.contentView = view
    }

    func show(_ text: String) {
        label.stringValue = text
        if !window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func hide() { window.orderOut(nil) }

    @objc func dismiss() {
        hide()
        onDismiss()
    }
}

func bannerText(_ status: Status, _ language: String) -> String {
    let italian = language == "it"
    let first = italian ? "Collega l'alimentatore" : "Plug in the charger"
    if let minutes = status.minutes {
        return first + "\n" + (italian ? "Spegnimento tra \(minutes) minuti" : "Shutdown in \(minutes) minutes")
    }
    return first + "\n" + (italian ? "Batteria: \(status.percent) per cento" : "Battery: \(status.percent) percent")
}

final class Controller: NSObject {
    let demo: Status?
    var overlays: [ScreenOverlay] = []
    var banner: Banner?
    var lastLook = Look()
    var dismissedTimestamp: Int?
    var shownTimestamp: Int?

    init(demo: Status?) {
        self.demo = demo
    }

    func start() {
        buildOverlays()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func buildOverlays() {
        overlays.forEach { $0.close() }
        overlays = NSScreen.screens.map { ScreenOverlay(screen: $0) }
        banner?.hide()
        banner = nil
    }

    @objc func screensChanged() {
        buildOverlays()
        overlays.forEach { $0.apply(lastLook) }
    }

    func currentStatus() -> Status? {
        if let demo { return demo }
        guard let status = Status.read(statusPath) else { return nil }
        if Int(Date().timeIntervalSince1970) - status.timestamp > staleSeconds { return nil }
        return status
    }

    func refresh() {
        let config = Config.load(configPath)
        let status = currentStatus()
        let look = Look.of(status, config)
        if look != lastLook {
            overlays.forEach { $0.apply(look) }
            lastLook = look
        }
        guard let status, look.banner, status.timestamp != dismissedTimestamp,
              let screen = NSScreen.main ?? NSScreen.screens.first else {
            banner?.hide()
            return
        }
        if banner == nil {
            banner = Banner(screen: screen, language: config.language) { [weak self] in
                self?.dismissedTimestamp = self?.shownTimestamp
            }
        }
        shownTimestamp = status.timestamp
        banner?.show(bannerText(status, config.language))
    }
}

var demo: Status?
let arguments = CommandLine.arguments
if arguments.count == 5, arguments[1] == "--demo", let minutes = Int(arguments[3]), let percent = Int(arguments[4]) {
    demo = Status(timestamp: Int(Date().timeIntervalSince1970), level: arguments[2],
                  minutes: minutes < 0 ? nil : minutes, percent: percent, charger: false)
} else if arguments.count != 1 {
    FileHandle.standardError.write("usage: BatteryAlertBar [--demo LEVEL MINUTES PERCENT]\n".data(using: .utf8)!)
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller(demo: demo)
controller.start()
if demo != nil {
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { app.terminate(nil) }
}
app.run()
