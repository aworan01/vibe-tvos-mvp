import AVKit
import SwiftUI

struct PlayerView: View {
    let channel: Channel
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if channel.capability.isNativelyPlayable {
                VideoPlayer(player: player)
                    .onAppear {
                        let item = AVPlayerItem(url: channel.streamURL)
                        player = AVPlayer(playerItem: item)
                        player?.play()
                    }
                    .onDisappear {
                        player?.pause()
                        player = nil
                    }
            } else {
                ContentUnavailableView("Playback Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(channel.capability.explanation))
            }
        }
        .navigationTitle(channel.name)
    }
}

