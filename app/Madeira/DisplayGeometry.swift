// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Lee Simpson
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// [display-geometry]: the screen as Madeira sees it, logged at launch and on
// every scene geometry or size-class change. The `[device]` line at launch
// (EntitlementChecker.swift) says nothing about a screen that changes while
// the app runs: a foldable (iPhone Duo) folds and unfolds, Stage Manager
// resizes. A line is written only when the reading differs from the scene's
// last one, so repeated callbacks for the same layout stay out of the log.

/// One reading of a scene's display. Foundation-only so the host checks can
/// build it (tests/host/check-duo-display.py).
struct DisplayGeometry: Equatable {
    /// Posted on the main queue when the app's own scene has a new reading. A
    /// fold that stays in landscape changes the scene's size without an
    /// orientation change, so the game layer and the touch controls re-frame
    /// on this as well as on UIDevice.orientationDidChangeNotification.
    static let changed = Notification.Name("MadeiraDisplayGeometryChanged")

    struct Insets: Equatable { var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0 }

    /// The scene in points, as laid out now (Stage Manager or Split View can make it smaller than the screen).
    var scene: CGSize
    /// The scene's UIScreen in points, and UIScreen.nativeBounds in pixels (portrait-up).
    var screen: CGSize
    var native: CGSize
    var scale: CGFloat
    var nativeScale: CGFloat
    var orientation: String
    var horizontal: String
    var vertical: String
    var idiom: String
    var safeArea: Insets
    var screens: Int
    var maxFPS: Int

    private static func size(_ s: CGSize) -> String { "\(Self.number(s.width))x\(Self.number(s.height))" }
    private static func number(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", Double(v))
    }

    /// The log line's fields, without the `[display-geometry] <reason>` prefix.
    var line: String {
        let i = safeArea
        return "scene=\(Self.size(scene))pt screen=\(Self.size(screen))pt native=\(Self.size(native))px"
            + " scale=\(Self.number(scale)) native-scale=\(String(format: "%.3f", Double(nativeScale)))"
            + " orientation=\(orientation) size-class=\(horizontal)/\(vertical) idiom=\(idiom)"
            + " safe-area=\(Self.number(i.top)),\(Self.number(i.left)),\(Self.number(i.bottom)),\(Self.number(i.right))"
            + " screens=\(screens) max-fps=\(maxFPS)"
    }
}

#if canImport(UIKit)
extension DisplayGeometry {
    @MainActor init(_ scene: UIWindowScene) {
        let screen = scene.screen
        let window = scene.keyWindow ?? scene.windows.first
        let insets = window?.safeAreaInsets ?? .zero
        self.init(scene: scene.coordinateSpace.bounds.size,
                  screen: screen.bounds.size,
                  native: screen.nativeBounds.size,
                  scale: screen.scale,
                  nativeScale: screen.nativeScale,
                  orientation: Self.name(scene.effectiveGeometry.interfaceOrientation),
                  horizontal: Self.name(scene.traitCollection.horizontalSizeClass),
                  vertical: Self.name(scene.traitCollection.verticalSizeClass),
                  idiom: Self.name(scene.traitCollection.userInterfaceIdiom),
                  safeArea: Insets(top: insets.top, left: insets.left, bottom: insets.bottom, right: insets.right),
                  screens: UIScreen.screens.count,
                  maxFPS: screen.maximumFramesPerSecond)
    }

    static func name(_ o: UIInterfaceOrientation) -> String {
        switch o {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portrait-upside-down"
        case .landscapeLeft: return "landscape-left"
        case .landscapeRight: return "landscape-right"
        case .unknown: return "unknown"
        @unknown default: return "other(\(o.rawValue))"
        }
    }

    static func name(_ c: UIUserInterfaceSizeClass) -> String {
        switch c {
        case .compact: return "compact"
        case .regular: return "regular"
        case .unspecified: return "unspecified"
        @unknown default: return "other(\(c.rawValue))"
        }
    }

    static func name(_ i: UIUserInterfaceIdiom) -> String {
        switch i {
        case .phone: return "phone"
        case .pad: return "pad"
        case .mac: return "mac"
        case .tv: return "tv"
        case .carPlay: return "carplay"
        case .unspecified: return "unspecified"
        default: return "other(\(i.rawValue))"
        }
    }
}

/// Watches every window scene's effective geometry (KVO) and size classes
/// (trait registration) and writes a `[display-geometry]` line when either
/// changes. Started from MadeiraApp.init, before any scene connects.
@MainActor final class DisplayGeometryMonitor {
    static let shared = DisplayGeometryMonitor()

