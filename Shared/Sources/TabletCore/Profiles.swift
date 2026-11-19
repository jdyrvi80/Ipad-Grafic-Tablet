//
//  Profiles.swift
//  TabletCore
//
//  Profili di configurazione, pulsanti e scorciatoie.
//  I profili vivono sul Mac (JSON in Application Support); all'iPad
//  arrivano solo le informazioni necessarie a disegnare l'interfaccia.
//

import Foundation

// MARK: - Tasti

/// Codici tasto virtuali macOS (kVK_*) per i tasti indipendenti dal layout.
public enum MacKeyCode {
    public static let returnKey: UInt16 = 0x24
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let delete: UInt16 = 0x33
    public static let escape: UInt16 = 0x35
    public static let command: UInt16 = 0x37
    public static let shift: UInt16 = 0x38
    public static let capsLock: UInt16 = 0x39
    public static let option: UInt16 = 0x3A
    public static let control: UInt16 = 0x3B
    public static let function: UInt16 = 0x3F
    public static let leftArrow: UInt16 = 0x7B
    public static let rightArrow: UInt16 = 0x7C
    public static let downArrow: UInt16 = 0x7D
    public static let upArrow: UInt16 = 0x7E

    public static func isModifier(_ code: UInt16) -> Bool {
        [command, shift, option, control, function, capsLock].contains(code)
    }

    /// Nome leggibile per i tasti speciali.
    public static func name(for code: UInt16) -> String? {
        switch code {
        case returnKey: return "↩"
        case tab: return "Tab"
        case space: return "Spazio"
        case delete: return "⌫"
        case escape: return "Esc"
        case command: return "⌘"
        case shift: return "⇧"
        case option: return "⌥"
        case control: return "⌃"
        case function: return "fn"
        case leftArrow: return "←"
        case rightArrow: return "→"
        case downArrow: return "↓"
        case upArrow: return "↑"
        default: return nil
        }
    }
}

