import Cocoa
import SwiftUI
import ScreenCaptureKit
import ServiceManagement

// MARK: - Config (everything user-tunable lives here, nothing hard-coded)

struct Config: Codable, Equatable {
    var top = 16            // dead border, in physical panel pixels
    var bottom = 0
    var left = 0
    var right = 0
    var keepAspect = true   // ON: keep the panel's own aspect ratio. OFF: use `aspectPreset`
    var aspectPreset = "16:9"   // free | 16:9 | 16:10 | 4:3 | 21:9 | custom  (used when keepAspect is off)
    var customW = 16.0
    var customH = 9.0
    var hiDPI = true        // virtual screen at 2x (UI looks like half the pixel size)
    var refresh = 60
    var displayUUID = ""    // "" = first physical display
    var enabled = true
    var sizeMode = "borders"    // borders | diagonal
    var panelInches = 48.0      // real diagonal of the physical panel
    var targetInches = 24.0     // diagonal to emulate in "diagonal" mode
    var startDelay = 10         // seconds to wait after login / wake before building the virtual screen
    var refW = 0                // panel resolution these settings were last applied at (0 = unknown)
    var refH = 0
    var loginDelay = 30         // seconds to wait when the app starts shortly after boot / login
    var autoStartOnLaunch = true
    var confineMouse = true     // keep the pointer on the virtual screen (stops it escaping onto the black border)
    var debugStage = 4          // 1...4: stop setup early to find a problem step; 4 = full

    /// Decodes saved settings, filling keys added by newer versions with defaults,
    /// so an app update never wipes the user's settings.
    static func load(from data: Data) -> Config? {
        guard let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defData = try? JSONEncoder().encode(Config()),
              var merged = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any] else { return nil }
        for (k, v) in saved where merged[k] != nil { merged[k] = v }
        guard let out = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: out)
    }

    /// nil = no ratio constraint (fill the available area)
    func effectiveRatio(panelW: Int, panelH: Int) -> Double? {
        if keepAspect { return Double(panelW) / Double(panelH) }
        switch aspectPreset {
        case "free":   return nil
        case "panel":  return Double(panelW) / Double(panelH)   // legacy saved value
        case "16:10":  return 16.0 / 10.0
        case "4:3":    return 4.0 / 3.0
        case "21:9":   return 21.0 / 9.0
        case "custom": return max(customW, 0.001) / max(customH, 0.001)
        default:       return 16.0 / 9.0
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    @Published var cfg: Config { didSet { save() } }
    private let key = "config.v1"
    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           var c = Config.load(from: d) {
            if c.aspectPreset == "panel" { c.aspectPreset = "16:9" }
            cfg = c
        } else { cfg = Config() }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(cfg) { UserDefaults.standard.set(d, forKey: key) }
    }
}

// MARK: - Geometry

struct Geometry { var vw: Int; var vh: Int; var x: Int; var y: Int }  // x,y = offset from panel top-left, in pixels

func geometry(_ c: Config, panelW: Int, panelH: Int) -> Geometry {
    let aw = max(panelW - c.left - c.right, 64)
    let ah = max(panelH - c.top - c.bottom, 64)
    var w = aw, h = ah
    if c.sizeMode == "diagonal" {
        // Same pixel density as the panel, so a smaller diagonal = fewer pixels.
        let s = min(1.0, max(c.targetInches, 1) / max(c.panelInches, 1))
        w = Int(Double(panelW) * s)
        h = Int(Double(panelH) * s)
    }
    w = max(min(w, aw), 64); h = max(min(h, ah), 64)
    if let r = c.effectiveRatio(panelW: panelW, panelH: panelH) {
        if Double(w) / Double(h) > r { w = Int(Double(h) * r) } else { h = Int(Double(w) / r) }
    }
    // Snap to multiples of 16: avoids awkward sizes (e.g. odd heights from wide ratios like 21:9)
    // and keeps 2x HiDPI dividing cleanly.
    w = max(w - w % 16, 64); h = max(h - h % 16, 64)
    return Geometry(vw: w, vh: h, x: c.left + (aw - w) / 2, y: c.top + (ah - h) / 2)
}

// MARK: - Display helpers

let virtualVendorTag: UInt32 = 0x4D59

