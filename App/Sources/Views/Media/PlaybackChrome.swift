import SwiftUI
import AVKit
import DSMKit

/// System player surface with the controls the Synology file player shows: speed, subtitles, fill.
struct PlaybackChrome: View {
    let player: AVPlayer
    var title: String = ""
    var subtitles: [VideoSubtitle] = []
    var subtitleID: String?
    var onSubtitle: (String?) -> Void = { _ in }
    var onClose: () -> Void = {}

    @State private var speed = 1.0
    @State private var gravity: AVLayerVideoGravity = .resizeAspect
    @State private var showSpeed = false
    @State private var showSubtitles = false
    @State private var elapsed: Double = 0
    @State private var duration: Double = 0
    @State private var playing = true

    private let speeds = [2.0, 1.5, 1.25, 1.0, 0.75]

    var body: some View {
        ZStack {
            PlayerLayerBox(player: player, gravity: gravity)
                .ignoresSafeArea()
            VStack {
                HStack(spacing: 12) {
                    Button(action: onClose) {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                VStack(spacing: 10) {
                    HStack {
                        Text(clock(elapsed)).font(.caption.monospacedDigit()).foregroundStyle(.white)
                        Slider(value: Binding(get: { elapsed }, set: { seek($0) }), in: 0...max(duration, 1))
                            .tint(.white)
                        Text(clock(duration)).font(.caption.monospacedDigit()).foregroundStyle(.white)
                    }
                    HStack(spacing: 28) {
                        Button { toggle() } label: {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .frame(width: 36)
                        }
                        Button { showSpeed = true } label: { control("倍速", "1.circle") }
                        Button { showSubtitles = true } label: { control("字幕", "captions.bubble") }
                        Button { cycleFill() } label: { control("画面填充", "rectangle") }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom))
            }
        }
        .background(Color.black)
        .confirmationDialog("播放速度", isPresented: $showSpeed, titleVisibility: .visible) {
            ForEach(speeds, id: \.self) { value in
                Button(value == 1 ? "1x" : String(format: "%g x", value)) { applySpeed(value) }
            }
        }
        .confirmationDialog("字幕", isPresented: $showSubtitles, titleVisibility: .visible) {
            Button("关闭字幕") { onSubtitle(nil) }
            ForEach(subtitles) { sub in
                Button(sub.title.isEmpty ? sub.id : sub.title) { onSubtitle(sub.id) }
            }
        }
        .onAppear { player.play(); playing = true }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            let time = player.currentTime().seconds
            elapsed = time.isFinite ? time : 0
            let d = player.currentItem?.duration.seconds ?? 0
            if d.isFinite, d > 0 { duration = d }
            playing = player.timeControlStatus == .playing
        }
    }

    private func control(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.body)
            Text(title).font(.caption2)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    private func toggle() {
        if playing { player.pause() } else { player.playImmediately(atRate: Float(speed)) }
        playing.toggle()
    }

    private func applySpeed(_ value: Double) {
        speed = value
        player.defaultRate = Float(value)
        if playing { player.playImmediately(atRate: Float(value)) }
    }

    private func seek(_ seconds: Double) {
        elapsed = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    private func cycleFill() {
        switch gravity {
        case .resizeAspect: gravity = .resizeAspectFill
        case .resizeAspectFill: gravity = .resize
        default: gravity = .resizeAspect
        }
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct PlayerLayerBox: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerHost {
        let view = PlayerHost()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ view: PlayerHost, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
    }
}

private final class PlayerHost: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
