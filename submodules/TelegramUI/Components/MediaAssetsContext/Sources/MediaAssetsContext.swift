import Foundation
import UIKit
import SwiftSignalKit
import Photos
import AVFoundation

public final class MediaAssetsContext: NSObject, PHPhotoLibraryChangeObserver {
    private let assetType: PHAssetMediaType?
    
    private let changeObserverGate = ChangeObserverGate()
    private let changeSink = ValuePipe<PHChange>()
    private let mediaAccessSink = ValuePipe<PHAuthorizationStatus>()
    private let cameraAccessSink = ValuePipe<AVAuthorizationStatus?>()
    
    public init(assetType: PHAssetMediaType? = nil) {
        self.assetType = assetType
        
        super.init()
    }
    
    /// Limited access also delivers changes (the user adds photos to the selection, takes a new one). Registered
    /// again when access is first granted, so the grid updates in that same session. Any thread. Not done in
    /// `init` (it is the first PhotoKit call of a picker open): every fetch below registers before it reads.
    private func registerChangeObserverIfAllowed(_ status: PHAuthorizationStatus) {
        if self.changeObserverGate.shouldRegister(for: status) {
            PHPhotoLibrary.shared().register(self)
        }
    }
    
    private func registerChangeObserverIfNeeded() {
        if !self.changeObserverGate.isRegistered {
            self.registerChangeObserverIfAllowed(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        }
    }
    
    deinit {
        if self.changeObserverGate.isRegistered {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }
    
    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        self.changeSink.putNext(changeInstance)
    }
    
    public func fetchAssets(_ collection: PHAssetCollection) -> Signal<PHFetchResult<PHAsset>, NoError> {
        self.registerChangeObserverIfNeeded()
        let options = PHFetchOptions()
        if let assetType = self.assetType {
            options.predicate = NSPredicate(format: "mediaType = %d", assetType.rawValue)
        }
        
        let initialFetchResult = PHAsset.fetchAssets(in: collection, options: options)
        let fetchResult = Atomic<PHFetchResult<PHAsset>>(value: initialFetchResult)
        return .single(initialFetchResult)
        |> then(
            self.changeSink.signal()
            |> mapToSignal { change in
                if let updatedFetchResult = change.changeDetails(for: fetchResult.with { $0 })?.fetchResultAfterChanges {
                    let _ = fetchResult.modify { _ in return updatedFetchResult }
                    return .single(updatedFetchResult)
                } else {
                    return .complete()
                }
            }
        )
    }
    
    public func fetchAssetsCollections(_ type: PHAssetCollectionType) -> Signal<PHFetchResult<PHAssetCollection>, NoError> {
        self.registerChangeObserverIfNeeded()
        let initialFetchResult = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
        let fetchResult = Atomic<PHFetchResult<PHAssetCollection>>(value: initialFetchResult)
        return .single(initialFetchResult)
        |> then(
            self.changeSink.signal()
            |> mapToSignal { change in
                if let updatedFetchResult = change.changeDetails(for: fetchResult.with { $0 })?.fetchResultAfterChanges {
                    let _ = fetchResult.modify { _ in return updatedFetchResult }
                    return .single(updatedFetchResult)
                } else {
                    return .complete()
                }
            }
        )
    }
    
    public func recentAssets() -> Signal<PHFetchResult<PHAsset>?, NoError> {
        self.registerChangeObserverIfNeeded()
        let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil)
        if let collection = collections.firstObject {
            return fetchAssets(collection)
            |> map(Optional.init)
        } else {
            return .single(nil)
        }
    }
        
    public func mediaAccess() -> Signal<PHAuthorizationStatus, NoError> {
        // The status is read when the signal is subscribed, on the subscriber's queue, not when it is built.
        return Signal<Void, NoError>.single(Void())
        |> map { _ -> PHAuthorizationStatus in
            return PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
        |> then(
            self.mediaAccessSink.signal()
        )
    }
    
    public func requestMediaAccess(completion: @escaping () -> Void = {}) -> Void {
        // The legacy request reports a Limited grant as .authorized, which hid the Manage banner.
        PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: { [weak self] status in
            Queue.mainQueue().async {
                self?.registerChangeObserverIfAllowed(status)
                completion()
            }
            self?.mediaAccessSink.putNext(status)
        })
    }
    
    public func cameraAccess() -> Signal<AVAuthorizationStatus?, NoError> {
#if targetEnvironment(simulator)
        return .single(.authorized)
#else
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            return .single(AVCaptureDevice.authorizationStatus(for: .video))
            |> then(
                self.cameraAccessSink.signal()
            )
        } else {
            return .single(nil)
        }
#endif
    }
    
    public func requestCameraAccess() -> Void {
        AVCaptureDevice.requestAccess(for: .video, completionHandler: { [weak self] result in
            if result {
                self?.cameraAccessSink.putNext(.authorized)
            } else {
                self?.cameraAccessSink.putNext(.denied)
            }
        })
    }
}
