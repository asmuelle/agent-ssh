import SwiftTerm
import SwiftUI
import UIKit

@MainActor
final class MobileTerminalPreferences: ObservableObject {
    static let shared = MobileTerminalPreferences()

    @Published var themeId: String {
        didSet { defaults.set(themeId, forKey: Keys.themeId) }
    }
    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }
    @Published var scrollbackLines: Int {
        didSet { defaults.set(scrollbackLines, forKey: Keys.scrollbackLines) }
    }
    @Published var cursorStyleId: String {
        didSet { defaults.set(cursorStyleId, forKey: Keys.cursorStyleId) }
    }
    @Published var mouseReporting: Bool {
        didSet { defaults.set(mouseReporting, forKey: Keys.mouseReporting) }
    }
    @Published var optionAsMeta: Bool {
        didSet { defaults.set(optionAsMeta, forKey: Keys.optionAsMeta) }
    }
    @Published var copyOnSelect: Bool {
        didSet { defaults.set(copyOnSelect, forKey: Keys.copyOnSelect) }
    }
    @Published var accessoryKeyIds: [String] {
        didSet {
            if let data = try? JSONEncoder().encode(accessoryKeyIds) {
                defaults.set(data, forKey: Keys.accessoryKeyIds)
            }
        }
    }

    private let defaults: UserDefaults

    var theme: MobileTerminalTheme {
        MobileTerminalTheme.resolve(themeId)
    }

    var clampedFontSize: Double {
        min(22, max(10, fontSize))
    }

    var clampedScrollbackLines: Int {
        min(100_000, max(500, scrollbackLines))
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.themeId = defaults.string(forKey: Keys.themeId) ?? "homebrew"
        self.fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 13
        self.scrollbackLines = defaults.object(forKey: Keys.scrollbackLines) as? Int ?? 10_000
        self.cursorStyleId = defaults.string(forKey: Keys.cursorStyleId) ?? "blinkBlock"
        self.mouseReporting = defaults.object(forKey: Keys.mouseReporting) as? Bool ?? true
        self.optionAsMeta = defaults.object(forKey: Keys.optionAsMeta) as? Bool ?? true
        self.copyOnSelect = defaults.object(forKey: Keys.copyOnSelect) as? Bool ?? false
        if let data = defaults.data(forKey: Keys.accessoryKeyIds),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            self.accessoryKeyIds = decoded
        } else {
            self.accessoryKeyIds = MobileTerminalAccessoryKeyDefinition.defaultIds
        }
    }

    private enum Keys {
        static let themeId = "mobileTerminalTheme"
        static let fontSize = "mobileTerminalFontSize"
        static let scrollbackLines = "mobileTerminalScrollbackLines"
        static let cursorStyleId = "mobileTerminalCursorStyle"
        static let mouseReporting = "mobileTerminalMouseReporting"
        static let optionAsMeta = "mobileTerminalOptionAsMeta"
        static let copyOnSelect = "mobileTerminalCopyOnSelect"
        static let accessoryKeyIds = "mobileTerminalAccessoryKeyIds"
    }
}

struct MobileTerminalTheme: Identifiable {
    let id: String
    let label: String
    let background: UIColor
    let foreground: UIColor
    let caret: UIColor
    let ansiPalette: [SwiftTerm.Color]

    func apply(to term: SwiftTerm.TerminalView) {
        term.backgroundColor = background
        term.nativeBackgroundColor = background
        term.nativeForegroundColor = foreground
        term.caretColor = caret
        term.installColors(ansiPalette)
    }

    static func resolve(_ id: String) -> MobileTerminalTheme {
        switch id {
        case "light":
            return .light
        case "dark":
            return .dark
        case "solarized-dark":
            return .solarizedDark
        case "dracula":
            return .dracula
        case "nord":
            return .nord
        case "tomorrow-night":
            return .tomorrowNight
        default:
            return .homebrew
        }
    }

