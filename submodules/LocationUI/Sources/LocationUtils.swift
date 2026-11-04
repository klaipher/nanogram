import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramStringFormatting
import MapKit
import AccountContext
import HardenedMedia

extension TelegramMediaMap {
    convenience init(coordinate: CLLocationCoordinate2D, liveBroadcastingTimeout: Int32? = nil, proximityNotificationRadius: Int32? = nil) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude, heading: nil, accuracyRadius: nil, venue: nil, liveBroadcastingTimeout: liveBroadcastingTimeout, liveProximityNotificationRadius: proximityNotificationRadius)
    }
    
    var coordinate: CLLocationCoordinate2D {
        return CLLocationCoordinate2D(latitude: self.latitude, longitude: self.longitude)
    }
}

extension MKMapRect {
    init(region: MKCoordinateRegion) {
        let point1 = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude + region.span.latitudeDelta / 2.0, longitude: region.center.longitude - region.span.longitudeDelta / 2.0))
        let point2 = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude - region.span.latitudeDelta / 2.0, longitude: region.center.longitude + region.span.longitudeDelta / 2.0))
        self = MKMapRect(x: min(point1.x, point2.x), y: min(point1.y, point2.y), width: abs(point1.x - point2.x), height: abs(point1.y - point2.y))
    }
}

public func locationCoordinatesAreEqual(_ lhs: CLLocationCoordinate2D?, _ rhs: CLLocationCoordinate2D?) -> Bool {
    if let lhs, let rhs {
        return lhs.isEqual(to: rhs)
    } else if (lhs == nil) != (rhs == nil) {
        return false
    } else {
        return true
    }
}

extension CLLocationCoordinate2D {
    func isEqual(to other: CLLocationCoordinate2D) -> Bool {
        return self.latitude == other.latitude && self.longitude == other.longitude
    }
}

public struct NearbyVenue {
    public let media: TelegramMediaMap
    public let resultId: String
}

public struct NearbyVenuesResult {
    public let venues: [NearbyVenue]
    public let queryId: Int64
}

public func nearbyVenues(context: AccountContext, story: Bool = false, isSecretChat: Bool, userRequested: Bool, latitude: Double, longitude: Double, query: String? = nil) -> Signal<NearbyVenuesResult?, NoError> {
    switch VenueSearchPolicy.backend(isSecretChat: isSecretChat, isStory: story, userRequested: userRequested, latitude: latitude, longitude: longitude) {
    case .none:
        return .single(nil)
    case .mapKit:
        return mapKitNearbyVenues(latitude: latitude, longitude: longitude, query: query)
    case let .bot(roundedLatitude, roundedLongitude):
        return botNearbyVenues(context: context, story: story, latitude: roundedLatitude, longitude: roundedLongitude, query: query)
    }
}

private func mapKitNearbyVenues(latitude: Double, longitude: Double, query: String?) -> Signal<NearbyVenuesResult?, NoError> {
    return Signal { subscriber in
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let search: MKLocalSearch
        if let query, !query.isEmpty {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.region = MKCoordinateRegion(center: center, latitudinalMeters: 2000.0, longitudinalMeters: 2000.0)
            request.resultTypes = [.pointOfInterest, .address]
            search = MKLocalSearch(request: request)
        } else {
            search = MKLocalSearch(request: MKLocalPointsOfInterestRequest(center: center, radius: 1000.0))
        }
        search.start(completionHandler: { response, _ in
            guard let response else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return
            }
            var venues: [NearbyVenue] = []
            for item in response.mapItems {
                guard let title = item.name, !title.isEmpty else {
                    continue
                }
                let placemark = item.placemark
                let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap { $0 }.joined(separator: " ")
                let address = [street, placemark.locality ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
                let media = TelegramMediaMap(latitude: placemark.coordinate.latitude, longitude: placemark.coordinate.longitude, heading: nil, accuracyRadius: nil, venue: MapVenue(title: title, address: address, provider: nil, id: nil, type: nil), liveBroadcastingTimeout: nil, liveProximityNotificationRadius: nil)
                venues.append(NearbyVenue(media: media, resultId: ""))
            }
            subscriber.putNext(NearbyVenuesResult(venues: venues, queryId: 0))
            subscriber.putCompletion()
        })
        return ActionDisposable {
            search.cancel()
        }
    }
}