public struct ModifierKeys: OptionSet, Codable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = ModifierKeys(rawValue: 1 << 0)
    public static let shift = ModifierKeys(rawValue: 1 << 1)
    public static let option = ModifierKeys(rawValue: 1 << 2)
    public static let control = ModifierKeys(rawValue: 1 << 3)
    public static let function = ModifierKeys(rawValue: 1 << 4)

    /// Simboli nell'ordine standard macOS: ⌃⌥⇧⌘
    public var symbols: String {
        var s = ""
        if contains(.function) { s += "fn " }
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// Combinazione di tasti.
/// Si può specificare il CARATTERE (es. "[") e lasciare al Mac il compito di
/// trovare il tasto giusto sul layout attivo (fondamentale con tastiera italiana),
/// oppure un keyCode registrato premendo il tasto sul Mac.
public struct KeyCombo: Codable, Hashable {
    public var keyCode: UInt16?
    public var character: String?
    public var modifiers: ModifierKeys

    public init(keyCode: UInt16? = nil, character: String? = nil, modifiers: ModifierKeys = []) {
        self.keyCode = keyCode
        self.character = character
        self.modifiers = modifiers
    }

    public static func char(_ c: String, _ mods: ModifierKeys = []) -> KeyCombo {
        KeyCombo(character: c, modifiers: mods)
    }

    public static func key(_ code: UInt16, _ mods: ModifierKeys = []) -> KeyCombo {
        KeyCombo(keyCode: code, modifiers: mods)
    }

    /// Tasto modificatore puro (per i pulsanti "tieni premuto" Alt, Shift…).
    public var isPureModifier: Bool {
        guard let code = keyCode else { return false }
        return MacKeyCode.isModifier(code)
    }

    public var displayName: String {
        let keyName: String
        if let c = character, !c.isEmpty {
            keyName = c == " " ? "Spazio" : c.uppercased()
        } else if let code = keyCode {
            keyName = MacKeyCode.name(for: code) ?? "Tasto \(code)"
        } else {
            keyName = "—"
        }
        if isPureModifier { return keyName }
        return modifiers.symbols + keyName
    }
}

// MARK: - Azioni

public enum ButtonAction: Codable, Hashable {
    /// Premi e rilascia la combinazione.
    case shortcut(KeyCombo)
    /// Tiene premuto finché il pulsante resta premuto (Alt, Spazio, Shift…).
    /// I modificatori vengono applicati anche agli eventi della penna.
    case holdKey(KeyCombo)
    case toggleCursorLock
    case togglePrecision
    /// Alterna penna/gomma: il Mac annuncia il puntatore come "eraser",
    /// come fa una Wacom quando si gira la penna.
    case toggleEraser
    case nextProfile
    case nextMode
    case none

    public var title: String {
        switch self {
        case .shortcut(let k): return "Scorciatoia \(k.displayName)"
        case .holdKey(let k): return "Tieni premuto \(k.displayName)"
        case .toggleCursorLock: return "Blocca/sblocca cursore"
        case .togglePrecision: return "Modalità precisione"
        case .toggleEraser: return "Penna ↔ gomma"
        case .nextProfile: return "Profilo successivo"
        case .nextMode: return "Modalità successiva"
        case .none: return "Nessuna azione"
        }
    }

    public var isHold: Bool {
        if case .holdKey = self { return true }
        return false
    }
}

public struct ToolbarButton: Codable, Hashable, Identifiable {
    public var id: UInt16
    public var label: String
    /// Nome SF Symbol mostrato sull'iPad.
    public var symbol: String
    public var action: ButtonAction

    public init(id: UInt16, label: String, symbol: String, action: ButtonAction) {
        self.id = id; self.label = label; self.symbol = symbol; self.action = action
    }

    public var info: ToolbarItemInfo {
        ToolbarItemInfo(id: id, label: label, symbol: symbol, isHold: action.isHold)
    }
}

// MARK: - Profilo

public struct TabletProfile: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var isPreset: Bool

    // Modalità e mapping
    /// Modalità: Display o Trackpad. Le vecchie modalità (Tavoletta, Schermo, Photoshop) diventano Display.
    public var mode: TabletMode {
        didSet { if !TabletMode.available.contains(mode) { mode = .display } }
    }
    public var penMapping: PenMapping
    public var displayUUID: String?          // nil = monitor principale
    public var activeArea: NormRect
    public var rotationQuarterTurns: Int     // 0…3
    public var leftHanded: Bool
    public var keepAspectRatio: Bool

    // Penna
    public var pressureCurve: PressureCurve
    public var stabilization: Double         // 0…1
    public var cursorSpeed: Double           // modalità relativa
    public var precisionFactor: Double       // 0.1…1
    public var hoverMovesCursor: Bool
    public var sendTilt: Bool
    public var palmRejection: Bool

    // Dito (touchpad)
    public var touchpadSpeed: Double
    public var scrollSpeed: Double

    // Pulsanti e gesture
    public var toolbarVisible: Bool
    public var toolbar: [ToolbarButton]
    public var doubleTapAction: ButtonAction
    public var squeezeAction: ButtonAction
    public var pinchOpenAction: ButtonAction
    public var pinchCloseAction: ButtonAction

    // Modalità Display (schermo del Mac sull'iPad)
    /// Area del monitor mostrata sull'iPad, normalizzata rispetto al monitor (0…1, origine in alto a sinistra).
    public var displayRegion: NormRect
    /// Qualità JPEG 0.3…0.95.
    public var mirrorQuality: Double
    /// Frazione della risoluzione dell'iPad usata per i fotogrammi (0.4…1).
    public var mirrorResolution: Double
    /// Fotogrammi al secondo massimi.
    public var mirrorMaxFPS: Int
    /// Quando lo schermo smette di cambiare, invia una versione a piena risoluzione e qualità alta.
    public var mirrorSharpenWhenIdle: Bool
    /// Cosa fanno due dita in modalità Display.
    public var displayGestures: DisplayGestureTarget
    /// Modalità Trackpad: opzioni come in Impostazioni di Sistema → Trackpad.
    public var trackpad: TrackpadOptions

    public init(id: UUID = UUID(), name: String, isPreset: Bool = false,
                penMapping: PenMapping? = nil, displayUUID: String? = nil,
                activeArea: NormRect = .full, rotationQuarterTurns: Int = 0,
                leftHanded: Bool = false, keepAspectRatio: Bool = true,
                pressureCurve: PressureCurve = .linear, stabilization: Double = 0,
                cursorSpeed: Double = 1.6, precisionFactor: Double = 0.3,
                hoverMovesCursor: Bool = true, sendTilt: Bool = true, palmRejection: Bool = true,
                touchpadSpeed: Double = 1.8, scrollSpeed: Double = 1.0,
                toolbarVisible: Bool = true, toolbar: [ToolbarButton] = [],
                doubleTapAction: ButtonAction = .toggleEraser,
                squeezeAction: ButtonAction = .shortcut(.char("z", [.command])),
                pinchOpenAction: ButtonAction = .shortcut(.char("+", [.command])),
                pinchCloseAction: ButtonAction = .shortcut(.char("-", [.command])),
                displayRegion: NormRect = .full, mirrorQuality: Double = 0.6,
                mirrorResolution: Double = 0.8, mirrorMaxFPS: Int = 30, mirrorSharpenWhenIdle: Bool = true,
                displayGestures: DisplayGestureTarget = .area) {
        self.id = id
        self.name = name
        self.isPreset = isPreset
        self.mode = .display
        self.penMapping = penMapping ?? .absolute
        self.displayUUID = displayUUID
        self.activeArea = activeArea
        self.rotationQuarterTurns = rotationQuarterTurns
        self.leftHanded = leftHanded
        self.keepAspectRatio = keepAspectRatio
        self.pressureCurve = pressureCurve
        self.stabilization = stabilization
        self.cursorSpeed = cursorSpeed
        self.precisionFactor = precisionFactor
        self.hoverMovesCursor = hoverMovesCursor
        self.sendTilt = sendTilt
        self.palmRejection = palmRejection
        self.touchpadSpeed = touchpadSpeed
        self.scrollSpeed = scrollSpeed
        self.toolbarVisible = toolbarVisible
        self.toolbar = toolbar
        self.doubleTapAction = doubleTapAction
        self.squeezeAction = squeezeAction
        self.pinchOpenAction = pinchOpenAction
        self.pinchCloseAction = pinchCloseAction
        self.displayRegion = displayRegion
        self.mirrorQuality = mirrorQuality
        self.mirrorResolution = mirrorResolution
        self.mirrorMaxFPS = mirrorMaxFPS
        self.mirrorSharpenWhenIdle = mirrorSharpenWhenIdle
        self.trackpad = TrackpadOptions()
        self.displayGestures = displayGestures
    }

    /// Decodifica tollerante: i campi mancanti (profili salvati da versioni precedenti)
    /// prendono il valore predefinito invece di far fallire il caricamento.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = TabletProfile(name: "Profilo")
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            guard let decoded = try? c.decodeIfPresent(T.self, forKey: key) else { return fallback }
            return decoded
        }
        id = value(.id, UUID())
        name = value(.name, base.name)
        isPreset = value(.isPreset, false)
        // Display e Trackpad restano; le modalità di versioni precedenti (Tavoletta, Schermo, Photoshop) diventano Display.
        let decodedMode: TabletMode = value(.mode, .display)
        mode = TabletMode.available.contains(decodedMode) ? decodedMode : .display
        penMapping = .absolute
        displayUUID = value(.displayUUID, base.displayUUID)
        activeArea = value(.activeArea, base.activeArea)
        rotationQuarterTurns = value(.rotationQuarterTurns, base.rotationQuarterTurns)
        leftHanded = value(.leftHanded, base.leftHanded)
        keepAspectRatio = value(.keepAspectRatio, base.keepAspectRatio)
        pressureCurve = value(.pressureCurve, base.pressureCurve)
        stabilization = value(.stabilization, base.stabilization)
        cursorSpeed = value(.cursorSpeed, base.cursorSpeed)
        precisionFactor = value(.precisionFactor, base.precisionFactor)
        hoverMovesCursor = value(.hoverMovesCursor, base.hoverMovesCursor)
        sendTilt = value(.sendTilt, base.sendTilt)
        palmRejection = value(.palmRejection, base.palmRejection)
        touchpadSpeed = value(.touchpadSpeed, base.touchpadSpeed)
        scrollSpeed = value(.scrollSpeed, base.scrollSpeed)
        toolbarVisible = value(.toolbarVisible, base.toolbarVisible)
        toolbar = value(.toolbar, base.toolbar)
        doubleTapAction = value(.doubleTapAction, base.doubleTapAction)
        squeezeAction = value(.squeezeAction, base.squeezeAction)
        pinchOpenAction = value(.pinchOpenAction, base.pinchOpenAction)
        pinchCloseAction = value(.pinchCloseAction, base.pinchCloseAction)
        displayRegion = value(.displayRegion, base.displayRegion)
        mirrorQuality = value(.mirrorQuality, base.mirrorQuality)
        mirrorResolution = value(.mirrorResolution, base.mirrorResolution)
        mirrorMaxFPS = value(.mirrorMaxFPS, base.mirrorMaxFPS)
        mirrorSharpenWhenIdle = value(.mirrorSharpenWhenIdle, base.mirrorSharpenWhenIdle)
        trackpad = value(.trackpad, base.trackpad)
        displayGestures = value(.displayGestures, base.displayGestures)
    }

    /// Rotazione effettiva: la modalità mancina aggiunge 180°.
    public var effectiveQuarterTurns: Int {
        (rotationQuarterTurns + (leftHanded ? 2 : 0)) % 4
    }

    public func button(id: UInt16) -> ToolbarButton? {
        toolbar.first { $0.id == id }
    }

    public var nextToolbarID: UInt16 {
        (toolbar.map(\.id).max() ?? 0) &+ 1
    }

    /// Copia modificabile di un profilo (anche preconfigurato).
    public func duplicated(named newName: String) -> TabletProfile {
        var p = self
        p.id = UUID()
        p.name = newName
        p.isPreset = false
        return p
    }
}

