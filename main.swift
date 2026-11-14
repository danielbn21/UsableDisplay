import Cocoa
import SwiftUI
import ScreenCaptureKit
import ServiceManagement

// MARK: - Config (everything user-tunable lives here, nothing hard-coded)

struct Config: Codable, Equatable {
    var top = 16            // black border, in physical panel pixels
    var bottom = 0
    var left = 0
    var right = 0
    var lockMode = "aspect"     // what the user locks: borders | aspect | size
    var anchor = "topLeft"      // corner the screen is aligned to: topLeft | topRight | bottomLeft | bottomRight
    var aspectPreset = "panel"  // panel | 16:9 | 16:10 | 4:3 | 21:9 | custom
    var customW = 16.0
    var customH = 9.0
    var hiDPI = true        // virtual screen at 2x (UI looks like half the pixel size)
    var refresh = 60
    var displayUUID = ""    // "" = automatic (largest display)
    var enabled = true
    var panelInches = 48.0      // real diagonal of the physical panel
    var targetInches = 24.0     // screen diagonal to emulate in the "size" lock
    var startDelay = 10         // seconds to wait after wake before building the virtual screen
    var refW = 0                // panel resolution these settings were last applied at (0 = unknown)
    var refH = 0
    var loginDelay = 30         // seconds to wait when the app starts shortly after boot / login
    var autoStartOnLaunch = true
    var confineMouse = true     // keep the pointer on the virtual screen (stops it escaping onto the black border)
    var debugStage = 4          // 1...4: stop setup early to find a problem step; 4 = full

    /// Decodes saved settings, filling keys added by newer versions with defaults and converting
    /// settings saved before the lock model existed, so an app update never wipes the user's settings.
    static func load(from data: Data) -> Config? {
        guard var saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defData = try? JSONEncoder().encode(Config()),
              var merged = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any] else { return nil }
        if saved["lockMode"] == nil {
            let keep = saved["keepAspect"] as? Bool ?? true
            let preset = saved["aspectPreset"] as? String ?? "panel"
            if (saved["sizeMode"] as? String) == "diagonal" {
                saved["lockMode"] = "size"
                if keep || preset == "free" { saved["aspectPreset"] = "panel" }
            } else if keep {
                saved["lockMode"] = "aspect"; saved["aspectPreset"] = "panel"
            } else if preset == "free" {
                saved["lockMode"] = "borders"
            } else {
                saved["lockMode"] = "aspect"
            }
        }
        if (saved["aspectPreset"] as? String) == "free" { saved["aspectPreset"] = "panel" }
        for (k, v) in saved where merged[k] != nil { merged[k] = v }
        guard let out = try? JSONSerialization.data(withJSONObject: merged) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: out)
    }

    func ratio(panelW: Int, panelH: Int) -> Double {
        switch aspectPreset {
        case "panel":  return Double(panelW) / Double(max(panelH, 1))
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
        if let d = UserDefaults.standard.data(forKey: key), let c = Config.load(from: d) { cfg = c }
        else { cfg = Config() }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(cfg) { UserDefaults.standard.set(d, forKey: key) }
    }
}

// MARK: - Geometry

struct Geometry {
    var pw: Int, ph: Int        // panel size in pixels
    var vw: Int, vh: Int        // virtual screen size in pixels
    var x: Int, y: Int          // offset of the virtual screen from the panel's top-left
    var note: String? = nil     // a warning about the current settings, if any

    // The black borders that result (what you actually get)
    var borderTop: Int { y }
    var borderLeft: Int { x }
    var borderBottom: Int { ph - y - vh }
    var borderRight: Int { pw - x - vw }
    var ratio: Double { Double(vw) / Double(max(vh, 1)) }
    // Offset of the virtual screen's center from the panel's center (+x right, +y down)
    var centerOffsetX: Int { x + vw / 2 - pw / 2 }
    var centerOffsetY: Int { y + vh / 2 - ph / 2 }
}

