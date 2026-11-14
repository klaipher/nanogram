import SwiftUI
import UIKit
import WatchKit
import TLottieKit

/// Renders one TGS sticker. Plays once each time the bubble scrolls into view, freezes on
/// the last frame, and replays on tap. `isVisible` comes from the bubble's
/// `onScrollVisibilityChange`: the message list is a plain VStack, so `onAppear` fires for
/// every row at once and can't be used to start or stop playback.
///
/// Pre-download / pre-load fallback chain: while the TGS hasn't been loaded yet, render
/// the sticker's raster thumbnail if available, otherwise a gray placeholder.
struct LottieAnimationView: View {
    let sticker: StickerVisual
    let displaySize: CGSize
    let isVisible: Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var player = LottieStickerPlayer()

    private var screenScale: CGFloat { WKInterfaceDevice.current().screenScale }
    private var pixelSize: CGSize {
        CGSize(width: displaySize.width * screenScale, height: displaySize.height * screenScale)
    }
    /// Off while the app is inactive or the wrist is down (always-on display).
    private var isActive: Bool { scenePhase == .active && !isLuminanceReduced }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isTicking)) { ctx in
            ZStack {
                if let frame = player.frame {
                    Image(decorative: frame, scale: screenScale)
                        .resizable()
                        .scaledToFit()
                } else if let thumbnail = stickerThumbnail(sticker) {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                } else {
                    Color.gray.opacity(0.2)
                }
            }
            .onChange(of: ctx.date) { _, now in
                player.tick(now: now, pixelSize: pixelSize)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .contentShape(Rectangle())
        .onTapGesture { player.replay(now: Foundation.Date()) }
        .onChange(of: isActive, initial: true) { _, active in
            player.setActive(active, now: Foundation.Date())
        }
        .onChange(of: isVisible, initial: true) { _, visible in
            player.update(path: sticker.localPath, isVisible: visible, pixelSize: pixelSize)
        }
        .onChange(of: sticker.localPath) { _, path in
            player.update(path: path, isVisible: isVisible, pixelSize: pixelSize)
        }
        .onDisappear { player.update(path: nil, isVisible: false) }
    }
}

/// Playback state of one animated sticker. Loads (off the main thread) only while visible,
/// drops the animation and its frame when scrolled away, ticks only while playing (not
/// after the last frame), and holds its position while the app is inactive.
@MainActor
@Observable
final class LottieStickerPlayer {
    enum Phase: Equatable {
        case idle
        case loading
        case playing(start: Foundation.Date)
        /// Inactive mid-play; `elapsed` is the position to resume from.
        case paused(elapsed: TimeInterval)
        case finished
        case failed
    }

    private(set) var phase: Phase = .idle
    private(set) var frame: CGImage?

    @ObservationIgnored private var animation: TLottieAnimation?
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastFrameIndex: Int?
    /// Render size in pixels (the bubble's size times the screen scale).
    @ObservationIgnored private var pixelSize = CGSize(width: 240, height: 240)
    @ObservationIgnored private(set) var loadTask: Task<Void, Never>?
    /// Frames rendered so far (tests).
    @ObservationIgnored private(set) var renderCount = 0

    var isTicking: Bool {
        if case .playing = phase { return true }
        return false
    }

    var hasAnimation: Bool { animation != nil }

    /// Frame to show `elapsed` seconds into the animation, nil once it has ended.
    nonisolated static func frameIndex(elapsed: TimeInterval, frameCount: Int, frameRate: Int) -> Int? {
        let count = max(1, frameCount)
        let index = Int(max(0, elapsed) * Double(max(1, frameRate)))
        return index < count ? index : nil
    }

    func update(path: String?, isVisible: Bool, pixelSize: CGSize? = nil) {
        if let pixelSize { self.pixelSize = pixelSize }
        guard isVisible else {
            tearDown()
            return
        }
        guard let path, phase == .idle else { return }
        phase = .loading
        generation += 1
        let token = generation
        loadTask = Task { [weak self] in
            let loaded = await Self.load(URL(fileURLWithPath: path))
            guard let self, self.generation == token else { return }
            self.loadTask = nil
            guard let loaded else {
                self.phase = .failed
                return
            }
            self.animation = loaded
            self.phase = self.isActive ? .playing(start: Foundation.Date()) : .paused(elapsed: 0)
            self.render(index: 0)
        }
    }

    func setActive(_ active: Bool, now: Foundation.Date) {
        isActive = active
        switch phase {
        case .playing(let start) where !active:
            phase = .paused(elapsed: now.timeIntervalSince(start))
        case .paused(let elapsed) where active:
            phase = .playing(start: now.addingTimeInterval(-elapsed))
        default:
            break
        }
    }

    func tick(now: Foundation.Date, pixelSize: CGSize) {
        guard let animation, case .playing(let start) = phase else { return }
        if pixelSize != self.pixelSize {
            self.pixelSize = pixelSize
            lastFrameIndex = nil
        }
        if let index = Self.frameIndex(elapsed: now.timeIntervalSince(start),
                                       frameCount: animation.frameCount,
                                       frameRate: animation.frameRate) {
            render(index: index)
        } else {
            render(index: animation.frameCount - 1)
            phase = .finished
        }
    }

    func replay(now: Foundation.Date) {
        guard phase == .finished, animation != nil else { return }
        phase = isActive ? .playing(start: now) : .paused(elapsed: 0)
    }

    private func tearDown() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        animation = nil
        if frame != nil { frame = nil }
        lastFrameIndex = nil
        if phase != .idle { phase = .idle }
    }

    private func render(index: Int) {
        guard let animation else { return }
        // A 30 Hz tick can land twice on one frame of a slower animation.
        if index == lastFrameIndex, frame != nil { return }
        frame = animation.renderFrame(index: index, size: pixelSize, scale: 1)
        lastFrameIndex = index
        renderCount += 1
    }

    /// Reads, inflates and parses the TGS off the main thread.
    @concurrent
    nonisolated private static func load(_ url: URL) async -> sending TLottieAnimation? {
        TLottieAnimation(tgsFileURL: url)
    }
}
