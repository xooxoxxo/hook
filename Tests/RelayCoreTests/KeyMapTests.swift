import Testing
@testable import RelayCore

private let list = KeyContext(mode: .list, selectionOpen: true, selectionHasProject: true)
private let detail = KeyContext(mode: .detail, askOpen: true, askHasProject: true, choiceCount: 3)
private func typing(_ c: KeyContext) -> KeyContext { var c = c; c.textFieldFocused = true; return c }

@Suite struct KeyMapTests {
    private func cmd(_ key: PanelKey, _ context: KeyContext) -> PanelCommand? { KeyMap.command(for: key, in: context) }

    // Panel, any context
    @Test func escapeLayers() {
        var c = list
        c.popoverOpen = true
        #expect(cmd(.escape, c) == .closePopover)
        #expect(cmd(.escape, typing(detail)) == .endEditing)
        #expect(cmd(.escape, detail) == .back)
        #expect(cmd(.escape, list) == .hide)
    }

    @Test func panelWideKeys() {
        for context in [list, detail, typing(detail)] {
            #expect(cmd(.cmdW, context) == .hide)
            #expect(cmd(.cmdR, context) == .refresh)
            #expect(cmd(.cmdComma, context) == .openSettings)
            #expect(cmd(.cmdQ, context) == .quit)
            #expect(cmd(.ctrlCmdLeft, context) == .dock(.left))
            #expect(cmd(.ctrlCmdRight, context) == .dock(.right))
            #expect(cmd(.ctrlCmdG, context) == .switchGrouping)
        }
    }

    @Test func undoOnlyOutsideTextFieldsAndWhenHeld() {
        var c = list
        c.undoAvailable = true
        #expect(cmd(.cmdZ, c) == .undoClose)
        #expect(cmd(.cmdZ, typing(c)) == nil)
        #expect(cmd(.cmdZ, list) == nil)
        #expect(cmd(.shiftCmdZ, c) == nil)
        #expect(cmd(.shiftCmdZ, typing(c)) == nil)
    }

    @Test func showAllProjectsNeedsAFilter() {
        var c = list
        #expect(cmd(.ctrlCmdA, c) == nil)
        c.filterOn = true
        #expect(cmd(.ctrlCmdA, c) == .clearFilter)
    }

