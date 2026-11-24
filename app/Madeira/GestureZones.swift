import Foundation
import SwiftUI
import UIKit

/// Gesture zones: invisible rectangles on screen where a gesture becomes input.
///
/// - A stick zone is a floating stick: the finger's landing point is the center,
///   and dragging from it deflects a controller stick (LS/RS) or a key stick
///   (WASD/arrows).
///
/// - A swipe zone turns a swipe into a short press of one input per direction
///   (D-pad by default), optionally limited to horizontal or vertical swipes,
///   and a tap into another.
///
/// - A look zone moves the mouse by the finger's motion, like a trackpad.
///
/// Zones sit under the touch controls: a control drawn over a zone keeps its
/// touches. They are edited in the controls editor, with the zone button.
// GestureZoneKind, SwipeDirections and GestureZone live in TouchControlPresets.swift's
// pure section: layouts store zones, and the host test compiles that section alone.

final class GestureZonesModel: ObservableObject {
    static let shared = GestureZonesModel()
    static let enabled = GamepadInput.flag("MADEIRA_GESTURE_ZONES")

    /// Saved once edits pause: a drag changes the zones every frame, and a file
    /// write per frame made moving a box lag.
    @Published var zones: [GestureZone] = [] { didSet { scheduleSave() } }
    /// The zones that feed the controller; the overlay reconfigures the pad
    /// only when this changes, not on every move.
    var padZoneIDs: Set<UUID> { Set(zones.filter(\.feedsPad).map(\.id)) }
    private var saveWork: DispatchWorkItem?
    private func scheduleSave() {
        guard !loading else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
    @Published var selected: UUID?

    private var loading = false
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("madeira-gesture-zones.json")
    }
    private init() {
        loading = true
        if let d = try? Data(contentsOf: Self.url),
           let z = try? JSONDecoder().decode([GestureZone].self, from: d) { zones = z }
        loading = false
    }
    private func save() {
        guard !loading, let d = try? JSONEncoder().encode(zones) else { return }
        try? d.write(to: Self.url, options: .atomic)
    }

    func index(of id: UUID?) -> Int? { id.flatMap { id in zones.firstIndex { $0.id == id } } }
    func contains(_ p: CGPoint, in bounds: CGRect) -> Bool {
        Self.enabled && zones.contains { ($0.kind != .trackpad || Tabletop.splitNow) && $0.contains(p, in: bounds.size) }
    }
    /// Pinch in the editor: scales the selected zone about its centre.
    private var pinchBase: GestureZone?
    func pinch(_ factor: Double?) {
        guard let i = index(of: selected), zones[i].locked != true else { return }
        guard let f = factor else { pinchBase = nil; return }
        if pinchBase == nil { pinchBase = zones[i] }
        guard let b = pinchBase else { return }
        let w = min(max(b.w * f, 0.06), 1), h = min(max(b.h * f, 0.08), 1)
        zones[i].w = w; zones[i].h = h
        zones[i].x = min(max(b.x + (b.w - w) / 2, 0), 1 - w)
        zones[i].y = min(max(b.y + (b.h - h) / 2, 0), 1 - h)
    }
    func add() {
        var z = GestureZone()
        // A second zone defaults to the right half, as a look or right stick area.
        if zones.contains(where: { $0.x < 0.5 }) { z.x = 0.6; z.stick = .pad("RS") }
        zones.append(z)
        selected = z.id
    }
}

// MARK: - Touch handling

struct GestureZoneSurface: UIViewRepresentable {
    let zone: GestureZone
    func makeUIView(context: Context) -> GestureZoneView { GestureZoneView() }
    func updateUIView(_ view: GestureZoneView, context: Context) { view.configure(zone) }
    static func dismantleUIView(_ view: GestureZoneView, coordinator: ()) { view.releaseAll() }
}

