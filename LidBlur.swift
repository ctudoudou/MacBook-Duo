// LidBlur.swift — simulates the iPhone Duo fold-blur effect on a MacBook (v6: trapezoidal black bars)
//
// Build:  swiftc -O LidBlur.swift -o LidBlur
// Run:    ./LidBlur | tee lidblur.log

import AppKit
import IOKit.hid

// MARK: - Private APIs: resolved at runtime from already-loaded SkyLight / CoreGraphics symbols
// Note: the function signatures below come from community reverse-engineering, not official
// headers, and may break after a system update.

enum SkyLight {
    typealias MainConnectionFn = @convention(c) () -> Int32
    typealias SetBlurRadiusFn = @convention(c) (Int32, UInt32, Int32) -> Int32
    typealias SpaceCreateFn = @convention(c) (Int32, Int, Int) -> UInt64
    typealias SpaceSetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Void
    typealias AddWindowsToSpaceFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    private static func fn<T>(_ names: [String], as type: T.Type) -> T? {
        for name in names {
            if let p = dlsym(rtldDefault, name) { return unsafeBitCast(p, to: type) }
        }
        return nil
    }

    static let mainConnection = fn(["SLSMainConnectionID", "CGSMainConnectionID"], as: MainConnectionFn.self)
    static let setBlurRadius = fn(["SLSSetWindowBackgroundBlurRadius", "CGSSetWindowBackgroundBlurRadius"], as: SetBlurRadiusFn.self)
    static let spaceCreate = fn(["SLSSpaceCreate", "CGSSpaceCreate"], as: SpaceCreateFn.self)
    static let spaceSetAbsoluteLevel = fn(["SLSSpaceSetAbsoluteLevel", "CGSSpaceSetAbsoluteLevel"], as: SpaceSetAbsoluteLevelFn.self)
    static let showSpaces = fn(["SLSShowSpaces", "CGSShowSpaces"], as: ShowSpacesFn.self)
    static let addWindowsToSpace = fn(["SLSSpaceAddWindowsAndRemoveFromSpaces", "CGSSpaceAddWindowsAndRemoveFromSpaces"], as: AddWindowsToSpaceFn.self)

    static var isBlurAvailable: Bool { mainConnection != nil && setBlurRadius != nil }
}

// MARK: - A Space above the lock screen
// Creates a space whose absolute level is higher than the lock screen, then moves the blur
// layer's window into it. Community data puts the lock screen around 300 and its notification
// center around 400; we use 400 here — try other values if the effect isn't visible.

final class LockScreenSpace {
    static let levelOptions: [Int32] = [100, 200, 300, 400]
    private(set) var level: Int32 = 400 // same as SkyLightWindow
    private(set) var spaceID: UInt64 = 0
    var isReady: Bool { spaceID != 0 }

    init() {
        guard let conn = SkyLight.mainConnection?(),
              let create = SkyLight.spaceCreate,
              let show = SkyLight.showSpaces else {
            print("sky: missing space-related symbols")
            return
        }
        let sid = create(conn, 1, 0)
        guard sid != 0 else {
            print("sky: failed to create space")
            return
        }
        spaceID = sid
        setLevel(level)
        show(conn, [NSNumber(value: sid)] as CFArray)
        print("sky: space=\(sid) created and shown")
    }

    func setLevel(_ newLevel: Int32) {
        guard isReady, let conn = SkyLight.mainConnection?(),
              let setAbs = SkyLight.spaceSetAbsoluteLevel else { return }
        let r = setAbs(conn, spaceID, newLevel)
        level = newLevel
        print("sky: setLevel(\(newLevel)) result=\(r)")
    }

    /// The underlying function has no return value, so there's no way to confirm success —
    /// only the debug tint lets you verify it visually.
    func adopt(_ window: NSWindow) -> Bool {
        guard isReady, let conn = SkyLight.mainConnection?(), let add = SkyLight.addWindowsToSpace else { return false }
        add(conn, spaceID, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        print("sky: sent adopt window=\(window.windowNumber) → space=\(spaceID)")
        return true
    }
}

// MARK: - Lid angle sensor (IOKit HID)

final class LidAngleSensor {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var failCount = 0
    private let none = IOOptionBits(kIOHIDOptionsTypeNone)

    var isAvailable: Bool { device != nil }