func screenID(_ s: NSScreen) -> CGDirectDisplayID {
    (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}
func displayUUID(_ id: CGDirectDisplayID) -> String {
    guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "" }
    return CFUUIDCreateString(nil, u) as String
}
func physicalScreens() -> [NSScreen] {
    // Skip our own virtual display and anything without a UUID (half-connected or virtual displays from other tools)
    NSScreen.screens.filter {
        let id = screenID($0)
        return CGDisplayVendorNumber(id) != virtualVendorTag && !displayUUID(id).isEmpty
    }
}
func nativePixels(_ id: CGDirectDisplayID) -> (Int, Int) {
    if let m = CGDisplayCopyDisplayMode(id) { return (m.pixelWidth, m.pixelHeight) }
    return (CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id))
}
func pickPhysical(_ c: Config) -> NSScreen? {
    let list = physicalScreens()
    if !c.displayUUID.isEmpty, let s = list.first(where: { displayUUID(screenID($0)) == c.displayUUID }) { return s }
    // Automatic: the display with the most pixels, so a stray 1080p display never wins over a 4K TV
    return list.max { a, b in
        let (aw, ah) = nativePixels(screenID(a)), (bw, bh) = nativePixels(screenID(b))
        return aw * ah < bw * bh
    }
}
func onlineDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    guard count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func describeOnlineDisplays() -> [String] {
    onlineDisplayIDs().map { id in
        let b = CGDisplayBounds(id)
        return "id \(id) active=\(CGDisplayIsActive(id)) mirrorSet=\(CGDisplayIsInMirrorSet(id)) mirrorOf=\(CGDisplayMirrorsDisplay(id)) main=\(CGDisplayIsMain(id)) vendor=\(CGDisplayVendorNumber(id)) bounds=\(Int(b.origin.x)),\(Int(b.origin.y)) \(Int(b.width))x\(Int(b.height))"
    }
}

/// NSScreen does not list a display that is mirroring another one, so a TV that macOS put into a
/// mirror set looks "lost" to the app. Switch any mirroring off. Returns true if something changed.
@discardableResult
func breakMirrorSets() -> Bool {
    let mirrored = onlineDisplayIDs().filter { CGDisplayIsInMirrorSet($0) != 0 }
    guard !mirrored.isEmpty else { return false }
    var cref: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cref) == .success else { return false }
    for id in mirrored { CGConfigureDisplayMirrorOfDisplay(cref, id, kCGNullDirectDisplay) }
    return CGCompleteDisplayConfiguration(cref, .forSession) == .success
}

func displayLabel(_ s: NSScreen) -> String {
    let (w, h) = nativePixels(screenID(s))
    return "\(s.localizedName)  (\(w)×\(h))"
}

// MARK: - Frame sink (ScreenCaptureKit -> CALayer)

final class FrameSink: NSObject, SCStreamOutput {
    weak var layer: CALayer?
    private var held: CVPixelBuffer?   // main thread only; keeps the shown frame's buffer alive
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb),
              let surf = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let layer = self.layer else { return }
            // Core Animation cross-fades `contents` changes by default (the "ghost").
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surf
            CATransaction.commit()
            self.held = pb
        }
    }
}

// MARK: - Controller

@MainActor
final class Controller {
    static let shared = Controller()
    private(set) var running = false
    private(set) var wantsAutoRestart = false   // true only after a display disconnect, never after a failure
    private(set) var status = "Stopped"
    var onStatusChange: (() -> Void)?
    private(set) var asleep = false
    private(set) var established = false   // true only while the virtual screen is fully up and running
    private var restartAfterWake = false
    private var pendingAuto = false
    private var scheduledToken = 0
    private var userInitiated = true
    private let blockedKey = "autostartBlocked"   // set while a start is in progress; survives crashes / forced reboots
    var autostartBlocked: Bool { UserDefaults.standard.bool(forKey: blockedKey) }

    func setStatus(_ s: String) { status = s; onStatusChange?() }
    private func log(_ s: String) { NSLog("UsableDisplay: \(s)") }

    private func cancel(_ msg: String, gen: Int) {
        guard gen == generation else { return }
        stop()
        UserDefaults.standard.set(false, forKey: blockedKey)
        setStatus(msg)
    }

    private func debugStop(_ stage: Int, gen: Int) {
        guard gen == generation else { return }
        UserDefaults.standard.set(false, forKey: blockedKey)
        setStatus("Debug: stopped after stage \(stage). Set the stage back to Full for normal use.")
    }

    typealias Panel = (id: CGDirectDisplayID, uuid: String, w: Int, h: Int, hz: Double, edr: Double)

    private func panelNow(_ cfg: Config, uuid: String?) -> Panel? {
        let screen: NSScreen?
        if let u = uuid { screen = physicalScreens().first { displayUUID(screenID($0)) == u } }
        else { screen = pickPhysical(cfg) }
        guard let s = screen else { return nil }
        let id = screenID(s)
        let (w, h) = nativePixels(id)
        let hz = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        return (id, displayUUID(id), w, h, hz, Double(s.maximumExtendedDynamicRangeColorComponentValue))
    }