final class GestureZoneView: UIView {
    private struct Finger {
        var owner = UUID()
        var origin: CGPoint
        var last: CGPoint
        var began: TimeInterval
        var swiped = false
        var stickDir = -1
    }
    private var fingers: [ObjectIdentifier: Finger] = [:]
    /// The one finger that drives a stick or look zone; later fingers are ignored.
    private var driver: ObjectIdentifier?
    private var zone = GestureZone()
    private var carryX = 0.0, carryY = 0.0

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
            name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(_ z: GestureZone) {
        if z.kind != zone.kind || z.stick != zone.stick { releaseAll() }
        zone = z
    }
    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { releaseAll() } }
    @objc private func interrupted() { releaseAll() }

    func releaseAll() {
        for f in fingers.values { release(f) }
        fingers.removeAll()
        driver = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            let key = ObjectIdentifier(t)
            fingers[key] = Finger(origin: p, last: p, began: t.timestamp)
            if zone.kind != .swipe, driver == nil { driver = key }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard UIApplication.shared.applicationState == .active else { releaseAll(); return }
        for t in touches {
            let key = ObjectIdentifier(t)
            guard var f = fingers[key] else { continue }
            let p = t.location(in: self)
            switch zone.kind {
            case .stick where key == driver: moveStick(&f, p)
            case .look where key == driver: look(&f, p)
            case .swipe: swipe(&f, p)
            default: break
            }
            f.last = p
            fingers[key] = f
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, tapAllowed: true) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, tapAllowed: false) }

    private func finish(_ touches: Set<UITouch>, tapAllowed: Bool) {
        for t in touches {
            let key = ObjectIdentifier(t)
            guard let f = fingers.removeValue(forKey: key) else { continue }
            if zone.kind == .swipe, tapAllowed, !f.swiped,
               hypot(f.last.x - f.origin.x, f.last.y - f.origin.y) < 12, t.timestamp - f.began < 0.3 {
                pulse(zone.tap)
            }
            release(f)
            if key == driver { driver = nil; carryX = 0; carryY = 0 }
        }
    }

    private func release(_ f: Finger) {
        if zone.kind == .stick {
            if zone.stick.isPad { GamepadInput.shared.touch(owner: f.owner, control: zone.id, value: nil) }
            if let q = zone.stick.stickKeys { for vk in PadKeyboardMouse.sectorKeys(f.stickDir, q) { winios_post_key(vk, 0) } }
        }
    }

    // ---- stick ----

    private func moveStick(_ f: inout Finger, _ p: CGPoint) {
        let radius = 70 / max(0.25, zone.sensitivity)
        let x = Double(p.x - f.origin.x) / radius, y = Double(f.origin.y - p.y) / radius
        if let name = zone.stick.padName {
            GamepadInput.shared.touch(owner: f.owner, control: zone.id,
                                      value: TouchPadAction.sample(name, x: x, y: y))
        } else if let q = zone.stick.stickKeys {
            let next = PadKeyboardMouse.sector(min(1, x), min(1, y))
            guard next != f.stickDir else { return }
            let old = Set(PadKeyboardMouse.sectorKeys(f.stickDir, q)), new = Set(PadKeyboardMouse.sectorKeys(next, q))
            for vk in old.subtracting(new) { winios_post_key(vk, 0) }
            for vk in new.subtracting(old) { winios_post_key(vk, 1) }
            f.stickDir = next
        }
    }

    // ---- look ----

    private func look(_ f: inout Finger, _ p: CGPoint) {
        carryX += Double(p.x - f.last.x) * 2 * zone.sensitivity
        carryY += Double(p.y - f.last.y) * 2 * zone.sensitivity
        let dx = carryX.rounded(.towardZero), dy = carryY.rounded(.towardZero)
        carryX -= dx; carryY -= dy
        if dx != 0 || dy != 0 { HardwareInput.shared.postRelative(Int32(dx), Int32(dy)) }
    }

    // ---- swipe ----

    /// A swipe fires once its length passes the threshold, then measures again
    /// from where it fired, so one long stroke or a back-and-forth repeats.
    private func swipe(_ f: inout Finger, _ p: CGPoint) {
        let threshold = 36 / max(0.25, zone.sensitivity)
        let dx = p.x - f.origin.x, dy = p.y - f.origin.y
        let dir: String?
        switch zone.directions {
        case .horizontal: dir = abs(dx) >= threshold ? (dx > 0 ? "right" : "left") : nil
        case .vertical:   dir = abs(dy) >= threshold ? (dy > 0 ? "down" : "up") : nil
        case .four:
            if hypot(dx, dy) < threshold { dir = nil }
            else if abs(dx) > abs(dy) { dir = dx > 0 ? "right" : "left" }
            else { dir = dy > 0 ? "down" : "up" }
        }
        guard let dir else { return }
        f.swiped = true
        f.origin = p
        pulse(zone.swipe[dir] ?? .none)
    }

    /// A short press: long enough for a game polling at 30 Hz to see it.
    private func pulse(_ action: ControlAction) {
        let hold = 0.07
        switch action {
        case .pad(let name):
            let owner = UUID(), control = zone.id
            GamepadInput.shared.touch(owner: owner, control: control, value: TouchPadAction.sample(name))
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                GamepadInput.shared.touch(owner: owner, control: control, value: nil)
            }
        case .key(let vk):
            winios_post_key(vk, 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { winios_post_key(vk, 0) }
        case .mouseLeft:
            winios_pointer(0, 0, 0x0002, 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { winios_pointer(0, 0, 0x0004, 0) }
        case .mouseRight:
            winios_pointer(0, 0, 0x0008, 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { winios_pointer(0, 0, 0x0010, 0) }
        case .keyboardToggle:
            MetalBackedView.toggleKeyboard()
        case .trackpadSwap:
            TrackpadMode.shared.toggle()
        case .none, .joystickWASD, .joystickArrows:
            break
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Views

/// The zones layer, under the touch controls. In play the zones are invisible
/// touch surfaces; in the editor they are outlined boxes to drag and resize.
struct GestureZonesLayer: View {
    let screen: CGSize
    let editing: Bool
    /// Tabletop trackpad mode: one trackpad over the whole bottom half, with
    /// the settings of the layout's first trackpad zone.
    var fullTrackpad = false
    @ObservedObject private var z = GestureZonesModel.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            if fullTrackpad {
                let first = z.zones.first { $0.kind == .trackpad }
                TrackpadZone(id: first?.id ?? TrackpadMode.fullID, settings: first?.pad ?? TrackpadSettings())
                    .frame(width: screen.width, height: screen.height)
            } else {
                ForEach(z.zones) { zone in
                    let r = zone.rect(in: screen)
                    Group {
                        if editing { GestureZoneEditBox(zone: zone, screen: screen) }
                        else if zone.kind == .trackpad {
                            // A trackpad works only in tabletop (the controls in the bottom half).
                            if Tabletop.splitNow { TrackpadZone(id: zone.id, settings: zone.pad) }
                        }
                        else { GestureZoneSurface(zone: zone) }
                    }
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                }
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
    }
}

private struct GestureZoneEditBox: View {
    let zone: GestureZone
    let screen: CGSize
    @ObservedObject private var z = GestureZonesModel.shared
    @State private var base: GestureZone?

    private var selected: Bool { z.selected == zone.id }
    private var outline: RoundedRectangle { RoundedRectangle(cornerRadius: 12) }

    /// Which edges a handle moves: -1 the left/top edge, 1 the right/bottom edge, 0 neither.
    private static let handles: [(x: Int, y: Int)] = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

    var body: some View {
        GeometryReader { g in
            ZStack {
                outline
                    .fill(Color.cyan.opacity(selected ? 0.18 : 0.08))
                    .overlay(outline.stroke(Color.cyan.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                    .overlay(Text(caption).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { v in edit { b, i in
                            z.zones[i].x = min(max(b.x + v.translation.width / screen.width, 0), 1 - b.w)
                            z.zones[i].y = min(max(b.y + v.translation.height / screen.height, 0), 1 - b.h)
                        } }
                        .onEnded { _ in base = nil })
                if zone.locked == true {
                    Image(systemName: "lock.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                        .position(x: g.size.width - 16, y: 16)
                } else if selected {
                    ForEach(0..<Self.handles.count, id: \.self) { k in
                        handle(Self.handles[k], in: g.size)
                    }
                }
            }
        }
    }

    private func handle(_ h: (x: Int, y: Int), in size: CGSize) -> some View {
        Circle().fill(Color.white).frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.cyan, lineWidth: 3))
            .frame(width: 44, height: 44)          // a finger-sized target around the dot
            .contentShape(Rectangle())
            .position(x: size.width / 2 * CGFloat(1 + h.x), y: size.height / 2 * CGFloat(1 + h.y))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { v in edit { b, i in
                    let dx = v.translation.width / screen.width, dy = v.translation.height / screen.height
                    let minW = 0.06, minH = 0.08
                    var x = b.x, y = b.y, w = b.w, hh = b.h
                    if h.x == -1 { let nx = min(max(b.x + dx, 0), b.x + b.w - minW); w = b.w + (b.x - nx); x = nx }
                    if h.x == 1 { w = min(max(b.w + dx, minW), 1 - b.x) }
                    if h.y == -1 { let ny = min(max(b.y + dy, 0), b.y + b.h - minH); hh = b.h + (b.y - ny); y = ny }
                    if h.y == 1 { hh = min(max(b.h + dy, minH), 1 - b.y) }
                    z.zones[i].x = x; z.zones[i].y = y; z.zones[i].w = w; z.zones[i].h = hh
                } }
                .onEnded { _ in base = nil })
    }

    private func edit(_ apply: (GestureZone, Int) -> Void) {
        z.selected = zone.id
        TouchControlsModel.shared.selected = nil
        guard zone.locked != true, let i = z.index(of: zone.id) else { return }
        if base == nil { base = z.zones[i] }
        if let b = base { apply(b, i) }
    }

    private var caption: String {
        switch zone.kind {
        case .stick: return "Stick: " + GestureZonePanel.name(zone.stick)
        case .look:  return "Look"
        case .swipe: return "Swipe: " + zone.directions.title
        case .trackpad: return "Trackpad"
        }
    }
}

/// Settings for the selected zone, shown at the centre of the screen.
struct GestureZonePanel: View {
    let zone: GestureZone
    let screen: CGSize
    @ObservedObject private var z = GestureZonesModel.shared

    static let stickChoices: [ControlAction] = [.pad("LS"), .pad("RS"), .joystickWASD, .joystickArrows]
    static let pressChoices: [ControlAction] = [.none,
        .pad("D↑"), .pad("D↓"), .pad("D←"), .pad("D→"),
        .pad("A"), .pad("B"), .pad("X"), .pad("Y"), .pad("LB"), .pad("RB"), .pad("LT"), .pad("RT"),
        .pad("L3"), .pad("R3"), .pad("Menu"), .pad("View"),
        .key(0x26), .key(0x28), .key(0x25), .key(0x27), .key(0x20), .key(0x0D), .key(0x1B), .key(0x09),
        .key(0x10), .key(0x45), .key(0x51), .key(0x46), .mouseLeft, .mouseRight]

    static func name(_ a: ControlAction) -> String {
        switch a {
        case .pad(let n): return PadBindings.displayName(n)
        case .joystickWASD: return "WASD"
        case .joystickArrows: return "Arrows"
        case .none: return "None"
        default: return a.label
        }
    }

    private var i: Int? { z.index(of: zone.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Gesture zone").font(.headline)
                Spacer()
                Button {
                    if let i { z.zones[i].locked = zone.locked == true ? nil : true }
                } label: { Image(systemName: zone.locked == true ? "lock.fill" : "lock.open") }
                // A locked zone has no delete button.
                if zone.locked != true {
                    Button(role: .destructive) {
                        if let i { z.zones.remove(at: i) }
                        z.selected = nil
                    } label: { Image(systemName: "trash") }
                }
                Button { z.selected = nil } label: { Image(systemName: "xmark") }
            }
            Picker("Kind", selection: binding(\.kind)) {
                ForEach(GestureZoneKind.allCases, id: \.self) { Text($0.title) }
            }.pickerStyle(.segmented)
            switch zone.kind {
            case .stick:
                row("Output", menu(binding(\.stick), Self.stickChoices))
            case .look:
                EmptyView()
            case .trackpad:
                trackpadSettings
            case .swipe:
                Picker("Directions", selection: binding(\.directions)) {
                    ForEach(SwipeDirections.allCases, id: \.self) { Text($0.title) }
                }.pickerStyle(.segmented)
                ForEach(directionsShown, id: \.self) { d in
                    row(d.capitalized, menu(swipeBinding(d), Self.pressChoices))
                }
                row("Tap", menu(binding(\.tap), Self.pressChoices))
            }
            LayerButtons { mv in if let i { mv.apply(&z.zones, i) } }
            Text("Zones always sit under buttons.").font(.caption).foregroundStyle(.white.opacity(0.6))
            if zone.kind != .trackpad {
                HStack {
                    Text(zone.kind == .swipe ? "Swipe length" : "Sensitivity").font(.subheadline)
                    Slider(value: binding(\.sensitivity), in: 0.25...3)
                }
            }
        }
        .padding(14)
        .frame(width: min(340, screen.width - 32))
        .foregroundStyle(.white)
        .background(GlassShape())
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { } // Panel gaps must not dismiss the selection beneath them.
        .position(x: panelX, y: screen.height / 2)
    }

    /// The side of the screen the zone covers less of.
    private var panelX: CGFloat {
        let half = min(340, screen.width - 32) / 2 + 16
        return zone.x + zone.w / 2 < 0.5 ? screen.width - half : half
    }

    /// A trackpad's settings (TrackpadSettings). Scrolls when the panel is taller than the screen.
    private var trackpadSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                slider("Speed", padBinding(\.speed))
                toggle("Acceleration", padBinding(\.acceleration))
                toggle("Tap to click", padBinding(\.tapToClick))
                toggle("Two-finger tap: right click", padBinding(\.twoFingerRightClick))
                toggle("Tap, then drag", padBinding(\.tapDrag))
                toggle("Three-finger drag", padBinding(\.threeFingerDrag))
                toggle("Click buttons", padBinding(\.clickButtons))
                toggle("Two-finger scroll", padBinding(\.scroll))
                if zone.pad.scroll {
                    slider("Scroll speed", padBinding(\.scrollSpeed))
                    toggle("Natural scrolling", padBinding(\.naturalScroll))
                    toggle("Scroll momentum", padBinding(\.momentum))
                }
            }
        }
        .frame(maxHeight: max(120, screen.height - 230))
    }
    private func toggle(_ title: String, _ b: Binding<Bool>) -> some View {
        Toggle(isOn: b) { Text(title).font(.subheadline) }.tint(.cyan)
    }
    private func slider(_ title: String, _ b: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Slider(value: b, in: 0.25...4)
            Text(String(format: "%.1f×", b.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 36)
        }
    }
    private func padBinding<T>(_ path: WritableKeyPath<TrackpadSettings, T>) -> Binding<T> {
        Binding(get: { zone.pad[keyPath: path] },
                set: { v in if let i { z.zones[i].pad[keyPath: path] = v } })
    }

    private var directionsShown: [String] {
        switch zone.directions {
        case .four: return GestureZone.directionNames
        case .horizontal: return ["left", "right"]
        case .vertical: return ["up", "down"]
        }
    }

    private func row(_ title: String, _ content: some View) -> some View {
        HStack { Text(title).font(.subheadline); Spacer(); content }
    }

    private func menu(_ b: Binding<ControlAction>, _ choices: [ControlAction]) -> some View {
        Menu {
            ForEach(choices, id: \.self) { a in Button(Self.name(a)) { b.wrappedValue = a } }
        } label: {
            Text(Self.name(b.wrappedValue)).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.15)))
        }
    }

    private func binding<T>(_ path: WritableKeyPath<GestureZone, T>) -> Binding<T> {
        Binding(get: { zone[keyPath: path] },
                set: { v in if let i { z.zones[i][keyPath: path] = v } })
    }
    private func swipeBinding(_ d: String) -> Binding<ControlAction> {
        Binding(get: { zone.swipe[d] ?? .none },
                set: { v in if let i { z.zones[i].swipe[d] = v } })
    }
}

