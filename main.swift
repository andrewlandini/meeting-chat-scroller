import Cocoa
import ApplicationServices
import CoreText

// MARK: - Config

let loopInterval: TimeInterval = 3.0   // wait between sequences
let activityPause: TimeInterval = 3.0  // pause after any mouse or keyboard use (restarts on each use)

let keyPageDown: CGKeyCode = 121       // Page Down (fn + ↓ on Mac keyboards)

// MARK: - Helpers

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ v: Bool) { value = v }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

/// Seconds since the user last touched the mouse/trackpad (move, click, drag, scroll).
func secondsSinceMouseActivity() -> TimeInterval {
    let types: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
        .otherMouseDragged, .scrollWheel,
    ]
    return types
        .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        .min() ?? .infinity
}

/// Marks our own key presses so the typing detector can ignore them.
let syntheticTag: Int64 = 0x4D43_5343   // "MCSC"

/// Last time the user typed (real key presses only; our own are filtered out by `syntheticTag`).
final class KeyActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval = -.infinity
    private var lastSynthetic: TimeInterval = -.infinity
    func sentSynthetic() { lock.lock(); lastSynthetic = ProcessInfo.processInfo.systemUptime; lock.unlock() }
    func isLikelyOurs(_ keyCode: UInt16) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keyCode == UInt16(keyPageDown) && ProcessInfo.processInfo.systemUptime - lastSynthetic < 0.1
    }
    func touch() { lock.lock(); last = ProcessInfo.processInfo.systemUptime; lock.unlock() }
    func secondsSince() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - last
    }
}
let keyActivity = KeyActivity()

/// Seconds since the user last used the mouse or keyboard.
func secondsSinceUserActivity() -> TimeInterval {
    min(secondsSinceMouseActivity(), keyActivity.secondsSince())
}

func press(_ key: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
        e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        keyActivity.sentSynthetic()
        e.post(tap: .cghidEventTap)
    }
}

// MARK: - Worker

enum State { case disabled, noPermission, pausedForActivity, running }

final class Worker: @unchecked Sendable {
    let enabled = Flag(true)
    var onState: ((State) -> Void)?
    private var lastState: State?

    private func report(_ s: State) {
        guard s != lastState else { return }
        lastState = s
        DispatchQueue.main.async { self.onState?(s) }
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                if !enabled.get() { report(.disabled) }
                else if !AXIsProcessTrusted() { report(.noPermission) }
                else if secondsSinceUserActivity() < activityPause { report(.pausedForActivity) }
                else {
                    report(.running)
                    press(keyPageDown)
                    Thread.sleep(forTimeInterval: loopInterval)
                    continue
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }
}

// MARK: - Vibe
//
// Monochrome, Geist, flat. Color is only a status cue, always paired with a word.
// Not a Vercel product mark — no triangle, no wordmark.

struct Vibe {
    let dark: Bool
    init(_ appearance: NSAppearance) {
        dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    var bg: NSColor { dark ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) }
    var fg: NSColor { dark ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1) }
    var secondary: NSColor {
        dark ? NSColor(srgbRed: 0.631, green: 0.631, blue: 0.631, alpha: 1) : NSColor(srgbRed: 0.302, green: 0.302, blue: 0.302, alpha: 1)
    }
    var tertiary: NSColor {
        dark ? NSColor(srgbRed: 0.561, green: 0.561, blue: 0.561, alpha: 1) : NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)
    }
    var line: NSColor {
        dark ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14) : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08)
    }
    var hover: NSColor {
        dark ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06) : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.04)
    }
    var fill: NSColor { fg }
    var fillFg: NSColor { bg }
    var trackOff: NSColor {
        dark ? NSColor(srgbRed: 0.227, green: 0.227, blue: 0.227, alpha: 1) : NSColor(srgbRed: 0.816, green: 0.816, blue: 0.816, alpha: 1)
    }
    var running: NSColor {
        dark ? NSColor(srgbRed: 0.45, green: 0.82, blue: 0.58, alpha: 1) : NSColor(srgbRed: 0.0, green: 0.48, blue: 0.32, alpha: 1)
    }
    var warning: NSColor {
        dark ? NSColor(srgbRed: 0.96, green: 0.65, blue: 0.14, alpha: 1) : NSColor(srgbRed: 0.71, green: 0.28, blue: 0.03, alpha: 1)
    }

    func dotColor(_ state: State) -> NSColor {
        switch state {
        case .running: return running
        case .noPermission: return warning
        case .pausedForActivity: return secondary
        case .disabled: return tertiary
        }
    }
}