    func connect() {
        close()
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, none)
        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey: 0x05AC, kIOHIDDeviceUsagePageKey: 0x0020, kIOHIDDeviceUsageKey: 0x008A],
            [kIOHIDVendorIDKey: 0x05AC, kIOHIDPrimaryUsagePageKey: 0x0020, kIOHIDPrimaryUsageKey: 0x008A],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matches as CFArray)
        guard IOHIDManagerOpen(mgr, none) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return }

        for dev in devices {
            guard IOHIDDeviceOpen(dev, none) == kIOReturnSuccess else { continue }
            if readRaw(dev) != nil {
                device = dev
                manager = mgr
                failCount = 0
                return
            }
            IOHIDDeviceClose(dev, none)
        }
        IOHIDManagerClose(mgr, none)
    }

    func close() {
        if let dev = device { IOHIDDeviceClose(dev, none) }
        if let mgr = manager { IOHIDManagerClose(mgr, none) }
        device = nil
        manager = nil
    }

    func read() -> Double? {
        guard let dev = device else { return nil }
        if let angle = readRaw(dev) {
            failCount = 0
            return angle
        }
        failCount += 1
        if failCount > 30 { connect() }
        return nil
    }

    private func readRaw(_ dev: IOHIDDevice) -> Double? {
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, &report, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        let raw = Double(UInt16(report[2]) << 8 | UInt16(report[1]))
        return (0...360).contains(raw) ? raw : nil
    }
}

// MARK: - Full-screen blur layer (built-in display only)

let invisibleAlpha: CGFloat = 1.0 / 255 // invisible at 8-bit depth, but the window still takes part in compositing

final class BlurOverlay {
    private var window: NSWindow?
    private var appliedRadius: Int32 = -1
    private var desiredRadius: Int32 = 1
    private var appliedAlpha: CGFloat = -1
    private var desiredAlpha: CGFloat = invisibleAlpha
    var debugTint = false { didSet { updateBackground() } }
    // Background opacity: 0.001 gets rounded to 0 at 8-bit depth, making the window fully
    // transparent — and with the current window setup the system then seems to skip background
    // blur entirely. Use the smallest nonzero value instead.
    var baseAlpha: CGFloat = 1.0 / 255 { didSet { updateBackground() } }

    private func updateBackground() {
        window?.backgroundColor = debugTint
            ? NSColor.systemRed.withAlphaComponent(0.25)
            : NSColor(white: 0, alpha: baseAlpha)
    }

    /// Rebuilds the window; if a space is passed, moves the window above the lock screen.
    /// Returns whether it was actually moved in.
    @discardableResult
    func rebuild(space: LockScreenSpace?) -> Bool {
        window?.orderOut(nil)
        window = nil
        appliedRadius = -1
        appliedAlpha = -1
        guard let screen = Self.builtinScreen() else { return false }

        // Window configuration mirrors SkyLightWindow's TopmostWindow
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless, .fullSizeContentView],
                         backing: .buffered, defer: false, screen: screen)
        w.isOpaque = false
        w.hasShadow = false
        w.isMovable = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        w.canBecomeVisibleWithoutLogin = true // allows showing on the lock/login screen (the key difference)
        w.level = space == nil ? .screenSaver : NSWindow.Level(rawValue: Int(Int32.max - 2))
        w.setFrame(screen.frame, display: false)
        window = w
        updateBackground()

        // Order matches the original: adopt into the space first, then show the window
        var adopted = false
        if let space { adopted = space.adopt(w) }
        w.orderFrontRegardless()
        apply()
        return adopted
    }

    func set(radius: Int32, alpha: CGFloat) {
        desiredRadius = radius
        desiredAlpha = alpha
        apply()
    }

    private func apply() {
        guard let w = window else { return }
        if desiredAlpha != appliedAlpha {
            w.alphaValue = desiredAlpha
            appliedAlpha = desiredAlpha
        }
        guard desiredRadius != appliedRadius,
              let conn = SkyLight.mainConnection, let setBlur = SkyLight.setBlurRadius else { return }
        _ = setBlur(conn(), UInt32(w.windowNumber), desiredRadius)
        appliedRadius = desiredRadius
    }

    static func builtinScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }
}

// MARK: - Keystone (trapezoid) projection model
// Assumes the viewer sits directly in front, eyes positioned eyeAboveTopMM above the top edge
// of the screen. As the lid folds below 90°, the top edge moves closer to the eye and appears
// wider; narrowing the top edge of the content proportionally to that distance makes it look,
// from straight on, as if the screen were still open at 90°. Only the horizontal edges are
// adjusted — the vertical extent stays full-bleed.

