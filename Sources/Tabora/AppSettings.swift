import AppKit
import ServiceManagement

struct ShortcutBinding: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    var displayText: String {
        var text = ""
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        text += keyName(for: UInt16(keyCode))
        return text
    }

    private func keyName(for code: UInt16) -> String {
        let names: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        if let name = names[code] { return name }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: code
        ) else { return "Key \(code)" }
        let value = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return value.isEmpty ? "Key \(code)" : value
    }
}

enum ShortcutAction: String, CaseIterable, Codable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, restoreLast

    var title: String {
        if self == .restoreLast { return "直前の配置を戻す" }
        return SnapZone(rawValue: rawValue)?.displayName ?? rawValue
    }

    var zone: SnapZone? { SnapZone(rawValue: rawValue) }
}

enum LinkedResizeDisplayMode: String, CaseIterable, Codable {
    case lightweight
    case mainOnly
    case allWindows

    var resizesMainWindowLive: Bool {
        self != .lightweight
    }

    var resizesLinkedWindowsLive: Bool {
        self == .allWindows
    }
}

enum LinkedResizePresentationStyle: String, CaseIterable, Codable {
    case mac
    case windows
    case combined

    var showsCenterControl: Bool {
        self != .windows
    }

    var showsSharedBoundary: Bool {
        self != .mac
    }
}

final class AppSettings {
    static let shared = AppSettings()
    static let didChangeNotification = Notification.Name("TaboraSettingsDidChange")

    private let defaults = UserDefaults.standard
    private let shortcutsKey = "shortcutBindings"
    private let edgeThresholdKey = "snapEdgeThreshold"
    private let cornerBandKey = "snapCornerBand"
    private let restoreSizeOnMoveKey = "restoreSnappedWindowSizeOnMove"
    private let linkedResizeEnabledKey = "linkedResizeEnabled"
    private let linkedResizeDisplayModeKey = "linkedResizeDisplayMode"
    // Keep the established setting key so the interaction style remains stable within this product domain.
    private let linkedResizePresentationStyleKey = "linkedResizeInteractionStyle"
    private let raiseConnectedWindowsOnClickKey = "raiseConnectedWindowsOnClick"
    // Preserve the established experimental cursor key within the Tabora settings domain.
    private let resizeCursorAdornmentEnabledKey = "experimentalResizeCursorEnabled"
    private let resizeCursorAdornmentDistanceKey = "resizeCursorAdornmentDistance"
    private let sideDwellExpansionEnabledKey = "sideDwellExpansionEnabled"
    private let sideDwellDurationKey = "sideDwellDuration"
    private let windowPreviewsEnabledKey = "windowPreviewsEnabled"
    private let missionControlPreviewMemoryLimitKey =
        "missionControlPreviewMemoryLimitMiB"
    private let constraintRecordingPromptsEnabledKey =
        "constraintRecordingPromptsEnabled"
    private let assistLayoutSwitchingEnabledKey =
        "experimentalAssistLayoutSwitchingEnabled"

    static let defaultEdgeThreshold: Double = 26
    static let defaultCornerBand: Double = 120
    static let defaultSideDwellDuration: Double = 2
    static let defaultLinkedResizeDisplayMode: LinkedResizeDisplayMode = .lightweight
    static let defaultLinkedResizePresentationStyle: LinkedResizePresentationStyle = .combined
    static let defaultRaiseConnectedWindowsOnClick = false
    static let defaultResizeCursorAdornmentEnabled = true
    // Keep 8 pt as both the visual default and the slider midpoint. This gives
    // equal room to tighten or loosen the cursor clearance without silently
    // changing the glyph size.
    static let defaultResizeCursorAdornmentDistance: Double = 8
    static let resizeCursorAdornmentDistanceRange = 4.0...12.0
    static let defaultMissionControlPreviewMemoryLimitMiB = 32
    static let missionControlPreviewMemoryLimitRange = 16...128
    static let missionControlPreviewMemoryLimitStep = 16
    static let defaultAssistLayoutSwitchingEnabled = false

    static func normalizedResizeCursorAdornmentDistance(_ value: Double) -> Double {
        normalizedFiniteValue(
            value,
            range: resizeCursorAdornmentDistanceRange,
            fallback: defaultResizeCursorAdornmentDistance
        )
    }

