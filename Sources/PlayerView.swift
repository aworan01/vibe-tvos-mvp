import AVKit
import SwiftUI
import VLCKit

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @StateObject private var playback = PlaybackCoordinator()
    @State private var channel: Channel
    @State private var controlsVisible = true

    init(channel: Channel) {
        _channel = State(initialValue: channel)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if playback.usesVLC {
                VLCVideo(player: playback.vlcPlayer).ignoresSafeArea()
            } else {
                AppleVideo(player: playback.avPlayer).ignoresSafeArea()
            }
            if !playback.message.isEmpty {
                VStack(spacing: 18) {
                    ProgressView().opacity(playback.failed ? 0 : 1)
                    Text(playback.message).font(.title3).multilineTextAlignment(.center)
                    if playback.failed { Button("Retry") { playback.start(channel) } }
                }
                .padding(30)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
            if controlsVisible { playerControls }
        }
        .onAppear {
            model.recordPlayback(channel)
            playback.start(channel)
        }
        .onDisappear { playback.stop() }
        .onPlayPauseCommand { playback.togglePause() }
        .onMoveCommand { direction in
            switch direction {
            case .left: zap(-1)
            case .right: zap(1)
            case .down, .up: controlsVisible.toggle()
            default: break
            }
        }
        .onTapGesture { controlsVisible.toggle() }
    }

    private var playerControls: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(channel.name).font(.title2.bold())
                    if let programme = model.nowProgramme(for: channel) {
                        Text(programme.title).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(playback.engineName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.thinMaterial, in: Capsule())
            }
            .padding(42)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.75), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            Spacer()
            HStack(spacing: 26) {
                Button("Previous", systemImage: "backward.end.fill") { zap(-1) }
                Button(
                    playback.paused ? "Play" : "Pause",
                    systemImage: playback.paused ? "play.fill" : "pause.fill"
                ) { playback.togglePause() }
                Button("Next", systemImage: "forward.end.fill") { zap(1) }
                Button(
                    model.favourites.contains(channel.id) ? "Unfavourite" : "Favourite",
                    systemImage: model.favourites.contains(channel.id) ? "star.fill" : "star"
                ) { model.toggleFavourite(channel) }
                Button("Close", systemImage: "xmark") { dismiss() }
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .padding(24)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 45)
        }
    }

    private func zap(_ offset: Int) {
        guard let next = model.channel(relativeTo: channel, offset: offset) else { return }
        channel = next
        model.recordPlayback(next)
        playback.start(next)
        controlsVisible = true
    }
}

@MainActor
final class PlaybackCoordinator: ObservableObject {
    enum Engine: String {
        case avPlayer = "AVPlayer"
        case vlc = "VLC"
        case clearKey = "ClearKey bridge"
    }

    let avPlayer = AVPlayer()
    let vlcPlayer = VLCMediaPlayer()
    @Published private(set) var engine: Engine = .avPlayer
    @Published private(set) var paused = false
    @Published private(set) var failed = false
    @Published private(set) var message = ""

    var usesVLC: Bool { engine != .avPlayer }
    var engineName: String { engine.rawValue }

    private var attempts: [Engine] = []
    private var attemptIndex = 0
    private var monitor: Task<Void, Never>?
    private var clearKeyPlayback: ClearKeyPlayback?
    private var activeChannel: Channel?

    func start(_ channel: Channel) {
        stop()
        activeChannel = channel
        switch channel.capability.container {
        case .hls:
            attempts = [.avPlayer, .vlc]
        case .dash:
            attempts = [.vlc]
            if channel.clearKey != nil { attempts.append(.clearKey) }
        case .unknown:
            attempts = [.avPlayer, .vlc]
        }
        attemptIndex = 0
        startCurrentAttempt()
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        vlcPlayer.stop()
        clearKeyPlayback?.cancel()
        clearKeyPlayback = nil
        paused = false
    }

    func togglePause() {
        guard !failed else { return }
        if usesVLC {
            if vlcPlayer.isPlaying { vlcPlayer.pause() } else { vlcPlayer.play() }
            paused = !vlcPlayer.isPlaying
        } else if avPlayer.timeControlStatus == .playing {
            avPlayer.pause()
            paused = true
        } else {
            avPlayer.play()
            paused = false
        }
    }

    private func startCurrentAttempt() {
        guard let channel = activeChannel, attempts.indices.contains(attemptIndex) else {
            failed = true
            message = finalFailureMessage()
            return
        }
        engine = attempts[attemptIndex]
        failed = false
        paused = false
        message = "Opening \(channel.name) with \(engine.rawValue)…"

        switch engine {
        case .avPlayer:
            avPlayer.replaceCurrentItem(with: AVPlayerItem(url: channel.streamURL))
            avPlayer.play()
        case .vlc:
            guard let media = VLCMedia(url: channel.streamURL) else {
                advance()
                return
            }
            if let userAgent = channel.userAgent {
                media.addOption(":http-user-agent=\(userAgent)")
            }
            vlcPlayer.media = media
            vlcPlayer.play()
        case .clearKey:
            guard let configuration = channel.clearKey,
                  let relay = ClearKeyPlayback(
                    source: channel.streamURL,
                    configuration: configuration
                  ) else {
                advance()
                return
            }
            clearKeyPlayback = relay
            guard let media = VLCMedia(url: relay.url) else {
                advance()
                return
            }
            vlcPlayer.media = media
            vlcPlayer.play()
        }
        monitorAttempt()
    }

    private func monitorAttempt() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            while !Task.isCancelled {
                let playing: Bool
                let errored: Bool
                switch self.engine {
                case .avPlayer:
                    playing = self.avPlayer.timeControlStatus == .playing
                    errored = self.avPlayer.currentItem?.status == .failed
                case .vlc, .clearKey:
                    playing = self.vlcPlayer.state == .playing
                    errored = self.vlcPlayer.state == .error ||
                        (self.clearKeyPlayback?.status.failed ?? 0) != 0
                }
                if playing {
                    self.message = ""
                    return
                }
                if errored || Date().timeIntervalSince(startedAt) >= 15 {
                    self.advance()
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func advance() {
        monitor?.cancel()
        monitor = nil
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        vlcPlayer.stop()
        clearKeyPlayback?.cancel()
        clearKeyPlayback = nil
        attemptIndex += 1
        startCurrentAttempt()
    }

    private func finalFailureMessage() -> String {
        guard let channel = activeChannel else { return "Playback failed." }
        if channel.capability.drm == .widevine {
            return "The stream did not play as clear media. Its Widevine declaration requires a licensed tvOS SDK."
        }
        if channel.capability.drm == .clearKey {
            return "Clear playback and the available ClearKey path both failed. Check source access, codec support, and key metadata."
        }
        return "Playback failed in AVPlayer and VLC. Check source access and codec support."
    }
}

private struct AppleVideo: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
}

private struct VLCVideo: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        if (player.drawable as? UIView) !== view { player.drawable = view }
    }
}

