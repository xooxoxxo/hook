import Testing
@testable import RelayUI

@Suite struct GalleryKitTests {
    @Test func defaults() {
        let options = GalleryOptions.parse([])
        #expect(options.outDir == "build/gallery")
        #expect(options.scenes.isEmpty)
        #expect(!options.contrast && !options.reduceTransparency && !options.xl)
        #expect(options.wants("components") && options.wants("queue"))
        #expect(options.fileSuffix == "")
    }

    @Test func outDirScenesAndFlags() {
        let options = GalleryOptions.parse(["out/g", "queue", "--xl", "detail-steps", "--contrast", "--reduce-transparency"])
        #expect(options.outDir == "out/g")
        #expect(options.scenes == ["queue", "detail-steps"])
        #expect(options.contrast && options.reduceTransparency && options.xl)
        #expect(options.wants("queue") && !options.wants("components"))
        #expect(options.fileSuffix == "-contrast-rt-xl")
    }

    @Test func suffixOrderIsFixed() {
        #expect(GalleryOptions.parse(["--xl", "--contrast"]).fileSuffix == "-contrast-xl")
        #expect(GalleryOptions.parse(["--reduce-transparency"]).fileSuffix == "-rt")
        #expect(GalleryOptions.parse(["--bogus", "x"]).outDir == "x")
    }

    @Test func xlScalesText() {
        #expect(GalleryOptions.parse([]).textScale == 1)
        #expect(GalleryOptions.parse(["--xl"]).textScale == 1.35)
    }

    @Test func indexListsEveryFileUnderItsScene() {
        let html = GalleryIndex.html([
            GalleryEntry(scene: "queue", files: ["queue-light.png", "queue-dark.png"], standIn: true),
            GalleryEntry(scene: "menubar-badges", files: ["menubar-badges-light.png"], standIn: false),
        ])
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains(#"<img src="queue-light.png""#))
        #expect(html.contains(#"<img src="queue-dark.png""#))
        #expect(html.contains("<figcaption>queue · light · panel material: stand-in</figcaption>"))
        #expect(html.contains("<figcaption>menubar-badges · light</figcaption>"))
        #expect(!html.contains("menubar-badges · light · panel material"))
    }

    @Test func indexEscapesNames() {
        let html = GalleryIndex.html([GalleryEntry(scene: "a<b", files: ["a<b-light.png"], standIn: false)])
        #expect(html.contains("a&lt;b"))
        #expect(!html.contains("a<b"))
    }
}
