// fixmon — fence off a damaged strip on the left edge of a display.
//
// 1. Overlay: paints the dead strip black, above everything (incl. full-screen apps).
// 2. Mouse lock: an event tap stops the cursor from entering the strip.
// 3. Window push: via the Accessibility API, windows that overlap the strip are
//    moved (and shrunk if needed) into the usable area. Tiled/maximized windows (native tiling,
//    Fill, Raycast) are re-tiled onto the usable area, so it behaves like the display is that size.
//    Event-driven (AX observers); while dragging, a Rectangle-style preview shows where it'll land.
//
// Settings persist in UserDefaults (domain: dev.fixmon) and are adjustable from the menu bar.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

let defaults = UserDefaults.standard
defaults.register(defaults: [
    "deadWidth": 300.0,      // points, measured from the display's left edge
    "displayMatch": "LG",    // substring of the display name; falls back to first external display
    "overlay": true,
    "mouseLock": true,
    "windowPush": true,
    "menuPush": true,        // pushing into the strip along the menu bar opens the app menus
    "fakeFullScreen": true,  // green button / full screen on the fenced display fills the usable area instead
])

// MARK: - Logging

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/fixmon.log")
var lastLogLine = ""

let logQueue = DispatchQueue(label: "fixmon.log")

func log(_ msg: String) { logQueue.async { writeLog(msg) } } // called from the tap, main and push queues

private func writeLog(_ msg: String) {
    guard msg != lastLogLine else { return } // drop repeats so per-event logs stay readable
    lastLogLine = msg
    let line = "\(Date()) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Display geometry

/// Stable identity of a physical display (vendor-model-serial), so the choice survives rearranging and replugging.
func displayKey(_ screen: NSScreen) -> String {
    let id = displayID(screen)
    return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
}

func targetScreen() -> NSScreen? {
    // A display picked from the menu wins; if it's unplugged, fence nothing rather than another screen.
    if let key = defaults.string(forKey: "displayKey") {
        return NSScreen.screens.first { displayKey($0) == key }
    }
    let match = defaults.string(forKey: "displayMatch") ?? ""
    if !match.isEmpty, let s = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains(match) }) {
        return s
    }
    return NSScreen.screens.first { CGDisplayIsBuiltin(displayID($0)) == 0 } // never fence off the built-in display
}

func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
}

var deadWidth: CGFloat { CGFloat(defaults.double(forKey: "deadWidth")) }

/// Dead strip and full display bounds in global CG coordinates (top-left origin), as used by events and AX.
/// Read from the event tap callback, so kept in plain globals refreshed on the main thread.
var deadRectCG = CGRect.null
var displayRectCG = CGRect.null
/// Display minus menu bar/Dock, and that minus the strip: what the display "should" be.
var visibleRectCG = CGRect.null
var usableRectCG = CGRect.null

/// Converts between Cocoa (bottom-left origin) and CG (top-left origin) global rects; it's its own inverse.
func flipped(_ r: CGRect) -> CGRect {
    let h = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
}

func refreshGeometry() {
    guard let screen = targetScreen() else {
        deadRectCG = .null; displayRectCG = .null; visibleRectCG = .null; usableRectCG = .null
        return
    }
    let b = CGDisplayBounds(displayID(screen))
    displayRectCG = b
    deadRectCG = CGRect(x: b.minX, y: b.minY, width: min(deadWidth, b.width - 100), height: b.height)
    let vis = flipped(screen.visibleFrame)
    let left = max(vis.minX, deadRectCG.maxX)
    visibleRectCG = vis
    usableRectCG = CGRect(x: left, y: vis.minY, width: vis.maxX - left, height: vis.height)
}

// MARK: - Overlay

final class Overlay {
    private var window: NSWindow?

    func update() {
        guard defaults.bool(forKey: "overlay"), let screen = targetScreen() else {
            window?.orderOut(nil)
            return
        }
        let f = screen.frame
        let rect = NSRect(x: f.minX, y: f.minY, width: deadRectCG.width, height: f.height)
        let w = window ?? makeWindow()
        w.setFrame(rect, display: true)
        w.orderFrontRegardless()
        window = w
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        return w
    }
}

