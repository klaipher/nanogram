import Foundation
import UIKit
import Photos
import MediaGrid

public final class MediaGridPhotoLibraryFiller {
    let filler: ThumbnailFiller
    let source: PhotoKitThumbnailSource
    var sharpNetworkIdle: () -> Bool = { false }
    public var onLog: ((String) -> Void)?
    public private(set) var networkFills = 0
    private var networkDeliveries = 0

    public var isNetworkLaneEnabled = true {
        didSet {
            if self.isNetworkLaneEnabled != oldValue {
                self.filler.networkConditionsChanged()
            }
        }
    }

    public var isMovingFast: Bool {
        get {
            return self.filler.isMovingFast
        }
        set {
            self.filler.isMovingFast = newValue
        }
    }

    public convenience init(store: MediaGridThumbnailStore, retryRegistryURL: URL?) {
        self.init(store: store, source: PhotoKitThumbnailSource(fetchResult: PHFetchResult<PHAsset>(), reversed: true), registry: ThumbnailRetryRegistry(url: retryRegistryURL))
    }

    private var pacer: ThumbnailFillPacer?

    init(store: MediaGridThumbnailStore, source: PhotoKitThumbnailSource, registry: ThumbnailRetryRegistry, pacingEnvironment: ThumbnailFillPacer.Environment = .live) {
        self.source = source
        self.filler = ThumbnailFiller(store: store, source: source, registry: registry)
        self.filler.isHalted = true
        self.pacer = ThumbnailFillPacer(environment: pacingEnvironment, onChange: { [weak self] isAllowed in
            self?.filler.isHalted = !isAllowed
        })
        store.onWritabilityChanged = { [weak self] isWritable in
            self?.filler.isPaused = !isWritable
        }
        self.filler.networkGate = { [weak self] in
            guard let self else {
                return false
            }
            return self.isNetworkLaneEnabled && self.sharpNetworkIdle()
        }
        self.filler.onNetworkFill = { [weak self] _ in
            self?.networkFills += 1
        }
        source.onNetworkDelivery = { [weak self] width, height in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.networkDeliveries += 1
                if self.networkDeliveries <= 100 {
                    self.onLog?("NETFILL n=\(self.networkDeliveries) delivered=\(width)x\(height)")
                }
            }
        }
        source.policy.onLog = { [weak self] message in
            DispatchQueue.main.async {
                self?.onLog?(message)
            }
        }
    }

    /// Whether the pacing policy lets the filler run right now.
    public var isFillingAllowed: Bool {
        return self.pacer?.isAllowed ?? false
    }

    /// A library picker is open: the filler may run (unless the app is in the background, Low Power
    /// Mode is on or the device is hot). Balanced by `releasePickerLease()`; main thread only.
    public func acquirePickerLease() {
        self.pacer?.pickerOpened()
    }

    public func releasePickerLease() {
        if Thread.isMainThread {
            self.pickerLeaseReleased()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.pickerLeaseReleased()
            }
        }
    }

    /// Number of pickers that hold a lease.
    var pickerLeaseCount: Int {
        return self.pacer?.openPickerCount ?? 0
    }

    /// Called on the main queue when the last picker's lease is released.
    var onLastPickerReleased: (() -> Void)?

    private func pickerLeaseReleased() {
        self.pacer?.pickerClosed()
        if self.pickerLeaseCount == 0 {
            self.source.fetchResult = PHFetchResult<PHAsset>()
            self.filler.releaseCatalog()
            self.onLastPickerReleased?()
        }
    }

    /// The picker `owner` is covered by a full-screen editor or camera, or minimized: the filler pauses
    /// until it is uncovered. The owner must uncover before it goes away. Main thread only.
    public func setPickerCovered(_ covered: Bool, by owner: AnyObject) {
        self.pacer?.setPickerCovered(covered, by: owner)
    }

    /// The app's settings: a few requests at a time, a cap on the store, no iCloud lane.
    public func applyAppPacing() {
        self.isNetworkLaneEnabled = false
        self.filler.idleInFlightLimit = ThumbnailFiller.pacedIdleLimit
        self.filler.fastInFlightLimit = ThumbnailFiller.pacedFastLimit
        self.filler.storedLimit = ThumbnailFiller.pacedStoredLimit
    }

    public var filledCount: Int {
        return self.filler.filledCount
    }

    public var unavailableCount: Int {
        return self.filler.unavailableCount
    }

    public var missingCount: Int {
        return self.filler.missingCount
    }

    public var inFlightCount: Int {
        return self.filler.inFlightCount
    }

    public var networkInFlightCount: Int {
        return self.filler.networkInFlightCount
    }

    public var isComplete: Bool {
        return self.filler.isComplete
    }

    public var retryEntryCount: Int {
        return self.filler.registry.count
    }

    public var launchRetriesReleased: Int {
        return self.filler.launchRetriesReleased
    }
}

public final class MediaGridPhotoLibraryServices {
    public static let shared: MediaGridPhotoLibraryServices = {
        let services = MediaGridPhotoLibraryServices(directory: MediaGridPhotoLibraryServices.defaultDirectory, launchDirectory: MediaGridLaunchCache.defaultDirectory, retryRegistryURL: MediaGridPhotoLibraryServices.defaultRetryRegistryURL, snapshotURL: MediaGridPhotoLibraryServices.defaultSnapshotURL)
        services.filler.applyAppPacing()
        return services
    }()