    private struct Watch {
        let geometry: NSKeyValueObservation
        let traits: UITraitChangeRegistration
    }
    private var watches: [ObjectIdentifier: Watch] = [:]
    private var last: [ObjectIdentifier: DisplayGeometry] = [:]
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let scene = note.object as? UIWindowScene { DisplayGeometryMonitor.shared.watch(scene, reason: "connect") }
            }
        }
        center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let scene = note.object as? UIWindowScene { DisplayGeometryMonitor.shared.report(scene, reason: "activate") }
            }
        }
        center.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let scene = note.object as? UIScene else { return }
                LogStore.shared.log("[display-geometry] disconnect scenes=\(UIApplication.shared.connectedScenes.count)")
                let id = ObjectIdentifier(scene)
                DisplayGeometryMonitor.shared.watches[id] = nil
                DisplayGeometryMonitor.shared.last[id] = nil
            }
        }
        for name in [UIScreen.didConnectNotification, UIScreen.didDisconnectNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    let what = note.name == UIScreen.didConnectNotification ? "screen-connect" : "screen-disconnect"
                    LogStore.shared.log("[display-geometry] \(what) screens=\(UIScreen.screens.count)")
                }
            }
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            watch(scene, reason: "launch")
        }
    }

    private func watch(_ scene: UIWindowScene, reason: String) {
        let id = ObjectIdentifier(scene)
        guard watches[id] == nil else { return }
        // UIKit changes effectiveGeometry on the main thread; the window's safe
        // area follows in the same layout pass, so the line is read just after.
        let geometry = scene.observe(\.effectiveGeometry, options: [.new]) { scene, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DisplayGeometryMonitor.shared.report(scene, reason: "geometry") }
            }
        }
        let traits = scene.registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) {
            (scene: UIWindowScene, _: UITraitCollection) in
            MainActor.assumeIsolated { DisplayGeometryMonitor.shared.report(scene, reason: "traits") }
        }
        watches[id] = Watch(geometry: geometry, traits: traits)
        report(scene, reason: reason)
    }

    func report(_ scene: UIWindowScene, reason: String) {
        let id = ObjectIdentifier(scene)
        if watches[id] == nil { watch(scene, reason: reason); return }
        let now = DisplayGeometry(scene)
        guard last[id] != now else { return }
        last[id] = now
        LogStore.shared.log("[display-geometry] \(reason) \(now.line)")
        // The app's own screen (not an external display's scene) sets the
        // Resolution choices: a foldable's fold changes them, a rotation does not.
        guard scene.session.role == .windowApplication else { return }
        NotificationCenter.default.post(name: DisplayGeometry.changed, object: scene)
        if ResolutionChoices.update(.landscape(points: now.screen, pixels: now.native)) {
            let d = ResolutionChoices.defaultSize()
            LogStore.shared.log("[display-geometry] resolution choices follow the screen: default \(d.w)x\(d.h)"
                + (ResolutionChoices.screen720Value.map { " 720-lines \($0)" } ?? ""))
        }
    }
}

// MARK: Tabletop (iPhone Duo half-folded)

/// iPhone Duo tabletop: half-folded like a laptop, with the hinge across the
/// screen (the inner screen held in portrait), the game goes in the top half
/// and the touch controls in the bottom half. Flat, fully open or closed, and
/// half-folded in landscape (a book) lay out as before.
///
/// The hinge is read with UIHingeInteraction (iOS 27.1). It is made through
/// the Objective-C runtime so the app still builds against an older SDK and
/// runs on older systems, where there is no hinge and nothing changes.
@MainActor final class Tabletop: ObservableObject {
    static let shared = Tabletop()

    /// The controls window is in the bottom half now (TouchControlsHost.attach sets it).
    nonisolated(unsafe) static var splitNow = false

    /// The hinge is partly open (UIHinge.Status.partiallyOpen), as last reported.
    @Published private(set) var halfOpen = false
    private(set) var status = 0
    private(set) var angle: Double = 0
    private var interaction: AnyObject?
    private var tried = false

    /// Above this hinge angle (radians, 180 degrees is flat) a partly open
    /// hinge counts as flat: a phone lying nearly flat on a table is not a laptop.
    static let flatAngle = 160.0 * Double.pi / 180

    /// Whether a screen (or window) of `size` is split now: half-folded, the
    /// hinge across it (taller than wide), and a game session on screen.
    func active(in size: CGSize) -> Bool {
        guard halfOpen, size.height > size.width else { return false }
        let library = LibraryModel.shared
        return library.current != nil || library.preparing != nil
    }

    /// The game's half: the top, down to the hinge (the middle of the screen).
    nonisolated static func gameRect(in b: CGRect) -> CGRect {
        CGRect(x: b.minX, y: b.minY, width: b.width, height: (b.height / 2).rounded(.down))
    }
    /// The controls' half: from the hinge to the bottom.
    nonisolated static func controlsRect(in b: CGRect) -> CGRect {
        let top = gameRect(in: b).maxY
        return CGRect(x: b.minX, y: top, width: b.width, height: b.maxY - top)
    }

