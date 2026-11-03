import Foundation
import RelayCore

/// The crash bar and the status bar's profile switcher.
extension Store {
    /// The launch check found a crash to offer. A later one replaces it.
    public func offerCrash(_ summary: CrashSummary) {
        let offer = CrashOffer(summary: summary)
        guard crashOffer != offer else { return }
        crashOffer = offer
    }

    /// Not Now: the bar goes, and the signature is handled so it isn't raised again.
    public func dismissCrash() {
        guard let offer = crashOffer else { return }
        crashOffer = nil
        onCrashHandled?(offer.summary.signature)
    }

    /// Review…: the send sheet.
    public func reviewCrash() {}

    /// Only on change, so a config reload that keeps the profiles doesn't republish.
    public func setProfiles(_ menu: ProfileMenu) {
        guard profiles != menu else { return }
        profiles = menu
    }

    /// Saves `source` (the shell merges it into config.json, as Settings › Queue does); the
    /// config reload then swaps the queue. Nothing happens for the profile already shown,
    /// or while config.json can't be saved.
    public func switchProfile(_ kind: SourceKind) {
        guard !profiles.readOnly, profiles.current?.kind != kind,
              profiles.profiles.contains(where: { $0.kind == kind }) else { return }
        shell.switchSource(kind)
    }

    public func setUpdating(_ on: Bool) {
        guard updating != on else { return }
        updating = on
    }
}
