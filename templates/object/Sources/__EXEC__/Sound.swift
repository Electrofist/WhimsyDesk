import AppKit

/// Optional one-shot sounds: Sounds/open.wav and Sounds/close.wav. Missing files are silent.
/// Loaded on first use, never looped, nothing scheduled.
enum Sound {
    private static var cache: [String: NSSound] = [:]

    static func play(_ name: String) {
        if cache[name] == nil, let url = Bundle.main.url(forResource: name, withExtension: "wav") {
            cache[name] = NSSound(contentsOf: url, byReference: false)
        }
        guard let sound = cache[name] else { return }
        sound.stop()
        sound.play()
    }
}