/// Rectangle-style footprint showing where a window being dragged into the strip will land.
final class Preview {
    private lazy var window: NSWindow = {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        w.isReleasedWhenClosed = false
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        v.layer?.borderWidth = 3
        v.layer?.cornerRadius = 12
        w.contentView = v
        return w
    }()

    func show(_ rectCG: CGRect?) {
        guard let r = rectCG else { window.orderOut(nil); return }
        window.setFrame(flipped(r), display: true)
        window.orderFrontRegardless()
    }
}

// MARK: - Mouse lock

var eventTap: CFMachPort?

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    var p = event.location
    if type == .leftMouseUp && swallowNextMouseUp {
        swallowNextMouseUp = false
        return nil
    }
    // Green button on the fenced display: fill the usable area instead of going full screen.
    // Option-click is left alone (it's the native zoom).
    if type == .leftMouseDown && defaults.bool(forKey: "fakeFullScreen") && displayRectCG.contains(p)
        && !event.flags.contains(.maskAlternate), let win = fullScreenButtonWindow(at: p), !isExcluded(win) {
        swallowNextMouseUp = true
        pushQueue.async { toggleFill(win) }
        return nil
    }
    if lockMouse && deadRectCG.contains(p) {
        p.x = deadRectCG.maxX
        event.location = p
        // Only moves/drags reposition the cursor; re-posting a click would click twice.
        if type == .mouseMoved || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged {
            let button = CGMouseButton(rawValue: UInt32(event.getIntegerValueField(.mouseEventButtonNumber))) ?? .left
            moveCursor(to: p, type: type, button: button) // inline: a main-queue hop is a visible frame of lag
        }
        if type == .mouseMoved && p.y < visibleRectCG.minY { DispatchQueue.main.async { menuBarPush() } }
    }
    return Unmanaged.passUnretained(event)
}

/// CGWarpMouseCursorPosition freezes hardware mouse input for ~0.25s, and pushing against the strip
/// re-triggers it on every event, so the cursor sticks. A posted move from a source with no
/// suppression interval moves the cursor without that freeze.
let cursorSource: CGEventSource? = {
    let s = CGEventSource(stateID: .combinedSessionState)
    s?.localEventsSuppressionInterval = 0
    return s
}()

func moveCursor(to p: CGPoint, type: CGEventType, button: CGMouseButton) {
    guard let e = CGEvent(mouseEventSource: cursorSource, mouseType: type, mouseCursorPosition: p, mouseButton: button) else {
        CGWarpMouseCursorPosition(p)
        return
    }
    e.post(tap: .cghidEventTap)
}

/// Mirror of the toggle, refreshed by apply(); the tap reads it per event.
var lockMouse = false
var swallowNextMouseUp = false

/// The tap also serves the green-button intercept, so it runs if either feature is on.
var needsTap: Bool { lockMouse || defaults.bool(forKey: "fakeFullScreen") }

let systemWideAX: AXUIElement = {
    let el = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(el, 0.15) // hit-testing runs inside the tap, so a slow app mustn't stall clicks
    return el
}()

/// The window whose green (full screen) button is under the point, if any.
func fullScreenButtonWindow(at p: CGPoint) -> AXUIElement? {
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWideAX, Float(p.x), Float(p.y), &hit) == .success, let el = hit,
          axString(el, kAXSubroleAttribute) == kAXFullScreenButtonSubrole else { return nil }
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &ref) == .success, let w = ref else { return nil }
    return (w as! AXUIElement)
}

var savedFrames: [(win: AXUIElement, frame: CGRect)] = [] // pushQueue only
var exitingFullScreen: [AXUIElement] = [] // pushQueue only