// MARK: - Layering

/// Later items draw on top and take touches first; this moves one item in that order.
enum LayerMove: CaseIterable {
    case front, forward, backward, back
    var icon: String {
        switch self {
        case .front: "arrow.up.to.line"; case .forward: "arrow.up"
        case .backward: "arrow.down"; case .back: "arrow.down.to.line"
        }
    }
    var label: String {
        switch self {
        case .front: "Bring to front"; case .forward: "Bring forward"
        case .backward: "Send backward"; case .back: "Send to back"
        }
    }
    func apply<T>(_ a: inout [T], _ i: Int) {
        let item = a.remove(at: i)
        let j: Int
        switch self {
        case .front: j = a.count
        case .forward: j = min(i + 1, a.count)
        case .backward: j = max(i - 1, 0)
        case .back: j = 0
        }
        a.insert(item, at: j)
    }
}

/// The four layer buttons, for the control and zone settings panels.
struct LayerButtons: View {
    let move: (LayerMove) -> Void
    var body: some View {
        HStack(spacing: 0) {
            Text("Layer").font(.subheadline).foregroundStyle(.white.opacity(0.7))
            Spacer()
            ForEach(LayerMove.allCases, id: \.self) { m in
                Button { move(m) } label: {
                    Image(systemName: m.icon).font(.system(size: 15))
                        .foregroundStyle(.white).frame(width: 40, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(m.label)
            }
        }
    }
}

// MARK: - Trackpad (iPhone Duo tabletop)

/// Tabletop trackpad mode: the swap button (ControlAction.trackpadSwap) turns
/// the bottom half into one big trackpad and back. Remembered per game.
final class TrackpadMode: ObservableObject {
    static let shared = TrackpadMode()
    /// The full trackpad's touch identity when the layout has no trackpad zone.
    static let fullID = UUID(uuidString: "7E0C5A1D-7A8C-4F5B-9E21-0D5A7C1B2E44")!
    private static let key = "madeira.trackpad.full-by-game"

    @Published private var fullByGame: [String: Bool] =
        (UserDefaults.standard.dictionary(forKey: TrackpadMode.key) as? [String: Bool]) ?? [:]

    private var gameKey: String { LibraryModel.shared.current?.uuidString ?? "default" }
    /// This game's choice (trackpad or buttons), wherever the controls are.
    var full: Bool { fullByGame[gameKey] ?? false }
    /// Trackpad mode is showing now: the game's choice, in tabletop.
    static var fullNow: Bool { Tabletop.splitNow && shared.full }

    func toggle() {
        fullByGame[gameKey] = !full
        UserDefaults.standard.set(fullByGame, forKey: Self.key)
        if TouchControlsModel.shared.hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        LogStore.shared.log("[trackpad] \(full ? "trackpad" : "buttons") (tabletop \(Tabletop.splitNow))")
    }
}

/// A trackpad as drawn: the pad's glass, the two click buttons under it, and
/// the touch surface over both.
struct TrackpadZone: View {
    let id: UUID
    let settings: TrackpadSettings
    @ObservedObject private var library = LibraryModel.shared

    var body: some View {
        GeometryReader { g in
            let full = CGRect(origin: .zero, size: g.size)
            let pad = settings.padRect(in: full)
            ZStack(alignment: .topLeading) {
                GlassShape(cornerRadius: 16)
                    .frame(width: pad.width, height: pad.height)
                    .position(x: pad.midX, y: pad.midY)
                if let b = settings.buttonRects(in: full) {
                    GlassShape(cornerRadius: 10).frame(width: b.left.width, height: b.left.height)
                        .position(x: b.left.midX, y: b.left.midY)
                    GlassShape(cornerRadius: 10).frame(width: b.right.width, height: b.right.height)
                        .position(x: b.right.midX, y: b.right.midY)
                }
                TrackpadSurface(id: id, settings: settings).frame(width: g.size.width, height: g.size.height)
            }
            .opacity(library.current != nil ? max(library.opacity, 0.3) : 1)
        }
    }
}

struct TrackpadSurface: UIViewRepresentable {
    let id: UUID
    let settings: TrackpadSettings
    func makeUIView(context: Context) -> TrackpadView { TrackpadView() }
    func updateUIView(_ view: TrackpadView, context: Context) { view.settings = settings }
    static func dismantleUIView(_ view: TrackpadView, coordinator: ()) { view.releaseAll() }
}

/// A multi-touch trackpad: one finger moves the pointer (relative, with
/// optional acceleration); tap clicks; two-finger tap right-clicks; tap then
/// touch again and move drags; three fingers drag; two fingers scroll the
/// wheel, with momentum; the click buttons along the bottom press and hold
/// the left and right buttons, and another finger can move the pointer
/// meanwhile, as on a laptop.
final class TrackpadView: UIView {
    var settings = TrackpadSettings()

    private struct Finger { var origin: CGPoint; var last: CGPoint }
    private var pad: [ObjectIdentifier: Finger] = [:]
    /// Fingers on the click buttons: 0 left, 1 right.
    private var buttons: [ObjectIdentifier: Int] = [:]
    private let leftHighlight = UIView(), rightHighlight = UIView()

    // One gesture: from the first pad finger down to the last one up.
    private var gestureStart: TimeInterval = 0
    private var maxFingers = 0
    private var moved = false
    private var dragging = false
    private var lastMoveTime: TimeInterval = 0
    // Tap, then drag: the first tap's click waits for a second touch.
    private var pendingClick: DispatchWorkItem?
    private var owedClick = false
    private static let tapDragWindow = 0.25
    private static let tapTime = 0.3
    private static let slop: CGFloat = 8

    private var carryX = 0.0, carryY = 0.0
    private var wheel = 0.0
    private var scrollVelocity = 0.0          // pt/s, finger y
    private var momentumLink: CADisplayLink?
    private var momentumLast: CFTimeInterval = 0

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        for v in [leftHighlight, rightHighlight] {
            v.backgroundColor = UIColor.white.withAlphaComponent(0.28)
            v.layer.cornerRadius = 10
            v.isHidden = true
            v.isUserInteractionEnabled = false
            addSubview(v)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted),
            name: UIApplication.willResignActiveNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { releaseAll() } }
    @objc private func interrupted() { releaseAll() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let b = settings.buttonRects(in: bounds) { leftHighlight.frame = b.left; rightHighlight.frame = b.right }
    }

    func releaseAll() {
        for which in Set(buttons.values) { button(which, down: false) }
        buttons.removeAll()
        if dragging { leftButton(false); dragging = false }
        pendingClick?.cancel(); pendingClick = nil; owedClick = false
        pad.removeAll()
        stopMomentum()
    }

    // ---- posting ----

    private func haptic() {
        if TouchControlsModel.shared.hapticsEnabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    }
    private func leftButton(_ down: Bool) { winios_pointer(0, 0, down ? 0x0002 : 0x0004, 0) }
    private func rightButton(_ down: Bool) { winios_pointer(0, 0, down ? 0x0008 : 0x0010, 0) }
    private func click(right: Bool = false) {
        haptic()
        if right { rightButton(true); rightButton(false) } else { leftButton(true); leftButton(false) }
    }
    private func button(_ which: Int, down: Bool) {
        if down { haptic() }
        if which == 0 { leftButton(down); leftHighlight.isHidden = !down } else { rightButton(down); rightHighlight.isHidden = !down }
    }

    /// Moves the pointer by a finger motion of `d` points over `dt` seconds.
    private func movePointer(_ d: CGPoint, dt: TimeInterval) {
        var gain = 1.6 * settings.speed
        if settings.acceleration, dt > 0 {
            let v = Double(hypot(d.x, d.y)) / dt
            gain *= min(1 + v / 500, 4)
        }
        carryX += Double(d.x) * gain
        carryY += Double(d.y) * gain
        let dx = carryX.rounded(.towardZero), dy = carryY.rounded(.towardZero)
        carryX -= dx; carryY -= dy
        if dx != 0 || dy != 0 { HardwareInput.shared.postRelative(Int32(dx), Int32(dy)) }
    }

    /// Scrolls by a finger motion of `dy` points (down is positive).
    private func scroll(_ dy: Double) {
        let step = 36 / max(0.25, settings.scrollSpeed)
        // Natural: the content follows the fingers, so fingers moving down show
        // what is above: the wheel turns up (+120).
        wheel += settings.naturalScroll ? dy : -dy
        var notches = 0
        while wheel >= step, notches < 16 { wheel -= step; notches += 1; winios_pointer(0, 0, 0x0800, UInt32(bitPattern: 120)) }
        while wheel <= -step, notches < 16 { wheel += step; notches += 1; winios_pointer(0, 0, 0x0800, UInt32(bitPattern: -120)) }
    }

    // ---- momentum ----

    private func startMomentum() {
        guard settings.scroll, settings.momentum, abs(scrollVelocity) > 150 else { return }
        stopMomentum()
        momentumLast = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(momentumTick))
        link.add(to: .main, forMode: .common)
        momentumLink = link
    }
    private func stopMomentum() { momentumLink?.invalidate(); momentumLink = nil }
    @objc private func momentumTick() {
        let now = CACurrentMediaTime(), dt = min(now - momentumLast, 0.05)
        momentumLast = now
        scroll(scrollVelocity * dt)
        scrollVelocity *= pow(0.94, dt * 60)
        if abs(scrollVelocity) < 40 { stopMomentum() }
    }

