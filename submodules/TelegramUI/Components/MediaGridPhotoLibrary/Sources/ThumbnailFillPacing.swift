import Foundation
import UIKit

/// When the background thumbnail filler may run. It walks the whole photo library, so it only runs
/// while a library picker is open, the app is in the foreground, Low Power Mode is off and the
/// device is not hot (thermal state serious or critical). It also pauses while the open picker is
/// covered: behind the full-screen editor, the camera, or while the sheet is minimized.
enum ThumbnailFillPacing {
    struct Conditions: Equatable {
        var openPickerCount: Int
        var isForeground: Bool
        var isLowPowerMode: Bool
        var thermalState: ProcessInfo.ThermalState
        var isPickerCovered: Bool = false
    }

    static func allowsFilling(_ conditions: Conditions) -> Bool {
        guard conditions.openPickerCount > 0, !conditions.isPickerCovered, conditions.isForeground, !conditions.isLowPowerMode else {
            return false
        }
        switch conditions.thermalState {
        case .nominal, .fair:
            return true
        case .serious, .critical:
            return false
        @unknown default:
            return false
        }
    }
}

/// Feeds `ThumbnailFillPacing` with the process state and tells its owner when it may have changed.
final class ThumbnailFillPacer {
    struct Environment {
        var isLowPowerMode: () -> Bool
        var thermalState: () -> ProcessInfo.ThermalState
        var notificationCenter: NotificationCenter

        static var live: Environment {
            return Environment(isLowPowerMode: { ProcessInfo.processInfo.isLowPowerModeEnabled }, thermalState: { ProcessInfo.processInfo.thermalState }, notificationCenter: .default)
        }
    }

    private let environment: Environment
    private let onChange: (Bool) -> Void
    var onChangeForTesting: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private(set) var openPickerCount = 0
    private(set) var isForeground = true
    private(set) var isAllowed = false
    private var coveringOwners = Set<ObjectIdentifier>()

    /// The open pickers are all covered (the pickers that cover are counted by owner, so a picker that
    /// is closed without uncovering must call `setPickerCovered(false, by:)` itself).
    var isPickerCovered: Bool {
        return !self.coveringOwners.isEmpty && self.coveringOwners.count >= self.openPickerCount
    }

    init(environment: Environment = .live, onChange: @escaping (Bool) -> Void) {
        self.environment = environment
        self.onChange = onChange
        let center = environment.notificationCenter
        let refresh: (Notification) -> Void = { [weak self] _ in
            self?.reevaluate()
        }
        self.observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.isForeground = false
            self?.reevaluate()
        }))
        self.observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.isForeground = true
            self?.reevaluate()
        }))
        self.observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main, using: refresh))
        self.observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: refresh))
    }

    deinit {
        for observer in self.observers {
            self.environment.notificationCenter.removeObserver(observer)
        }
    }

    func pickerOpened() {
        self.openPickerCount += 1
        self.reevaluate()
    }

    func pickerClosed() {
        self.openPickerCount = max(0, self.openPickerCount - 1)
        self.reevaluate()
    }

    func setPickerCovered(_ covered: Bool, by owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        if covered {
            self.coveringOwners.insert(id)
        } else {
            self.coveringOwners.remove(id)
        }
        self.reevaluate()
    }

    func reevaluate() {
        let allowed = ThumbnailFillPacing.allowsFilling(ThumbnailFillPacing.Conditions(openPickerCount: self.openPickerCount, isForeground: self.isForeground, isLowPowerMode: self.environment.isLowPowerMode(), thermalState: self.environment.thermalState(), isPickerCovered: self.isPickerCovered))
        if allowed != self.isAllowed {
            self.isAllowed = allowed
            self.onChange(allowed)
            self.onChangeForTesting?(allowed)
        }
    }
}
