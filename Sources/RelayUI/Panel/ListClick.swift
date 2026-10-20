import AppKit

/// Click versus key in the queue. The List calls its selection binding's
/// setter only for changes it makes itself, so `opensOnSelection` is asked only about
/// those; programmatic selection (Back, After Done, Undo) never opens an ask.
enum ListClick {
    /// The List just changed the selection because of this event. A left click opens
    /// the row; arrow keys, a right click and everything else only select.
    static func opensOnSelection(_ type: NSEvent.EventType?) -> Bool {
        type == .leftMouseDown || type == .leftMouseUp
    }

    /// A click on the row that is already selected doesn't change the selection, so
    /// the row's tap gesture opens it, unless a detail already shows (the setter opened it).
    static func tapOpens(openDetail: String?) -> Bool {
        openDetail == nil
    }
}