/// Works out the virtual screen from the settings.
///  - borders: the four borders define the screen; aspect ratio and size follow.
///  - aspect:  the borders define an area; the largest screen of the chosen ratio is placed in it, against the anchor corner or centered.
///  - size:    size (diagonal) and ratio are fixed; the two borders next to the anchor corner position the screen
///             (with center, the four borders define an area and the screen is centered in it).
func geometry(_ c: Config, panelW pw: Int, panelH ph: Int) -> Geometry {
    let minSide = 64
    let isCenter = c.anchor == "center"
    let anchorLeft = isCenter || c.anchor == "topLeft" || c.anchor == "bottomLeft"   // (the Borders lock treats center as top left)
    let anchorTop = isCenter || c.anchor == "topLeft" || c.anchor == "topRight"
    var note: String?
    func even(_ v: Int) -> Int { max(v - v % 2, 2) }   // even sizes keep 2x HiDPI exact

    let aw = pw - c.left - c.right      // area the borders leave
    let ah = ph - c.top - c.bottom
    let areaW = max(aw, minSide), areaH = max(ah, minSide)

    var w: Int, h: Int, x: Int, y: Int
    switch c.lockMode {
    case "borders":
        if aw < 640 || ah < 360 { note = "The borders leave very little room for the screen." }
        w = even(min(areaW, pw)); h = even(min(areaH, ph))
        x = anchorLeft ? c.left : pw - c.right - w
        y = anchorTop ? c.top : ph - c.bottom - h
    case "aspect":
        if aw < 640 || ah < 360 { note = "The borders leave very little room for the screen." }
        let r = c.ratio(panelW: pw, panelH: ph)
        if Double(areaW) / Double(areaH) > r { h = areaH; w = Int(Double(h) * r) }
        else { w = areaW; h = Int(Double(w) / r) }
        w = even(min(max(w, minSide), pw)); h = even(min(max(h, minSide), ph))
        // aligned to the anchor corner, or centered, inside the area the borders leave
        x = isCenter ? c.left + (areaW - w) / 2 : (anchorLeft ? c.left : c.left + areaW - w)
        y = isCenter ? c.top + (areaH - h) / 2 : (anchorTop ? c.top : c.top + areaH - h)
    default:   // "size"
        let r = c.ratio(panelW: pw, panelH: ph)
        let panelDiag = (Double(pw) * Double(pw) + Double(ph) * Double(ph)).squareRoot()
        let d = panelDiag * max(c.targetInches, 1) / max(c.panelInches, 1)   // same pixel density as the panel
        w = Int(d * r / (1 + r * r).squareRoot())
        h = Int(d / (1 + r * r).squareRoot())
        if w > pw || h > ph {
            let f = min(Double(pw) / Double(max(w, 1)), Double(ph) / Double(max(h, 1)))
            w = Int(Double(w) * f); h = Int(Double(h) * f)
            note = "That screen size does not fit on the panel, so it was reduced."
        }
        w = even(max(w, minSide)); h = even(max(h, minSide))
        x = isCenter ? c.left + (areaW - w) / 2 : (anchorLeft ? c.left : pw - c.right - w)
        y = isCenter ? c.top + (areaH - h) / 2 : (anchorTop ? c.top : ph - c.bottom - h)
        if x < 0 || y < 0 || x + w > pw || y + h > ph {
            note = "The screen does not fit with those borders, so it was moved to fit."
        }
    }
    x = min(max(x, 0), max(pw - w, 0))
    y = min(max(y, 0), max(ph - h, 0))
    return Geometry(pw: pw, ph: ph, vw: w, vh: h, x: x, y: y, note: note)
}

func equivalentInches(_ c: Config, _ g: Geometry) -> Double {
    c.panelInches * hypot(Double(g.vw), Double(g.vh)) / max(hypot(Double(g.pw), Double(g.ph)), 1)
}

func ratioName(_ r: Double) -> String {
    let known: [(String, Double)] = [("16:9", 16.0 / 9), ("16:10", 1.6), ("4:3", 4.0 / 3), ("21:9", 21.0 / 9),
                                     ("32:9", 32.0 / 9), ("3:2", 1.5), ("5:4", 1.25), ("1:1", 1.0)]
    if let k = known.first(where: { abs($0.1 - r) / $0.1 < 0.01 }) { return k.0 }
    return String(format: "%.2f:1", r)
}

