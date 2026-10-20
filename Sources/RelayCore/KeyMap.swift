import Foundation

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

/// The keys the panel listens for.
public enum PanelKey: Hashable, Sendable {
    case escape, returnKey, optionReturn, up, down, left, right, digit(Int)
    case cmdW, cmdR, cmdComma, cmdZ, shiftCmdZ, cmdQ, cmdReturn, cmdDelete, cmdLeftBracket, cmdUp, cmdDown, cmdT, cmdL
    case shiftCmdT, shiftCmdC, shiftCmdO, shiftCmdR, shiftCmdL, ctrlCmdLeft, ctrlCmdRight, ctrlCmdG, ctrlCmdA, ctrlCmdP
}

public struct KeyContext: Equatable, Sendable {
    public enum Mode: Sendable { case list, detail }
    public var mode: Mode
    public var textFieldFocused: Bool
    public var popoverOpen: Bool
    /// A Done or Skip is held (the Undo bar shows).
    public var undoAvailable: Bool
    public var filterOn: Bool
    /// List: nil with no selection, true for an open ask, false for a closed one.
    public var selectionOpen: Bool?
    public var selectionHasProject: Bool
    public var closedHeaderFocused: Bool
    /// Detail: the open ask is open (not closed).
    public var askOpen: Bool
    public var askHasProject: Bool
    public var choiceCount: Int
    public var hasDraftOrPick: Bool

    public init(mode: Mode, textFieldFocused: Bool = false, popoverOpen: Bool = false, undoAvailable: Bool = false,
                filterOn: Bool = false, selectionOpen: Bool? = nil, selectionHasProject: Bool = false, closedHeaderFocused: Bool = false,
                askOpen: Bool = true, askHasProject: Bool = false, choiceCount: Int = 0, hasDraftOrPick: Bool = false) {
        self.mode = mode
        self.textFieldFocused = textFieldFocused
        self.popoverOpen = popoverOpen
        self.undoAvailable = undoAvailable
        self.filterOn = filterOn
        self.selectionOpen = selectionOpen
        self.selectionHasProject = selectionHasProject
        self.closedHeaderFocused = closedHeaderFocused
        self.askOpen = askOpen
        self.askHasProject = askHasProject
        self.choiceCount = choiceCount
        self.hasDraftOrPick = hasDraftOrPick
    }
}

public enum PanelCommand: Equatable, Sendable {
    case closePopover, endEditing, back, hide, refresh, openSettings, undoClose, quit, dock(SidebarEdge), switchGrouping, clearFilter
    case showOnlyProject, openSelection, done, sendAndDone, skip, reopen, copyLink, setClosedExpanded(Bool)
    /// `pickChoice(i)`: the 0-based choice index.
    case previousAsk, nextAsk, tickCurrent, untickLast, copyCurrentCode, openCurrentURL, focusReply, pickChoice(Int)
}

/// The single source for the panel's keys. Inside a focused text field the text-editing
/// meaning wins (⌘Z, ⇧⌘Z, ⌘⌫, ⌘↑/⌘↓, Return): those return nil and go on to the field.
public enum KeyMap {
    public static func command(for key: PanelKey, in c: KeyContext) -> PanelCommand? {
        if key == .escape {
            if c.popoverOpen { return .closePopover }
            if c.textFieldFocused { return .endEditing }
            return c.mode == .detail ? .back : .hide
        }
        if c.popoverOpen { return nil }

        switch key {
        case .cmdW: return .hide
        case .cmdR: return .refresh
        case .cmdComma: return .openSettings
        case .cmdQ: return .quit
        case .cmdZ: return !c.textFieldFocused && c.undoAvailable ? .undoClose : nil
        case .shiftCmdZ: return nil
        case .ctrlCmdLeft: return .dock(.left)
        case .ctrlCmdRight: return .dock(.right)
        case .ctrlCmdG: return .switchGrouping
        case .ctrlCmdA: return c.filterOn ? .clearFilter : nil
        default: break
        }

        switch c.mode {
        case .list: return listCommand(key, c)
        case .detail: return detailCommand(key, c)
        }
    }