    /// Waits until the physical display is present and reports the same non-zero resolution
    /// for 2 seconds in a row (a TV that is still re-locking its signal will not pass).
    /// Pass `uuid` to follow a specific display even if its ID changes.
    private func waitForStablePanel(_ cfg: Config, uuid: String? = nil, seconds: Int, stableSamples: Int = 4) async -> Panel? {
        var last = "", streak = 0
        for _ in 0..<(seconds * 2) {
            if let p = panelNow(cfg, uuid: uuid), p.w > 0, p.h > 0 {
                let key = "\(p.uuid):\(p.w)x\(p.h)@\(p.hz)"
                if key == last { streak += 1 } else { last = key; streak = 1 }
                if streak >= stableSamples { return p }
            } else { last = ""; streak = 0 }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }
    private var lastAttempt = ""
    private var generation = 0
    private var vdisplay: CGVirtualDisplay?
    private var stream: SCStream?
    private var window: NSWindow?
    private let sink = FrameSink()

    func start(userInitiated: Bool = true) {
        if userInitiated { scheduledToken += 1; pendingAuto = false }   // cancels any pending automatic start
        self.userInitiated = userInitiated
        stop()
        let cfg = Settings.shared.cfg
        guard cfg.enabled else { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            setStatus("Needs Screen Recording permission")
            if userInitiated {
                let a = NSAlert()
                a.messageText = "Screen Recording permission needed"
                a.informativeText = "Enable UsableDisplay in System Settings > Privacy & Security > Screen & System Audio Recording, then choose 'Re-apply' from the menu bar icon."
                a.runModal()
            }
            return
        }
        UserDefaults.standard.set(true, forKey: blockedKey)   // cleared once the stream is up
        setStatus("Starting…")
        running = true
        generation += 1
        let gen = generation
        Task { await run(cfg, gen: gen) }
    }

    /// Automatic start (login, wake, display reconnect): waits, checks the display is really there,
    /// and refuses to run if the previous start failed or was interrupted.
    func scheduleAutoStart(after seconds: Double) {
        scheduledToken += 1
        let token = scheduledToken
        pendingAuto = true
        setStatus("Waiting to start…")
        Task { [self] in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            guard token == scheduledToken else { return }
            @MainActor func giveUp(_ why: String) { pendingAuto = false; setStatus(why) }
            let cfg = Settings.shared.cfg
            guard cfg.enabled else { return giveUp("Disabled") }
            if autostartBlocked {
                return giveUp("Not started: the last start failed or was interrupted. Choose Re-apply to try again.")
            }
            pendingAuto = false
            start(userInitiated: false)
        }
    }

    func systemWillSleep() {
        restartAfterWake = restartAfterWake || running || wantsAutoRestart || pendingAuto
        scheduledToken += 1
        pendingAuto = false
        asleep = true
        stop()                       // tear everything down before the displays go away
        setStatus("Paused while the Mac sleeps")
    }

    func systemDidWake(delay: Double) {
        asleep = false
        guard restartAfterWake else { return }
        restartAfterWake = false
        scheduleAutoStart(after: delay)
    }

    /// Emergency button: remove our virtual display and put macOS's saved display layout back.
    func restoreDisplays() {
        scheduledToken += 1
        pendingAuto = false
        restartAfterWake = false
        stop()
        breakMirrorSets()
        CGRestorePermanentDisplayConfiguration()
        setStatus("Stopped. Display layout restored.")
    }

    // MARK: Cursor guard
    // The real display sits diagonally off the virtual one and touches it at a corner, so a fast flick into
    // that corner can put the pointer on the black border where clicks do nothing. Warp it back.
    private var cursorTimer: Timer?

    private func startCursorGuard() {
        cursorTimer?.invalidate()
        // No pause in mouse movement after a warp (the old global function was removed from macOS)
        CGEventSource(stateID: .combinedSessionState)?.localEventsSuppressionInterval = 0
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.guardCursor() }
        }
        RunLoop.main.add(t, forMode: .common)
        cursorTimer = t
    }

    private func guardCursor() {
        guard let vd = vdisplay, let loc = CGEvent(source: nil)?.location else { return }
        let b = CGDisplayBounds(vd.displayID)
        guard !b.contains(loc) else { return }
        let p = CGPoint(x: min(max(loc.x, b.minX + 1), b.maxX - 2),
                        y: min(max(loc.y, b.minY + 1), b.maxY - 2))
        _ = CGWarpMouseCursorPosition(p)
        _ = CGAssociateMouseAndMouseCursorPosition(1)
    }

    func stop(autoRestart: Bool = false) {
        cursorTimer?.invalidate()
        cursorTimer = nil
        log("stop(autoRestart: \(autoRestart))")
        established = false
        generation += 1
        running = false
        wantsAutoRestart = autoRestart
        setStatus(autoRestart ? "Waiting for the display to return…" : "Stopped")
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
        window?.orderOut(nil)
        window = nil
        vdisplay = nil   // releasing destroys the virtual display
    }

    private func fail(_ msg: String, gen: Int, soft: Bool = false) {
        log("fail: \(msg) [\(lastAttempt)] (run \(gen), current \(generation))")
        guard gen == generation else { return }   // a newer run already took over
        stop()                                    // also disables auto-restart, so no retry loop
        if soft { UserDefaults.standard.set(false, forKey: blockedKey) }   // nothing was changed, safe to try again later
        else { CGRestorePermanentDisplayConfiguration() }                  // undo any display layout change we made
        setStatus("Failed: \(msg)")
        guard userInitiated else { return }       // never pop up a dialog during an automatic start
        let a = NSAlert()
        a.messageText = "Couldn't set up the virtual screen"
        a.informativeText = "\(msg)\nRequested: \(lastAttempt)\n\nCheck that the display is connected and showing a picture, or try a different border size or aspect ratio in Settings, then press Apply. The app will not retry on its own."
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func run(_ cfg: Config, gen: Int) async {
        for line in describeOnlineDisplays() { log("online (start): \(line)") }
        if breakMirrorSets() {
            log("start: found a display mirror set and switched it off")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard gen == generation else { return }
        }
        // 0a. Automatic starts: wait until the desktop session is really up (Dock and Finder running)
        if !userInitiated {
            setStatus("Waiting for the desktop to finish loading…")
            for _ in 0..<120 {
                let ids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
                if ids.contains("com.apple.dock") && ids.contains("com.apple.finder") { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard gen == generation else { return }
            }
        }
        // 0b. Wait until the physical display reports a stable resolution, refresh rate and HDR state
        //     (6 s for automatic starts, 2 s when you start it yourself)
        setStatus("Waiting for the display to be ready…")
        guard let panel = await waitForStablePanel(cfg, seconds: userInitiated ? 10 : 60,
                                                   stableSamples: userInitiated ? 4 : 12) else {
            return fail("the physical display isn't ready (no stable signal yet)", gen: gen, soft: true)
        }
        guard gen == generation else { return }
        setStatus("Starting…")
        for s in NSScreen.screens {
            let id = screenID(s), (w, h) = nativePixels(id)
            log("display \(id) [\(s.localizedName)] \(w)×\(h) uuid=\(displayUUID(id)) vendor=\(CGDisplayVendorNumber(id)) model=\(CGDisplayModelNumber(id))")
        }
        log("panel \(panel.w)×\(panel.h) @ \(Int(panel.hz)) Hz, HDR headroom \(panel.edr), userInitiated=\(userInitiated)")
        let puuid = panel.uuid
        let (pw, ph) = (panel.w, panel.h)
        // Settings were made for a particular panel resolution; don't build at a different one by surprise.
        if userInitiated, cfg.refW > 0, (cfg.refW != pw || cfg.refH != ph) {
            let a = NSAlert()
            a.messageText = "The display resolution has changed"
            a.informativeText = "The display is now \(pw)×\(ph), but your settings were made for \(cfg.refW)×\(cfg.refH). If the screen just flickered or went green, the HDMI connection may not have recovered (try unplugging and replugging the cable). Build the virtual screen anyway?"
            a.addButton(withTitle: "Cancel")
            a.addButton(withTitle: "Build Anyway")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertSecondButtonReturn else {
                return cancel("Cancelled: the display resolution differs from your saved settings.", gen: gen)
            }
            guard gen == generation else { return }
        }
        if !userInitiated, cfg.refW > 0, (cfg.refW != pw || cfg.refH != ph) {
            return fail("the display is running at \(pw)×\(ph), but your settings were made for \(cfg.refW)×\(cfg.refH). Open Settings and press Apply to confirm.", gen: gen, soft: true)
        }
        let g = geometry(cfg, panelW: pw, panelH: ph)
        lastAttempt = "\(g.vw)×\(g.vh) on a \(pw)×\(ph) panel, HiDPI \(cfg.hiDPI ? "on" : "off"), \(cfg.refresh) Hz"

        // 1. Virtual display
        guard let desc = CGVirtualDisplayDescriptor() else { return fail("descriptor init failed", gen: gen) }
        desc.queue = DispatchQueue.main
        desc.name = "Usable Display"
        desc.vendorID = virtualVendorTag
        desc.productID = 0x0001
        // New identity every time, so macOS cannot re-apply a saved (possibly mirrored) layout from an earlier run
        desc.serialNum = UInt32.random(in: 1...0x0FFF_FFFF)
        desc.maxPixelsWide = UInt32(g.vw)
        desc.maxPixelsHigh = UInt32(g.vh)
        desc.sizeInMillimeters = CGSize(width: 25.4 * Double(g.vw) / 110.0, height: 25.4 * Double(g.vh) / 110.0)
        guard let vd = CGVirtualDisplay(descriptor: desc) else { return fail("virtual display init failed", gen: gen) }
        let div = cfg.hiDPI ? 2 : 1
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = cfg.hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt32(g.vw / div), height: UInt32(g.vh / div),
                                               refreshRate: Double(cfg.refresh))]
        guard vd.apply(settings) else { return fail("applySettings failed", gen: gen) }
        vdisplay = vd

        // 2. Wait for macOS to publish it
        var vScreen: NSScreen?
        for _ in 0..<40 {
            vScreen = NSScreen.screens.first { screenID($0) == vd.displayID }
            if vScreen != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard gen == generation, let vs = vScreen else { return fail("virtual display never appeared", gen: gen) }
        log("stage 1 ok: virtual display present")
        for line in describeOnlineDisplays() { log("online (after virtual display): \(line)") }
        if breakMirrorSets() {
            log("stage 1: a display mirror set appeared and was switched off")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard gen == generation else { return }
        }
        if cfg.debugStage <= 1 { return debugStop(1, gen: gen) }

        // 3. Make the virtual display the main one; park the physical one at its far corner
        //    (corner contact only, so the cursor rarely wanders onto the overlay).
        guard gen == generation, let cur = await waitForStablePanel(cfg, uuid: puuid, seconds: 10) else {
            return fail("the physical display went away when the virtual screen was created", gen: gen)
        }
        log("layout: begin (panel \(cur.w)×\(cur.h) @ \(Int(cur.hz)) Hz is stable, virtual screen \(Int(vs.frame.width))×\(Int(vs.frame.height)) pt)")
        var cref: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cref) == .success else {
            return fail("could not begin the display layout change", gen: gen)
        }
        CGConfigureDisplayOrigin(cref, vd.displayID, 0, 0)
        CGConfigureDisplayOrigin(cref, cur.id, Int32(vs.frame.width), Int32(vs.frame.height))
        let t0 = Date()
        let err = CGCompleteDisplayConfiguration(cref, .forSession)
        log("layout: transaction returned \(err.rawValue) after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        guard err == .success else {
            return fail("macOS rejected the display layout change (error \(err.rawValue))", gen: gen)
        }

        log("layout: waiting for the physical display to settle again")
        // The TV may need a few seconds to re-lock its signal. Find it again by UUID (its ID can change)
        // and make sure it is back at the same resolution before drawing on it.
        guard gen == generation, let back = await waitForStablePanel(cfg, uuid: puuid, seconds: 20),
              back.w == pw, back.h == ph,
              let screen = NSScreen.screens.first(where: { screenID($0) == back.id }) else {
            return fail("the physical display did not come back at \(pw)×\(ph) after the virtual screen was added", gen: gen)
        }
        log("stage 2 ok: layout applied, physical display is back")
        if cfg.debugStage <= 2 { return debugStop(2, gen: gen) }

        // 4. Black overlay window on the physical display, with the content layer inset
        let scale = screen.backingScaleFactor
        let win = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        win.level = .screenSaver
        win.backgroundColor = .black
        win.isOpaque = true
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        let layer = CALayer()
        layer.frame = CGRect(x: CGFloat(g.x) / scale,
                             y: CGFloat(ph - g.y - g.vh) / scale,
                             width: CGFloat(g.vw) / scale,
                             height: CGFloat(g.vh) / scale)
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer.contentsGravity = .resize
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(layer)
        win.contentView = view
        win.setFrame(screen.frame, display: true)
        win.orderFrontRegardless()
        window = win
        sink.layer = layer
        log("stage 3 ok: black overlay shown")
        if cfg.debugStage <= 3 { return debugStop(3, gen: gen) }

        // 5. Capture the virtual display
        do {
            var target: SCDisplay?
            for _ in 0..<20 {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                target = content.displays.first { $0.displayID == vd.displayID }
                if target != nil { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard gen == generation, let d = target else { return fail("capture target not found", gen: gen) }
            let sc = SCStreamConfiguration()
            sc.width = g.vw
            sc.height = g.vh
            sc.pixelFormat = kCVPixelFormatType_32BGRA
            sc.showsCursor = true
            sc.queueDepth = 5
            sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(cfg.refresh))
            let st = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: sc, delegate: nil)
            try st.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "usabledisplay.capture"))
            try await st.startCapture()
            if gen == generation {
                stream = st
                established = true
                if cfg.confineMouse { startCursorGuard() }
                if (userInitiated || cfg.refW == 0) && (cfg.refW != pw || cfg.refH != ph) {
                    Settings.shared.cfg.refW = pw
                    Settings.shared.cfg.refH = ph
                }
                UserDefaults.standard.set(false, forKey: blockedKey)
                setStatus("Running")
                log("stage 4 ok: capturing")
            } else { try? await st.stopCapture() }
        } catch {
            fail("capture error: \(error)", gen: gen)
        }
    }
}

