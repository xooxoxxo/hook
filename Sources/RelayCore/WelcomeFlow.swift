import Foundation

/// The setup window's seven pages. Pure: the view feeds it Continue, Back, the source
/// page's Start, the first list, the 10 s timer, config changes and the window closing.
public struct WelcomeFlow: Equatable, Sendable {
    public enum Page: Int, CaseIterable, Sendable {
        case welcome, source, agents, notifications, shortcut, testAsk, done

        /// 1-based, for the dots and VoiceOver ("Page 2 of 7").
        public var number: Int { rawValue + 1 }

        /// Continue may leave these with nothing done: the page is then skipped, not done.
        /// The source page needs a source; Welcome and Done have nothing to do.
        public var optional: Bool {
            switch self {
            case .agents, .notifications, .shortcut, .testAsk: true
            case .welcome, .source, .done: false
            }
        }
    }

    public static let pageCount = Page.allCases.count
    public static let firstListTimeout: TimeInterval = MailboxDraft.connectTimeout

    public var page: Page
    /// Start was pressed for a mailbox and the first list hasn't answered yet.
    public var starting = false
    /// "Can't reach the mailbox: <reason>", under the source page's fields.
    public var error: String?
    /// Pages left with their action done, and optional pages left without it.
    public private(set) var done: Set<Page> = []
    public private(set) var skipped: Set<Page> = []
    /// The last move went forward (push from the trailing edge) or back.
    public private(set) var forward = true
    /// Open Hook was pressed, or the window closed: setup is over either way.
    public private(set) var finished = false
    /// Setup ended before the Done page's Open Hook.
    public private(set) var skippedSetup = false

    public init(page: Page = .welcome) {
        self.page = page
    }

    public var canGoBack: Bool { page != .welcome && !starting && !finished }

    /// Continue on any page but the source page (whose Continue is `startTapped`).
    /// `complete`: the page's own action is done; an optional page left without it is skipped.
    public mutating func continueTapped(complete: Bool = true) {
        guard !finished, !starting else { return }
        switch page {
        case .source:
            return
        case .done:
            done.insert(.done)
            finished = true
            return
        default:
            break
        }
        if page.optional && !complete {
            skipped.insert(page)
            done.remove(page)
        } else {
            done.insert(page)
            skipped.remove(page)
        }
        advance()
    }

    public mutating func back() {
        guard canGoBack, let previous = Page(rawValue: page.rawValue - 1) else { return }
        error = nil
        forward = false
        page = previous
    }

    /// The window closed before Open Hook: setup counts as skipped.
    public mutating func closed() {
        guard !finished else { return }
        finished = true
        skippedSetup = true
    }

    // MARK: The source page

    public mutating func startTapped(isMailbox: Bool) {
        guard page == .source, !starting, !finished else { return }
        error = nil
        if isMailbox {
            starting = true
        } else {
            sourceDone()
        }
    }

    public mutating func firstList(ok: Bool, reason: String?) {
        guard page == .source, starting else { return }
        starting = false
        if ok {
            sourceDone()
        } else {
            error = "Can't reach the mailbox: " + (reason ?? MailboxDraft.noAnswer)
        }
    }

    /// Start's save of config.json failed (This Mac): the page stays with the reason.
    public mutating func saveFailed(_ text: String) {
        guard page == .source else { return }
        starting = false
        error = text
    }

    public mutating func timedOut() {
        firstList(ok: false, reason: MailboxDraft.noAnswer)
    }

    /// install.sh wrote a working config while the source page was open. During Start the
    /// save is Start's own, so the first list decides.
    public mutating func configResolved() {
        guard page == .source, !starting, !finished else { return }
        sourceDone()
    }

    // MARK: When it shows

    /// At launch: a missing config, one with no source yet, or one that holds
    /// `onboarding: "pending"`. Never over a config.json that can't be read.
    public static func showsAtLaunch(_ load: ConfigLoad) -> Bool {
        switch load {
        case .missing: true
        case .unreadable: false
        case .loaded(let config): config.resolvedSource() == .incomplete || config.wantsOnboarding
        }
    }

    /// Setup is over and the config still holds the `onboarding` key: remove it, so the
    /// window doesn't come back at the next launch. Never creates a config.
    public static func removesOnboardingKey(finished: Bool, config: RelayConfig?) -> Bool {
        finished && config?.onboarding != nil
    }

    private mutating func sourceDone() {
        done.insert(.source)
        advance()
    }

    private mutating func advance() {
        guard let next = Page(rawValue: page.rawValue + 1) else { return }
        error = nil
        forward = true
        page = next
    }
}