    private static func listCommand(_ key: PanelKey, _ c: KeyContext) -> PanelCommand? {
        switch key {
        case .returnKey:
            return !c.textFieldFocused && !c.closedHeaderFocused && c.selectionOpen != nil ? .openSelection : nil
        case .cmdReturn: return c.selectionOpen == true ? .done : nil
        case .cmdDelete: return !c.textFieldFocused && c.selectionOpen == true ? .skip : nil
        case .shiftCmdR: return c.selectionOpen == false ? .reopen : nil
        case .shiftCmdL: return c.selectionOpen != nil ? .copyLink : nil
        case .ctrlCmdP: return c.selectionOpen != nil && c.selectionHasProject ? .showOnlyProject : nil
        case .right: return c.closedHeaderFocused ? .setClosedExpanded(true) : nil
        case .left: return c.closedHeaderFocused ? .setClosedExpanded(false) : nil
        default: return nil
        }
    }

    private static func detailCommand(_ key: PanelKey, _ c: KeyContext) -> PanelCommand? {
        switch key {
        case .cmdLeftBracket: return .back
        case .cmdUp: return c.textFieldFocused ? nil : .previousAsk
        case .cmdDown: return c.textFieldFocused ? nil : .nextAsk
        case .cmdReturn: return c.askOpen ? (c.hasDraftOrPick ? .sendAndDone : .done) : nil
        case .cmdDelete: return !c.textFieldFocused && c.askOpen ? .skip : nil
        case .shiftCmdR: return c.askOpen ? nil : .reopen
        case .cmdT: return c.askOpen ? .tickCurrent : nil
        case .shiftCmdT: return c.askOpen ? .untickLast : nil
        case .shiftCmdC: return .copyCurrentCode
        case .shiftCmdO: return .openCurrentURL
        case .ctrlCmdP: return c.askHasProject ? .showOnlyProject : nil
        case .cmdL: return .focusReply
        case .shiftCmdL: return .copyLink
        case .digit(let n):
            guard !c.textFieldFocused, n >= 1, n <= min(6, c.choiceCount) else { return nil }
            return .pickChoice(n - 1)
        default: return nil
        }
    }
}

// MARK: Key events

extension PanelKey {
    /// kVK codes of the digit keys 1–6 (ANSI positions; 5 and 6 are swapped on the hardware).
    static let digitCodes: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6]

    /// A key-down as a panel key, or nil when it is not one. Keys whose character is not
    /// printable or moves with the layout (Esc, Return, Delete, arrows, "[", digits) are read
    /// by kVK code; letters and "," by `characters` (charactersIgnoringModifiers), lowercased,
    /// so ⇧⌘Z arriving as "Z" is still Z. Only the command, shift, option and control
    /// modifiers count; the caller drops the others.
    public init?(keyCode: UInt16, modifiers: KeyModifiers, characters: String?) {
        let character = characters?.lowercased() ?? ""
        switch modifiers {
        case []:
            switch keyCode {
            case 53: self = .escape
            case 36, 76: self = .returnKey
            case 126: self = .up
            case 125: self = .down
            case 123: self = .left
            case 124: self = .right
            default:
                guard let digit = Self.digitCodes[keyCode] else { return nil }
                self = .digit(digit)
            }
        case [.option]:
            guard keyCode == 36 || keyCode == 76 else { return nil }
            self = .optionReturn
        case [.command]:
            switch keyCode {
            case 36, 76: self = .cmdReturn
            case 51: self = .cmdDelete
            case 126: self = .cmdUp
            case 125: self = .cmdDown
            case 33: self = .cmdLeftBracket
            default:
                switch character {
                case "w": self = .cmdW
                case "r": self = .cmdR
                case ",": self = .cmdComma
                case "z": self = .cmdZ
                case "q": self = .cmdQ
                case "t": self = .cmdT
                case "l": self = .cmdL
                default: return nil
                }
            }
        case [.shift, .command]:
            switch character {
            case "z": self = .shiftCmdZ
            case "t": self = .shiftCmdT
            case "c": self = .shiftCmdC
            case "o": self = .shiftCmdO
            case "r": self = .shiftCmdR
            case "l": self = .shiftCmdL
            default: return nil
            }
        case [.control, .command]:
            switch keyCode {
            case 123: self = .ctrlCmdLeft
            case 124: self = .ctrlCmdRight
            default:
                switch character {
                case "g": self = .ctrlCmdG
                case "a": self = .ctrlCmdA
                case "p": self = .ctrlCmdP
                default: return nil
                }
            }
        default:
            return nil
        }
    }
}