final class KeystoneModel {
    var viewDistanceMM: Double = 500
    var eyeAboveTopMM: Double = 100
    var exaggeration: Double = 1
    let screenHeightMM: Double

    init() {
        var h = 190.0
        if let screen = BlurOverlay.builtinScreen(),
           let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            let size = CGDisplayScreenSize(id)
            if size.height > 50 { h = Double(size.height) }
        }
        screenHeightMM = h
    }

    private func rawInset(_ angle: Double) -> Double {
        guard angle < 90 else { return 0 }
        let H = screenHeightMM, D = viewDistanceMM, E = H + eyeAboveTopMM
        let t = angle * .pi / 180
        let d90 = hypot(D, E - H)
        let dT = hypot(D - H * cos(t), E - H * sin(t))
        return (1 - dT / d90) / 2
    }

    /// Inset ratio per side at the top edge (relative to screen width). Takes the max over
    /// [angle, 90] so the black bar doesn't shrink back as the lid nears fully closed and the
    /// effective distance increases again.
    func topInset(angle: Double) -> Double {
        guard angle < 90 else { return 0 }
        var m = 0.0
        var a = max(angle, 0)
        while a < 90 { m = max(m, rawInset(a)); a += 2 }
        return min(max(m * exaggeration, 0), 0.45)
    }
}

// MARK: - Black bar mask layer (separate window, stacked above the blur layer, unaffected by its opacity)

final class MaskOverlay {
    private var window: NSWindow?
    private let shape = CAShapeLayer()
    private var appliedInsetPt: CGFloat = -1
    private var desiredInset: CGFloat = 0

    func rebuild(space: LockScreenSpace?) {
        window?.orderOut(nil)
        window = nil
        appliedInsetPt = -1
        guard let screen = BlurOverlay.builtinScreen() else { return }

        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless, .fullSizeContentView],
                         backing: .buffered, defer: false, screen: screen)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isMovable = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        w.canBecomeVisibleWithoutLogin = true
        w.level = space == nil
            ? NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            : NSWindow.Level(rawValue: Int(Int32.max - 1))
        w.setFrame(screen.frame, display: false)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        shape.removeFromSuperlayer()
        shape.fillColor = NSColor.black.cgColor
        shape.frame = view.bounds
        view.layer?.addSublayer(shape)
        w.contentView = view
        window = w

        if let space { _ = space.adopt(w) }
        w.orderFrontRegardless()
        apply()
    }

    /// inset: per-side top-edge inset ratio (0...0.45)
    func set(inset: CGFloat) {
        desiredInset = inset
        apply()
    }

    private func apply() {
        guard let view = window?.contentView else { return }
        let size = view.bounds.size
        let insetPt = (desiredInset * size.width * 2).rounded() / 2 // half-point granularity, to avoid needless redraws
        guard insetPt != appliedInsetPt else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if insetPt < 0.5 {
            shape.path = nil
        } else {
            let p = CGMutablePath()
            p.addLines(between: [CGPoint(x: 0, y: size.height), CGPoint(x: insetPt, y: size.height), CGPoint(x: 0, y: 0)])
            p.closeSubpath()
            p.addLines(between: [CGPoint(x: size.width, y: size.height), CGPoint(x: size.width - insetPt, y: size.height), CGPoint(x: size.width, y: 0)])
            p.closeSubpath()
            shape.path = p
        }
        CATransaction.commit()
        appliedInsetPt = insetPt
    }
}

// MARK: - Angle → blur intensity (0...1)

final class AngleMapper {
    var clearAngle: Double = 85
    var blurAngle: Double = 30

    private(set) var smoothedAngle: Double?
    private var lastTime: TimeInterval = 0
    private let tau: TimeInterval = 0.06

    func reset() { smoothedAngle = nil }