// MARK: - Settings UI

enum SettingsPage: String, CaseIterable, Identifiable {
    case display, size, aspect, virtual, startup, troubleshooting
    var id: String { rawValue }
    var title: String {
        switch self {
        case .display: return "Display"
        case .size: return "Size & Borders"
        case .aspect: return "Aspect Ratio"
        case .virtual: return "Virtual Screen"
        case .startup: return "Startup"
        case .troubleshooting: return "Troubleshooting"
        }
    }
    var symbol: String {
        switch self {
        case .display: return "display"
        case .size: return "arrow.up.left.and.arrow.down.right"
        case .aspect: return "aspectratio"
        case .virtual: return "rectangle.on.rectangle"
        case .startup: return "power"
        case .troubleshooting: return "wrench.and.screwdriver"
        }
    }
    var color: Color {
        switch self {
        case .display: return .blue
        case .size: return .orange
        case .aspect: return .purple
        case .virtual: return .teal
        case .startup: return .green
        case .troubleshooting: return .gray
        }
    }
}

struct SidebarIcon: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(color))
    }
}

struct SettingsView: View {
    @ObservedObject var s = Settings.shared
    @State private var page: SettingsPage? = .display
    @State private var uniform = 0
    @State private var applied = Settings.shared.cfg   // what the running virtual screen was last built from
    var onApply: () -> Void