enum GeistWeight { case regular, medium, semibold }

func geist(_ size: CGFloat, _ weight: GeistWeight) -> NSFont {
    let name: String
    let system: NSFont.Weight
    switch weight {
    case .regular: name = "Geist-Regular"; system = .regular
    case .medium: name = "Geist-Medium"; system = .medium
    case .semibold: name = "Geist-SemiBold"; system = .semibold
    }
    return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: system)
}

func mono(_ size: CGFloat, _ weight: GeistWeight = .medium) -> NSFont {
    let name = weight == .regular ? "GeistMono-Regular" : "GeistMono-Medium"
    return NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .medium)
}

func activateBundledFonts() {
    guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts") else { return }
    guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
    for url in files where url.pathExtension.lowercased() == "otf" {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

// MARK: - Mark
//
// Symmetric up/down arrows. The pair's visual center is the gap. Inside a squircle,
// geometric centering reads low, so the glyph is raised. See `iconNudgeFraction`.

struct ArrowMetrics {
    var headW: CGFloat
    var headH: CGFloat
    var shaftW: CGFloat
    var shaftH: CGFloat
    var gap: CGFloat
    var tipToTip: CGFloat { gap + 2 * (headH + shaftH) }
}

func arrowMetrics() -> ArrowMetrics {
    ArrowMetrics(headW: 268, headH: 146, shaftW: 86, shaftH: 102, gap: 58)
}

func arrowPath(_ metrics: ArrowMetrics, up: Bool) -> NSBezierPath {
    let path = NSBezierPath()
    let halfShaft = metrics.shaftW / 2
    let halfHead = metrics.headW / 2
    let dir: CGFloat = up ? 1 : -1
    let base = dir * metrics.gap / 2
    let neck = base + dir * metrics.shaftH
    let tip = neck + dir * metrics.headH
    path.move(to: NSPoint(x: -halfShaft, y: base))
    path.line(to: NSPoint(x: halfShaft, y: base))
    path.line(to: NSPoint(x: halfShaft, y: neck))
    path.line(to: NSPoint(x: halfHead, y: neck))
    path.line(to: NSPoint(x: 0, y: tip))
    path.line(to: NSPoint(x: -halfHead, y: neck))
    path.line(to: NSPoint(x: -halfShaft, y: neck))
    path.close()
    return path
}

func drawArrowPair(center: CGPoint, scale: CGFloat, color: NSColor) {
    let metrics = arrowMetrics()
    color.setFill()
    for up in [true, false] {
        let src = arrowPath(metrics, up: up)
        let placed = NSBezierPath()
        for i in 0..<src.elementCount {
            var pts = [NSPoint](repeating: .zero, count: 3)
            let el = src.element(at: i, associatedPoints: &pts)
            let map: (NSPoint) -> NSPoint = { NSPoint(x: center.x + $0.x * scale, y: center.y + $0.y * scale) }
            switch el {
            case .moveTo: placed.move(to: map(pts[0]))
            case .lineTo: placed.line(to: map(pts[0]))
            case .closePath: placed.close()
            default: break
            }
        }
        placed.fill()
    }
}

/// optical: +1.8% of the tile. Content centered on the geometric middle of a squircle reads low.
let iconNudgeFraction: CGFloat = 0.018

func squirclePath(in rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    let n: CGFloat = 5
    let a = rect.width / 2
    let b = rect.height / 2
    let cx = rect.midX
    let cy = rect.midY
    let steps = 256
    func sign(_ v: CGFloat) -> CGFloat { v < 0 ? -1 : 1 }
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t)
        let st = sin(t)
        let x = cx + a * sign(ct) * pow(abs(ct), 2 / n)
        let y = cy + b * sign(st) * pow(abs(st), 2 / n)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) }
        else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func drawAppIcon(in rect: NSRect, nudgeFraction: CGFloat) {
    let tile = squirclePath(in: rect.insetBy(dx: rect.width * 0.004, dy: rect.height * 0.004))
    NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1).setFill()
    tile.fill()
    let metrics = arrowMetrics()
    let glyphH = rect.height * (rect.height < 48 ? 0.52 : 0.44)
    let scale = glyphH / metrics.tipToTip
    let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * nudgeFraction)
    drawArrowPair(center: center, scale: scale, color: .white)
}