    // List
    @Test func listArrowsAreStock() {
        for key in [PanelKey.up, .down] { #expect(cmd(key, list) == nil) }
    }

    @Test func listReturnOpens() {
        #expect(cmd(.returnKey, list) == .openSelection)
        #expect(cmd(.returnKey, KeyContext(mode: .list)) == nil)
        var header = list
        header.closedHeaderFocused = true
        #expect(cmd(.returnKey, header) == nil)
    }

    @Test func listDoneSkipReopenOnTheSelection() {
        #expect(cmd(.cmdReturn, list) == .done)
        #expect(cmd(.cmdDelete, list) == .skip)
        #expect(cmd(.shiftCmdR, list) == nil)
        var closed = list
        closed.selectionOpen = false
        #expect(cmd(.cmdReturn, closed) == nil)
        #expect(cmd(.cmdDelete, closed) == nil)
        #expect(cmd(.shiftCmdR, closed) == .reopen)
        #expect(cmd(.cmdReturn, KeyContext(mode: .list)) == nil)
    }

    @Test func listCopyLinkAndShowOnly() {
        #expect(cmd(.shiftCmdL, list) == .copyLink)
        #expect(cmd(.shiftCmdL, KeyContext(mode: .list)) == nil)
        #expect(cmd(.ctrlCmdP, list) == .showOnlyProject)
        var noProject = list
        noProject.selectionHasProject = false
        #expect(cmd(.ctrlCmdP, noProject) == nil)
    }

    @Test func listClosedHeaderArrows() {
        var header = list
        header.closedHeaderFocused = true
        #expect(cmd(.right, header) == .setClosedExpanded(true))
        #expect(cmd(.left, header) == .setClosedExpanded(false))
        #expect(cmd(.right, list) == nil)
    }

    // Detail
    @Test func detailBack() {
        #expect(cmd(.cmdLeftBracket, detail) == .back)
    }

    @Test func detailNeighboursUnlessTyping() {
        #expect(cmd(.cmdUp, detail) == .previousAsk)
        #expect(cmd(.cmdDown, detail) == .nextAsk)
        #expect(cmd(.cmdUp, typing(detail)) == nil)
        #expect(cmd(.cmdDown, typing(detail)) == nil)
    }

    @Test func detailPrimaryActsWhileTyping() {
        #expect(cmd(.cmdReturn, detail) == .done)
        var draft = typing(detail)
        draft.hasDraftOrPick = true
        #expect(cmd(.cmdReturn, draft) == .sendAndDone)
        var closed = detail
        closed.askOpen = false
        #expect(cmd(.cmdReturn, closed) == nil)
    }

    @Test func detailSkipNotWhileTyping() {
        #expect(cmd(.cmdDelete, detail) == .skip)
        #expect(cmd(.cmdDelete, typing(detail)) == nil)
        var closed = detail
        closed.askOpen = false
        #expect(cmd(.cmdDelete, closed) == nil)
    }

    @Test func detailReopenOnlyWhenClosed() {
        #expect(cmd(.shiftCmdR, detail) == nil)
        var closed = detail
        closed.askOpen = false
        #expect(cmd(.shiftCmdR, closed) == .reopen)
    }

    @Test func detailTicks() {
        #expect(cmd(.cmdT, detail) == .tickCurrent)
        #expect(cmd(.shiftCmdT, detail) == .untickLast)
        var closed = detail
        closed.askOpen = false
        #expect(cmd(.cmdT, closed) == nil)
        #expect(cmd(.shiftCmdT, closed) == nil)
    }

    @Test func detailCurrentLeafKeys() {
        #expect(cmd(.shiftCmdC, detail) == .copyCurrentCode)
        #expect(cmd(.shiftCmdO, detail) == .openCurrentURL)
    }

    @Test func detailShowOnly() {
        #expect(cmd(.ctrlCmdP, detail) == .showOnlyProject)
        var noProject = detail
        noProject.askHasProject = false
        #expect(cmd(.ctrlCmdP, noProject) == nil)
    }

    @Test func detailFocusReplyAndCopyLink() {
        #expect(cmd(.cmdL, detail) == .focusReply)
        #expect(cmd(.shiftCmdL, detail) == .copyLink)
    }

    @Test func detailDigitsPickChoices() {
        #expect(cmd(.digit(1), detail) == .pickChoice(0))
        #expect(cmd(.digit(3), detail) == .pickChoice(2))
        #expect(cmd(.digit(4), detail) == nil)
        #expect(cmd(.digit(1), typing(detail)) == nil)
        #expect(cmd(.digit(1), list) == nil)
        var six = detail
        six.choiceCount = 6
        #expect(cmd(.digit(6), six) == .pickChoice(5))
        #expect(cmd(.digit(7), six) == nil)
    }

    // Reply field
    @Test func returnAndOptionReturnBelongToTheField() {
        #expect(cmd(.returnKey, typing(detail)) == nil)
        #expect(cmd(.optionReturn, typing(detail)) == nil)
        #expect(cmd(.returnKey, detail) == nil)
        #expect(cmd(.returnKey, typing(list)) == nil)
    }

    @Test func aPopoverTakesEverythingButEscape() {
        var c = detail
        c.popoverOpen = true
        #expect(cmd(.cmdReturn, c) == nil)
        #expect(cmd(.cmdW, c) == nil)
    }

    @Test func modifiers() {
        let both: KeyModifiers = [.command, .shift]
        #expect(both.contains(.command) && both.contains(.shift) && !both.contains(.option))
        #expect(Set([KeyModifiers.command, .shift, .option, .control].map(\.rawValue)).count == 4)
    }

}