    // Settings are saved as you type; they only take effect when you press Apply.
    var pending: Bool {
        var a = applied
        a.refW = s.cfg.refW; a.refH = s.cfg.refH; a.enabled = s.cfg.enabled   // changed by the app itself
        return a != s.cfg
    }

    var summary: String {
        guard let scr = pickPhysical(s.cfg) else { return "No physical display found" }
        let (pw, ph) = nativePixels(screenID(scr))
        let g = geometry(s.cfg, panelW: pw, panelH: ph)
        let eq = String(format: "%.1f", s.cfg.panelInches * Double(g.vw) / Double(pw))
        return "Display:          \(scr.localizedName)\nPhysical panel:   \(pw) × \(ph) px\nVirtual screen:   \(g.vw) × \(g.vh) px\nPosition:         \(g.x) px from left, \(g.y) px from top\nEquivalent size:  ≈ \(eq) inch"
    }

    var oneLine: String {
        guard let scr = pickPhysical(s.cfg) else { return "No physical display found" }
        let (pw, ph) = nativePixels(screenID(scr))
        let g = geometry(s.cfg, panelW: pw, panelH: ph)
        let eq = String(format: "%.1f", s.cfg.panelInches * Double(g.vw) / Double(pw))
        return "\(pw)×\(ph) panel  →  \(g.vw)×\(g.vh) virtual screen  ·  ≈ \(eq) inch"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $page) {
                    ForEach(SettingsPage.allCases) { p in
                        HStack(spacing: 8) {
                            SidebarIcon(symbol: p.symbol, color: p.color)
                            Text(p.title)
                        }
                        .padding(.vertical, 2)
                        .tag(p)
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 200)

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    Text((page ?? .display).title)
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 2)
                    ScrollView {
                        Form { pageContent(page ?? .display) }
                            .formStyle(.grouped)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Divider()

            HStack(spacing: 12) {
                Text(oneLine)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                if pending {
                    Text("Changes not applied yet").font(.caption).foregroundStyle(.orange)
                }
                Button("Apply") {
                    NSApp.keyWindow?.makeFirstResponder(nil)   // commit any text field being edited
                    DispatchQueue.main.async {
                        applied = s.cfg
                        onApply()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(minWidth: 700, minHeight: 480)
    }

    // MARK: Pages

    @ViewBuilder
    func pageContent(_ p: SettingsPage) -> some View {
        switch p {
        case .display: displayPage
        case .size: sizePage
        case .aspect: aspectPage
        case .virtual: virtualPage
        case .startup: startupPage
        case .troubleshooting: troubleshootingPage
        }
    }

    @ViewBuilder var displayPage: some View {
        Section {
            Picker("Display", selection: $s.cfg.displayUUID) {
                Text("Automatic (largest display)").tag("")
                ForEach(physicalScreens(), id: \.self) { sc in
                    Text(displayLabel(sc)).tag(displayUUID(screenID(sc)))
                }
            }
            dblRow("Real panel diagonal", $s.cfg.panelInches, unit: "inch")
        } header: { Text("Physical display") }
          footer: { Text("The real size of your TV or monitor. Only used to convert inches to pixels.") }

        Section {
            Text(summary)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        } header: { Text("Current result") }
    }

    @ViewBuilder var sizePage: some View {
        Section {
            Picker("Mode", selection: $s.cfg.sizeMode) {
                Text("Border pixels").tag("borders")
                Text("Screen size").tag("diagonal")
            }
            .pickerStyle(.segmented)
            if s.cfg.sizeMode == "diagonal" {
                dblRow("Emulated screen diagonal", $s.cfg.targetInches, unit: "inch")
            }
        } header: { Text("Image size") }
          footer: {
            Text(s.cfg.sizeMode == "diagonal"
                 ? "The image is shrunk to look like a screen of this size and centered on the panel."
                 : "The image fills the panel minus the black borders set below.")
        }

        Section {
            intRow("Top", $s.cfg.top)
            intRow("Bottom", $s.cfg.bottom)
            intRow("Left", $s.cfg.left)
            intRow("Right", $s.cfg.right)
            LabeledContent("Set all sides") {
                HStack(spacing: 6) {
                    TextField("", value: $uniform, format: .number)
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing).frame(width: 80)
                    Text("px").foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                    Button("Set") {
                        s.cfg.top = uniform; s.cfg.bottom = uniform
                        s.cfg.left = uniform; s.cfg.right = uniform
                    }
                }
            }
        } header: { Text(s.cfg.sizeMode == "diagonal" ? "Dead-pixel reserve" : "Black border") }
          footer: { Text("Pixels on each edge of the physical panel that are kept black (measured in panel pixels).") }
    }

    @ViewBuilder var aspectPage: some View {
        Section {
            Toggle("Keep screen aspect ratio", isOn: $s.cfg.keepAspect)
            Picker("Ratio", selection: $s.cfg.aspectPreset) {
                Text("None (fill area)").tag("free")
                Text("16:9").tag("16:9")
                Text("16:10").tag("16:10")
                Text("4:3").tag("4:3")
                Text("21:9").tag("21:9")
                Text("Custom").tag("custom")
            }
            .disabled(s.cfg.keepAspect)
            if s.cfg.aspectPreset == "custom" && !s.cfg.keepAspect {
                LabeledContent("Custom ratio") {
                    HStack(spacing: 6) {
                        TextField("", value: $s.cfg.customW, format: .number)
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing).frame(width: 60)
                        Text(":")
                        TextField("", value: $s.cfg.customH, format: .number)
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing).frame(width: 60)
                    }
                }
            }
        } footer: {
            Text(s.cfg.keepAspect
                 ? "On: the image keeps your screen's own shape. Extra black is added on the other edges as needed."
                 : "Off: choose any ratio. Extra black is added on the other edges so the image has that shape.")
        }
    }

