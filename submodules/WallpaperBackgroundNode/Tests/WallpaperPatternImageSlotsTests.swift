import XCTest

/// The chat background keeps rendered wallpaper patterns (about 40 ms of main-thread CG work each,
/// measured on device). Full chats share one slot; previews and other non-shared nodes get their own,
/// so a long-press chat preview hits on its second open and never evicts the chat's pattern.
final class WallpaperPatternImageSlotsTests: XCTestCase {
    private struct Entry: Equatable {
        let wallpaper: String
        let size: Int
    }

    func testPreviewStoresDoNotEvictTheSharedEntry() {
        var slots = WallpaperPatternImageSlots<Entry>()
        slots.store(Entry(wallpaper: "a", size: 956), isShared: true)
        slots.store(Entry(wallpaper: "a", size: 700), isShared: false)
        slots.store(Entry(wallpaper: "a", size: 640), isShared: false)

        XCTAssertEqual(slots.first(where: { $0.size == 956 }), Entry(wallpaper: "a", size: 956))
        XCTAssertEqual(slots.first(where: { $0.size == 640 }), Entry(wallpaper: "a", size: 640))
        XCTAssertNil(slots.first(where: { $0.size == 700 }))
        XCTAssertEqual(slots.count, 2)
    }

    func testSharedEntryIsPreferredOnAmbiguousMatch() {
        var slots = WallpaperPatternImageSlots<Entry>()
        slots.store(Entry(wallpaper: "a", size: 700), isShared: false)
        slots.store(Entry(wallpaper: "a", size: 956), isShared: true)
        XCTAssertEqual(slots.first(where: { $0.wallpaper == "a" }), Entry(wallpaper: "a", size: 956))
    }

    func testSharedStoreReplacesOnlyTheSharedSlot() {
        var slots = WallpaperPatternImageSlots<Entry>()
        slots.store(Entry(wallpaper: "a", size: 956), isShared: true)
        slots.store(Entry(wallpaper: "b", size: 700), isShared: false)
        slots.store(Entry(wallpaper: "c", size: 956), isShared: true)
        XCTAssertNil(slots.first(where: { $0.wallpaper == "a" }))
        XCTAssertNotNil(slots.first(where: { $0.wallpaper == "b" }))
        XCTAssertNotNil(slots.first(where: { $0.wallpaper == "c" }))
    }

    func testBackgroundDropsOnlyTheNonSharedEntry() {
        var slots = WallpaperPatternImageSlots<Entry>()
        slots.store(Entry(wallpaper: "a", size: 956), isShared: true)
        slots.store(Entry(wallpaper: "a", size: 700), isShared: false)
        slots.removeNonShared()
        XCTAssertEqual(slots.count, 1)
        XCTAssertNotNil(slots.first(where: { $0.size == 956 }))
    }

    func testMemoryWarningDropsEverything() {
        var slots = WallpaperPatternImageSlots<Entry>()
        slots.store(Entry(wallpaper: "a", size: 956), isShared: true)
        slots.store(Entry(wallpaper: "a", size: 700), isShared: false)
        slots.removeAll()
        XCTAssertEqual(slots.count, 0)
        XCTAssertNil(slots.first(where: { _ in true }))
    }
}
