import AppKit

/// Painted art, if it has been added. Each piece is a PNG in Resources/Art (copied into the app by
/// build.sh). Missing pieces fall back to the art drawn in code. See Resources/Art/README.md.
enum ArtFiles {
    private static var cache: [String: CGImage?] = [:]

    static func image(_ name: String) -> CGImage? {
        if let hit = cache[name] { return hit }
        var image: CGImage?
        var urls: [URL] = []
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Art") { urls.append(url) }
        // When run with `swift run`, read straight from the source folder.
        urls.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/Art/\(name).png").standardizedFileURL)
        for url in urls {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                image = cg
                break
            }
        }
        cache[name] = image
        return image
    }
}