/// Green button: fill the usable area, or restore the previous frame if already filled (pushQueue).
func toggleFill(_ win: AXUIElement) {
    guard let f = windowFrame(win) else { return }
    let use = usableRectCG
    let filled = abs(f.minX - use.minX) < 2 && abs(f.minY - use.minY) < 2 && abs(f.width - use.width) < 2 && abs(f.height - use.height) < 2
    let saved = savedFrames.firstIndex { CFEqual($0.win, win) }
    if filled, let i = saved {
        _ = setFrame(win, savedFrames[i].frame)
        savedFrames.remove(at: i)
    } else {
        if let i = saved { savedFrames.remove(at: i) }
        savedFrames.append((win, f))
        _ = setFrame(win, use)
    }
}

/// Browsers use real full screen for video; taking them out of it would also exit the video.
let fullScreenExempt: Set<String> = ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "company.thebrowser.Browser",
                                     "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac", "app.zen-browser.zen",
                                     "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]

/// Full screen entered some other way (⌃⌘F, fn F, View menu) on the fenced display: take the window back out
/// and fill the usable area. Retries because exiting is ignored while the enter animation is still running (pushQueue).
func exitFullScreen(_ win: AXUIElement, attempt: Int = 0) {
    guard let pos = axValue(win, kAXPositionAttribute, .cgPoint, CGPoint.zero),
          let size = axValue(win, kAXSizeAttribute, .cgSize, CGSize.zero),
          displayRectCG.contains(CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)) else { return }
    var pid: pid_t = 0
    AXUIElementGetPid(win, &pid)
    let app = NSRunningApplication(processIdentifier: pid)
    if let id = app?.bundleIdentifier, fullScreenExempt.contains(id) || excludedApps.contains(id) { return }
    if attempt == 0 {
        guard !exitingFullScreen.contains(where: { CFEqual($0, win) }) else { return } // already on it
        exitingFullScreen.append(win)
    }
    let done = { exitingFullScreen.removeAll { CFEqual($0, win) } }
    if axBool(win, "AXFullScreen") {
        guard attempt < 10 else { done(); log("full screen exit gave up: \(app?.localizedName ?? "?")"); return }
        if attempt == 0 { log("full screen -> fill: \(app?.localizedName ?? "?")") }
        AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, kCFBooleanFalse)
        pushQueue.asyncAfter(deadline: .now() + 0.4) { exitFullScreen(win, attempt: attempt + 1) }
    } else {
        // The exit animation restores the old frame; fill after it settles.
        pushQueue.asyncAfter(deadline: .now() + 0.5) { _ = setFrame(win, usableRectCG); done() }
    }
}

func startMouseLock() -> Bool {
    guard eventTap == nil else { return true }
    let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]
    let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    // HID level sees moves before the window server places the cursor, so the clamp lands before the
    // cursor is drawn inside the strip; the session level is the fallback.
    var level = "HID"
    var tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: tapCallback, userInfo: nil)
    if tap == nil {
        level = "session"
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: tapCallback, userInfo: nil)
    }
    guard let tap else {
        log("event tap creation failed (AX trusted: \(AXIsProcessTrusted()))")
        return false
    }
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    eventTap = tap
    log("event tap active (\(level) level)")
    return true
}

func stopMouseLock() {
    guard let tap = eventTap else { return }
    CGEvent.tapEnable(tap: tap, enable: false)
    CFMachPortInvalidate(tap)
    eventTap = nil
}

// MARK: - Window push

func axValue<T>(_ el: AXUIElement, _ attr: String, _ type: AXValueType, _ empty: T) -> T? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success, let v = ref,
          CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var out = empty
    return AXValueGetValue(v as! AXValue, type, &out) ? out : nil
}

func axString(_ el: AXUIElement, _ attr: String) -> String? {
    var ref: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success ? ref as? String : nil
}

func axBool(_ el: AXUIElement, _ attr: String) -> Bool {
    var ref: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success && (ref as? Bool) == true
}

let pushQueue = DispatchQueue(label: "fixmon.push")
var pushInFlight = false
var axPrimed = Set<pid_t>() // only touched on pushQueue