    static let all: [MobileTerminalTheme] = [
        .homebrew,
        .dark,
        .light,
        .solarizedDark,
        .dracula,
        .nord,
        .tomorrowNight,
    ]
}

extension MobileTerminalTheme {
    static let light = MobileTerminalTheme(
        id: "light",
        label: "Light",
        background: .white,
        foreground: .black,
        caret: .black,
        ansiPalette: MobileHexColor.xtermPalette
    )

    static let dark = MobileTerminalTheme(
        id: "dark",
        label: "Dark",
        background: UIColor(white: 0.07, alpha: 1),
        foreground: UIColor(white: 0.92, alpha: 1),
        caret: UIColor(white: 0.92, alpha: 1),
        ansiPalette: MobileHexColor.xtermPalette
    )

    static let homebrew = MobileTerminalTheme(
        id: "homebrew",
        label: "Homebrew",
        background: MobileHexColor.ui("000000"),
        foreground: MobileHexColor.ui("00a600"),
        caret: MobileHexColor.ui("00d900"),
        ansiPalette: [
            MobileHexColor.term("000000"), MobileHexColor.term("990000"), MobileHexColor.term("00a600"), MobileHexColor.term("999900"),
            MobileHexColor.term("0000b2"), MobileHexColor.term("b200b2"), MobileHexColor.term("00a6b2"), MobileHexColor.term("bfbfbf"),
            MobileHexColor.term("666666"), MobileHexColor.term("e50000"), MobileHexColor.term("00d900"), MobileHexColor.term("e5e500"),
            MobileHexColor.term("0000ff"), MobileHexColor.term("e500e5"), MobileHexColor.term("00e5e5"), MobileHexColor.term("e5e5e5"),
        ]
    )

    static let solarizedDark = MobileTerminalTheme(
        id: "solarized-dark",
        label: "Solarized Dark",
        background: MobileHexColor.ui("002b36"),
        foreground: MobileHexColor.ui("839496"),
        caret: MobileHexColor.ui("839496"),
        ansiPalette: [
            MobileHexColor.term("073642"), MobileHexColor.term("dc322f"), MobileHexColor.term("859900"), MobileHexColor.term("b58900"),
            MobileHexColor.term("268bd2"), MobileHexColor.term("d33682"), MobileHexColor.term("2aa198"), MobileHexColor.term("eee8d5"),
            MobileHexColor.term("002b36"), MobileHexColor.term("cb4b16"), MobileHexColor.term("586e75"), MobileHexColor.term("657b83"),
            MobileHexColor.term("839496"), MobileHexColor.term("6c71c4"), MobileHexColor.term("93a1a1"), MobileHexColor.term("fdf6e3"),
        ]
    )

    static let dracula = MobileTerminalTheme(
        id: "dracula",
        label: "Dracula",
        background: MobileHexColor.ui("282a36"),
        foreground: MobileHexColor.ui("f8f8f2"),
        caret: MobileHexColor.ui("f8f8f2"),
        ansiPalette: [
            MobileHexColor.term("21222c"), MobileHexColor.term("ff5555"), MobileHexColor.term("50fa7b"), MobileHexColor.term("f1fa8c"),
            MobileHexColor.term("bd93f9"), MobileHexColor.term("ff79c6"), MobileHexColor.term("8be9fd"), MobileHexColor.term("f8f8f2"),
            MobileHexColor.term("6272a4"), MobileHexColor.term("ff6e6e"), MobileHexColor.term("69ff94"), MobileHexColor.term("ffffa5"),
            MobileHexColor.term("d6acff"), MobileHexColor.term("ff92df"), MobileHexColor.term("a4ffff"), MobileHexColor.term("ffffff"),
        ]
    )

