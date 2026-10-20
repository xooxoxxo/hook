import AppKit
import RelayUI

// RelayGallery: renders every scene offscreen (windows at -20000, never ordered
// front, the app never activated) into build/gallery, plus index.html.
let app = PreviewApp.shared
app.setActivationPolicy(.prohibited)

let options = GalleryOptions.parse(Array(CommandLine.arguments.dropFirst()))
DS.Font.galleryScale = options.textScale
let known = Set(allScenes.map(\.name))
for name in options.scenes.sorted() where !known.contains(name) {
    FileHandle.standardError.write(Data("RelayGallery: unknown scene \(name)\n".utf8))
    exit(2)
}
do {
    try FileManager.default.createDirectory(atPath: options.outDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("RelayGallery: can't create \(options.outDir)\n".utf8))
    exit(1)
}

var entries: [GalleryEntry] = []
var failures: [String] = []
for scene in allScenes where options.wants(scene.name) {
    let result = render(scene, options: options)
    entries.append(GalleryEntry(scene: scene.name, files: result.files, standIn: scene.standIn))
    failures += result.failures.map { "\(scene.name): \($0)" }
}
let index = (options.outDir as NSString).appendingPathComponent("index.html")
do {
    try GalleryIndex.html(entries).write(toFile: index, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("RelayGallery: can't write \(index)\n".utf8))
    exit(1)
}
print("RelayGallery: \(entries.count) scene(s) in \(options.outDir)")
if !failures.isEmpty {
    for failure in failures { FileHandle.standardError.write(Data("alignment: \(failure)\n".utf8)) }
    FileHandle.standardError.write(Data("RelayGallery: \(failures.count) alignment failure(s)\n".utf8))
    exit(1)
}
exit(0)
