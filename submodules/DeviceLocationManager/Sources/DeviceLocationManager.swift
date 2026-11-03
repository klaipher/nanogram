import Foundation
import CoreLocation
import SwiftSignalKit

public enum DeviceLocationMode: Int32 {
    case preciseForeground = 0
    case preciseAlways = 1
}

private final class DeviceLocationSubscriber {
    let id: Int32
    let mode: DeviceLocationMode
    let update: (CLLocation, Double?) -> Void
    
    init(id: Int32, mode: DeviceLocationMode, update: @escaping (CLLocation, Double?) -> Void) {
        self.id = id
        self.mode = mode
        self.update = update
    }
}

enum DeviceLocationAuthorization: Equatable {
    case whenInUse
    case always
}

struct DeviceLocationConfiguration: Equatable {
    var distanceFilter: CLLocationDistance
    var updatesHeading: Bool
    var allowsBackgroundUpdates: Bool
    var authorization: DeviceLocationAuthorization
}

/// How to run location for the current subscribers. A screen showing location (`.preciseForeground`: a map, the
/// location picker) gets every fix and the compass. Live location alone (`.preciseAlways`, for hours, mostly in the
/// background) sends one update per 4 s and takes its heading from the course while moving, so it skips moves
/// under 10 m and the magnetometer. Only live location asks for Always access; a map asked for it too.
func deviceLocationConfiguration(modes: [DeviceLocationMode]) -> DeviceLocationConfiguration? {
    if modes.isEmpty {
        return nil
    }
    let hasScreen = modes.contains(.preciseForeground)
    let hasLiveLocation = modes.contains(.preciseAlways)
    return DeviceLocationConfiguration(
        distanceFilter: hasScreen ? kCLDistanceFilterNone : 10.0,
        updatesHeading: hasScreen,
        allowsBackgroundUpdates: hasLiveLocation,
        authorization: hasLiveLocation ? .always : .whenInUse
    )
}

public final class DeviceLocationManager: NSObject {
    private let queue: Queue
    private let log: ((String) -> Void)?
    
    private let manager: CLLocationManager
    private var requestedAuthorization: DeviceLocationAuthorization?
    
    private var nextSubscriberId: Int32 = 0
    private var subscribers: [DeviceLocationSubscriber] = []
    private var currentConfiguration: DeviceLocationConfiguration?
    
    private var currentLocation: CLLocation?
    private var currentHeading: CLHeading?
    
    public init(queue: Queue, log: ((String) -> Void)? = nil) {
        assert(queue.isCurrent())
        
        self.queue = queue
        self.log = log
        self.manager = CLLocationManager()
        
        super.init()
        
        self.manager.delegate = self
        self.manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        self.manager.distanceFilter = kCLDistanceFilterNone
        self.manager.activityType = .other
        self.manager.pausesLocationUpdatesAutomatically = false
        self.manager.headingFilter = 2.0
        if #available(iOS 11.0, *) {
            self.manager.showsBackgroundLocationIndicator = true
        }
    }
    
    public func push(mode: DeviceLocationMode, updated: @escaping (CLLocation, Double?) -> Void) -> Disposable {
        assert(self.queue.isCurrent())
        
        let id = self.nextSubscriberId
        self.nextSubscriberId += 1
        self.subscribers.append(DeviceLocationSubscriber(id: id, mode: mode, update: updated))
        
        if let currentLocation = self.currentLocation {
            updated(currentLocation, self.currentHeading?.magneticHeading)
        }
        
        self.updateTopMode()
        
        let queue = self.queue
        return ActionDisposable { [weak queue, weak self] in
            if let queue = queue {
                queue.async {
                    if let strongSelf = self {
                        loop: for i in 0 ..< strongSelf.subscribers.count {
                            if strongSelf.subscribers[i].id == id {
                                strongSelf.subscribers.remove(at: i)
                                break loop
                            }
                        }
                        
                        strongSelf.updateTopMode()
                    }
                }
            }
        }
    }
    
    private func updateTopMode() {
        assert(self.queue.isCurrent())
        
        let previousConfiguration = self.currentConfiguration
        let configuration = deviceLocationConfiguration(modes: self.subscribers.map(\.mode))
        if configuration == previousConfiguration {
            return
        }
        self.currentConfiguration = configuration
        if let configuration {
            self.log?("setting configuration \(configuration)")
            self.manager.allowsBackgroundLocationUpdates = configuration.allowsBackgroundUpdates
            self.manager.distanceFilter = configuration.distanceFilter
            
            switch configuration.authorization {
            case .whenInUse:
                if self.requestedAuthorization == nil {
                    self.requestedAuthorization = .whenInUse
                    self.manager.requestWhenInUseAuthorization()
                }
            case .always:
                if self.requestedAuthorization != .always {
                    self.requestedAuthorization = .always
                    self.manager.requestAlwaysAuthorization()
                }
            }
            
            if previousConfiguration == nil {
                self.manager.startUpdatingLocation()
            }
            if configuration.updatesHeading != (previousConfiguration?.updatesHeading ?? false) {
                if configuration.updatesHeading {
                    self.manager.startUpdatingHeading()
                } else {
                    self.manager.stopUpdatingHeading()
                    self.currentHeading = nil
                }
            }
        } else {
            self.currentLocation = nil
            self.currentHeading = nil
            self.manager.stopUpdatingLocation()
            self.manager.stopUpdatingHeading()
            self.log?("stopped")
        }
    }
}

extension CLHeading {
    var effectiveHeading: Double? {
        if self.headingAccuracy < 0.0 {
            return nil
        }
        if self.trueHeading > 0.0 {
            return self.trueHeading
        } else {
            return self.magneticHeading
        }
    }
}

extension DeviceLocationManager: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        assert(self.queue.isCurrent())
        
        if let location = locations.first {
            if self.currentConfiguration != nil {
                self.currentLocation = location
                for subscriber in self.subscribers {
                    subscriber.update(location, self.currentHeading?.effectiveHeading)
                }
            }
        }
    }
    
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        assert(self.queue.isCurrent())
        
        if self.currentConfiguration != nil {
            self.currentHeading = newHeading
            if let currentLocation = self.currentLocation {
                for subscriber in self.subscribers {
                    subscriber.update(currentLocation, newHeading.effectiveHeading)
                }
            }
        }
    }
}

public func currentLocationManagerCoordinate(manager: DeviceLocationManager, timeout timeoutValue: Double) -> Signal<CLLocationCoordinate2D?, NoError> {
    return (
        Signal { subscriber in
            let disposable = manager.push(mode: .preciseForeground, updated: { location, _ in
                subscriber.putNext(location.coordinate)
                subscriber.putCompletion()
            })
            return disposable
        }
        |> runOn(Queue.mainQueue())
    )
    |> timeout(timeoutValue, queue: Queue.mainQueue(), alternate: .single(nil))
}