// MARK: - Profili preconfigurati

public enum ProfilePresets {

    // ID fissi: i preset restano riconoscibili tra un avvio e l'altro.
    static let photoshopID = UUID(uuidString: "6F1C6A10-0001-4C8B-9E3A-7A0B11111111")!
    static let lightroomID = UUID(uuidString: "6F1C6A10-0002-4C8B-9E3A-7A0B22222222")!
    static let illustratorID = UUID(uuidString: "6F1C6A10-0003-4C8B-9E3A-7A0B33333333")!
    static let drawingID = UUID(uuidString: "6F1C6A10-0004-4C8B-9E3A-7A0B44444444")!
    static let genericID = UUID(uuidString: "6F1C6A10-0005-4C8B-9E3A-7A0B55555555")!

    // Pulsanti riutilizzabili
    static func undo(_ id: UInt16) -> ToolbarButton {
        ToolbarButton(id: id, label: "Annulla", symbol: "arrow.uturn.backward", action: .shortcut(.char("z", [.command])))
    }
    static func redo(_ id: UInt16) -> ToolbarButton {
        ToolbarButton(id: id, label: "Ripeti", symbol: "arrow.uturn.forward", action: .shortcut(.char("z", [.command, .shift])))
    }
    static func zoomIn(_ id: UInt16) -> ToolbarButton {
        ToolbarButton(id: id, label: "Zoom +", symbol: "plus.magnifyingglass", action: .shortcut(.char("+", [.command])))
    }
    static func zoomOut(_ id: UInt16) -> ToolbarButton {
        ToolbarButton(id: id, label: "Zoom −", symbol: "minus.magnifyingglass", action: .shortcut(.char("-", [.command])))
    }
    static func fit(_ id: UInt16) -> ToolbarButton {
        ToolbarButton(id: id, label: "Adatta", symbol: "arrow.up.left.and.arrow.down.right", action: .shortcut(.char("0", [.command])))
    }
    static func brushUp(_ id: UInt16) -> ToolbarButton {
        ToolbarButton(id: id, label: "Pennello +", symbol: "circle.circle", action: .shortcut(.char("]")))
    }
    static func brushDown(_ id: UInt16) -> ToolbarButton {
        ToolbarButton(id: id, label: "Pennello −", symbol: "smallcircle.filled.circle", action: .shortcut(.char("[")))
    }
    static func hold(_ id: UInt16, _ label: String, _ symbol: String, _ code: UInt16, _ mods: ModifierKeys) -> ToolbarButton {
        ToolbarButton(id: id, label: label, symbol: symbol, action: .holdKey(.key(code, mods)))
    }
    static func alt(_ id: UInt16) -> ToolbarButton { hold(id, "Alt", "option", MacKeyCode.option, [.option]) }
    static func shift(_ id: UInt16) -> ToolbarButton { hold(id, "Shift", "shift", MacKeyCode.shift, [.shift]) }
    static func command(_ id: UInt16) -> ToolbarButton { hold(id, "Cmd", "command", MacKeyCode.command, [.command]) }
    static func control(_ id: UInt16) -> ToolbarButton { hold(id, "Ctrl", "control", MacKeyCode.control, [.control]) }
    static func space(_ id: UInt16) -> ToolbarButton { hold(id, "Spazio", "hand.raised", MacKeyCode.space, []) }
    static func tab(_ id: UInt16) -> ToolbarButton {
        ToolbarButton(id: id, label: "Tab", symbol: "arrow.right.to.line", action: .shortcut(.key(MacKeyCode.tab)))
    }
    static func eraser(_ id: UInt16) -> ToolbarButton {
        ToolbarButton(id: id, label: "Gomma", symbol: "eraser", action: .toggleEraser)
    }
    static func precision(_ id: UInt16) -> ToolbarButton {
        ToolbarButton(id: id, label: "Precisione", symbol: "scope", action: .togglePrecision)
    }
    static func tool(_ id: UInt16, _ label: String, _ symbol: String, _ ch: String) -> ToolbarButton {
        ToolbarButton(id: id, label: label, symbol: symbol, action: .shortcut(.char(ch)))
    }