    static let nord = MobileTerminalTheme(
        id: "nord",
        label: "Nord",
        background: MobileHexColor.ui("2e3440"),
        foreground: MobileHexColor.ui("d8dee9"),
        caret: MobileHexColor.ui("d8dee9"),
        ansiPalette: [
            MobileHexColor.term("3b4252"), MobileHexColor.term("bf616a"), MobileHexColor.term("a3be8c"), MobileHexColor.term("ebcb8b"),
            MobileHexColor.term("81a1c1"), MobileHexColor.term("b48ead"), MobileHexColor.term("88c0d0"), MobileHexColor.term("e5e9f0"),
            MobileHexColor.term("4c566a"), MobileHexColor.term("bf616a"), MobileHexColor.term("a3be8c"), MobileHexColor.term("ebcb8b"),
            MobileHexColor.term("81a1c1"), MobileHexColor.term("b48ead"), MobileHexColor.term("8fbcbb"), MobileHexColor.term("eceff4"),
        ]
    )

    static let tomorrowNight = MobileTerminalTheme(
        id: "tomorrow-night",
        label: "Tomorrow Night",
        background: MobileHexColor.ui("1d1f21"),
        foreground: MobileHexColor.ui("c5c8c6"),
        caret: MobileHexColor.ui("c5c8c6"),
        ansiPalette: [
            MobileHexColor.term("1d1f21"), MobileHexColor.term("cc6666"), MobileHexColor.term("b5bd68"), MobileHexColor.term("f0c674"),
            MobileHexColor.term("81a2be"), MobileHexColor.term("b294bb"), MobileHexColor.term("8abeb7"), MobileHexColor.term("c5c8c6"),
            MobileHexColor.term("969896"), MobileHexColor.term("cc6666"), MobileHexColor.term("b5bd68"), MobileHexColor.term("f0c674"),
            MobileHexColor.term("81a2be"), MobileHexColor.term("b294bb"), MobileHexColor.term("8abeb7"), MobileHexColor.term("ffffff"),
        ]
    )
}

enum MobileTerminalCursorStyle: String, CaseIterable, Identifiable {
    case blinkBlock
    case steadyBlock
    case blinkUnderline
    case steadyUnderline
    case blinkBar
    case steadyBar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blinkBlock:
            return "Blink Block"
        case .steadyBlock:
            return "Block"
        case .blinkUnderline:
            return "Blink Underline"
        case .steadyUnderline:
            return "Underline"
        case .blinkBar:
            return "Blink Bar"
        case .steadyBar:
            return "Bar"
        }
    }

    var swiftTermStyle: CursorStyle {
        CursorStyle.from(string: rawValue) ?? .blinkBlock
    }
}

struct MobileTerminalAccessoryKeyDefinition: Identifiable, Hashable {
    let id: String
    let title: String
    let key: MobileTerminalAccessoryKey

    static let all: [MobileTerminalAccessoryKeyDefinition] = [
        .init(id: "escape", title: "Esc", key: .escape),
        .init(id: "tab", title: "Tab", key: .tab),
        .init(id: "enter", title: "Enter", key: .enter),
        .init(id: "left", title: "Left", key: .left),
        .init(id: "down", title: "Down", key: .down),
        .init(id: "up", title: "Up", key: .up),
        .init(id: "right", title: "Right", key: .right),
        .init(id: "slash", title: "/", key: .text("/")),
        .init(id: "dash", title: "-", key: .text("-")),
        .init(id: "pipe", title: "|", key: .text("|")),
        .init(id: "tilde", title: "~", key: .text("~")),
        .init(id: "tmux-prefix", title: "tmux", key: .tmuxPrefix),
        .init(id: "tmux-split", title: "Split", key: .tmuxSplitVertical),
        .init(id: "tmux-pane", title: "Pane", key: .tmuxNextPane),
        .init(id: "ctrl-c", title: "^C", key: .control("c")),
        .init(id: "ctrl-d", title: "^D", key: .control("d")),
        .init(id: "ctrl-l", title: "^L", key: .control("l")),
    ]

    static let defaultIds: [String] = all.map(\.id)

    static func selected(ids: [String]) -> [MobileTerminalAccessoryKeyDefinition] {
        let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let selected = ids.compactMap { byId[$0] }
        return selected.isEmpty ? all : selected
    }
}