    static func normalizedEdgeThreshold(_ value: Double) -> Double {
        normalizedFiniteValue(
            value,
            range: edgeThresholdRange,
            fallback: defaultEdgeThreshold
        )
    }

    static func normalizedCornerBand(_ value: Double) -> Double {
        normalizedFiniteValue(
            value,
            range: cornerBandRange,
            fallback: defaultCornerBand
        )
    }

    static func normalizedSideDwellDuration(_ value: Double) -> Double {
        normalizedFiniteValue(
            value,
            range: sideDwellDurationRange,
            fallback: defaultSideDwellDuration
        )
    }

    static func normalizedMissionControlPreviewMemoryLimitMiB(
        _ value: Int
    ) -> Int {
        let clamped = min(
            max(value, missionControlPreviewMemoryLimitRange.lowerBound),
            missionControlPreviewMemoryLimitRange.upperBound
        )
        let step = missionControlPreviewMemoryLimitStep
        return Int((Double(clamped) / Double(step)).rounded()) * step
    }

    static func missionControlPreviewMemoryByteLimit(_ value: Int) -> Int {
        normalizedMissionControlPreviewMemoryLimitMiB(value) * 1024 * 1024
    }
    static let edgeThresholdRange: ClosedRange<Double> = 8...80
    static let cornerBandRange: ClosedRange<Double> = 60...300
    static let sideDwellDurationRange: ClosedRange<Double> = 0.5...5