    public static var all: [TabletProfile] {
        [photoshop, lightroom, illustrator, drawing, generic]
    }

    public static var photoshop: TabletProfile {
        TabletProfile(
            id: photoshopID, name: "Photoshop Retouching", isPreset: true,
            pressureCurve: PressureCurve(control1: CurvePoint(x: 0.25, y: 0.3),
                                         control2: CurvePoint(x: 0.6, y: 0.85)),
            stabilization: 0.25,
            toolbar: [undo(1), redo(2), brushUp(3), brushDown(4), zoomIn(5), zoomOut(6), fit(7),
                      alt(8), space(9), eraser(10), precision(11)],
            doubleTapAction: .toggleEraser,
            squeezeAction: .shortcut(.char("z", [.command])))
    }

    /// Tavoletta con schermo: l'iPad mostra il monitor del Mac e si ritocca direttamente sull'immagine.
    public static var lightroom: TabletProfile {
        TabletProfile(
            id: lightroomID, name: "Lightroom", isPreset: true,
            pressureCurve: .linear, stabilization: 0.15,
            toolbar: [undo(1), redo(2), brushUp(3), brushDown(4),
                      tool(5, "Zoom", "magnifyingglass", "z"),
                      tool(6, "Prima/Dopo", "rectangle.split.2x1", "\\"),
                      alt(7), space(8)],
            doubleTapAction: .shortcut(.char("z", [.command])),
            squeezeAction: .shortcut(.char("\\")))
    }

