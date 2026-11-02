import Foundation
import RelayCore
import Testing
import UniformTypeIdentifiers
@testable import RelayUI

/// What a file row's actions reached: the shell's file actions and its pasteboard.
@MainActor private final class FileRecorder {
    var acted: [String] = []
    var copied: [String] = []
    /// Runs inside the click's file check, between the row's first gate and the act.
    var duringCheck: (@MainActor () async -> Void)?

    func actions(_ found: FileCheck) -> FileActions {
        FileActions(
            check: { [weak self] _ in
                await self?.duringCheck?()
                return found
            },
            open: { [weak self] _ in self?.acted.append("open") },
            openWith: { [weak self] _, _ in self?.acted.append("openWith") },
            openWithOther: { [weak self] _ in self?.acted.append("openWithOther") },
            reveal: { [weak self] _ in self?.acted.append("reveal") },
            apps: { _ in [] })
    }
}

/// The file rows' lock (Open, Open With, Reveal in Finder, Copy Path): each goes through the
/// Store's stamp-bound check at the moment it acts, never the lock the row rendered.
@Suite @MainActor struct FileRowLockTests {
    private static let stepFile = "/Users/someone/plans/brief.md"
    private static let linkFile = "~/notes/plan.md"
    private static let checked = FileCheck.document(CheckedFile(url: URL(fileURLWithPath: stepFile), type: .text,
                                                               device: 1, inode: 2))
    private static let commands: [FileRowCommand] = [.open, .openWith(URL(fileURLWithPath: "/Applications/TextEdit.app")),
                                                     .openWithOther, .reveal, .copyPath]

    private func body(_ code: String) -> Instructable {
        var body = idSteps(2, codes: [2: code])
        body.steps[0].file = Self.stepFile
        body.links = [LinkRef(label: "Plan", path: Self.linkFile)]
        return body
    }

    /// An accepted rev 2 of "a", open, and the row context DetailView builds for its snapshot.
    private func acceptedStore(_ defaults: TestDefaults) async -> (Store, FakeQueueSource, RevisionStamp?) {
        let store = reviewingStore(defaults)
        let two = revised("a", [body("run 2"), body("run two")])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        store.open("a")
        markAccepted(store, "a", two.detail.revisions[1].stamp)
        return (store, fake, store.detail("a")?.stamp)
    }

    private func correct(_ fake: FakeQueueSource, _ store: Store) async {
        let three = revised("a", [body("run 2"), body("run two"), body("run 3")])
        await fake.setItems([three.item])
        await fake.setDetail(three.detail)
        await store.refresh()
    }

    private func context(_ store: Store, stamp: RevisionStamp?, _ recorder: FileRecorder) -> FileRowContext {
        FileRowContext(actions: recorder.actions(Self.checked), copy: { recorder.copied.append($0) },
                       allows: { store.allowsFileAction("a", stamp: stamp, path: $0) })
    }

