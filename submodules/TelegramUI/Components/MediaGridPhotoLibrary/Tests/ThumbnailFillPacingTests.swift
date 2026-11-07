import XCTest
import UIKit
import Photos
import MediaGrid
@testable import MediaGridPhotoLibrary

final class ThumbnailFillPacingTests: XCTestCase {
    private func conditions(open: Int = 1, foreground: Bool = true, lowPower: Bool = false, thermal: ProcessInfo.ThermalState = .nominal) -> ThumbnailFillPacing.Conditions {
        return ThumbnailFillPacing.Conditions(openPickerCount: open, isForeground: foreground, isLowPowerMode: lowPower, thermalState: thermal)
    }

    func testRunsOnlyWhileAPickerIsOpenInTheForeground() {
        XCTAssertTrue(ThumbnailFillPacing.allowsFilling(self.conditions()))
        XCTAssertFalse(ThumbnailFillPacing.allowsFilling(self.conditions(open: 0)))
        XCTAssertFalse(ThumbnailFillPacing.allowsFilling(self.conditions(foreground: false)))
    }

    func testSkippedInLowPowerMode() {
        XCTAssertFalse(ThumbnailFillPacing.allowsFilling(self.conditions(lowPower: true)))
    }

    func testThermalStates() {
        XCTAssertTrue(ThumbnailFillPacing.allowsFilling(self.conditions(thermal: .nominal)))
        XCTAssertTrue(ThumbnailFillPacing.allowsFilling(self.conditions(thermal: .fair)))
        XCTAssertFalse(ThumbnailFillPacing.allowsFilling(self.conditions(thermal: .serious)))
        XCTAssertFalse(ThumbnailFillPacing.allowsFilling(self.conditions(thermal: .critical)))
    }

    private final class Fixture {
        var isLowPowerMode = false
        var thermalState = ProcessInfo.ThermalState.nominal
        var changes: [Bool] = []
        let center = NotificationCenter()
        var pacer: ThumbnailFillPacer!

        init() {
            let environment = ThumbnailFillPacer.Environment(isLowPowerMode: { [unowned self] in self.isLowPowerMode }, thermalState: { [unowned self] in self.thermalState }, notificationCenter: self.center)
            self.pacer = ThumbnailFillPacer(environment: environment, onChange: { [unowned self] allowed in
                self.changes.append(allowed)
            })
        }
    }

    func testStartsWhenThePickerOpensAndStopsWhenItCloses() {
        let fixture = Fixture()
        XCTAssertFalse(fixture.pacer.isAllowed)
        XCTAssertTrue(fixture.changes.isEmpty)
        fixture.pacer.pickerOpened()
        XCTAssertTrue(fixture.pacer.isAllowed)
        fixture.pacer.pickerClosed()
        XCTAssertFalse(fixture.pacer.isAllowed)
        XCTAssertEqual(fixture.changes, [true, false])
    }

    func testTwoPickersKeepItRunningUntilBothClose() {
        let fixture = Fixture()
        fixture.pacer.pickerOpened()
        fixture.pacer.pickerOpened()
        fixture.pacer.pickerClosed()
        XCTAssertTrue(fixture.pacer.isAllowed)
        fixture.pacer.pickerClosed()
        XCTAssertFalse(fixture.pacer.isAllowed)
        fixture.pacer.pickerClosed()
        XCTAssertEqual(fixture.pacer.openPickerCount, 0)
        XCTAssertEqual(fixture.changes, [true, false])
    }

    func testLowPowerAndThermalChangesReevaluate() {
        let fixture = Fixture()
        fixture.pacer.pickerOpened()
        fixture.isLowPowerMode = true
        fixture.pacer.reevaluate()
        XCTAssertFalse(fixture.pacer.isAllowed)
        fixture.isLowPowerMode = false
        fixture.pacer.reevaluate()
        XCTAssertTrue(fixture.pacer.isAllowed)
        fixture.thermalState = .serious
        fixture.pacer.reevaluate()
        XCTAssertFalse(fixture.pacer.isAllowed)
        fixture.thermalState = .fair
        fixture.pacer.reevaluate()
        XCTAssertTrue(fixture.pacer.isAllowed)
        XCTAssertEqual(fixture.changes, [true, false, true, false, true])
    }