    public static var illustrator: TabletProfile {
        TabletProfile(
            id: illustratorID, name: "Illustrator", isPreset: true,
            pressureCurve: .linear, stabilization: 0.35,
            toolbar: [undo(1), redo(2),
                      tool(3, "Selezione", "cursorarrow", "v"),
                      tool(4, "Penna", "pencil.tip", "p"),
                      tool(5, "Pennello", "paintbrush.pointed", "b"),
                      zoomIn(6), zoomOut(7), fit(8), space(9), shift(10), alt(11)],
            doubleTapAction: .shortcut(.char("z", [.command])),
            squeezeAction: .togglePrecision)
    }

    public static var drawing: TabletProfile {
        TabletProfile(
            id: drawingID, name: "Disegno digitale", isPreset: true,
            pressureCurve: .soft, stabilization: 0.45,
            toolbar: [undo(1), redo(2), tool(3, "Pennello", "paintbrush.pointed", "b"), eraser(4),
                      brushUp(5), brushDown(6), space(7), alt(8)],
            doubleTapAction: .toggleEraser,
            squeezeAction: .shortcut(.char("z", [.command])))
    }

    public static var generic: TabletProfile {
        TabletProfile(
            id: genericID, name: "Utilizzo generico", isPreset: true,
            pressureCurve: .linear, stabilization: 0, cursorSpeed: 1.6,
            toolbarVisible: false,
            toolbar: [undo(1), redo(2), alt(3), shift(4), command(5), control(6), space(7), tab(8)],
            doubleTapAction: .shortcut(.char("z", [.command])),
            squeezeAction: .none)
    }
}

// MARK: - Qualità dell'immagine sull'iPad (modalità Display)

/// Combinazioni pronte di risoluzione, qualità JPEG e fotogrammi al secondo.
public enum MirrorQualityPreset: String, CaseIterable, Identifiable {
    case smooth, balanced, sharp, maximum
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .smooth: return "Fluida"
        case .balanced: return "Bilanciata"
        case .sharp: return "Nitida"
        case .maximum: return "Massima"
        }
    }

    /// Frazione della risoluzione Retina dell'iPad (1 = un pixel inviato per ogni pixel dello schermo).
    public var resolution: Double {
        switch self {
        case .smooth: return 0.6
        case .balanced: return 0.8
        case .sharp, .maximum: return 1.0
        }
    }

    public var quality: Double {
        switch self {
        case .smooth: return 0.55
        case .balanced: return 0.7
        case .sharp: return 0.85
        case .maximum: return 0.95
        }
    }

    public var maxFPS: Int {
        switch self {
        case .smooth, .balanced, .sharp: return 30
        case .maximum: return 20
        }
    }

    /// Preset che corrisponde alle impostazioni del profilo (nil = personalizzate).
    public static func matching(_ p: TabletProfile) -> MirrorQualityPreset? {
        allCases.first { preset in
            abs(preset.resolution - p.mirrorResolution) < 0.01 && abs(preset.quality - p.mirrorQuality) < 0.01
                && preset.maxFPS == p.mirrorMaxFPS
        }
    }

    public func apply(to p: inout TabletProfile) {
        p.mirrorResolution = resolution
        p.mirrorQuality = quality
        p.mirrorMaxFPS = maxFPS
    }
}
