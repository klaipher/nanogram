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
    /// 30 Hz; 24 Hz in Low Power Mode with `WatchFeature.offMainStickerRender` (WATCH-GPU-1).
    private var frameInterval: TimeInterval {
        LottieStickerPlayer.minimumFrameInterval(
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            capEnabled: WatchFeatureFlags.isEnabled(.offMainStickerRender)
        )
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: !player.isTicking)) { ctx in
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

    /// Where frames come from: rendered on the main actor (default) or by a renderer off it (WATCH-GPU-1).
    private enum Source {
        case inline(TLottieAnimation)
        case offMain(LottieFrameRenderer)

        var frameCount: Int {
            switch self {
            case .inline(let animation): return animation.frameCount
            case .offMain(let renderer): return renderer.frameCount
            }
        }

        var frameRate: Int {
            switch self {
            case .inline(let animation): return animation.frameRate
            case .offMain(let renderer): return renderer.frameRate
            }
        }
    }

    @ObservationIgnored private var source: Source?
    @ObservationIgnored private let renderOffMain: Bool
    /// Off-main rendering: one render at a time; a frame that is due while one runs replaces any older waiting
    /// frame, so a slow render drops frames instead of queueing them.
    @ObservationIgnored private var renderInFlight = false
    @ObservationIgnored private var pendingIndex: Int?
    @ObservationIgnored private(set) var renderTask: Task<Void, Never>?
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

    var hasAnimation: Bool { source != nil }

    init(renderOffMain: Bool = WatchFeatureFlags.isEnabled(.offMainStickerRender)) {
        self.renderOffMain = renderOffMain
    }

    /// Time between timeline ticks. Low Power Mode lowers it to 24 Hz when the cap is enabled.
    nonisolated static func minimumFrameInterval(lowPowerMode: Bool, capEnabled: Bool) -> TimeInterval {
        (lowPowerMode && capEnabled) ? 1.0 / 24.0 : 1.0 / 30.0
    }

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
            if self.renderOffMain {
                self.source = .offMain(LottieFrameRenderer(loaded))
            } else {
                self.source = .inline(loaded)
            }
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
        guard let source, case .playing(let start) = phase else { return }
        if pixelSize != self.pixelSize {
            self.pixelSize = pixelSize
            lastFrameIndex = nil
        }
        if let index = Self.frameIndex(elapsed: now.timeIntervalSince(start),
                                       frameCount: source.frameCount,
                                       frameRate: source.frameRate) {
            render(index: index)
        } else {
            render(index: source.frameCount - 1)
            phase = .finished
        }
    }

    func replay(now: Foundation.Date) {
        guard phase == .finished, source != nil else { return }
        phase = isActive ? .playing(start: now) : .paused(elapsed: 0)
    }

    private func tearDown() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        renderTask?.cancel()
        renderTask = nil
        renderInFlight = false
        pendingIndex = nil
        source = nil
        if frame != nil { frame = nil }
        lastFrameIndex = nil
        if phase != .idle { phase = .idle }
    }

    private func render(index: Int) {
        guard let source else { return }
        // A 30 Hz tick can land twice on one frame of a slower animation.
        if index == lastFrameIndex, frame != nil { return }
        switch source {
        case .inline(let animation):
            frame = animation.renderFrame(index: index, size: pixelSize, scale: 1)
            lastFrameIndex = index
            renderCount += 1
        case .offMain(let renderer):
            renderOffMain(renderer, index: index)
        }
    }

    private func renderOffMain(_ renderer: LottieFrameRenderer, index: Int) {
        if renderInFlight {
            pendingIndex = index
            return
        }
        renderInFlight = true
        let token = generation
        let size = pixelSize
        renderTask = Task { [weak self] in
            let rendered = await renderer.render(index: index, size: size)
            self?.finishRender(rendered, index: index, token: token)
        }
    }

    /// Publishes a finished frame. A result from before a tear-down (the generation moved on) is dropped.
    private func finishRender(_ rendered: RenderedLottieFrame?, index: Int, token: Int) {
        guard token == generation else { return }
        renderInFlight = false
        renderTask = nil
        if let rendered {
            frame = rendered.image
            lastFrameIndex = index
            renderCount += 1
        }
        if let next = pendingIndex {
            pendingIndex = nil
            if next != lastFrameIndex { render(index: next) }
        }
    }

    /// Reads, inflates and parses the TGS off the main thread.
    @concurrent
    nonisolated private static func load(_ url: URL) async -> sending TLottieAnimation? {
        TLottieAnimation(tgsFileURL: url)
    }
}

/// One rendered frame, handed from the renderer back to the main actor. `CGImage` is immutable.
struct RenderedLottieFrame: @unchecked Sendable {
    let image: CGImage
}

/// Owns one parsed animation and rasterises it off the main actor. tlottie instances are single-threaded; the
/// actor is what guarantees one render at a time. The pixels land directly in the CFData behind the CGImage
/// (no second copy), so the cost per frame is the rasterisation itself.
actor LottieFrameRenderer {
    nonisolated let frameCount: Int
    nonisolated let frameRate: Int
    private let animation: TLottieAnimation

    init(_ animation: sending TLottieAnimation) {
        self.frameCount = animation.frameCount
        self.frameRate = animation.frameRate
        self.animation = animation
    }

    func render(index: Int, size: CGSize) -> RenderedLottieFrame? {
        guard let image = animation.renderFrame(index: index, size: size, scale: 1) else { return nil }
        return RenderedLottieFrame(image: image)
    }
}
