import Testing
@testable import RelayCore

private func item(_ id: String, updated: String) -> WireItem {
    WireItem(
        id: id, title: "t-\(id)", status: "open", projectId: "P",
        created: "2026-10-10T12:00:00+00:00", updated: updated,
        payload: Payload(why: nil, cmd: nil, link: nil, instructable: nil))
}

@Test func diffFindsAddedChangedRemoved() {
    let old = [item("a", updated: "1"), item("b", updated: "1"), item("c", updated: "1")]
    let new = [item("d", updated: "1"), item("a", updated: "1"), item("b", updated: "2")]
    let diff = QueueLogic.diff(old: old, new: new)
    #expect(diff == QueueDiff(added: ["d"], changed: ["b"], removed: ["c"]))
    #expect(QueueLogic.normalizedID("6F1C2B0E-8A1D-4C55-9A77-0D2F3C4B5A61")
            == "6f1c2b0e-8a1d-4c55-9a77-0d2f3c4b5a61")
    #expect(QueueLogic.normalizedID("../../etc/passwd") == nil)
}