enum MobileTerminalAccessoryKey: Hashable {
    case escape
    case tab
    case enter
    case left
    case right
    case up
    case down
    case text(String)
    case control(String)
    case tmuxPrefix
    case tmuxSplitVertical
    case tmuxNextPane

    func data(control: Bool, alt: Bool) -> Data {
        var bytes: [UInt8] = []
        if alt {
            bytes.append(0x1B)
        }

        switch self {
        case .escape:
            bytes.append(0x1B)
        case .tab:
            bytes.append(0x09)
        case .enter:
            bytes.append(control ? 0x0A : 0x0D)
        case .left:
            bytes.append(contentsOf: control ? [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x44] : [0x1B, 0x5B, 0x44])
        case .right:
            bytes.append(contentsOf: control ? [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x43] : [0x1B, 0x5B, 0x43])
        case .up:
            bytes.append(contentsOf: control ? [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x41] : [0x1B, 0x5B, 0x41])
        case .down:
            bytes.append(contentsOf: control ? [0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x42] : [0x1B, 0x5B, 0x42])
        case .text(let value):
            bytes.append(contentsOf: textBytes(value, control: control))
        case .control(let value):
            bytes.append(contentsOf: textBytes(value, control: true))
        case .tmuxPrefix:
            bytes.append(0x02)
        case .tmuxSplitVertical:
            bytes.append(contentsOf: [0x02, 0x25])
        case .tmuxNextPane:
            bytes.append(contentsOf: [0x02, 0x6F])
        }

        return Data(bytes)
    }

    private func textBytes(_ value: String, control: Bool) -> [UInt8] {
        guard control else {
            return Array(value.utf8)
        }

        switch value.lowercased() {
        case "a": return [0x01]
        case "b": return [0x02]
        case "c": return [0x03]
        case "d": return [0x04]
        case "e": return [0x05]
        case "f": return [0x06]
        case "g": return [0x07]
        case "h": return [0x08]
        case "i": return [0x09]
        case "j": return [0x0A]
        case "k": return [0x0B]
        case "l": return [0x0C]
        case "m": return [0x0D]
        case "n": return [0x0E]
        case "o": return [0x0F]
        case "p": return [0x10]
        case "q": return [0x11]
        case "r": return [0x12]
        case "s": return [0x13]
        case "t": return [0x14]
        case "u": return [0x15]
        case "v": return [0x16]
        case "w": return [0x17]
        case "x": return [0x18]
        case "y": return [0x19]
        case "z": return [0x1A]
        case "[": return [0x1B]
        case "\\": return [0x1C]
        case "]": return [0x1D]
        case "^": return [0x1E]
        case "/": return [0x1F]
        default: return Array(value.utf8)
        }
    }
}

private enum MobileHexColor {
    static let xtermPalette: [SwiftTerm.Color] = [
        term("000000"), term("cd0000"), term("00cd00"), term("cdcd00"),
        term("0000ee"), term("cd00cd"), term("00cdcd"), term("e5e5e5"),
        term("7f7f7f"), term("ff0000"), term("00ff00"), term("ffff00"),
        term("5c5cff"), term("ff00ff"), term("00ffff"), term("ffffff"),
    ]

    static func ui(_ hex: String) -> UIColor {
        let (red, green, blue) = parse(hex)
        return UIColor(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    static func term(_ hex: String) -> SwiftTerm.Color {
        let (red, green, blue) = parse(hex)
        return SwiftTerm.Color(
            red: UInt16(red) &* 257,
            green: UInt16(green) &* 257,
            blue: UInt16(blue) &* 257
        )
    }

    private static func parse(_ hex: String) -> (UInt8, UInt8, UInt8) {
        precondition(hex.count == 6, "expected 6-char hex, got \(hex)")
        let bytes = stride(from: 0, to: 6, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            guard let value = UInt8(hex[start..<end], radix: 16) else {
                preconditionFailure("malformed hex segment in \(hex)")
            }
            return value
        }
        return (bytes[0], bytes[1], bytes[2])
    }
}