    // ---- touches ----

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self), key = ObjectIdentifier(t)
            if let b = settings.buttonRects(in: bounds), b.left.contains(p) || b.right.contains(p) {
                let which = b.left.contains(p) ? 0 : 1
                buttons[key] = which
                if !buttons.contains(where: { $0.key != key && $0.value == which }) { button(which, down: true) }
                continue
            }
            if pad.isEmpty {
                stopMomentum()
                gestureStart = t.timestamp; lastMoveTime = t.timestamp
                maxFingers = 0; moved = false; scrollVelocity = 0
                // A touch right after a tap: the tap's click waits to see whether this drags.
                if let w = pendingClick { w.cancel(); pendingClick = nil; owedClick = true }
            }
            pad[key] = Finger(origin: p, last: p)
            maxFingers = max(maxFingers, pad.count)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard UIApplication.shared.applicationState == .active else { releaseAll(); return }
        let mine = touches.filter { pad[ObjectIdentifier($0)] != nil }
        guard !mine.isEmpty, let t0 = mine.first else { return }
        // The centroid's motion, from the fingers that moved in this event.
        var sx: CGFloat = 0, sy: CGFloat = 0
        for t in mine {
            let key = ObjectIdentifier(t)
            guard var f = pad[key] else { continue }
            let p = t.location(in: self)
            sx += p.x - f.last.x; sy += p.y - f.last.y
            f.last = p
            if hypot(p.x - f.origin.x, p.y - f.origin.y) > Self.slop { moved = true }
            pad[key] = f
        }
        let n = CGFloat(mine.count)
        let d = CGPoint(x: sx / n, y: sy / n)
        let dt = max(t0.timestamp - lastMoveTime, 1.0 / 240)
        lastMoveTime = t0.timestamp
        guard moved else { return }
        switch pad.count {
        case 1:
            if owedClick && settings.tapDrag && !dragging { owedClick = false; dragging = true; haptic(); leftButton(true) }
            movePointer(d, dt: dt)
        case 2:
            guard settings.scroll else { return }
            scroll(Double(d.y))
            scrollVelocity = scrollVelocity * 0.6 + Double(d.y) / dt * 0.4
        case 3:
            guard settings.threeFingerDrag else { return }
            if !dragging { dragging = true; haptic(); leftButton(true) }
            movePointer(d, dt: dt)
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches, cancelled: true) }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        var last: UITouch?
        for t in touches {
            let key = ObjectIdentifier(t)
            if let which = buttons.removeValue(forKey: key) {
                if !buttons.values.contains(which) { button(which, down: false) }
                continue
            }
            if pad.removeValue(forKey: key) != nil { last = t }
        }
        guard let t = last, pad.isEmpty else { return }
        // The gesture is over.
        let quick = t.timestamp - gestureStart < Self.tapTime
        if dragging {
            dragging = false
            leftButton(false)
        } else if !cancelled, !moved, quick, maxFingers == 1, settings.tapToClick {
            if owedClick {
                owedClick = false
                click(); click()                       // a double tap
            } else if settings.tapDrag {
                let w = DispatchWorkItem { [weak self] in self?.pendingClick = nil; self?.click() }
                pendingClick = w
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapDragWindow, execute: w)
            } else {
                click()
            }
        } else if !cancelled, !moved, quick, maxFingers == 2, settings.twoFingerRightClick {
            if owedClick { owedClick = false; click() }
            click(right: true)
        } else if maxFingers == 2, moved {
            startMomentum()
        }
        if owedClick { owedClick = false; click() }
        carryX = 0; carryY = 0
    }
}
