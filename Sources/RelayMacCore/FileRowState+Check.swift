import RelayCore

extension FileRowState {
    /// The state a click found; nil when the file is a document that opened.
    public static func after(_ check: FileCheck) -> FileRowState? {
        switch check {
        case .document: return nil
        case .refused: return .refused
        case .missing: return .missing
        case .network: return .network
        }
    }

}