/// Edges within this many points of a grid line count as tiled.
let snapTolerance: CGFloat = 10

/// Where a window frame should be, or nil if it's fine where it is.
/// Tiled/maximized windows (both edges on the visible area's halves/thirds/quarters grid) are re-tiled onto
/// the same grid of the usable area; anything else overlapping the strip is slid right (narrowed if needed).
func targetFrame(_ f: CGRect) -> CGRect? {
    let vis = visibleRectCG, use = usableRectCG
    guard !use.isNull, displayRectCG.contains(CGPoint(x: f.midX, y: f.midY)) else { return nil }
    let grid: [CGFloat] = [0, 1/4, 1/3, 1/2, 2/3, 3/4, 1]
    func onGrid(_ x: CGFloat, _ r: CGRect) -> CGFloat? { grid.first { abs(r.minX + $0 * r.width - x) <= snapTolerance } }
    if onGrid(f.minX, use) != nil && onGrid(f.maxX, use) != nil { return nil } // already tiled in the usable area

    var t = f
    if let a = onGrid(f.minX, vis), let b = onGrid(f.maxX, vis), b > a {
        t.origin.x = (use.minX + a * use.width).rounded()
        t.size.width = ((b - a) * use.width).rounded()
    } else if f.minX < use.minX - 1 {
        t.origin.x = use.minX
        t.size.width = min(f.width, use.width)
    } else {
        return nil
    }
    return t.integral == f.integral ? nil : t
}

/// Bundle IDs the user excluded from the menu: their windows are never moved, re-tiled or taken out of full screen.
var excludedApps: Set<String> { Set(defaults.stringArray(forKey: "excludedApps") ?? []) }

func isExcluded(_ win: AXUIElement) -> Bool {
    var pid: pid_t = 0
    guard AXUIElementGetPid(win, &pid) == .success, let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
    return excludedApps.contains(id)
}

/// Window kinds we move: regular windows, dialogs (alerts, Open/Save panels) and floating panels
/// (inspectors, palettes). Sheets ride along with their parent; menus, popovers and tooltips are left alone.
let movableSubroles: Set<String> = [kAXStandardWindowSubrole, kAXDialogSubrole, kAXSystemDialogSubrole,
                                    kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole]

/// Frame of a movable, visible window, or nil for anything we shouldn't touch.
func windowFrame(_ win: AXUIElement) -> CGRect? {
    guard !isExcluded(win), axString(win, kAXRoleAttribute) == kAXWindowRole,
          let sub = axString(win, kAXSubroleAttribute), movableSubroles.contains(sub),
          !axBool(win, kAXMinimizedAttribute), !axBool(win, "AXFullScreen"),
          let pos = axValue(win, kAXPositionAttribute, .cgPoint, CGPoint.zero),
          let size = axValue(win, kAXSizeAttribute, .cgSize, CGSize.zero) else { return nil }
    return CGRect(origin: pos, size: size)
}

func setFrame(_ win: AXUIElement, _ t: CGRect) -> AXError {
    var pos = t.origin, size = t.size
    // Size, position, size: the first resize keeps a wide window from being clamped by the screen edge
    // when moved, the last one wins if the app clamped the first.
    var err = AXError.failure
    if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v) }
    if let v = AXValueCreate(.cgPoint, &pos) { err = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, v) }
    if let v = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v) }
    return err
}

/// Runs on pushQueue.
func fixWindow(_ win: AXUIElement) {
    if defaults.bool(forKey: "fakeFullScreen") && axBool(win, "AXFullScreen") { exitFullScreen(win); return }
    guard defaults.bool(forKey: "windowPush"), let f = windowFrame(win), let t = targetFrame(f) else { return }
    let err = setFrame(win, t)
    var pid: pid_t = 0
    AXUIElementGetPid(win, &pid)
    log("fix \(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?") \(f) -> \(t) err=\(err.rawValue)")
}

