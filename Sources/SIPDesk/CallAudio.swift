import AppKit
import AVFoundation

@MainActor
final class CallAudio {
    private var player: AVAudioPlayer?
    private var playing: String?
    private var attentionRequest: Int?

    func ring() {
        play("ringtone", volume: 0.45)
        if attentionRequest == nil { attentionRequest = NSApp.requestUserAttention(.criticalRequest) }
    }

    func ringback() { play("ringback", volume: 0.16) }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
        if let attentionRequest { NSApp.cancelUserAttentionRequest(attentionRequest) }
        attentionRequest = nil
    }

    private func play(_ name: String, volume: Float) {
        guard playing != name else { return }
        stop()
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
              let sound = try? AVAudioPlayer(contentsOf: url) else { return }
        player = sound
        playing = name
        sound.numberOfLoops = -1
        sound.volume = volume
        sound.play()
    }
}

