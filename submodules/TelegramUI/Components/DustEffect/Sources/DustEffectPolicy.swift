import Foundation

// Timing and quality decisions of the dust effect. Foundation only, so the host tests can compile it.
enum DustEffectTiming {
    // The sweep: every grain has started to move once the phase reaches this.
    static let sweepDuration: Float = 0.8
    // The longest a grain lives once it moves at full speed, in simulation time:
    // 2.0 + 1.8 + 0.3 in dustEffectInitializeParticle.
    static let maxParticleLifetime: Double = 4.1
    // Covers Float rounding in the shader's lifetime countdown.
    static let lifetimeMargin: Double = 0.05
    // Simulation time runs twice as fast as the animation (see DustEffectLayer).
    static let simulationTimeScale: Double = 2.0

    // A limit for an item whose grains were never simulated (no GPU buffer, or frames lost): well past the end.
    static func maxDuration(animationSpeed: Float) -> Double {
        let speed = Double(max(animationSpeed, 0.01))
        return Double(DustEffectTiming.sweepDuration) / speed + DustEffectTiming.maxParticleLifetime / DustEffectTiming.simulationTimeScale + 2.0
    }

    // Seconds between two frames. The display link's target timestamps are steadier than the time the callback ran.
    // Falls back to the link's frame duration on the first frame and after a stall, like before.
    static func frameDeltaTime(targetTimestamp: Double?, previousTargetTimestamp: Double?, frameDuration: Double) -> Double {
        if let targetTimestamp, let previousTargetTimestamp {
            let delta = targetTimestamp - previousTargetTimestamp
            if delta > 0.001 && delta < 0.2 {
                return delta
            }
        }
        return frameDuration
    }
}

// What one item has been through on the GPU. All grains are gone once every one of them has had the longest lifetime
// at full speed, and they all move at full speed from the end of the sweep.
struct DustEffectItemProgress {
    private(set) var simulatedTimeAfterSweep: Double = 0.0

    // Call with the phase and the time step of every particle update dispatched.
    mutating func didDispatchUpdate(phase: Float, simulationTimeStep: Double) {
        if phase >= DustEffectTiming.sweepDuration && simulationTimeStep > 0.0 {
            self.simulatedTimeAfterSweep += simulationTimeStep
        }
    }

    var isFinished: Bool {
        return self.simulatedTimeAfterSweep >= DustEffectTiming.maxParticleLifetime + DustEffectTiming.lifetimeMargin
    }
}

enum DustEffectThermalState {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .serious
        }
    }
}

struct DustEffectQuality: Equatable {
    // At 120 Hz only while some item is still sweeping; the drift after it is slow.
    var usesHighFrameRateDuringSweep: Bool
    // One grain per `particleStride` x `particleStride` points.
    var particleStride: Int
    var isFluidEnabled: Bool

    static let full = DustEffectQuality(usesHighFrameRateDuringSweep: true, particleStride: 1, isFluidEnabled: true)

    static func current(isLowPowerModeEnabled: Bool, thermalState: DustEffectThermalState) -> DustEffectQuality {
        switch thermalState {
        case .critical:
            return DustEffectQuality(usesHighFrameRateDuringSweep: false, particleStride: 2, isFluidEnabled: false)
        case .serious:
            return DustEffectQuality(usesHighFrameRateDuringSweep: false, particleStride: 2, isFluidEnabled: true)
        case .nominal, .fair:
            if isLowPowerModeEnabled {
                return DustEffectQuality(usesHighFrameRateDuringSweep: false, particleStride: 2, isFluidEnabled: true)
            }
            return .full
        }
    }

    static func current() -> DustEffectQuality {
        let processInfo = ProcessInfo.processInfo
        return DustEffectQuality.current(isLowPowerModeEnabled: processInfo.isLowPowerModeEnabled, thermalState: DustEffectThermalState(processInfo.thermalState))
    }

    // Grains across and down an item of `size` points. Zero for an item too small to dissolve.
    func particleGrid(itemSize: CGSize) -> (columns: Int, rows: Int) {
        let stride = CGFloat(max(1, self.particleStride))
        return (DustEffectQuality.count(itemSize.width / stride), DustEffectQuality.count(itemSize.height / stride))
    }

    private static func count(_ value: CGFloat) -> Int {
        // Bubbles are capped at 1800 pt by the caller; the cap only keeps the conversion from trapping.
        guard value.isFinite, value >= 1.0 else {
            return 0
        }
        return Int(min(value, 8192.0))
    }
}