/// Regular apps, plus menu-bar apps you installed (their panels/dialogs). Skips the dozens of XPC helpers
/// and system agents (Dock, Control Center…) that also run as "accessory" and stall AX queries.
func shouldManage(_ app: NSRunningApplication) -> Bool {
    guard app.processIdentifier != getpid() else { return false }
    if app.activationPolicy == .regular { return true }
    guard app.activationPolicy == .accessory, let path = app.bundleURL?.path, path.hasSuffix(".app") else { return false }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return (path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")) && !path.dropLast(4).contains(".app/")
}

/// Full sweep over every window; the observers handle the common case, this catches what they miss.
func pushWindows() {
    guard defaults.bool(forKey: "windowPush"), AXIsProcessTrusted(), !deadRectCG.isNull else { return }

    for app in NSWorkspace.shared.runningApplications where shouldManage(app) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0) // runs off the main thread, so a slow app only delays this pass
        var ref: CFTypeRef?
        if !axPrimed.contains(app.processIdentifier) {
            // Chrome/Electron apps only answer AX window queries once this is set.
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            axPrimed.insert(app.processIdentifier)
        }
        let wErr = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref)
        if wErr != .success { log("windows of \(app.localizedName ?? "?"): err=\(wErr.rawValue)") }
        guard wErr == .success,
              let windows = ref as? [AXUIElement] else { continue }

        windows.forEach(fixWindow)
    }
}

// MARK: - Window observers (event-driven push)

var observers: [pid_t: AXObserver] = [:] // main thread only
var pendingWindows: [AXUIElement] = []
var pendingFlush: DispatchWorkItem?
var dragWindow: AXUIElement?
var previewInFlight = false
let preview = Preview()

var mouseIsDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

let axCallback: AXObserverCallback = { _, element, _, _ in windowChanged(element) }

/// A window was created, moved or resized (main thread).
func windowChanged(_ win: AXUIElement) {
    if mouseIsDown {
        // Mid-drag: don't fight the user, just show where it'll land; mouse-up does the fix.
        dragWindow = win
        updatePreview()
        return
    }
    if !pendingWindows.contains(where: { CFEqual($0, win) }) { pendingWindows.append(win) }
    // Debounced so tiling/zoom animations finish before we re-tile.
    pendingFlush?.cancel()
    let work = DispatchWorkItem {
        let wins = pendingWindows
        pendingWindows = []
        pushQueue.async { wins.forEach(fixWindow) }
    }
    pendingFlush = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
}

func updatePreview() {
    guard !previewInFlight, let win = dragWindow, defaults.bool(forKey: "windowPush") else { return }
    previewInFlight = true
    pushQueue.async {
        let t = windowFrame(win).flatMap(targetFrame)
        DispatchQueue.main.async {
            previewInFlight = false
            preview.show(dragWindow == nil ? nil : t)
        }
    }
}

func mouseReleased() {
    preview.show(nil)
    guard let win = dragWindow else { return }
    dragWindow = nil
    windowChanged(win)
}

func watchApp(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard shouldManage(app), observers[pid] == nil else { return }
    var obs: AXObserver?
    guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
    let axApp = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(axApp, 0.5)
    var ok = false
    for n in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification] {
        if AXObserverAddNotification(obs, axApp, n as CFString, nil) == .success { ok = true }
    }
    guard ok else { return } // app not ready (or AX not granted); the timer retries
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    observers[pid] = obs
}

func observeAll() {
    guard AXIsProcessTrusted() else { return }
    NSWorkspace.shared.runningApplications.forEach(watchApp)
}

func unobserve(_ pid: pid_t) {
    guard let obs = observers.removeValue(forKey: pid) else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
}

// MARK: - App menus (the left of the menu bar is under the strip)

func axChildren(_ el: AXUIElement) -> [AXUIElement] {
    var ref: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success ? (ref as? [AXUIElement] ?? []) : []
}

