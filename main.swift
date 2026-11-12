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
           var c = try? JSONDecoder().decode(Config.self, from: d) {
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
    NSScreen.screens.filter { CGDisplayVendorNumber(screenID($0)) != virtualVendorTag }
}
func nativePixels(_ id: CGDirectDisplayID) -> (Int, Int) {
    if let m = CGDisplayCopyDisplayMode(id) { return (m.pixelWidth, m.pixelHeight) }
    return (CGDisplayPixelsWide(id), CGDisplayPixelsHigh(id))
}
func pickPhysical(_ c: Config) -> NSScreen? {
    let list = physicalScreens()
    if !c.displayUUID.isEmpty, let s = list.first(where: { displayUUID(screenID($0)) == c.displayUUID }) { return s }
    return list.first
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
    private var lastAttempt = ""
    private var generation = 0
    private var vdisplay: CGVirtualDisplay?
    private var stream: SCStream?
    private var window: NSWindow?
    private let sink = FrameSink()

    func start() {
        stop()
        let cfg = Settings.shared.cfg
        guard cfg.enabled else { return }
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            let a = NSAlert()
            a.messageText = "Screen Recording permission needed"
            a.informativeText = "Enable UsableDisplay in System Settings > Privacy & Security > Screen & System Audio Recording, then choose 'Re-apply' from the menu bar icon."
            a.runModal()
            return
        }
        running = true
        generation += 1
        let gen = generation
        Task { await run(cfg, gen: gen) }
    }

    func stop(autoRestart: Bool = false) {
        generation += 1
        running = false
        wantsAutoRestart = autoRestart
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
        window?.orderOut(nil)
        window = nil
        vdisplay = nil   // releasing destroys the virtual display
    }

    private func fail(_ msg: String, gen: Int) {
        guard gen == generation else { return }   // a newer run already took over
        NSLog("UsableDisplay: \(msg) [\(lastAttempt)]")
        stop()                                    // also disables auto-restart, so no retry loop
        let a = NSAlert()
        a.messageText = "Couldn't set up the virtual screen"
        a.informativeText = "\(msg)\nRequested: \(lastAttempt)\n\nTry a different border size or aspect ratio in Settings and press Apply. The app will not retry on its own."
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    private func run(_ cfg: Config, gen: Int) async {
        guard let phys = pickPhysical(cfg) else { return fail("no physical display", gen: gen) }
        let pid = screenID(phys)
        let (pw, ph) = nativePixels(pid)
        let g = geometry(cfg, panelW: pw, panelH: ph)
        lastAttempt = "\(g.vw)×\(g.vh) on a \(pw)×\(ph) panel, HiDPI \(cfg.hiDPI ? "on" : "off"), \(cfg.refresh) Hz"

        // 1. Virtual display
        guard let desc = CGVirtualDisplayDescriptor() else { return fail("descriptor init failed", gen: gen) }
        desc.queue = DispatchQueue.main
        desc.name = "Usable Display"
        desc.vendorID = virtualVendorTag
        desc.productID = 0x0001
        desc.serialNum = 1
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

        // 3. Make the virtual display the main one; park the physical one at its far corner
        //    (corner contact only, so the cursor rarely wanders onto the overlay).
        var cref: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cref)
        CGConfigureDisplayOrigin(cref, vd.displayID, 0, 0)
        CGConfigureDisplayOrigin(cref, pid, Int32(vs.frame.width), Int32(vs.frame.height))
        CGCompleteDisplayConfiguration(cref, .forSession)
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard gen == generation,
              let screen = NSScreen.screens.first(where: { screenID($0) == pid }) else { return fail("physical screen lost", gen: gen) }

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
            if gen == generation { stream = st } else { try? await st.stopCapture() }
        } catch {
            fail("capture error: \(error)", gen: gen)
        }
    }
}

// MARK: - Settings UI

struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SettingsView: View {
    @ObservedObject var s = Settings.shared
    @State private var uniform = 0
    var onApply: () -> Void
    var onHeight: (CGFloat) -> Void = { _ in }   // reports the full content height

    var summary: String {
        guard let scr = pickPhysical(s.cfg) else { return "No physical display found" }
        let (pw, ph) = nativePixels(screenID(scr))
        let g = geometry(s.cfg, panelW: pw, panelH: ph)
        let eq = String(format: "%.1f", s.cfg.panelInches * Double(g.vw) / Double(pw))
        return "Physical panel:   \(pw) × \(ph) px\nVirtual screen:   \(g.vw) × \(g.vh) px\nPosition:         \(g.x) px from left, \(g.y) px from top\nEquivalent size:  ≈ \(eq) inch"
    }

    var body: some View {
        ScrollView {
            Form {
                Section {
                    Picker("Display", selection: $s.cfg.displayUUID) {
                        Text("First physical display").tag("")
                        ForEach(physicalScreens(), id: \.self) { sc in
                            Text(sc.localizedName).tag(displayUUID(screenID(sc)))
                        }
                    }
                    dblRow("Real panel diagonal", $s.cfg.panelInches, unit: "inch")
                } header: { Text("Physical display") }
                  footer: { Text("The real size of your TV or monitor. Only used to convert inches to pixels.") }

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
                } header: { Text("Aspect ratio") }
                  footer: {
                    Text(s.cfg.keepAspect
                         ? "On: the image keeps your screen's own shape. Extra black is added on the other edges as needed."
                         : "Off: choose any ratio. Extra black is added on the other edges so the image has that shape.")
                }

                Section {
                    Toggle("HiDPI (2×)", isOn: $s.cfg.hiDPI)
                    Picker("Refresh rate", selection: $s.cfg.refresh) {
                        Text("30 Hz").tag(30); Text("60 Hz").tag(60); Text("120 Hz").tag(120)
                    }
                } header: { Text("Virtual screen") }
                  footer: { Text("HiDPI makes the interface look half the pixel size (sharper, larger text).") }

                Section {
                    Text(summary).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                } header: { Text("Result") }

                HStack {
                    Button("Reset to defaults") { s.cfg = Config() }
                    Spacer()
                    Button("Apply") {
                        NSApp.keyWindow?.makeFirstResponder(nil)   // commit any text field being edited
                        DispatchQueue.main.async { onApply() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .formStyle(.grouped)
            .background(GeometryReader { g in
                Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
            })
        }
        .frame(minWidth: 520, minHeight: 200)
        .onPreferenceChange(ContentHeightKey.self) { onHeight($0) }
    }

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
    var settingsContentHeight: CGFloat = 0
    var userResizedSettings = false
    var settingsNeedsCenter = true
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
        buildMenu()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
        Controller.shared.start()
    }

    func applicationWillTerminate(_ n: Notification) { Controller.shared.stop() }

    func buildMenu() {
        let m = NSMenu()
        let en = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        en.state = Settings.shared.cfg.enabled ? .on : .off
        m.addItem(en)
        m.addItem(NSMenuItem(title: "Re-apply", action: #selector(reapply), keyEquivalent: "r"))
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
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("login item error: \(error)") }
        buildMenu()
    }
    @objc func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingView(rootView: SettingsView(
                onApply: { Controller.shared.start() },
                onHeight: { [weak self] h in self?.settingsContentHeightChanged(h) }))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "UsableDisplay Settings"
            w.contentView = host
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willStartLiveResizeNotification,
                                                   object: w, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.userResizedSettings = true }
            }
            settingsWindow = w
        }
        userResizedSettings = false
        settingsNeedsCenter = true
        fitSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func settingsContentHeightChanged(_ h: CGFloat) {
        guard h > 100 else { return }
        settingsContentHeight = h
        if !userResizedSettings { fitSettingsWindow() }
    }

    /// Size the window to its full content so no scroll bar is needed,
    /// unless the screen is too small, in which case it fills the available height and scrolls.
    func fitSettingsWindow() {
        guard let w = settingsWindow else { return }
        guard settingsContentHeight > 100 else { return }   // wait for the first measurement
        let vis = (w.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let chrome = w.frame.height - w.contentLayoutRect.height          // title bar
        let contentH = min(settingsContentHeight, vis.height - chrome - 24)
        var f = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: w.contentLayoutRect.width, height: contentH))
        if settingsNeedsCenter {
            f.origin = NSPoint(x: vis.midX - f.width / 2, y: vis.midY - f.height / 2)
            settingsNeedsCenter = false
        } else {
            f.origin = NSPoint(x: w.frame.origin.x, y: w.frame.maxY - f.height)   // keep the top edge fixed
        }
        f.origin.y = min(max(f.origin.y, vis.minY), vis.maxY - f.height)
        w.setFrame(f, display: true, animate: false)
    }

    // Re-run automatically when the HDMI display disconnects/reconnects (e.g. TV power cycle).
    func screensChanged() {
        debounce?.cancel()
        let w = DispatchWorkItem {
            Task { @MainActor in
                let cfg = Settings.shared.cfg
                guard cfg.enabled else { return }
                let present = pickPhysical(cfg) != nil
                if present && !Controller.shared.running && Controller.shared.wantsAutoRestart { Controller.shared.start() }
                else if !present && Controller.shared.running { Controller.shared.stop(autoRestart: true) }
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