    func update(angle: Double, now: TimeInterval) -> Double {
        let dt = now - lastTime
        lastTime = now
        if let s = smoothedAngle, dt > 0, dt < 0.5 {
            smoothedAngle = s + (angle - s) * (1 - exp(-dt / tau))
        } else {
            smoothedAngle = angle
        }
        let a = smoothedAngle ?? angle
        let span = max(clearAngle - blurAngle, 1)
        let t = min(max((clearAngle - a) / span, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Transition mode

enum TransitionMode: Int, CaseIterable {
    case hybrid // opacity fades in during the first 20% of intensity, while radius grows with angle throughout
    case alpha  // radius fixed at its max, only window opacity is adjusted

    var title: String {
        switch self {
        case .hybrid: return "Hybrid (radius + opacity)"
        case .alpha:  return "Opacity (fixed radius)"
        }
    }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sensor = LidAngleSensor()
    private let overlay = BlurOverlay()
    private let mapper = AngleMapper()
    private let mask = MaskOverlay()
    private var keystone: KeystoneModel!
    private var lockSpace: LockScreenSpace?
    private var keystoneEnabled = true
    private let distanceOptions: [Double] = [350, 500, 700]   // mm
    private let exaggerationOptions: [Double] = [1, 1.5, 2]

    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let skyLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let clearItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let blurItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var lastStatusText = ""
    private var lastRawAngle: Double?
    private var timer: Timer?

    private var enabled = true
    private var lockScreenEnabled = true
    private var debugTint = false
    private let baseAlphaOptions: [Int] = [1, 3, 10] // unit: 1/255
    private var mode: TransitionMode = .hybrid
    private var maxRadius: Double = 40
    private let radiusOptions: [Double] = [20, 40, 60, 90]

    // Lock-screen failsafe
    private var isLocked = false
    private var wakeTime: TimeInterval = 0
    private var readFailSince: TimeInterval?
    private let lockFailsafe: TimeInterval = 6   // force clear if still locked this many seconds after waking
    private let readFailsafe: TimeInterval = 0.5 // force clear after this many seconds of consecutive sensor read failures

    // Debug logging
    private var lastLogKey = ""
    private var lastLoggedAngle: Double = -999

    func applicationDidFinishLaunching(_ notification: Notification) {
        sensor.connect()
        keystone = KeystoneModel()
        print("keystone: screen height \(Int(keystone.screenHeightMM)) mm")
        lockSpace = LockScreenSpace()
        setupMenu()
        rebuildOverlay()

        let t = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(tick),
                      userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLocked(_:)),
                        name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenUnlocked(_:)),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    private func rebuildOverlay() {
        let space = lockScreenEnabled ? lockSpace : nil
        let adopted = overlay.rebuild(space: space)
        mask.rebuild(space: space) // built after, higher level, stacks above the blur layer
        if !lockScreenEnabled {
            skyLine.title = "Lock screen layer: disabled"
        } else if adopted, let space = lockSpace {
            skyLine.title = "Lock screen layer: moved into space \(space.spaceID) (level \(space.level))"
        } else {
            skyLine.title = "Lock screen layer: failed to enable (desktop only)"
        }
    }

    // MARK: Main loop

    @objc private func tick() {
        guard SkyLight.isBlurAvailable else {
            setStatus("Private blur API unavailable (unsupported system version)")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime

        guard let angle = sensor.read() else {
            if readFailSince == nil { readFailSince = now }
            if let since = readFailSince, now - since > readFailsafe {
                overlay.set(radius: 1, alpha: invisibleAlpha) // never stay blurred when the angle can't be read
                mask.set(inset: 0)
            }
            setStatus(sensor.isAvailable ? "Angle: read failed (forced clear)" : "No angle sensor found (may not be supported on this machine)")
            if sensor.isAvailable { print(String(format: "%.3f  READ FAIL", now)) }
            return
        }
        readFailSince = nil
        lastRawAngle = angle

        var intensity = mapper.update(angle: angle, now: now)
        let failsafeActive = isLocked && now - wakeTime > lockFailsafe
        if failsafeActive { intensity = 0 }

        var radius: Int32 = 1
        var alpha: CGFloat = invisibleAlpha
        if enabled {
            switch mode {
            case .hybrid:
                radius = max(1, Int32((intensity * maxRadius).rounded()))
                alpha = CGFloat(min(1, intensity / 0.2))
            case .alpha:
                radius = Int32(maxRadius)
                alpha = CGFloat(intensity)
            }
            alpha = max(invisibleAlpha, (alpha * 100).rounded() / 100)
        }
        if debugTint { alpha = 1 } // keep the debug tint always visible
        overlay.set(radius: radius, alpha: alpha)

        var inset = 0.0
        if keystoneEnabled && !failsafeActive, let a = mapper.smoothedAngle {
            inset = keystone.topInset(angle: a)
        }
        mask.set(inset: CGFloat(inset))

        let suffix = failsafeActive ? " (lock-screen failsafe: forced clear)" : ""
        setStatus(String(format: "Angle: %.0f°  Blur: %.0f%%", angle, intensity * 100) + suffix)

        let key = "\(radius)-\(alpha)-\(isLocked)-\(Int(inset * 1000))"
        if key != lastLogKey || abs(angle - lastLoggedAngle) >= 1 {
            print(String(format: "%.3f  mode=%@  locked=%@  raw=%.0f  smooth=%.1f  radius=%d  alpha=%.2f  inset=%.3f",
                         now, mode == .hybrid ? "hybrid" : "alpha", isLocked ? "Y" : "N", angle,
                         mapper.smoothedAngle ?? -1, radius, alpha, inset))
            lastLogKey = key
            lastLoggedAngle = angle
        }
    }

    private func setStatus(_ text: String) {
        guard text != lastStatusText else { return }
        lastStatusText = text
        statusLine.title = text
    }

    // MARK: System events

    @objc private func didWake(_ n: Notification) {
        wakeTime = ProcessInfo.processInfo.systemUptime
        mapper.reset()
        if !sensor.isAvailable { sensor.connect() }
        print(String(format: "%.3f  WAKE", wakeTime))
    }

    @objc private func screenLocked(_ n: Notification) {
        isLocked = true
        wakeTime = ProcessInfo.processInfo.systemUptime // also start the clock here if locked without sleeping first
        print(String(format: "%.3f  LOCKED", wakeTime))
    }

    @objc private func screenUnlocked(_ n: Notification) {
        isLocked = false
        print(String(format: "%.3f  UNLOCKED", ProcessInfo.processInfo.systemUptime))
    }

    @objc private func screensChanged(_ n: Notification) {
        rebuildOverlay()
    }

    // MARK: Menu

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "LidBlur")

        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(skyLine)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Enable blur", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = .on
        menu.addItem(toggle)

        let lockToggle = NSMenuItem(title: "Apply on lock screen", action: #selector(toggleLockScreen(_:)), keyEquivalent: "")
        lockToggle.target = self
        lockToggle.state = lockScreenEnabled ? .on : .off
        menu.addItem(lockToggle)

        let levelMenu = NSMenu()
        for (i, lv) in LockScreenSpace.levelOptions.enumerated() {
            let item = NSMenuItem(title: "\(lv)", action: #selector(pickLevel(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = lv == (lockSpace?.level ?? 300) ? .on : .off
            levelMenu.addItem(item)
        }
        let levelItem = NSMenuItem(title: "Lock screen level", action: nil, keyEquivalent: "")
        levelItem.submenu = levelMenu
        menu.addItem(levelItem)

        let tint = NSMenuItem(title: "Debug: show red tint", action: #selector(toggleTint(_:)), keyEquivalent: "")
        tint.target = self
        menu.addItem(tint)

        let baseMenu = NSMenu()
        for (i, v) in baseAlphaOptions.enumerated() {
            let item = NSMenuItem(title: "\(v)/255", action: #selector(pickBaseAlpha(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == 0 ? .on : .off
            baseMenu.addItem(item)
        }
        let baseItem = NSMenuItem(title: "Debug: background opacity", action: nil, keyEquivalent: "")
        baseItem.submenu = baseMenu
        menu.addItem(baseItem)

        menu.addItem(.separator())
        let ksToggle = NSMenuItem(title: "Trapezoidal black bars", action: #selector(toggleKeystone(_:)), keyEquivalent: "")
        ksToggle.target = self
        ksToggle.state = keystoneEnabled ? .on : .off
        menu.addItem(ksToggle)

        let distMenu = NSMenu()
        for (i, d) in distanceOptions.enumerated() {
            let item = NSMenuItem(title: "\(Int(d / 10)) cm", action: #selector(pickDistance(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = d == keystone.viewDistanceMM ? .on : .off
            distMenu.addItem(item)
        }
        let distItem = NSMenuItem(title: "Viewing distance", action: nil, keyEquivalent: "")
        distItem.submenu = distMenu
        menu.addItem(distItem)

        let exMenu = NSMenu()
        for (i, e) in exaggerationOptions.enumerated() {
            let item = NSMenuItem(title: String(format: "%.1f×", e), action: #selector(pickExaggeration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = e == keystone.exaggeration ? .on : .off
            exMenu.addItem(item)
        }
        let exItem = NSMenuItem(title: "Black bar exaggeration", action: nil, keyEquivalent: "")
        exItem.submenu = exMenu
        menu.addItem(exItem)
        menu.addItem(.separator())

        let modeMenu = NSMenu()
        for m in TransitionMode.allCases {
            let item = NSMenuItem(title: m.title, action: #selector(pickMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = m.rawValue
            item.state = m == mode ? .on : .off
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "Transition mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)
        menu.addItem(.separator())

        clearItem.action = #selector(calibrateClear(_:))
        clearItem.target = self
        blurItem.action = #selector(calibrateBlur(_:))
        blurItem.target = self
        menu.addItem(clearItem)
        menu.addItem(blurItem)
        refreshCalibrationTitles()

        let radiusMenu = NSMenu()
        for (i, r) in radiusOptions.enumerated() {
            let item = NSMenuItem(title: "\(Int(r))", action: #selector(pickRadius(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = r == maxRadius ? .on : .off
            radiusMenu.addItem(item)
        }
        let radiusItem = NSMenuItem(title: "Max blur radius", action: nil, keyEquivalent: "")
        radiusItem.submenu = radiusMenu
        menu.addItem(radiusItem)

        menu.addItem(.separator())
        let redetect = NSMenuItem(title: "Re-detect sensor", action: #selector(redetect(_:)), keyEquivalent: "")
        redetect.target = self
        menu.addItem(redetect)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func refreshCalibrationTitles() {
        clearItem.title = String(format: "Clear angle: %.0f° (click to set to current angle)", mapper.clearAngle)
        blurItem.title = String(format: "Max blur angle: %.0f° (click to set to current angle)", mapper.blurAngle)
    }

    private func check(_ sender: NSMenuItem) {
        sender.menu?.items.forEach { $0.state = .off }
        sender.state = .on
    }

    @objc private func toggleLockScreen(_ sender: NSMenuItem) {
        lockScreenEnabled.toggle()
        sender.state = lockScreenEnabled ? .on : .off
        rebuildOverlay()
    }

    @objc private func pickLevel(_ sender: NSMenuItem) {
        lockSpace?.setLevel(LockScreenSpace.levelOptions[sender.tag])
        check(sender)
        rebuildOverlay()
    }

    @objc private func toggleKeystone(_ sender: NSMenuItem) {
        keystoneEnabled.toggle()
        sender.state = keystoneEnabled ? .on : .off
    }

    @objc private func pickDistance(_ sender: NSMenuItem) {
        keystone.viewDistanceMM = distanceOptions[sender.tag]
        check(sender)
    }

    @objc private func pickExaggeration(_ sender: NSMenuItem) {
        keystone.exaggeration = exaggerationOptions[sender.tag]
        check(sender)
    }

    @objc private func pickBaseAlpha(_ sender: NSMenuItem) {
        overlay.baseAlpha = CGFloat(baseAlphaOptions[sender.tag]) / 255
        check(sender)
    }

    @objc private func toggleTint(_ sender: NSMenuItem) {
        debugTint.toggle()
        overlay.debugTint = debugTint
        sender.state = debugTint ? .on : .off
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        mode = TransitionMode(rawValue: sender.tag) ?? .hybrid
        check(sender)
    }

    @objc private func calibrateClear(_ sender: NSMenuItem) {
        guard let a = lastRawAngle else { return }
        mapper.clearAngle = a
        if mapper.blurAngle > a - 10 { mapper.blurAngle = max(a - 10, 0) }
        refreshCalibrationTitles()
    }

    @objc private func calibrateBlur(_ sender: NSMenuItem) {
        guard let a = lastRawAngle else { return }
        mapper.blurAngle = a
        if mapper.clearAngle < a + 10 { mapper.clearAngle = a + 10 }
        refreshCalibrationTitles()
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        enabled.toggle()
        sender.state = enabled ? .on : .off
    }

    @objc private func pickRadius(_ sender: NSMenuItem) {
        maxRadius = radiusOptions[sender.tag]
        check(sender)
    }

    @objc private func redetect(_ sender: NSMenuItem) {
        sensor.connect()
        lastStatusText = ""
    }
}

// MARK: - Entry point

setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