/// Mirrors one of the frontmost app's menus via AX; filled lazily when opened, so it's always current.
final class AXMenuProxy: NSMenu, NSMenuDelegate {
    let owner: AXUIElement // the menu bar item or menu item whose first child is the AXMenu

    init(title: String, owner: AXUIElement) {
        self.owner = owner
        super.init(title: title)
        autoenablesItems = false
        delegate = self
    }

    required init(coder: NSCoder) { fatalError() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        guard let axMenu = axChildren(owner).first else { return }
        for el in axChildren(axMenu) {
            let title = axString(el, kAXTitleAttribute) ?? ""
            if title.isEmpty { // separators are untitled items
                if let last = items.last, !last.isSeparatorItem { addItem(.separator()) }
                continue
            }
            let item = NSMenuItem(title: title, action: #selector(press(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = el
            item.isEnabled = axBool(el, kAXEnabledAttribute)
            if let mark = axString(el, kAXMenuItemMarkCharAttribute), !mark.isEmpty { item.state = .on }
            if let key = axString(el, kAXMenuItemCmdCharAttribute), !key.isEmpty, key.count == 1 {
                // Shown for reference only; AX modifier bits: 1 shift, 2 option, 4 control, 8 no-command.
                var refMods = 0
                if let n = axNumber(el, kAXMenuItemCmdModifiersAttribute) { refMods = n }
                var mods: NSEvent.ModifierFlags = refMods & 8 == 0 ? [.command] : []
                if refMods & 1 != 0 { mods.insert(.shift) }
                if refMods & 2 != 0 { mods.insert(.option) }
                if refMods & 4 != 0 { mods.insert(.control) }
                item.keyEquivalent = key.lowercased()
                item.keyEquivalentModifierMask = mods
            }
            if !axChildren(el).isEmpty { item.submenu = AXMenuProxy(title: title, owner: el) }
            addItem(item)
        }
        if let last = items.last, last.isSeparatorItem { removeItem(last) }
    }

    @objc func press(_ sender: NSMenuItem) {
        guard let el = sender.representedObject else { return }
        let ax = el as! AXUIElement
        // After our menu has closed, so the app gets the action with its own state restored.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            AXUIElementSetMessagingTimeout(ax, 2)
            AXUIElementPerformAction(ax, kAXPressAction as CFString)
        }
    }
}

func axNumber(_ el: AXUIElement, _ attr: String) -> Int? {
    var ref: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success ? (ref as? NSNumber)?.intValue : nil
}

/// The frontmost app's whole menu bar as one menu (one submenu per top-level menu), or nil.
func frontAppMenu() -> NSMenu? {
    guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(axApp, 1)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &ref) == .success, let bar = ref else { return nil }
    let menu = NSMenu(title: app.localizedName ?? "")
    for barItem in axChildren(bar as! AXUIElement) {
        guard let title = axString(barItem, kAXTitleAttribute), !title.isEmpty else { continue }
        let item = NSMenuItem(title: title == "Apple" ? "" : title, action: nil, keyEquivalent: "")
        item.submenu = AXMenuProxy(title: title, owner: barItem)
        menu.addItem(item)
    }
    return menu.items.isEmpty ? nil : menu
}

var appMenuOpen = false

/// Pops the frontmost app's menus at the cursor (hotkey, or pushing into the strip along the menu bar).
func showAppMenu() {
    guard !appMenuOpen, let menu = frontAppMenu() else { return }
    appMenuOpen = true
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    appMenuOpen = false
}

/// Pushing left into the strip within the menu bar opens the app menus; a few pushes in a row so merely
/// sliding along the top doesn't trigger it.
var menuPushStart = 0.0
var menuPushCount = 0

func menuBarPush() {
    guard defaults.bool(forKey: "menuPush") else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if now - menuPushStart > 0.4 { menuPushStart = now; menuPushCount = 0 }
    menuPushCount += 1
    if menuPushCount == 4 { showAppMenu() }
}

var hotKeyRef: EventHotKeyRef?

