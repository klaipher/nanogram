import Foundation
import CoreLocation
import SwiftSignalKit

enum DeviceLocationBackend: Equatable {
    case locationManager
    case liveUpdates
}

/// Live location alone (no compass, Always access) can run on `CLLocationUpdate.liveUpdates`, which stops delivering
/// fixes while the device is stationary. A screen needing the heading keeps the `CLLocationManager` path.
func deviceLocationBackend(configuration: DeviceLocationConfiguration, stationaryUpdatesEnabled: Bool, isLiveUpdatesAvailable: Bool) -> DeviceLocationBackend {
    if stationaryUpdatesEnabled && isLiveUpdatesAvailable && configuration.authorization == .always && !configuration.updatesHeading {
        return .liveUpdates
    }
    return .locationManager
}

/// `liveUpdates` has no distance filter: skip moves smaller than the configured one, as `CLLocationManager` did.
func shouldDeliverLiveUpdate(previous: CLLocation?, next: CLLocation, distanceFilter: CLLocationDistance) -> Bool {
    guard let previous else {
        return true
    }
    if distanceFilter == kCLDistanceFilterNone {
        return true
    }
    return next.distance(from: previous) >= distanceFilter
}

let deviceLocationStationaryUpdatesDefaultsKey = "NanogramStationaryLocation"

func deviceLocationIsLiveUpdatesAvailable() -> Bool {
    if #available(iOS 17.0, *) {
        return true
    }
    return false
}

typealias LiveLocationSource = @Sendable () -> AsyncStream<CLLocation>

func systemLiveLocationSource() -> AsyncStream<CLLocation> {
    return AsyncStream { continuation in
        let task = Task.detached(priority: .utility) {
            if #available(iOS 17.0, *) {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                        if Task.isCancelled {
                            break
                        }
                        if let location = update.location {
                            continuation.yield(location)
                        }
                    }
                } catch {
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

final class LiveLocationUpdates: @unchecked Sendable {
    private var task: Task<Void, Never>?
    private var backgroundSession: AnyObject?
    private var serviceSession: AnyObject?
    
    init(source: LiveLocationSource = systemLiveLocationSource, startsSessions: Bool = true, onUpdate: @escaping @Sendable (CLLocation) -> Void) {
        if startsSessions, #available(iOS 17.0, *) {
            self.backgroundSession = CLBackgroundActivitySession()
            if #available(iOS 18.0, *) {
                self.serviceSession = CLServiceSession(authorization: .always)
            }
        }
        let stream = source()
        self.task = Task.detached(priority: .utility) {
            for await location in stream {
                if Task.isCancelled {
                    break
                }
                onUpdate(location)
            }
        }
    }
    
    deinit {
        self.stop()
    }
    
    func stop() {
        self.task?.cancel()
        self.task = nil
        if #available(iOS 17.0, *) {
            (self.backgroundSession as? CLBackgroundActivitySession)?.invalidate()
        }
        if #available(iOS 18.0, *) {
            (self.serviceSession as? CLServiceSession)?.invalidate()
        }
        self.backgroundSession = nil
        self.serviceSession = nil
    }
}

private final class WeakLocationManager: @unchecked Sendable {
    weak var value: DeviceLocationManager?
    let queue: Queue
    
    init(_ value: DeviceLocationManager) {
        self.value = value
        self.queue = value.queue
    }
}

extension DeviceLocationManager {
    func makeLiveLocationUpdates() -> LiveLocationUpdates {
        let weakSelf = WeakLocationManager(self)
        return LiveLocationUpdates(onUpdate: { location in
            weakSelf.queue.async {
                weakSelf.value?.receivedLiveUpdate(location)
            }
        })
    }
}
