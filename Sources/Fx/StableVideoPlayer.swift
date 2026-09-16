import AVKit
import SwiftUI

/// SwiftUI's VideoPlayer currently crashes while resolving its private
/// _AVKit_SwiftUI representable metadata on some macOS 26 builds. Hosting the
/// public AppKit player view directly avoids that framework boundary while
/// retaining the same native controls and playback behavior.
struct StableVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) {
        view.player?.pause()
        view.player = nil
    }
}