func makeAppIcon() -> NSImage {
    let size = NSSize(width: 1024, height: 1024)
    return NSImage(size: size, flipped: false) { rect in
        drawAppIcon(in: rect, nudgeFraction: iconNudgeFraction)
        return true
    }
}

enum MenuMark { case arrows, pause, warning }

func menuMark(for state: State) -> MenuMark {
    switch state {
    case .running, .disabled: return .arrows
    case .pausedForActivity: return .pause
    case .noPermission: return .warning
    }
}

func menuBarImage(for state: State) -> NSImage {
    // Menu-bar size is too small for the dock mark. SF Symbols are already optically tuned here.
    let name: String
    switch menuMark(for: state) {
    case .arrows: name = "arrow.up.arrow.down"
    case .pause: name = "pause"
    case .warning: name = "exclamationmark.triangle"
    }
    let base = NSImage(systemSymbolName: name, accessibilityDescription: statusTitle(state)) ?? NSImage()
    let image = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)) ?? base
    image.isTemplate = true
    return image
}

// MARK: - Controls

final class ClickRow: NSView {
    var onClick: () -> Void = {}
    private var hovered = false
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        onClick()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        Vibe(effectiveAppearance).hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 2), xRadius: 6, yRadius: 6).fill()
    }

    override func accessibilityLabel() -> String? {
        subviews.compactMap { ($0 as? NSTextField)?.stringValue }.first { !$0.isEmpty }
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }
}

final class ToggleView: NSView {
    var on = true { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let vibe = Vibe(effectiveAppearance)
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (on ? vibe.fill : vibe.trackOff).setFill()
        track.fill()
        let d = bounds.height - 4
        let x = on ? bounds.width - d - 2 : 2
        let knob = NSBezierPath(ovalIn: NSRect(x: x, y: 2, width: d, height: d))
        (on ? vibe.fillFg : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)).setFill()
        knob.fill()
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: on && !vibe.dark ? 0 : 0.12).setStroke()
        knob.lineWidth = 1
        knob.stroke()
    }
}

final class FillButton: NSView {
    var title: String
    var onClick: () -> Void = {}
    private var hovered = false

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let vibe = Vibe(effectiveAppearance)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        vibe.fill.setFill()
        path.fill()
        if hovered {
            NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.18).setFill()
            path.fill()
        }
        let font = geist(13, .medium)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: vibe.fillFg])
        let size = text.size()
        // optical: the em box includes descender space, so a cap-height label reads low. Raise 1pt in a 32pt control.
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2 + 1, width: size.width, height: size.height)
        text.draw(in: rect)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
}

func makeField() -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: "")
    field.drawsBackground = false
    field.isBezeled = false
    field.isEditable = false
    field.isSelectable = false
    field.lineBreakMode = .byWordWrapping
    field.maximumNumberOfLines = 0
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}

func fieldHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
    field.preferredMaxLayoutWidth = width
    let size = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 2000)) ?? NSSize(width: width, height: 16)
    return ceil(size.height)
}

// MARK: - Panel

let panelWidth: CGFloat = 300

func statusTitle(_ state: State) -> String {
    switch state {
    case .running: return "Running"
    case .pausedForActivity: return "Paused"
    case .disabled: return "Off"
    case .noPermission: return "Needs permission"
    }
}

func statusDetail(_ state: State) -> String {
    switch state {
    case .running: return "Sending Page Down"
    case .pausedForActivity: return "You're using the computer"
    case .disabled: return "Turned off"
    case .noPermission: return "Allow Accessibility to send keys"
    }
}