func signed(_ v: Int) -> String { String(format: "%+d", v) }

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
    private func log(_ s: String) { NSLog("UsableArea: \(s)") }

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
                a.informativeText = "Enable UsableArea in System Settings > Privacy & Security > Screen & System Audio Recording, then choose 'Re-apply' from the menu bar icon."
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

    private var runNote = ""

    private func makeVirtualDisplay(_ g: Geometry, hiDPI: Bool, maxW: Int, maxH: Int, refresh: Int) -> CGVirtualDisplay? {
        guard let desc = CGVirtualDisplayDescriptor() else { return nil }
        desc.queue = DispatchQueue.main
        desc.name = "Usable Display"
        desc.vendorID = virtualVendorTag
        desc.productID = 0x0001
        // New identity every time, so macOS cannot re-apply a saved (possibly mirrored) layout from an earlier run
        desc.serialNum = UInt32.random(in: 1...0x0FFF_FFFF)
        desc.maxPixelsWide = UInt32(maxW)
        desc.maxPixelsHigh = UInt32(maxH)
        desc.sizeInMillimeters = CGSize(width: 25.4 * Double(g.vw) / 110.0, height: 25.4 * Double(g.vh) / 110.0)
        guard let vd = CGVirtualDisplay(descriptor: desc) else { return nil }
        let div = hiDPI ? 2 : 1
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt32(g.vw / div), height: UInt32(g.vh / div),
                                               refreshRate: Double(refresh))]
        guard vd.apply(settings) else { return nil }
        return vd
    }

    /// NSScreen hides a display that is mirroring another one, so also look at the online display list
    /// and switch mirroring off if the new display is hidden.
    private func waitForVirtualScreen(_ vd: CGVirtualDisplay, seconds: Int) async -> NSScreen? {
        for i in 0..<(seconds * 10) {
            if let s = NSScreen.screens.first(where: { screenID($0) == vd.displayID }) { return s }
            if i >= 5 && i % 10 == 5, onlineDisplayIDs().contains(vd.displayID), breakMirrorSets() {
                log("the virtual display was hidden in a mirror set; mirroring switched off")
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
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

        // 1+2. Create the virtual display and wait for macOS to publish it. macOS has refused some shapes
        //      (very wide ones, in our tests), so if the first try does not appear, try again with other parameters.
        runNote = ""
        var attempts: [(name: String, hiDPI: Bool, maxW: Int, maxH: Int)] = [
            ("as requested", cfg.hiDPI, g.vw, g.vh),
            ("larger maximum size", cfg.hiDPI, max(g.vw, pw), max(g.vh, ph))
        ]
        if cfg.hiDPI { attempts.append(("without HiDPI", false, max(g.vw, pw), max(g.vh, ph))) }
        var created: CGVirtualDisplay?
        var vScreen: NSScreen?
        for (n, att) in attempts.enumerated() {
            guard gen == generation else { return }
            if n > 0 {
                vdisplay = nil                                   // remove the previous attempt first
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            guard let d = makeVirtualDisplay(g, hiDPI: att.hiDPI, maxW: att.maxW, maxH: att.maxH, refresh: cfg.refresh) else {
                log("virtual display attempt '\(att.name)': macOS refused the settings")
                continue
            }
            vdisplay = d
            if let s = await waitForVirtualScreen(d, seconds: 5) {
                created = d; vScreen = s
                if att.hiDPI != cfg.hiDPI { runNote = "HiDPI is off: macOS refused the HiDPI mode for this shape" }
                log("virtual display attempt '\(att.name)' worked (\(g.vw)×\(g.vh), HiDPI \(att.hiDPI))")
                break
            }
            log("virtual display attempt '\(att.name)' did not appear")
        }
        if vScreen == nil {
            for line in describeOnlineDisplays() { log("online (virtual display missing): \(line)") }
        }
        guard gen == generation, let vd = created, let vs = vScreen else {
            return fail("virtual display never appeared (tried \(attempts.count) variants)", gen: gen)
        }
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
            try st.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "usablearea.capture"))
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
                setStatus(runNote.isEmpty ? "Running" : "Running (\(runNote))")
                log("stage 4 ok: capturing")
            } else { try? await st.stopCapture() }
        } catch {
            fail("capture error: \(error)", gen: gen)
        }
    }
}

