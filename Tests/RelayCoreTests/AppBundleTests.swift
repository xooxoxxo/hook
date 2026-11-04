import Foundation
import Testing

/// What Hook.app carries besides the binary: the app icon (named in Info.plist, copied by
/// scripts/build.sh) and the menu-bar glyphs.
@Suite struct AppBundleTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func infoPlistNamesTheIcon() throws {
        let data = try Data(contentsOf: Self.root.appending(path: "Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
    }

    /// Every slot from 16 pt @1x to 512 pt @2x: ic04/ic05 (16 and 32 px), ic11-ic14 (the @2x
    /// slots), ic07-ic10 (128 to 1024 px).
    @Test func theIconHasEverySize() throws {
        let data = try Data(contentsOf: Self.root.appending(path: "Resources/AppIcon.icns"))
        let bytes = [UInt8](data)
        #expect(String(decoding: bytes[0..<4], as: UTF8.self) == "icns")
        func be32(_ at: Int) -> Int { bytes[at..<at + 4].reduce(0) { $0 << 8 | Int($1) } }
        #expect(be32(4) == bytes.count)
        var types: Set<String> = []
        var offset = 8
        while offset + 8 <= bytes.count {
            let length = be32(offset + 4)
            guard length >= 8 else { break }
            types.insert(String(decoding: bytes[offset..<offset + 4], as: UTF8.self))
            offset += length
        }
        #expect(offset == bytes.count)
        let slots: Set<String> = ["ic04", "ic05", "ic07", "ic08", "ic09", "ic10", "ic11", "ic12", "ic13", "ic14"]
        #expect(slots.subtracting(types).sorted() == [])
    }

    @Test func buildCopiesTheIconAndTheGlyphs() throws {
        let script = try String(contentsOf: Self.root.appending(path: "scripts/build.sh"), encoding: .utf8)
        #expect(script.contains(#"cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns""#))
        #expect(script.contains(#"cp -R "$MENUBAR" "$APP/Contents/Resources/MenuBar""#))
        let glyphs = Self.root.appending(path: "Sources/RelayUI/Resources/MenuBar")
        for name in ["menubar-idle.png", "menubar-idle@2x.png", "menubar-new.png", "menubar-new@2x.png"] {
            #expect(FileManager.default.fileExists(atPath: glyphs.appending(path: name).path), "\(name)")
        }
    }
}