    /// Starts reading the hinge from `view`'s hierarchy (a window in the app's scene). Once.
    func install(on view: UIView) {
        guard !tried else { return }
        tried = true
        guard let cls = NSClassFromString("UIHingeInteraction") else {
            LogStore.shared.log("[tabletop] no hinge on this system (UIHingeInteraction needs iOS 27.1)")
            return
        }
        typealias Handler = @convention(block) (AnyObject, AnyObject) -> Void
        typealias InitIMP = @convention(c) (Unmanaged<AnyObject>, Selector, Handler) -> Unmanaged<AnyObject>?
        let handler: Handler = { _, update in
            // Read on the calling (main) thread; only plain values cross over.
            let hinge = (update as? NSObject)?.value(forKey: "hinge") as? NSObject
            let status = (hinge?.value(forKey: "status") as? NSNumber)?.intValue ?? -1
            let angle = (hinge?.value(forKey: "angle") as? NSNumber)?.doubleValue ?? 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Tabletop.shared.hingeChanged(status: status, angle: angle) }
            }
        }
        let initSel = NSSelectorFromString("initWithUpdateHandler:")
        guard let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc")),
              let imp = class_getMethodImplementation(cls, initSel) else { return }
        // init consumes the allocation's +1 and returns +1.
        let make = unsafeBitCast(imp, to: InitIMP.self)
        guard let made = make(allocated, initSel, handler)?.takeRetainedValue(),
              let hinge = made as? UIInteraction else {
            LogStore.shared.log("[tabletop] UIHingeInteraction could not be made")
            return
        }
        interaction = made
        view.addInteraction(hinge)
        LogStore.shared.log("[tabletop] watching the hinge")
    }

    /// status: UIHinge.Status (0 unknown, 1 closed, 2 partly open, 3 fully open), -1 no hinge.
    private func hingeChanged(status: Int, angle: Double) {
        let half = status == 2 && !(angle > Self.flatAngle)
        let degrees = Int((angle * 180 / Double.pi).rounded())
        if status != self.status || abs(angle - self.angle) > 0.09 || half != halfOpen {
            LogStore.shared.log("[tabletop] hinge status=\(status) angle=\(degrees)deg half-open=\(half)")
        }
        self.status = status
        self.angle = angle
        guard half != halfOpen else { return }
        halfOpen = half
        // The game layer and the controls window re-frame (sessionBody follows @Published).
        TouchControlsHost.attach()
        MetalBackedView.refreshDisplayMode(reason: "hinge")
    }
}

// MARK: A desktop big enough for the game's window

/// A desktop session (SLRR: a 1366x768 window, with its frame, on a 1280x720
/// desktop) whose game window reaches past the wine desktop is shown whole
/// (Winios DESKTOP FIT), but the pointer cannot leave the desktop, so the
/// window's right and bottom strips could not be pointed at. While a session
/// runs this checks for that, and once seen it sets the game's Resolution to
/// the smallest standard size that holds the whole window: from the next
/// start the pointer reaches every part of it. The picture does not change.
enum DesktopGrow {
    private static var timer: Timer?
    private static var done = false

    static func start() {
        stop()
        done = false
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { DesktopGrow.check() }
        }
    }
    static func stop() { timer?.invalidate(); timer = nil }

    /// The smallest standard mode holding w x h, or nil.
    nonisolated static func fitting(_ w: Int, _ h: Int) -> (w: Int, h: Int)? {
        GuestDisplay.standardModes.filter { $0.w >= w && $0.h >= h }.min { $0.w * $0.h < $1.w * $1.h }
    }

    @MainActor static func check() {
        guard !done else { return }
        let library = LibraryModel.shared
        guard let id = library.current, var entry = library.entries.first(where: { $0.id == id }) else { return }
        var w: Int32 = 0, h: Int32 = 0
        guard winios_desktop_overflow(&w, &h) != 0 else { return }
        let have = entry.launchResolution.split(separator: "x").compactMap { Int($0) }
        guard have.count == 2, Int(w) > have[0] || Int(h) > have[1] else { return }
        done = true
        guard let next = fitting(max(Int(w), have[0]), max(Int(h), have[1])) else {
            LogStore.shared.log("[desktop-grow] window needs \(w)x\(h) on a \(have[0])x\(have[1]) desktop: no standard size holds it")
            return
        }
        entry.resolution = "\(next.w)x\(next.h)"
        library.save(entry)
        LogStore.shared.log("[desktop-grow] window needs \(w)x\(h) on a \(have[0])x\(have[1]) desktop: Resolution set to \(next.w)x\(next.h) from the next start")
    }
}
#endif