final class PanelView: NSView {
    var onToggle: () -> Void = {}
    var onAccessibility: () -> Void = {}
    var onReset: () -> Void = {}
    var onHelp: () -> Void = {}
    var onQuit: () -> Void = {}

    private let titleField = makeField()
    private let statusField = makeField()
    private let detailField = makeField()
    private let eyebrowField = makeField()
    private let bodyField = makeField()
    private let enabledRow = ClickRow()
    private let enabledLabel = makeField()
    private let toggle = ToggleView()
    private var actionRows: [ClickRow] = []
    private var actionLabels: [NSTextField] = []
    private var dividerYs: [CGFloat] = []
    private var dotFrame = NSRect.zero
    private(set) var state: State = .running

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let actions = ["Accessibility settings", "Reset permission & relaunch", "How to use", "Quit"]
        for title in actions {
            let row = ClickRow()
            let label = makeField()
            label.stringValue = title
            label.font = geist(13, .medium)
            row.addSubview(label)
            actionRows.append(row)
            actionLabels.append(label)
            addSubview(row)
        }
        actionRows[0].onClick = { [weak self] in self?.onAccessibility() }
        actionRows[1].onClick = { [weak self] in self?.onReset() }
        actionRows[2].onClick = { [weak self] in self?.onHelp() }
        actionRows[3].onClick = { [weak self] in self?.onQuit() }

        titleField.stringValue = "Meeting Chat Scroller"
        titleField.font = geist(14, .medium)
        eyebrowField.font = mono(11, .medium)
        bodyField.font = geist(13, .regular)
        bodyField.stringValue = "Pauses when you move, click, scroll, or type. Resumes after \(Int(activityPause)) seconds."
        statusField.font = geist(13, .regular)
        detailField.font = geist(12, .regular)
        enabledLabel.stringValue = "Enabled"
        enabledLabel.font = geist(13, .medium)
        enabledRow.addSubview(enabledLabel)
        enabledRow.addSubview(toggle)
        enabledRow.onClick = { [weak self] in self?.onToggle() }
        for v in [titleField, statusField, detailField, eyebrowField, bodyField, enabledRow] {
            addSubview(v)
        }
        apply(.running, enabled: true)
    }
    required init?(coder: NSCoder) { nil }

    func apply(_ state: State, enabled: Bool) {
        self.state = state
        statusField.stringValue = statusTitle(state)
        detailField.stringValue = statusDetail(state)
        toggle.on = enabled
        layoutContents()
        applyColors()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
        needsDisplay = true
    }

    private func applyColors() {
        let vibe = Vibe(effectiveAppearance)
        titleField.textColor = vibe.fg
        statusField.textColor = vibe.fg
        detailField.textColor = vibe.secondary
        enabledLabel.textColor = vibe.fg
        eyebrowField.attributedStringValue = NSAttributedString(
            string: "PAGE DOWN  ·  \(Int(loopInterval))S",
            attributes: [.font: mono(11, .medium), .foregroundColor: vibe.tertiary, .kern: 0.8]
        )
        bodyField.textColor = vibe.secondary
        for label in actionLabels { label.textColor = vibe.fg }
        toggle.needsDisplay = true
    }

    func layoutContents() {
        let textX: CGFloat = 16
        let textW = panelWidth - 32
        var y: CGFloat = 14
        dividerYs.removeAll()

        titleField.frame = NSRect(x: textX, y: y, width: textW, height: 18)
        y += 24

        let dot: CGFloat = 6
        dotFrame = NSRect(x: textX, y: y + 5, width: dot, height: dot)
        statusField.frame = NSRect(x: textX + 12, y: y, width: textW - 12, height: 16)
        y += 18
        detailField.frame = NSRect(x: textX + 12, y: y, width: textW - 12, height: 15)
        y += 15 + 12
        dividerYs.append(y)
        y += 1

        enabledRow.frame = NSRect(x: 0, y: y, width: panelWidth, height: 40)
        enabledLabel.frame = NSRect(x: textX, y: 11, width: 160, height: 18)
        toggle.frame = NSRect(x: panelWidth - 16 - 32, y: 11, width: 32, height: 18)
        y += 40
        dividerYs.append(y)
        y += 1

        y += 14
        eyebrowField.frame = NSRect(x: textX, y: y, width: textW, height: 14)
        y += 20
        let bodyH = fieldHeight(bodyField, width: textW)
        bodyField.frame = NSRect(x: textX, y: y, width: textW, height: bodyH)
        y += bodyH + 14
        dividerYs.append(y)
        y += 1

        for (i, row) in actionRows.enumerated() {
            row.frame = NSRect(x: 0, y: y, width: panelWidth, height: 32)
            actionLabels[i].frame = NSRect(x: textX, y: 7, width: textW, height: 18)
            y += 32
        }
        y += 8
        setFrameSize(NSSize(width: panelWidth, height: y))
    }

    override func draw(_ dirtyRect: NSRect) {
        let vibe = Vibe(effectiveAppearance)
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        vibe.bg.setFill()
        card.fill()
        vibe.line.setStroke()
        card.lineWidth = 1
        card.stroke()

        // optical: a circle reads smaller than adjacent text, and cap-height sits above the em-box center. Nudge the dot up 0.5pt.
        let dot = NSBezierPath(ovalIn: dotFrame.offsetBy(dx: 0, dy: -0.5))
        vibe.dotColor(state).setFill()
        dot.fill()

        vibe.line.setStroke()
        for y in dividerYs {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 0, y: y))
            line.line(to: NSPoint(x: bounds.width, y: y))
            line.lineWidth = 1
            line.stroke()
        }
    }

    override func isAccessibilityElement() -> Bool { false }
}