private func botNearbyVenues(context: AccountContext, story: Bool, latitude: Double, longitude: Double, query: String?) -> Signal<NearbyVenuesResult?, NoError> {
    let botUsername: Signal<String, NoError>
    if story {
        botUsername = context.engine.data.get(TelegramEngine.EngineData.Item.Configuration.App())
        |> map { appConfiguration in
            let storiesConfiguration = StoriesConfiguration.with(appConfiguration: appConfiguration)
            return storiesConfiguration.venueSearchBot
        }
    } else {
        botUsername = context.engine.data.get(TelegramEngine.EngineData.Item.Configuration.SearchBots())
        |> map { searchBotsConfiguration -> String in
            return searchBotsConfiguration.venueBotUsername ?? "foursquare"
        }
    }
    return botUsername
    |> mapToSignal { botUsername in
        return context.engine.peers.resolvePeerByName(name: botUsername, referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            guard case let .result(result) = result else {
                return .complete()
            }
            return .single(result)
        }
        |> mapToSignal { peer -> Signal<ChatContextResultCollection?, NoError> in
            guard let peer = peer else {
                return .single(nil)
            }
            return context.engine.messages.requestChatContextResults(botId: peer.id, peerId: context.account.peerId, query: query ?? "", location: .single((latitude, longitude)), offset: "")
            |> map { results -> ChatContextResultCollection? in
                return results?.results
            }
            |> `catch` { error -> Signal<ChatContextResultCollection?, NoError> in
                return .single(nil)
            }
        }
        |> map { contextResult -> NearbyVenuesResult? in
            guard let contextResult else {
                return nil
            }
            var venues: [NearbyVenue] = []
            for result in contextResult.results {
                if case let .mapLocation(mapMedia, _) = result.message, mapMedia.venue != nil {
                    venues.append(NearbyVenue(media: mapMedia, resultId: result.id))
                }
            }
            return NearbyVenuesResult(venues: venues, queryId: contextResult.queryId)
        }
    }
}

func stringForEstimatedDuration(strings: PresentationStrings, time: Double, format: (String) -> String) -> String? {
    if time > 0.0 {
        let time = max(time, 60.0)
        let minutes = Int32(time / 60.0) % 60
        let hours = Int32(time / 3600.0)
        let days = Int32(time / (3600.0 * 24.0))
        
        let string: String
        if hours >= 24 {
            string = strings.Map_ETADays(days)
        } else if hours > 0 {
            if hours == 1 && minutes == 0 {
                string = strings.Map_ETAHours(1)
            } else {
                string = strings.Map_ETAHours(10).replacingOccurrences(of: "10", with: String(format: "%d:%02d", arguments: [hours, minutes]))
            }
        } else {
            string = strings.Map_ETAMinutes(minutes)
        }
        return format(string)
    } else {
        return nil
    }
}

public func throttledUserLocation(_ userLocation: Signal<CLLocation?, NoError>) -> Signal<CLLocation?, NoError> {
    return userLocation
    |> reduceLeft(value: nil) { current, updated, emit -> CLLocation? in
        if let current = current {
            if let updated = updated {
                if updated.distance(from: current) > 250 || (updated.horizontalAccuracy < 50.0 && updated.horizontalAccuracy < current.horizontalAccuracy) {
                    emit(updated)
                    return updated
                } else {
                    return current
                }
            } else {
                return current
            }
        } else {
            if let updated = updated, updated.horizontalAccuracy > 0.0 {
                emit(updated)
                return updated
            } else {
                return nil
            }
        }
    }
}

public enum ExpectedTravelTime: Equatable {
    case unknown
    case calculating
    case ready(Double)
}

public func getExpectedTravelTime(coordinate: CLLocationCoordinate2D, transportType: MKDirectionsTransportType) -> Signal<ExpectedTravelTime, NoError> {
    return Signal { subscriber in
        subscriber.putNext(.calculating)
        
        let destinationPlacemark = MKPlacemark(coordinate: coordinate, addressDictionary: nil)
        let destination = MKMapItem(placemark: destinationPlacemark)
        
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination
        request.transportType = transportType
        request.requestsAlternateRoutes = false
        
        let directions = MKDirections(request: request)
        directions.calculateETA { response, error in
            if let travelTime = response?.expectedTravelTime {
                subscriber.putNext(.ready(travelTime))
            } else {
                subscriber.putNext(.unknown)
            }
            subscriber.putCompletion()
        }
        return ActionDisposable {
            directions.cancel()
        }
    }
}
