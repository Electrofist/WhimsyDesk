import AppKit

/// Two one-shot sounds. No loops, no hum, nothing scheduled.
final class SoundPlayer {
    private let open: NSSound?
    private let seal: NSSound?

    init() {
        open = SoundPlayer.load("open_click")
        seal = SoundPlayer.load("seal_click")
    }

    private static func load(_ name: String) -> NSSound? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        return NSSound(contentsOf: url, byReference: false)
    }

    func playOpen() { play(open) }

    func playSeal() { play(seal) }

    func stopAll() {
        open?.stop()
        seal?.stop()
    }

    private func play(_ sound: NSSound?) {
        guard let sound = sound else { return }
        sound.stop()
        sound.play()
    }
}