// MARK: - Help

final class HelpView: NSView {
    let done = FillButton(title: "Done")
    private var fields: [NSTextField] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 440, height: 520))
        wantsLayer = true
        addSubview(done)
        rebuild()
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    func rebuild() {
        fields.forEach { $0.removeFromSuperview() }
        fields.removeAll()
        let vibe = Vibe(effectiveAppearance)
        let textW = bounds.width - 48
        var y: CGFloat = 36

        func add(_ string: String, font: NSFont, color: NSColor, gap: CGFloat, kern: CGFloat = 0) -> CGFloat {
            let field = makeField()
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            field.attributedStringValue = NSAttributedString(string: string, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style,
                .kern: kern,
            ])
            let h = fieldHeight(field, width: textW)
            field.frame = NSRect(x: 24, y: y, width: textW, height: h)
            addSubview(field)
            fields.append(field)
            return y + h + gap
        }

        y = add("How to use", font: geist(20, .semibold), color: vibe.fg, gap: 8, kern: -0.3)
        y = add("Presses Page Down (fn + ↓) every \(Int(loopInterval)) seconds, in the frontmost window.",
                font: geist(13, .regular), color: vibe.secondary, gap: 20)

        y = add("PAUSES", font: mono(11, .medium), color: vibe.tertiary, gap: 6, kern: 0.7)
        y = add("Move, click, scroll, or type, and it stops. It resumes after \(Int(activityPause)) seconds of quiet.",
                font: geist(13, .regular), color: vibe.fg, gap: 20)

        y = add("STATUS", font: mono(11, .medium), color: vibe.tertiary, gap: 8, kern: 0.7)
        let lines = [
            ("Running", "scrolling"),
            ("Paused", "you're using the computer"),
            ("Off", "turned off"),
            ("Needs permission", "Accessibility is off"),
        ]
        for (name, meaning) in lines {
            let field = makeField()
            field.attributedStringValue = statusLine(name, meaning, vibe: vibe)
            let h = fieldHeight(field, width: textW)
            field.frame = NSRect(x: 24, y: y, width: textW, height: h)
            addSubview(field)
            fields.append(field)
            y += h + 3
        }
        y += 14

        y = add("CONTROLS", font: mono(11, .medium), color: vibe.tertiary, gap: 6, kern: 0.7)
        y = add("The menu bar icon opens the panel. The Dock menu has Enabled and Quit. ⌘Q quits when this app is active.",
                font: geist(13, .regular), color: vibe.fg, gap: 20)

        y = add("SETUP", font: mono(11, .medium), color: vibe.tertiary, gap: 6, kern: 0.7)
        y = add("Allow Meeting Chat Scroller in System Settings → Privacy & Security → Accessibility. If the warning stays, choose Reset permission & relaunch, then allow it again.",
                font: geist(13, .regular), color: vibe.fg, gap: 8)

        y = add("Leave the chat window in front when you step away.",
                font: geist(12, .regular), color: vibe.secondary, gap: 20)

        done.frame = NSRect(x: bounds.width - 24 - 76, y: y, width: 76, height: 32)
        setFrameSize(NSSize(width: bounds.width, height: done.frame.maxY + 20))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Vibe(effectiveAppearance).bg.setFill()
        bounds.fill()
    }
}