    @ViewBuilder var virtualPage: some View {
        Section {
            Toggle("HiDPI (2×)", isOn: $s.cfg.hiDPI)
            Picker("Refresh rate", selection: $s.cfg.refresh) {
                Text("30 Hz").tag(30); Text("60 Hz").tag(60); Text("120 Hz").tag(120)
            }
        } footer: { Text("HiDPI makes the interface look half the pixel size (sharper, larger text).") }

        Section {
            Toggle("Keep the mouse on the virtual screen", isOn: $s.cfg.confineMouse)
        } footer: { Text("Stops the pointer wandering onto the black border, where clicks do nothing.") }
    }

    @ViewBuilder var startupPage: some View {
        Section {
            Toggle("Start automatically when the app launches", isOn: $s.cfg.autoStartOnLaunch)
            intRow("Delay after login", $s.cfg.loginDelay, unit: "sec")
            intRow("Delay after wake", $s.cfg.startDelay, unit: "sec")
        } footer: {
            Text("The delays give the display time to settle before the virtual screen is built. If your screen goes green at login, increase the login delay or turn off automatic start and use Re-apply from the menu.")
        }
    }

    @ViewBuilder var troubleshootingPage: some View {
        Section {
            Picker("Setup stage", selection: $s.cfg.debugStage) {
                Text("Full (normal)").tag(4)
                Text("1: virtual display only").tag(1)
                Text("2: + display layout").tag(2)
                Text("3: + black overlay, no capture").tag(3)
            }
        } header: { Text("Setup") }
          footer: { Text("Stops setup early to find which step causes a problem. Leave on Full for normal use.") }

        Section {
            Button("Reset all settings to defaults", role: .destructive) { s.cfg = Config() }
        } footer: { Text("Restores every setting, including the border sizes. Press Apply afterwards to use them.") }
    }