/// ⌃⌥M opens the app menus anywhere.
func registerHotKey() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { showAppMenu() }
        return noErr
    }, 1, &spec, nil, nil)
    RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x666D6F6E, id: 1),
                        GetApplicationEventTarget(), 0, &hotKeyRef)
}

// MARK: - App / menu bar

/// Menu-bar glyph: a monitor with its left strip blacked out (template, so it follows light/dark).
func statusIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
        let screen = NSRect(x: 1.5, y: 4.5, width: 15, height: 10)
        let outline = NSBezierPath(roundedRect: screen, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1.5
        NSColor.black.set()
        outline.stroke()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSRect(x: 0, y: 0, width: 6.5, height: 16).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSRect(x: 8, y: 2, width: 2, height: 2.5).fill() // neck
        NSBezierPath(roundedRect: NSRect(x: 5, y: 0.5, width: 8, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill() // foot
        return true
    }
    img.isTemplate = true
    return img
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let overlay = Overlay()
    var statusItem: NSStatusItem!
    var timer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Ask for Accessibility once; needed for the event tap and for moving windows.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = statusIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.apply() }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.apply() }
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { watchApp(app) }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { unobserve(app.processIdentifier) }
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in mouseReleased() }
        registerHotKey()

        // Fallback sweep; the AX observers do the real-time work.
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            observeAll() // picks up apps that weren't ready, or everything once Accessibility is granted
            if !pushInFlight && !mouseIsDown {
                pushInFlight = true
                pushQueue.async { pushWindows(); DispatchQueue.main.async { pushInFlight = false } }
            }
            // The tap can't be created until Accessibility is granted; keep retrying.
            if needsTap && eventTap == nil { _ = startMouseLock() }
            _ = self
        }
        apply()
    }

    func apply() {
        refreshGeometry()
        log("apply: dead=\(deadRectCG) display=\(displayRectCG) AX=\(AXIsProcessTrusted())")
        overlay.update()
        lockMouse = defaults.bool(forKey: "mouseLock")
        if needsTap { _ = startMouseLock() } else { stopMouseLock() }
        observeAll()
        pushQueue.async { pushWindows() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Accessibility: \(AXIsProcessTrusted() ? "granted" : "missing") · Mouse lock: \(eventTap != nil ? "active" : "inactive")",
                     action: nil, keyEquivalent: "")
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "⚠︎ Grant Accessibility access…", action: #selector(openAXSettings), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        // Built now, while the app the user was in is still frontmost (menu-bar clicks don't activate us).
        if let appMenu = frontAppMenu() {
            let item = NSMenuItem(title: "\(appMenu.title) menus  (⌃⌥M)", action: nil, keyEquivalent: "")
            item.submenu = appMenu
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for (title, key) in [("Black overlay", "overlay"), ("Lock mouse out", "mouseLock"), ("Push windows out", "windowPush"),
                             ("Menu bar push opens app menus", "menuPush"), ("Green button fills usable area", "fakeFullScreen")] {
            let item = NSMenuItem(title: title, action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = defaults.bool(forKey: key) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(widthSliderItem())
        menu.addItem(displayMenuItem())
        menu.addItem(excludeMenuItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: "About fixmon", action: #selector(about), keyEquivalent: "").target = self
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(withTitle: "Restart fixmon", action: #selector(restart), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Quit fixmon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func toggle(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        apply()
    }

    // MARK: Display picker

    func displayMenuItem() -> NSMenuItem {
        let current = targetScreen()
        let item = NSMenuItem(title: "Display: \(current?.localizedName ?? "not connected")", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for screen in NSScreen.screens {
            let builtin = CGDisplayIsBuiltin(displayID(screen)) != 0
            let s = NSMenuItem(title: screen.localizedName + (builtin ? "  (built-in)" : ""), action: #selector(pickDisplay(_:)), keyEquivalent: "")
            s.target = self
            s.representedObject = displayKey(screen)
            s.state = screen == current ? .on : .off
            sub.addItem(s)
        }
        item.submenu = sub
        return item
    }

    @objc func pickDisplay(_ sender: NSMenuItem) {
        defaults.set(sender.representedObject as? String, forKey: "displayKey")
        apply()
    }

    // MARK: Excluded apps

    func excludeMenuItem() -> NSMenuItem {
        let excluded = excludedApps
        let item = NSMenuItem(title: excluded.isEmpty ? "Excluded apps" : "Excluded apps (\(excluded.count))", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(withTitle: "Excluded apps' windows are left where they are.", action: nil, keyEquivalent: "")
        sub.addItem(.separator())
        // Running apps first, then excluded ones that aren't running (so they can still be un-excluded).
        var seen = Set<String>()
        let running = NSWorkspace.shared.runningApplications.filter(shouldManage)
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        for app in running {
            guard let id = app.bundleIdentifier, seen.insert(id).inserted else { continue }
            sub.addItem(excludeItem(title: app.localizedName ?? id, id: id, icon: app.icon, on: excluded.contains(id)))
        }
        for id in excluded.subtracting(seen).sorted() {
            sub.addItem(excludeItem(title: id, id: id, icon: nil, on: true))
        }
        item.submenu = sub
        return item
    }

    func excludeItem(title: String, id: String, icon: NSImage?, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(toggleExclude(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = id
        item.state = on ? .on : .off
        if let icon = icon?.copy() as? NSImage {
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
        return item
    }

    @objc func toggleExclude(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var set = excludedApps
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        defaults.set(set.sorted(), forKey: "excludedApps")
        apply()
    }

    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: Width slider

    var widthLabel: NSTextField?
    var widthSlider: NSSlider?
    var widthApply: DispatchWorkItem?

    /// "Dead zone" label over [−] slider [+]; the overlay follows live while dragging.
    func widthSliderItem() -> NSMenuItem {
        let maxWidth = displayRectCG.isNull ? 2000 : Double(displayRectCG.width) - 100
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 48))

        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 20, y: 27, width: 250, height: 17)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        view.addSubview(label)

        let minus = NSButton(title: "−", target: self, action: #selector(nudgeWidth(_:)))
        minus.tag = -5
        let plus = NSButton(title: "+", target: self, action: #selector(nudgeWidth(_:)))
        plus.tag = 5
        for (b, x) in [(minus, 14.0), (plus, 246.0)] {
            b.bezelStyle = .inline
            b.frame = NSRect(x: x, y: 4, width: 22, height: 20)
            view.addSubview(b)
        }

        let slider = NSSlider(value: Double(deadWidth), minValue: 0, maxValue: maxWidth, target: self, action: #selector(slideWidth(_:)))
        slider.frame = NSRect(x: 40, y: 4, width: 202, height: 20)
        slider.isContinuous = true
        view.addSubview(slider)

        widthLabel = label
        widthSlider = slider
        updateWidthLabel()
        let item = NSMenuItem()
        item.view = view
        return item
    }

    func updateWidthLabel() {
        widthLabel?.stringValue = "Dead zone: \(Int(deadWidth)) pt on \(targetScreen()?.localizedName ?? "no display")"
    }

    @objc func slideWidth(_ sender: NSSlider) {
        setWidth((sender.doubleValue / 5).rounded() * 5)
    }

    @objc func nudgeWidth(_ sender: NSButton) {
        setWidth(Double(deadWidth) + Double(sender.tag))
        widthSlider?.doubleValue = Double(deadWidth)
    }

    func setWidth(_ w: Double) {
        defaults.set(max(0, w), forKey: "deadWidth")
        updateWidthLabel()
        refreshGeometry()
        overlay.update()
        // Pushing every window on each slider tick is wasteful; do it once the slider settles.
        widthApply?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply() }
        widthApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            log("launch at login: \(error)")
        }
    }

    /// Relaunches the bundle (picks up a rebuilt binary too): a detached shell reopens it once we've quit.
    @objc func restart() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        log("restart requested")
        NSApp.terminate(nil)
    }

    @objc func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
