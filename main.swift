import Cocoa
import ApplicationServices

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

// MARK: - Menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let worker = Worker()
    var statusItem: NSStatusItem!
    var helpWindow: NSWindow?
    var keyMonitorsInstalled = false
    let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    let toggleItem = NSMenuItem(title: "Enabled", action: #selector(toggle), keyEquivalent: "e")

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        toggleItem.target = self
        toggleItem.state = .on
        menu.addItem(toggleItem)
        let perm = NSMenuItem(title: "Open Accessibility Settings…", action: #selector(openPerms), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)
        let reset = NSMenuItem(title: "Reset Permission & Relaunch…", action: #selector(resetPerms), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let help = NSMenuItem(title: "How to Use…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        help.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Help")
        menu.addItem(help)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Meeting Chat Scroller", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit")
        menu.addItem(quit)
        statusItem.menu = menu

        // Dock icon + app menu, so the app can be quit from the Dock (right-click → Quit) or with ⌘Q.
        NSApp.applicationIconImage = makeAppIcon()
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Meeting Chat Scroller", action: #selector(quitApp), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(NSMenuItem(title: "How to Use Meeting Chat Scroller", action: #selector(showHelp), keyEquivalent: "?"))
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = mainMenu

        // Ask for Accessibility up front (needed to send keys).
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        worker.onState = { [weak self] in self?.render($0) }
        render(.running)
        worker.start()
    }

    /// Watches for real typing. Key monitors only work once Accessibility is granted, so install lazily.
    func installKeyMonitorsIfTrusted() {
        guard !keyMonitorsInstalled, AXIsProcessTrusted() else { return }
        keyMonitorsInstalled = true
        let note: (NSEvent) -> Void = { e in
            let tagged = e.cgEvent?.getIntegerValueField(.eventSourceUserData) == syntheticTag
            if !tagged && !(e.type == .keyDown && keyActivity.isLikelyOurs(e.keyCode)) { keyActivity.touch() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: note)
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { note($0); return $0 }
    }

    func render(_ s: State) {
        installKeyMonitorsIfTrusted()
        let (symbol, text): (String, String) = switch s {
        case .disabled:          ("arrow.up.arrow.down.circle", "Disabled")
        case .noPermission:      ("exclamationmark.triangle", "Needs Accessibility permission")
        case .pausedForActivity: ("pause.circle", "Paused (you’re using the mouse or keyboard)")
        case .running:           ("arrow.up.arrow.down.circle.fill", "Running")
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.alphaValue = s == .disabled ? 0.4 : 1.0
        statusLine.title = text
    }

    /// Extra items in the Dock icon's right-click menu (macOS adds Quit automatically).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Enabled", action: #selector(toggle), keyEquivalent: "")
        item.target = self
        item.state = worker.enabled.get() ? .on : .off
        menu.addItem(item)
        return menu
    }

    @objc func quitApp() { NSApp.terminate(nil) }

    @objc func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        if helpWindow == nil { helpWindow = makeHelpWindow() }
        helpWindow?.center()
        helpWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func toggle() {
        let on = !worker.enabled.get()
        worker.enabled.set(on)
        toggleItem.state = on ? .on : .off
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

/// Dock icon drawn at runtime: white up/down arrows on a blue rounded square.
func makeAppIcon() -> NSImage {
    let size = NSSize(width: 512, height: 512)
    return NSImage(size: size, flipped: false) { rect in
        let bg = NSBezierPath(roundedRect: rect.insetBy(dx: 50, dy: 50), xRadius: 90, yRadius: 90)
        NSGradient(starting: NSColor(red: 0.25, green: 0.55, blue: 1, alpha: 1),
                   ending: NSColor(red: 0.10, green: 0.30, blue: 0.85, alpha: 1))?.draw(in: bg, angle: -90)
        let cfg = NSImage.SymbolConfiguration(pointSize: 230, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let sym = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let s = sym.size
            sym.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
}

// MARK: - Help window

/// Builds the "How to Use" window: bold headings, inline icons, numbered steps.
func makeHelpWindow() -> NSWindow {
    let width: CGFloat = 440
    let body = NSFont.systemFont(ofSize: 13)
    let text = NSMutableAttributedString()

    func para(spacingBefore: CGFloat = 0, indent: CGFloat = 0, tab: CGFloat? = nil) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = spacingBefore
        p.paragraphSpacing = 4
        p.lineSpacing = 2
        p.firstLineHeadIndent = 0
        p.headIndent = indent
        if let tab { p.tabStops = [NSTextTab(textAlignment: .left, location: tab)] }
        return p
    }
    func add(_ str: String, font: NSFont = body, color: NSColor = .labelColor, style: NSParagraphStyle = para()) {
        text.append(NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
    }
    func heading(_ str: String) {
        add(str + "\n", font: .systemFont(ofSize: 14, weight: .semibold), style: para(spacingBefore: 14))
    }
    func icon(_ symbol: String, color: NSColor = .labelColor) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        else { return }
        let att = NSTextAttachment()
        att.image = img
        att.bounds = NSRect(x: 0, y: -2, width: img.size.width, height: img.size.height)
        text.append(NSAttributedString(attachment: att))
    }
    func iconRow(_ symbol: String, _ label: String, color: NSColor = .labelColor) {
        let style = para(indent: 32, tab: 32)
        let start = text.length
        icon(symbol, color: color)
        add("\t" + label + "\n", style: style)
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: text.length - start))
    }
    func bullet(_ marker: String, _ str: String) {
        add(marker + "\t" + str + "\n", style: para(indent: 22, tab: 22))
    }

    add("How to Use\n", font: .systemFont(ofSize: 20, weight: .bold))
    add("Meeting Chat Scroller keeps a chat window scrolling for you, so you don’t have to.\n",
        color: .secondaryLabelColor)

    heading("What it does")
    add("Every \(Int(loopInterval)) seconds it presses Page Down (fn + ↓). "
        + "The keys go to whichever window is in front.\n")

    heading("It pauses while you’re using the computer")
    add("Move the mouse, click, scroll or type, and it stops right away. "
        + "It starts again by itself once you’ve left the mouse and keyboard alone for \(Int(activityPause)) seconds.\n")

    heading("Turning it off")
    bullet("•", "To pause: click the menu bar icon, then click Enabled.")
    bullet("•", "To quit: right-click the Dock icon and choose Quit, or press ⌘Q.")

    heading("The menu bar icon")
    iconRow("arrow.up.arrow.down.circle.fill", "Running")
    iconRow("pause.circle", "Paused because you’re using the mouse or keyboard")
    iconRow("arrow.up.arrow.down.circle", "Turned off", color: .tertiaryLabelColor)
    iconRow("exclamationmark.triangle", "Needs permission (see below)")

    heading("First-time setup")
    bullet("1.", "Open System Settings → Privacy & Security → Accessibility.")
    bullet("2.", "Turn on Meeting Chat Scroller.")
    bullet("3.", "Still seeing the warning icon? Click the menu bar icon, choose "
        + "Reset Permission & Relaunch…, then turn it on again.")

    add("\n")
    add("Tip: the keys go to whichever window is in front, so leave your chat window in front when you step away.\n",
        font: .systemFont(ofSize: 12), color: .secondaryLabelColor, style: para(spacingBefore: 6))

    // Text view sized to fit its content, so there's no scrolling.
    let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
    tv.isEditable = false
    tv.isSelectable = false
    tv.drawsBackground = false
    tv.textContainerInset = NSSize(width: 24, height: 22)
    tv.textStorage?.setAttributedString(text)
    tv.layoutManager?.ensureLayout(for: tv.textContainer!)
    let textHeight = (tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 400) + 44
    tv.frame.size.height = textHeight

    let button = NSButton(title: "Got It", target: nil, action: #selector(NSWindow.performClose(_:)))
    button.keyEquivalent = "\r"
    button.bezelStyle = .rounded
    button.sizeToFit()

    let buttonArea: CGFloat = 52
    let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: textHeight + buttonArea))
    tv.frame.origin = NSPoint(x: 0, y: buttonArea)
    button.frame.origin = NSPoint(x: width - button.frame.width - 20, y: 16)
    content.addSubview(tv)
    content.addSubview(button)

    let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Meeting Chat Scroller Help"
    window.contentView = content
    window.isReleasedWhenClosed = false
    return window
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