// MARK: - Settings UI

enum SettingsPage: String, CaseIterable, Identifiable {
    case display, size, virtual, startup, troubleshooting
    var id: String { rawValue }
    var title: String {
        switch self {
        case .display: return "Display"
        case .size: return "Size & Borders"
        case .virtual: return "Virtual Screen"
        case .startup: return "Startup"
        case .troubleshooting: return "Troubleshooting"
        }
    }
    var symbol: String {
        switch self {
        case .display: return "display"
        case .size: return "arrow.up.left.and.arrow.down.right"
        case .virtual: return "rectangle.on.rectangle"
        case .startup: return "power"
        case .troubleshooting: return "wrench.and.screwdriver"
        }
    }
    var color: Color {
        switch self {
        case .display: return .blue
        case .size: return .orange
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

/// Mini picture of the panel: black = panel, blue = the virtual screen, numbers = resulting black borders.
struct ScreenDiagram: View {
    let g: Geometry
    let lock: String
    let anchor: String

    func label(_ v: Int) -> some View {
        Text("\(v) px").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
    }

    var body: some View {
        GeometryReader { geo in
            let sideW: CGFloat = 64, sideH: CGFloat = 18
            let maxW = max(geo.size.width - 2 * sideW, 50)
            let maxH = max(geo.size.height - 2 * sideH, 50)
            let scale = min(maxW / CGFloat(max(g.pw, 1)), maxH / CGFloat(max(g.ph, 1)))
            let panelW = CGFloat(g.pw) * scale, panelH = CGFloat(g.ph) * scale
            let ox = (geo.size.width - panelW) / 2, oy = (geo.size.height - panelH) / 2
            let rx = ox + CGFloat(g.x) * scale, ry = oy + CGFloat(g.y) * scale
            let rw = CGFloat(g.vw) * scale, rh = CGFloat(g.vh) * scale
            let ax = anchor == "center" ? rx + rw / 2 : (anchor.hasSuffix("Left") ? rx : rx + rw)
            let ay = anchor == "center" ? ry + rh / 2 : (anchor.hasPrefix("top") ? ry : ry + rh)
            ZStack {
                Rectangle().fill(Color.black)
                    .frame(width: panelW, height: panelH)
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.7), lineWidth: 1))
                    .position(x: ox + panelW / 2, y: oy + panelH / 2)
                Rectangle().fill(Color.accentColor.opacity(0.35))
                    .frame(width: rw, height: rh)
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                    .overlay(
                        VStack(spacing: 1) {
                            Text("\(g.vw) × \(g.vh)").font(.caption.weight(.semibold)).monospacedDigit()
                            Text(ratioName(g.ratio)).font(.caption2)
                        }
                        .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.5)
                    )
                    .position(x: rx + rw / 2, y: ry + rh / 2)
                if lock != "borders" {
                    Circle().fill(Color.white).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                        .position(x: ax, y: ay)
                }
                label(g.borderTop).position(x: geo.size.width / 2, y: oy - 10)
                label(g.borderBottom).position(x: geo.size.width / 2, y: oy + panelH + 10)
                label(g.borderLeft).position(x: ox - sideW / 2, y: geo.size.height / 2)
                label(g.borderRight).position(x: ox + panelW + sideW / 2, y: geo.size.height / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

struct ScreenInfo {
    var name: String
    var g: Geometry
    var panelHz: Double
    var inches: Double
}

struct SettingsView: View {
    enum Edge { case top, bottom, left, right }

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

    var info: ScreenInfo? {
        guard let scr = pickPhysical(s.cfg) else { return nil }
        let id = screenID(scr)
        let (pw, ph) = nativePixels(id)
        let g = geometry(s.cfg, panelW: pw, panelH: ph)
        return ScreenInfo(name: scr.localizedName, g: g,
                          panelHz: CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0,
                          inches: equivalentInches(s.cfg, g))
    }

    func refreshText(_ i: ScreenInfo) -> String {
        var t = "\(s.cfg.refresh) Hz"
        let tv = Int(i.panelHz.rounded())
        if tv > 0 && tv != s.cfg.refresh { t += " (TV runs at \(tv) Hz)" }
        return t
    }

    var oneLine: String {
        guard let i = info else { return "No physical display found" }
        let g = i.g
        let hidpi = s.cfg.hiDPI ? "HiDPI on (UI looks like \(g.vw / 2)×\(g.vh / 2))" : "HiDPI off"
        return [
            "\(g.pw)×\(g.ph) panel → \(g.vw)×\(g.vh) virtual screen",
            "≈ \(String(format: "%.1f", i.inches)) inch",
            refreshText(i),
            hidpi,
            "center offset \(signed(g.centerOffsetX)), \(signed(g.centerOffsetY)) px"
        ].joined(separator: "  ·  ")
    }

    var summary: String {
        guard let i = info else { return "No physical display found" }
        let g = i.g
        return """
        Display:          \(i.name)
        Physical panel:   \(g.pw) × \(g.ph) px
        Virtual screen:   \(g.vw) × \(g.vh) px  (\(ratioName(g.ratio)))
        Position:         \(g.x) px from left, \(g.y) px from top
        Center offset:    \(signed(g.centerOffsetX)), \(signed(g.centerOffsetY)) px  (x, y)
        Refresh rate:     \(refreshText(i))
        HiDPI:            \(s.cfg.hiDPI ? "on, UI looks like \(g.vw / 2) × \(g.vh / 2)" : "off")
        Equivalent size:  ≈ \(String(format: "%.1f", i.inches)) inch
        """
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
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
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
        .frame(minWidth: 700, minHeight: 420)
    }

    // MARK: Pages

    @ViewBuilder
    func pageContent(_ p: SettingsPage) -> some View {
        switch p {
        case .display: displayPage
        case .size: sizePage
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

    // MARK: Size & Borders

    var lockHelp: String {
        switch s.cfg.lockMode {
        case "borders": return "You set the four borders. The screen size and aspect ratio are calculated from them."
        case "size": return "You set the screen size and aspect ratio. Only the two borders next to the chosen corner are used, to position the screen, and the other two are calculated. With Center, all four borders mark an area and the screen is centered in it."
        default: return "You set the aspect ratio. The borders mark the area the screen may use, and the largest screen of that ratio is placed in it, against the chosen corner or centered."
        }
    }

    var bordersHeader: String {
        s.cfg.lockMode == "size" && s.cfg.anchor != "center" ? "Position (borders)" : "Black borders"
    }

    var bordersFooter: String {
        guard let g = info?.g else { return "" }
        switch s.cfg.lockMode {
        case "borders": return "Pixels on each edge of the panel that stay black."
        case "size" where s.cfg.anchor != "center":
            return "The borders next to the chosen corner position the screen. The other two (greyed) are calculated."
        default: return "These borders mark the area the screen may use. Resulting black borders: top \(g.borderTop), bottom \(g.borderBottom), left \(g.borderLeft), right \(g.borderRight) px."
        }
    }

    @ViewBuilder var sizePage: some View {
        Section {
            if let i = info {
                ScreenDiagram(g: i.g, lock: s.cfg.lockMode, anchor: s.cfg.anchor)
                    .frame(height: 170)
                if let n = i.g.note {
                    Label(n, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("No physical display found").foregroundStyle(.secondary)
            }
        } header: { Text("Preview") }

        Section {
            Picker("Lock", selection: $s.cfg.lockMode) {
                Text("Borders").tag("borders")
                Text("Aspect ratio").tag("aspect")
                Text("Size").tag("size")
            }
            .pickerStyle(.segmented)
        } header: { Text("What stays fixed") }
          footer: { Text(lockHelp) }

        Section {
            if s.cfg.lockMode == "borders" {
                LabeledContent("Aspect ratio (calculated)") {
                    if let g = info?.g {
                        Text("\(ratioName(g.ratio))  (\(String(format: "%.3f", g.ratio)) : 1)").foregroundStyle(.secondary)
                    }
                }
            } else {
                Picker("Aspect ratio", selection: $s.cfg.aspectPreset) {
                    Text("Match panel").tag("panel")
                    Text("16:9").tag("16:9")
                    Text("16:10").tag("16:10")
                    Text("4:3").tag("4:3")
                    Text("21:9").tag("21:9")
                    Text("Custom").tag("custom")
                }
                if s.cfg.aspectPreset == "custom" {
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
            }
            if s.cfg.lockMode == "size" {
                dblRow("Screen diagonal", $s.cfg.targetInches, unit: "inch")
            } else if let i = info {
                LabeledContent("Screen size (calculated)") {
                    Text("\(i.g.vw) × \(i.g.vh) px  ·  ≈ \(String(format: "%.1f", i.inches)) inch").foregroundStyle(.secondary)
                }
            }
            if s.cfg.lockMode != "borders" {
                Picker("Align to", selection: $s.cfg.anchor) {
                    Text("Center").tag("center")
                    Text("Top left").tag("topLeft")
                    Text("Top right").tag("topRight")
                    Text("Bottom left").tag("bottomLeft")
                    Text("Bottom right").tag("bottomRight")
                }
            }
        } header: { Text("Shape and size") }

        Section {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow { borderCell("Top", .top); borderCell("Bottom", .bottom) }
                GridRow { borderCell("Left", .left); borderCell("Right", .right) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if s.cfg.lockMode != "size" || s.cfg.anchor == "center" {
                LabeledContent("Set all sides") {
                    HStack(spacing: 6) {
                        TextField("", value: $uniform, format: .number)
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing).frame(width: 72)
                        Text("px").foregroundStyle(.secondary)
                        Button("Set") {
                            s.cfg.top = uniform; s.cfg.bottom = uniform
                            s.cfg.left = uniform; s.cfg.right = uniform
                        }
                    }
                }
            }
        } header: { Text(bordersHeader) }
          footer: { Text(bordersFooter) }
    }

    func edgeBinding(_ e: Edge) -> Binding<Int> {
        Binding(
            get: {
                switch e {
                case .top: return s.cfg.top
                case .bottom: return s.cfg.bottom
                case .left: return s.cfg.left
                case .right: return s.cfg.right
                }
            },
            set: { v in
                switch e {
                case .top: s.cfg.top = v
                case .bottom: s.cfg.bottom = v
                case .left: s.cfg.left = v
                case .right: s.cfg.right = v
                }
            })
    }

    /// In the "size" lock only the two borders next to the anchor corner are inputs; the others are calculated.
    func editable(_ e: Edge) -> Bool {
        guard s.cfg.lockMode == "size", s.cfg.anchor != "center" else { return true }
        let leftAnchor = s.cfg.anchor.hasSuffix("Left"), topAnchor = s.cfg.anchor.hasPrefix("top")
        switch e {
        case .left: return leftAnchor
        case .right: return !leftAnchor
        case .top: return topAnchor
        case .bottom: return !topAnchor
        }
    }

    func resulting(_ e: Edge) -> Int {
        guard let g = info?.g else { return 0 }
        switch e {
        case .top: return g.borderTop
        case .bottom: return g.borderBottom
        case .left: return g.borderLeft
        case .right: return g.borderRight
        }
    }

    @ViewBuilder
    func borderCell(_ title: String, _ e: Edge) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 56, alignment: .leading)
            if editable(e) {
                TextField("", value: edgeBinding(e), format: .number)
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing).frame(width: 72)
            } else {
                Text("\(resulting(e))").monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            }
            Text("px").foregroundStyle(.secondary)
        }
    }

    // MARK: Other pages

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
            item.button?.image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: "UsableArea")
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
            let vis = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(820, vis.width - 40), height: min(800, vis.height - 80)),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "UsableArea Settings"
            w.contentView = host
            w.contentMinSize = NSSize(width: 700, height: 420)
            w.isReleasedWhenClosed = false
            if !w.setFrameUsingName("UsableAreaSettings2") { w.center() }
            _ = w.setFrameAutosaveName("UsableAreaSettings2")
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