    @Test func theStoreAllowsOnlyAShownFileOfTheRenderedRevision() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let store = reviewingStore(defaults)
        let two = revised("a", [body("run 2"), body("run two")])
        let fake = FakeQueueSource(items: [two.item], details: ["a": two.detail])
        await start(store, fake)
        store.open("a")
        // Locked: no file, whatever the stamp.
        for stamp in [store.detail("a")?.stamp, two.detail.revisions[1].stamp] {
            #expect(store.allowsFileAction("a", stamp: stamp, path: Self.stepFile) == false)
            #expect(store.allowsFileAction("a", stamp: stamp, path: Self.linkFile) == false)
        }
        markAccepted(store, "a", two.detail.revisions[1].stamp)
        let shown = store.detail("a")?.stamp
        #expect(store.allowsFileAction("a", stamp: shown, path: Self.stepFile))
        #expect(store.allowsFileAction("a", stamp: shown, path: Self.linkFile))
        #expect(store.allowsFileAction("a", stamp: shown, path: "/etc/passwd") == false)
        await correct(fake, store)
        #expect(store.allowsFileAction("a", stamp: shown, path: Self.stepFile) == false)
    }

    @Test func eachActionWorksWhileTheRenderedRevisionIsCurrent() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, _, shown) = await acceptedStore(defaults)
        let recorder = FileRecorder()
        let context = context(store, stamp: shown, recorder)
        let link = FileLink(Self.stepFile, home: "/Users/someone")!
        for command in Self.commands {
            #expect(await context.perform(command, on: link, state: .available).outcome == .done)
        }
        #expect(recorder.acted == ["open", "openWith", "openWithOther", "reveal"])
        #expect(recorder.copied == [Self.stepFile])
    }

    @Test func aCorrectionBetweenRenderAndClickRefusesEachAction() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, shown) = await acceptedStore(defaults)
        let recorder = FileRecorder()
        // The row rendered unlocked, at `shown`; rev 3 arrives before the click.
        let context = context(store, stamp: shown, recorder)
        #expect(context.actionsEnabled)
        await correct(fake, store)
        for raw in [Self.stepFile, Self.linkFile] {
            let link = FileLink(raw, home: "/Users/someone")!
            for command in Self.commands {
                let result = await context.perform(command, on: link, state: .available)
                #expect(result.outcome == .refused)
                #expect(result.check == nil)
            }
        }
        #expect(recorder.acted.isEmpty)
        #expect(recorder.copied.isEmpty)
    }

    @Test func aCorrectionDuringTheFileCheckRefusesTheAct() async {
        let defaults = TestDefaults()
        defer { defaults.drop() }
        let (store, fake, shown) = await acceptedStore(defaults)
        let recorder = FileRecorder()
        let context = context(store, stamp: shown, recorder)
        let link = FileLink(Self.stepFile, home: "/Users/someone")!
        var corrected = false
        recorder.duringCheck = {
            guard !corrected else { return }
            corrected = true
            await correct(fake, store)
        }
        for command in [FileRowCommand.open, .reveal] {
            #expect(await context.perform(command, on: link, state: .available).outcome == .refused)
        }
        #expect(recorder.acted.isEmpty)
    }

    @Test func aLockedContextRefusesWithoutAskingTheStore() async {
        let recorder = FileRecorder()
        var asked = 0
        let context = FileRowContext(actions: recorder.actions(Self.checked), copy: { recorder.copied.append($0) },
                                     contentLocked: true, allows: { _ in asked += 1; return true })
        let link = FileLink(Self.stepFile, home: "/Users/someone")!
        for command in Self.commands {
            #expect(await context.perform(command, on: link, state: .available).outcome == .refused)
        }
        #expect(asked == 0)
        #expect(recorder.acted.isEmpty)
        #expect(recorder.copied.isEmpty)
    }

    @Test func aFileTheCheckDoesNotFindIsUnavailableNotDone() async {
        let recorder = FileRecorder()
        let context = FileRowContext(actions: recorder.actions(.missing), copy: { recorder.copied.append($0) })
        let link = FileLink(Self.stepFile, home: "/Users/someone")!
        let result = await context.perform(.open, on: link, state: .available)
        #expect(result.outcome == .unavailable)
        #expect(result.check == .missing)
        #expect(recorder.acted.isEmpty)
    }

    @Test func copyPathFromAnotherMacCopiesThePathAsSent() async {
        let recorder = FileRecorder()
        let context = FileRowContext(actions: recorder.actions(Self.checked), copy: { recorder.copied.append($0) })
        let link = FileLink(Self.linkFile, home: "/Users/someone")!
        #expect(await context.perform(.copyPath, on: link, state: .otherMac("studio")).outcome == .done)
        #expect(await context.perform(.copyPath, on: link, state: .available).outcome == .done)
        #expect(recorder.copied == [Self.linkFile, "/Users/someone/notes/plan.md"])
    }
}