func statusLine(_ name: String, _ meaning: String, vibe: Vibe) -> NSAttributedString {
    let line = NSMutableAttributedString(string: name, attributes: [
        .font: geist(13, .medium),
        .foregroundColor: vibe.fg,
    ])
    line.append(NSAttributedString(string: "   " + meaning, attributes: [
        .font: geist(13, .regular),
        .foregroundColor: vibe.secondary,
    ]))
    return line
}

final class HelpWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 53 || event.keyCode == 76 {
            close()
            return
        }
        super.keyDown(with: event)
    }
}

func makeHelpWindow() -> NSWindow {
    let view = HelpView(frame: .zero)
    let window = HelpWindow(
        contentRect: view.bounds,
        styleMask: [.titled, .closable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.title = "How to use"
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.titlebarSeparatorStyle = .none
    window.isMovableByWindowBackground = true
    window.backgroundColor = NSColor(name: NSColor.Name("vibeHelpBG")) { Vibe($0).bg }
    window.contentView = view
    window.isReleasedWhenClosed = false
    view.done.onClick = { [weak window] in window?.close() }
    return window
}

// MARK: - Menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let worker = Worker()
    var statusItem: NSStatusItem!
    var helpWindow: NSWindow?
    var panel: NSPanel!
    var panelView: PanelView!
    var keyMonitorsInstalled = false
    var dismissMonitorsInstalled = false

    func applicationDidFinishLaunching(_ n: Notification) {
        activateBundledFonts()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        panelView = PanelView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 280))
        panelView.onToggle = { [weak self] in self?.toggleEnabled() }
        panelView.onAccessibility = { [weak self] in
            self?.closePanel()
            self?.openPerms()
        }
        panelView.onReset = { [weak self] in
            self?.closePanel()
            self?.resetPerms()
        }
        panelView.onHelp = { [weak self] in self?.showHelp() }
        panelView.onQuit = { [weak self] in self?.quitApp() }

        panel = NSPanel(
            contentRect: panelView.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = panelView
        panel.isReleasedWhenClosed = false

        NSApp.applicationIconImage = makeAppIcon()
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: "Quit Meeting Chat Scroller", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let helpItem = NSMenuItem(title: "How to Use Meeting Chat Scroller", action: #selector(showHelp), keyEquivalent: "?")
        helpItem.target = self
        helpMenu.addItem(helpItem)
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = mainMenu

        installDismissMonitors()

        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        worker.onState = { [weak self] in self?.render($0) }
        render(currentState())
        worker.start()
    }

    func currentState() -> State {
        if !worker.enabled.get() { return .disabled }
        if !AXIsProcessTrusted() { return .noPermission }
        if secondsSinceUserActivity() < activityPause { return .pausedForActivity }
        return .running
    }

    func installKeyMonitorsIfTrusted() {
        guard !keyMonitorsInstalled, AXIsProcessTrusted() else { return }
        keyMonitorsInstalled = true
        let note: (NSEvent) -> Void = { [weak self] e in
            if e.type == .keyDown && e.keyCode == 53 {
                DispatchQueue.main.async { self?.closePanel() }
            }
            let tagged = e.cgEvent?.getIntegerValueField(.eventSourceUserData) == syntheticTag
            if !tagged && !(e.type == .keyDown && keyActivity.isLikelyOurs(e.keyCode)) { keyActivity.touch() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: note)
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { note($0); return $0 }
    }

    func installDismissMonitors() {
        guard !dismissMonitorsInstalled else { return }
        dismissMonitorsInstalled = true
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            DispatchQueue.main.async { self?.dismissIfOutside(event) }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissIfOutside(event)
            return event
        }
    }

    func dismissIfOutside(_ event: NSEvent) {
        guard panel.isVisible else { return }
        let screenPoint: NSPoint
        if let window = event.window {
            screenPoint = window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        } else {
            screenPoint = event.locationInWindow
        }
        if panel.frame.contains(screenPoint) { return }
        if let button = statusItem.button, let window = button.window {
            let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            if buttonRect.contains(screenPoint) { return }
        }
        closePanel()
    }

    func render(_ s: State) {
        installKeyMonitorsIfTrusted()
        let image = menuBarImage(for: s)
        statusItem.button?.image = image
        statusItem.button?.alphaValue = s == .disabled ? 0.4 : 1
        statusItem.button?.setAccessibilityLabel("Meeting Chat Scroller, \(statusTitle(s))")
        panelView.apply(s, enabled: worker.enabled.get())
        if panel.isVisible { syncPanelFrame() }
    }

    func syncPanelFrame() {
        let origin = panel.frame.origin
        panel.setContentSize(panelView.frame.size)
        panel.setFrameOrigin(origin)
    }

    func positionPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        panel.setContentSize(panelView.frame.size)
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        var x = buttonRect.midX - size.width / 2
        let y = buttonRect.minY - 6 - size.height
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc func togglePanel() {
        if panel.isVisible {
            closePanel()
            return
        }
        render(currentState())
        positionPanel()
        panel.orderFrontRegardless()
        statusItem.button?.isHighlighted = true
    }

    func closePanel() {
        panel.orderOut(nil)
        statusItem.button?.isHighlighted = false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        item.target = self
        item.state = worker.enabled.get() ? .on : .off
        menu.addItem(item)
        return menu
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    @objc func showHelp() {
        closePanel()
        NSApp.activate(ignoringOtherApps: true)
        if helpWindow == nil { helpWindow = makeHelpWindow() }
        if let view = helpWindow?.contentView as? HelpView {
            view.rebuild()
            helpWindow?.setContentSize(view.frame.size)
        }
        helpWindow?.backgroundColor = Vibe(NSApp.effectiveAppearance).bg
        helpWindow?.center()
        helpWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleEnabled() {
        worker.enabled.set(!worker.enabled.get())
        render(currentState())
    }

    /// Clears this app's (possibly stale) Accessibility entry, then relaunches so macOS prompts fresh.
    /// Needed because the app is ad-hoc signed: a new build doesn't match the old grant even if the toggle looks on.
    @objc func resetPerms() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.andrewlandini.meetingchatscroller"
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", bundleID]
        try? reset.run()
        reset.waitUntilExit()

        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; open \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    @objc func openPerms() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// MARK: - Icon export / preview

func bitmap(pixelsWide w: Int, pixelsHigh h: Int, draw: (CGContext, NSRect) -> Void) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w,
        pixelsHigh: h,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    if let ctx = NSGraphicsContext.current?.cgContext {
        draw(ctx, NSRect(x: 0, y: 0, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func writeIconSet(to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sizes: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for (name, px) in sizes {
        guard let data = bitmap(pixelsWide: px, pixelsHigh: px, draw: { _, rect in
            drawAppIcon(in: rect, nudgeFraction: iconNudgeFraction)
        }) else { continue }
        try data.write(to: dir.appendingPathComponent(name))
    }
}

func runCLI(_ args: [String]) -> Int32? {
    if let i = args.firstIndex(of: "--write-iconset"), i + 1 < args.count {
        do {
            try writeIconSet(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))
            return 0
        } catch {
            fputs("iconset: \(error)\n", stderr)
            return 1
        }
    }
    return nil
}

let app = NSApplication.shared
if let code = runCLI(CommandLine.arguments) {
    exit(code)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