    private static func normalizedFiniteValue(
        _ value: Double,
        range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    var constraintRecordingPromptsEnabled: Bool {
        get {
            guard defaults.object(
                forKey: constraintRecordingPromptsEnabledKey
            ) != nil else { return true }
            return defaults.bool(forKey: constraintRecordingPromptsEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: constraintRecordingPromptsEnabledKey)
            notify()
        }
    }

    var windowPreviewsEnabled: Bool {
        get {
            guard defaults.object(forKey: windowPreviewsEnabledKey) != nil else {
                return false
            }
            return defaults.bool(forKey: windowPreviewsEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: windowPreviewsEnabledKey)
            notify()
        }
    }

    var assistLayoutSwitchingEnabled: Bool {
        get {
            guard defaults.object(
                forKey: assistLayoutSwitchingEnabledKey
            ) != nil else {
                return Self.defaultAssistLayoutSwitchingEnabled
            }
            return defaults.bool(forKey: assistLayoutSwitchingEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: assistLayoutSwitchingEnabledKey)
            notify()
        }
    }

    var missionControlPreviewMemoryLimitMiB: Int {
        get {
            guard defaults.object(
                forKey: missionControlPreviewMemoryLimitKey
            ) != nil else {
                return Self.defaultMissionControlPreviewMemoryLimitMiB
            }
            return Self.normalizedMissionControlPreviewMemoryLimitMiB(
                defaults.integer(forKey: missionControlPreviewMemoryLimitKey)
            )
        }
        set {
            defaults.set(
                Self.normalizedMissionControlPreviewMemoryLimitMiB(newValue),
                forKey: missionControlPreviewMemoryLimitKey
            )
            notify()
        }
    }

    var restoreSnappedWindowSizeOnMove: Bool {
        get {
            guard defaults.object(forKey: restoreSizeOnMoveKey) != nil else {
                return true
            }
            return defaults.bool(forKey: restoreSizeOnMoveKey)
        }
        set {
            defaults.set(newValue, forKey: restoreSizeOnMoveKey)
            notify()
        }
    }

    var linkedResizeEnabled: Bool {
        get {
            guard defaults.object(forKey: linkedResizeEnabledKey) != nil else {
                return true
            }
            return defaults.bool(forKey: linkedResizeEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: linkedResizeEnabledKey)
            notify()
        }
    }

    var linkedResizeDisplayMode: LinkedResizeDisplayMode {
        get {
            guard let rawValue = defaults.string(forKey: linkedResizeDisplayModeKey),
                  let mode = LinkedResizeDisplayMode(rawValue: rawValue) else {
                return Self.defaultLinkedResizeDisplayMode
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: linkedResizeDisplayModeKey)
            notify()
        }
    }

    var linkedResizePresentationStyle: LinkedResizePresentationStyle {
        get {
            guard let rawValue = defaults.string(
                forKey: linkedResizePresentationStyleKey
            ), let style = LinkedResizePresentationStyle(rawValue: rawValue) else {
                return Self.defaultLinkedResizePresentationStyle
            }
            return style
        }
        set {
            defaults.set(
                newValue.rawValue,
                forKey: linkedResizePresentationStyleKey
            )
            notify()
        }
    }

    var raiseConnectedWindowsOnClick: Bool {
        get {
            guard defaults.object(forKey: raiseConnectedWindowsOnClickKey) != nil else {
                return Self.defaultRaiseConnectedWindowsOnClick
            }
            return defaults.bool(forKey: raiseConnectedWindowsOnClickKey)
        }
        set {
            defaults.set(newValue, forKey: raiseConnectedWindowsOnClickKey)
            notify()
        }
    }

    var resizeCursorAdornmentEnabled: Bool {
        get {
            guard defaults.object(
                forKey: resizeCursorAdornmentEnabledKey
            ) != nil else {
                return Self.defaultResizeCursorAdornmentEnabled
            }
            return defaults.bool(forKey: resizeCursorAdornmentEnabledKey)
        }
        set {
            defaults.set(
                newValue,
                forKey: resizeCursorAdornmentEnabledKey
            )
            notify()
        }
    }

    var resizeCursorAdornmentDistance: Double {
        get {
            guard defaults.object(forKey: resizeCursorAdornmentDistanceKey) != nil else {
                // The retired scale preference controlled glyph size, not spacing.
                // Do not reinterpret it as points and unexpectedly move the marks.
                return Self.defaultResizeCursorAdornmentDistance
            }
            return Self.normalizedResizeCursorAdornmentDistance(
                defaults.double(forKey: resizeCursorAdornmentDistanceKey)
            )
        }
        set {
            defaults.set(
                Self.normalizedResizeCursorAdornmentDistance(newValue),
                forKey: resizeCursorAdornmentDistanceKey
            )
            notify()
        }
    }

    var sideDwellExpansionEnabled: Bool {
        get {
            guard defaults.object(forKey: sideDwellExpansionEnabledKey) != nil else {
                return true
            }
            return defaults.bool(forKey: sideDwellExpansionEnabledKey)
        }
        set {
            defaults.set(newValue, forKey: sideDwellExpansionEnabledKey)
            notify()
        }
    }

    var sideDwellDuration: Double {
        get {
            guard defaults.object(forKey: sideDwellDurationKey) != nil else {
                return Self.defaultSideDwellDuration
            }
            return Self.normalizedSideDwellDuration(
                defaults.double(forKey: sideDwellDurationKey)
            )
        }
        set {
            defaults.set(
                Self.normalizedSideDwellDuration(newValue),
                forKey: sideDwellDurationKey
            )
            notify()
        }
    }

    var shortcuts: [ShortcutAction: ShortcutBinding] {
        get {
            guard let data = defaults.data(forKey: shortcutsKey),
                  let decoded = try? JSONDecoder().decode([ShortcutAction: ShortcutBinding].self, from: data) else { return [:] }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: shortcutsKey) }
            notify()
        }
    }


    var edgeThreshold: Double {
        get {
            guard defaults.object(forKey: edgeThresholdKey) != nil else {
                return Self.defaultEdgeThreshold
            }
            return Self.normalizedEdgeThreshold(
                defaults.double(forKey: edgeThresholdKey)
            )
        }
        set {
            defaults.set(
                Self.normalizedEdgeThreshold(newValue),
                forKey: edgeThresholdKey
            )
            notify()
        }
    }

    var cornerBand: Double {
        get {
            guard defaults.object(forKey: cornerBandKey) != nil else {
                return Self.defaultCornerBand
            }
            return Self.normalizedCornerBand(
                defaults.double(forKey: cornerBandKey)
            )
        }
        set {
            defaults.set(
                Self.normalizedCornerBand(newValue),
                forKey: cornerBandKey
            )
            notify()
        }
    }

    func resetDragDetectionSettings() {
        defaults.removeObject(forKey: edgeThresholdKey)
        defaults.removeObject(forKey: cornerBandKey)
        defaults.removeObject(forKey: sideDwellExpansionEnabledKey)
        defaults.removeObject(forKey: sideDwellDurationKey)
        notify()
    }

    var launchAtLogin: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { return }
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
        notify()
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