    public static var defaultDirectory: URL {
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MediaGridThumbnails", isDirectory: true)
    }

    static var defaultRetryRegistryURL: URL {
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MediaGridThumbnailRetries.plist")
    }

    static var defaultSnapshotURL: URL {
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MediaGridLaunchSnapshot.plist")
    }

    public let store: MediaGridThumbnailStore
    public let filler: MediaGridPhotoLibraryFiller
    public let snapshotURL: URL?
    private let launchDirectory: URL?
    private var launchCoverage: () -> MediaGridLaunchCache.Coverage
    private var cachedLaunchCache: MediaGridLaunchCache?

    public init(directory: URL?, launchDirectory: URL?, retryRegistryURL: URL?, snapshotURL: URL?, launchCoverage: (() -> MediaGridLaunchCache.Coverage)? = nil) {
        self.store = MediaGridThumbnailStore(directory: directory)
        self.filler = MediaGridPhotoLibraryFiller(store: self.store, retryRegistryURL: retryRegistryURL)
        self.snapshotURL = snapshotURL
        self.launchDirectory = launchDirectory
        self.launchCoverage = launchCoverage ?? {
            let screen = UIScreen.main
            return MediaGridLaunchCache.coverage(screenSize: screen.bounds.size, scale: screen.scale)
        }
        self.filler.onLastPickerReleased = { [weak self] in
            self?.releaseMemoryAfterLastPicker(completion: nil)
        }
    }

    /// The shared store and launch cache otherwise keep ~80-110 MB (decoded 768x768 pages, writer contexts, launch
    /// images) until a memory warning or the background. After the last picker closes: write what is pending, then
    /// drop every decoded page and the launch images. The next picker decodes what it shows again. Main thread.
    func releaseMemoryAfterLastPicker(completion: (() -> Void)?) {
        self.cachedLaunchCache?.releaseImages()
        self.store.flush(completion: { [weak self] in
            // A picker that opened meanwhile owns the visible set.
            if self?.filler.pickerLeaseCount == 0 {
                self?.store.trimToVisible(ids: [])
            }
            completion?()
        })
    }

    public var launchCache: MediaGridLaunchCache {
        if let cache = self.cachedLaunchCache {
            return cache
        }
        let coverage = self.launchCoverage()
        let cache = MediaGridLaunchCache(directory: self.launchDirectory, capacity: coverage.capacity, pixelSize: coverage.pixelSize)
        self.cachedLaunchCache = cache
        return cache
    }

    @discardableResult
    public func configureLaunchCoverage(_ coverage: @escaping () -> MediaGridLaunchCache.Coverage) -> Bool {
        guard self.cachedLaunchCache == nil else {
            return false
        }
        self.launchCoverage = coverage
        return true
    }

    /// Storage Usage's "Clear cache" clears the whole cache, not a single chat's media.
    public static func clearsThumbnailCache(chatScoped: Bool, clearingCategories: Bool) -> Bool {
        return !chatScoped && clearingCategories
    }

    /// Deletes the thumbnail pages and index, the launch cache, the launch snapshot and the retry
    /// registry. Thumbnails of an open picker are rebuilt by its filler; with no picker open
    /// nothing is rebuilt until the next one opens. The completion runs on the main queue.
    public func clearCaches(completion: (() -> Void)? = nil) {
        self.store.removeAll(completion: completion)
        self.filler.filler.registry.remove(ids: self.filler.filler.registry.ids())
        self.cachedLaunchCache?.releaseImages()
        let snapshotURL = self.snapshotURL
        let launchDirectory = self.launchDirectory
        DispatchQueue.global(qos: .utility).async {
            var urls: [URL] = []
            if let snapshotURL {
                urls.append(snapshotURL)
            }
            if let launchDirectory, let names = try? FileManager.default.contentsOfDirectory(at: launchDirectory, includingPropertiesForKeys: nil) {
                urls.append(contentsOf: names)
            }
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    public func startLaunchLoading() {
        self.launchCache.startLoading()
    }

    public func makeLaunchMatch(fetchResult: PHFetchResult<PHAsset>, reversed: Bool) -> MediaGridLaunchMatch {
        return MediaGridPhotoLibraryDataSource.launchMatch(cache: self.launchCache, fetchResult: fetchResult, reversed: reversed)
    }

    public func makeDataSource(fetchResult: PHFetchResult<PHAsset>, reversed: Bool, isLibrary: Bool) -> MediaGridPhotoLibraryDataSource {
        guard isLibrary else {
            return MediaGridPhotoLibraryDataSource(fetchResult: fetchResult, reversed: reversed, store: self.store, launch: nil)
        }
        return MediaGridPhotoLibraryDataSource(fetchResult: fetchResult, reversed: reversed, store: self.store, launch: self.makeLaunchMatch(fetchResult: fetchResult, reversed: reversed), filler: self.filler, snapshotURL: self.snapshotURL)
    }
}