    func testBackgroundingStopsAndForegroundingResumes() {
        let fixture = Fixture()
        fixture.pacer.pickerOpened()
        let stopped = self.expectation(description: "stopped")
        fixture.pacer.onChangeForTesting = { allowed in
            if !allowed {
                stopped.fulfill()
            }
        }
        fixture.center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        self.wait(for: [stopped], timeout: 5.0)
        XCTAssertFalse(fixture.pacer.isAllowed)
        let resumed = self.expectation(description: "resumed")
        fixture.pacer.onChangeForTesting = { allowed in
            if allowed {
                resumed.fulfill()
            }
        }
        fixture.center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        self.wait(for: [resumed], timeout: 5.0)
        XCTAssertTrue(fixture.pacer.isAllowed)
    }

    func testFillerIsHaltedUntilAPickerLeaseAndAgainAfterIt() {
        let fixture = Fixture()
        let store = MediaGridThumbnailStore(directory: nil)
        let filler = MediaGridPhotoLibraryFiller(store: store, source: PhotoKitThumbnailSource(fetchResult: PHFetchResult<PHAsset>(), reversed: true), registry: ThumbnailRetryRegistry(url: nil), pacingEnvironment: ThumbnailFillPacer.Environment(isLowPowerMode: { [unowned fixture] in fixture.isLowPowerMode }, thermalState: { [unowned fixture] in fixture.thermalState }, notificationCenter: fixture.center))
        XCTAssertTrue(filler.filler.isHalted)
        XCTAssertFalse(filler.isFillingAllowed)
        filler.acquirePickerLease()
        XCTAssertFalse(filler.filler.isHalted)
        XCTAssertTrue(filler.isFillingAllowed)
        filler.releasePickerLease()
        XCTAssertTrue(filler.filler.isHalted)
    }

    func testAppPacingSettings() {
        let store = MediaGridThumbnailStore(directory: nil)
        let filler = MediaGridPhotoLibraryFiller(store: store, retryRegistryURL: nil)
        XCTAssertTrue(filler.isNetworkLaneEnabled)
        filler.applyAppPacing()
        XCTAssertFalse(filler.isNetworkLaneEnabled)
        XCTAssertEqual(filler.filler.idleInFlightLimit, 4)
        XCTAssertEqual(filler.filler.fastInFlightLimit, 2)
        XCTAssertEqual(filler.filler.storedLimit, 60_000)
    }

    func testClearCacheRuleIsTheWholeCacheNotAChat() {
        XCTAssertTrue(MediaGridPhotoLibraryServices.clearsThumbnailCache(chatScoped: false, clearingCategories: true))
        XCTAssertFalse(MediaGridPhotoLibraryServices.clearsThumbnailCache(chatScoped: true, clearingCategories: true))
        XCTAssertFalse(MediaGridPhotoLibraryServices.clearsThumbnailCache(chatScoped: false, clearingCategories: false))
    }

    func testClearCachesEmptiesTheStoreAndRetryRegistry() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThumbnailFillPacingTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let services = MediaGridPhotoLibraryServices(directory: directory.appendingPathComponent("thumbs", isDirectory: true), launchDirectory: directory.appendingPathComponent("launch", isDirectory: true), retryRegistryURL: nil, snapshotURL: directory.appendingPathComponent("snapshot.plist"))
        let loaded = self.expectation(description: "loaded")
        services.store.load {
            loaded.fulfill()
        }
        self.wait(for: [loaded], timeout: 20.0)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }.cgImage
        guard let image else {
            return XCTFail("no image")
        }
        services.store.write(image, id: "a", version: "1")
        XCTAssertEqual(services.store.version(for: "a"), "1")
        _ = services.filler.filler.registry.recordFailure(id: "b", version: "1")
        XCTAssertEqual(services.filler.retryEntryCount, 1)
        let cleared = self.expectation(description: "cleared")
        services.clearCaches(completion: {
            cleared.fulfill()
        })
        self.wait(for: [cleared], timeout: 5.0)
        XCTAssertTrue(services.store.storedIds().isEmpty)
        XCTAssertEqual(services.filler.retryEntryCount, 0)
    }
}
