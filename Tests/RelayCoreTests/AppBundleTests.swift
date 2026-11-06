import Foundation
import Testing

/// What Hook.app carries besides the binary: the app icon (named in Info.plist, copied by
/// scripts/build.sh) and the menu-bar glyphs. The icon is Assets.car, compiled from
/// Resources/AppIcon.icon by scripts/app-icon.sh (CFBundleIconName), and AppIcon.icns
/// (CFBundleIconFile).
@Suite struct AppBundleTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func infoPlistNamesTheIcon() throws {
        let data = try Data(contentsOf: Self.root.appending(path: "Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        #expect(plist["CFBundleIconName"] as? String == "AppIcon")
    }

    /// macOS 26 and later only fill their icon shape with an icon compiled from an Icon Composer
    /// document: a BOM-store catalog holding AppIcon's layered stack, beside the flat images
    /// macOS 14 and 15 read.
    @Test func theCatalogHoldsTheLayeredIcon() throws {
        let car = try Data(contentsOf: Self.root.appending(path: "Resources/Assets.car"))
        #expect(car.prefix(8) == Data("BOMStore".utf8))
        #expect(car.range(of: Data("AppIcon.iconstack".utf8)) != nil)
        let icon = Self.root.appending(path: "Resources/AppIcon.icon")
        let json = try Data(contentsOf: icon.appending(path: "icon.json"))
        let doc = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let groups = try #require(doc["groups"] as? [[String: Any]])
        let images = groups.flatMap { ($0["layers"] as? [[String: Any]]) ?? [] }.compactMap { $0["image-name"] as? String }
        #expect(!images.isEmpty)
        for name in images {
            #expect(FileManager.default.fileExists(atPath: icon.appending(path: "Assets/\(name)").path), "\(name)")
        }
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
        #expect(script.contains(#"cp Resources/Assets.car "$APP/Contents/Resources/Assets.car""#))
        #expect(script.contains(#"cp -R "$MENUBAR" "$APP/Contents/Resources/MenuBar""#))
        let glyphs = Self.root.appending(path: "Sources/RelayUIMac/Resources/MenuBar")
        for name in ["menubar-idle.png", "menubar-idle@2x.png", "menubar-new.png", "menubar-new@2x.png"] {
            #expect(FileManager.default.fileExists(atPath: glyphs.appending(path: name).path), "\(name)")
        }
        #expect(script.contains(#"cp -R "$NOTIFICATION" "$APP/Contents/Resources/Notification""#))
        let fish = Self.root.appending(path: "Sources/RelayUIMac/Resources/Notification/ask-fish.png")
        #expect(FileManager.default.fileExists(atPath: fish.path))
    }
}