    // MARK: Rows

    func intRow(_ title: String, _ v: Binding<Int>, unit: String = "px") -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: v, format: .number)
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing).frame(width: 80)
                Text(unit).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            }
        }
    }

    func dblRow(_ title: String, _ v: Binding<Double>, unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: v, format: .number)
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing).frame(width: 80)
                Text(unit).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            }
        }
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var settingsWindow: NSWindow?
    var debounce: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let path = Bundle.main.path(forResource: "MenuIcon", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            img.size = NSSize(width: img.size.width / 3, height: img.size.height / 3)  // PNG is @3x
            img.isTemplate = true   // adapts to light/dark menu bar
            item.button?.image = img
        } else {
            item.button?.image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: "UsableDisplay")
        }
        Controller.shared.onStatusChange = { [weak self] in self?.buildMenu() }
        buildMenu()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Controller.shared.systemWillSleep() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Controller.shared.systemDidWake(delay: Double(Settings.shared.cfg.startDelay)) }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
        let cfg = Settings.shared.cfg
        if cfg.autoStartOnLaunch {
            // Shortly after boot (login item) use the longer delay; a manual launch later uses the short one.
            let recentBoot = ProcessInfo.processInfo.systemUptime < 600
            Controller.shared.scheduleAutoStart(after: Double(recentBoot ? cfg.loginDelay : cfg.startDelay))
        } else {
            Controller.shared.setStatus("Idle. Choose Re-apply to start.")
        }
    }

    func applicationWillTerminate(_ n: Notification) { Controller.shared.stop() }

    func buildMenu() {
        let m = NSMenu()
        let st = NSMenuItem(title: "Status: " + String(Controller.shared.status.prefix(80)), action: nil, keyEquivalent: "")
        st.isEnabled = false
        m.addItem(st)
        m.addItem(.separator())
        let en = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        en.state = Settings.shared.cfg.enabled ? .on : .off
        m.addItem(en)
        m.addItem(NSMenuItem(title: "Re-apply", action: #selector(reapply), keyEquivalent: "r"))
        m.addItem(NSMenuItem(title: "Restore Displays (emergency)", action: #selector(restoreDisplays), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for i in m.items where i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
        item.menu = m
    }

    @objc func toggleEnabled() {
        Settings.shared.cfg.enabled.toggle()
        buildMenu()
        Settings.shared.cfg.enabled ? Controller.shared.start() : Controller.shared.stop()
    }
    @objc func reapply() { Controller.shared.start() }
    @objc func restoreDisplays() { Controller.shared.restoreDisplays() }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("login item error: \(error)") }
        buildMenu()
    }
    @objc func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingView(rootView: SettingsView(onApply: { Controller.shared.start() }))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "UsableDisplay Settings"
            w.contentView = host
            w.contentMinSize = NSSize(width: 700, height: 480)
            w.isReleasedWhenClosed = false
            if !w.setFrameUsingName("UsableDisplaySettings") { w.center() }
            _ = w.setFrameAutosaveName("UsableDisplaySettings")
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // Re-run automatically when the HDMI display disconnects/reconnects (e.g. TV power cycle).
    func screensChanged() {
        debounce?.cancel()
        let w = DispatchWorkItem {
            Task { @MainActor in
                let cfg = Settings.shared.cfg
                guard cfg.enabled, !Controller.shared.asleep else { return }
                let present = pickPhysical(cfg) != nil
                if present && !Controller.shared.running && Controller.shared.wantsAutoRestart { Controller.shared.scheduleAutoStart(after: 3) }
                else if !present && Controller.shared.running && Controller.shared.established { Controller.shared.stop(autoRestart: true) }
            }
        }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()   // blocks for the app's lifetime, so `delegate` stays alive
}
