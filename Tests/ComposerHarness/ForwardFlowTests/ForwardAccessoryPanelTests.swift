import XCTest
import QuartzCore
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import ChatPresentationInterfaceState
import ChatInterfaceState
import AccountContext
@testable import ForwardAccessoryPanelNode
@testable import HarnessAppContext

/// The forward panel the chat picker shows above its comment field
/// (`PeerSelectionControllerNode.containerLayoutUpdated` → `ForwardAccessoryPanelNode.updateState`).
/// The picker lays itself out on every keystroke in that field and on every selection change, and
/// each layout calls `updateState` with the same messages and options.
final class ForwardAccessoryPanelTests: XCTestCase {
    private static var fixture: ForwardFlowFixture?

    private var fixture: ForwardFlowFixture {
        if let fixture = ForwardAccessoryPanelTests.fixture {
            return fixture
        }
        let fixture = ForwardFlowFixture(testCase: self)
        ForwardAccessoryPanelTests.fixture = fixture
        return fixture
    }

    private var nextMessageId: Int32 = 1

    private func interfaceState(hideNames: Bool = false) -> ChatPresentationInterfaceState {
        let context = self.fixture.context
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let state = ChatPresentationInterfaceState(chatWallpaper: .builtin(WallpaperSettings()), theme: presentationData.theme, preferredGlassType: .default, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat, nameDisplayOrder: presentationData.nameDisplayOrder, limitsConfiguration: context.currentLimitsConfiguration.with { $0 }, fontSize: presentationData.chatFontSize, bubbleCorners: presentationData.chatBubbleCorners, accountPeerId: context.account.peerId, mode: .standard(.default), chatLocation: .peer(id: EnginePeer.Id(0)), subject: nil, greetingData: nil, pendingUnpinnedAllMessages: false, activeGroupCallInfo: nil, hasActiveGroupCall: false, threadData: nil, isGeneralThreadClosed: nil, replyMessage: nil, accountPeerColor: nil, businessIntro: nil)
        return state.updatedInterfaceState { $0.withUpdatedForwardOptionsState(ChatInterfaceForwardOptionsState(hideNames: hideNames, hideCaptions: false, unhideNamesOnCaptionChange: false)) }
    }

    /// A panel over `count` freshly stored messages, laid out once and loaded, as the picker builds it
    /// (no animation cache or renderer).
    private func makePanel(count: Int, authorCount: Int, hideNames: Bool = false, textForIndex: ((Int) -> String)? = nil) -> (ForwardAccessoryPanelNode, ChatPresentationInterfaceState) {
        let ids = self.fixture.storeSourceMessages(count: count, authorCount: authorCount, firstId: self.nextMessageId, textForIndex: textForIndex)
        self.nextMessageId += Int32(count)
        let context = self.fixture.context
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let state = self.interfaceState(hideNames: hideNames)
        let panel = ForwardAccessoryPanelNode(context: context, messageIds: ids, theme: presentationData.theme, strings: presentationData.strings, fontSize: presentationData.chatFontSize, nameDisplayOrder: presentationData.nameDisplayOrder, forwardOptionsState: state.interfaceState.forwardOptionsState, animationCache: nil, animationRenderer: nil)
        let size = panel.calculateSizeThatFits(CGSize(width: 402.0, height: 800.0))
        panel.frame = CGRect(origin: CGPoint(), size: size)
        panel.updateState(size: size, inset: 0.0, interfaceState: state)
        XCTAssertTrue(ForwardFlowFixture.spin(until: { (panel.textNode.attributedText?.string ?? "From: ") != "From: " }), "the panel never showed its messages")
        return (panel, state)
    }

    private func snapshot(_ panel: ForwardAccessoryPanelNode) -> [String] {
        return [
            "title=\(panel.titleNode.attributedText?.string ?? "nil")",
            "text=\(panel.textNode.attributedText?.string ?? "nil")",
            "accessibility=\(panel.actionArea.accessibilityLabel ?? "nil")",
            "titleFrame=\(panel.titleNode.frame)",
            "textFrame=\(panel.textNode.frame)",
            "closeHidden=\(panel.closeButton.isHidden)"
        ]
    }

    // MARK: - Same text and layout

    func testPanelContentForOneMessage() {
        let (panel, state) = self.makePanel(count: 1, authorCount: 1)
        let expected = [
            "title=Forward Message",
            "text=Author 0: Message 0",
            "accessibility=Forward message. From: Author 0.\nAuthor 0: Message 0",
            "titleFrame=(65.0, 7.0, 125.0, 17.0)",
            "textFrame=(65.0, 25.0, 143.0, 17.0)",
            "closeHidden=true"
        ]
        XCTAssertEqual(self.snapshot(panel), expected)
        panel.updateState(size: panel.bounds.size, inset: 0.0, interfaceState: state)
        XCTAssertEqual(self.snapshot(panel), expected, "a repeated layout changed the panel")
    }

    func testPanelContentForTenMessages() {
        let (panel, state) = self.makePanel(count: 10, authorCount: 3)
        let expected = self.snapshot(panel)
        XCTAssertEqual(expected[0], "title=Forward 10 Messages")
        XCTAssertEqual(expected[1], "text=From: Author 0, Author 1, Author 2")
        XCTAssertEqual(expected[2], "accessibility=Forward messages. From: Author 0, Author 1, Author 2.\nFrom: Author 0, Author 1, Author 2")
        panel.updateState(size: panel.bounds.size, inset: 0.0, interfaceState: state)
        XCTAssertEqual(self.snapshot(panel), expected, "a repeated layout changed the panel")
    }

    func testPanelContentForHundredMessages() {
        let (panel, state) = self.makePanel(count: 100, authorCount: 20)
        let expected = self.snapshot(panel)
        XCTAssertEqual(expected[0], "title=Forward 100 Messages")
        XCTAssertTrue(expected[1].hasPrefix("text=From: Author 0, Author 1, Author 2"), expected[1])
        XCTAssertTrue(expected[1].hasSuffix("Author 19"), expected[1])
        panel.updateState(size: panel.bounds.size, inset: 0.0, interfaceState: state)
        XCTAssertEqual(self.snapshot(panel), expected, "a repeated layout changed the panel")
    }

    /// Changing the options, the width or the inset between layouts still changes the panel.
    func testPanelFollowsOptionsWidthAndInset() {
        let (panel, state) = self.makePanel(count: 10, authorCount: 3)
        let hidden = self.interfaceState(hideNames: true)
        panel.updateState(size: panel.bounds.size, inset: 0.0, interfaceState: hidden)
        XCTAssertEqual(panel.textNode.attributedText?.string, "Sender names removed")
        panel.updateState(size: panel.bounds.size, inset: 0.0, interfaceState: state)
        XCTAssertEqual(panel.textNode.attributedText?.string, "From: Author 0, Author 1, Author 2")

        panel.updateState(size: CGSize(width: 200.0, height: 45.0), inset: 0.0, interfaceState: state)
        let narrow = panel.textNode.frame
        XCTAssertLessThan(narrow.width, 95.0)
        panel.updateState(size: CGSize(width: 402.0, height: 45.0), inset: 16.0, interfaceState: state)
        XCTAssertEqual(panel.titleNode.frame.minX, 81.0)
        XCTAssertGreaterThan(panel.textNode.frame.width, narrow.width)
    }

    /// Text another path wrote into the text node (the theme refresh recolours it, the options tip
    /// replaces it) is overwritten by the next layout, exactly as before.
    func testLayoutRestoresTextWrittenFromOutside() {
        let (panel, state) = self.makePanel(count: 1, authorCount: 1)
        panel.textNode.attributedText = NSAttributedString(string: "Tap here for forwarding options")
        panel.updateState(size: panel.bounds.size, inset: 0.0, interfaceState: state)
        XCTAssertEqual(panel.textNode.attributedText?.string, "Author 0: Message 0")
    }

    /// A theme change recolours the panel through the layout it triggers.
    func testThemeChangeRecoloursTheText() {
        let (panel, state) = self.makePanel(count: 10, authorCount: 3)
        let dark = defaultDarkColorPresentationTheme
        let strings = self.fixture.context.sharedContext.currentPresentationData.with { $0 }.strings
        panel.updateThemeAndStrings(theme: dark, strings: strings, forwardOptionsState: state.interfaceState.forwardOptionsState)
        let color = panel.textNode.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        XCTAssertEqual(color, dark.chat.inputPanel.secondaryTextColor)
        let titleColor = panel.titleNode.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        XCTAssertEqual(titleColor, dark.chat.inputPanel.panelControlAccentColor)
        XCTAssertEqual(panel.textNode.attributedText?.string, "From: Author 0, Author 1, Author 2")
    }

    // MARK: - Repeated layouts

    /// A layout with the same messages, options, theme and geometry builds nothing new: the text
    /// node keeps the attributed string it already lays out.
    func testRepeatedLayoutKeepsTheBuiltText() {
        let (panel, state) = self.makePanel(count: 10, authorCount: 3)
        let title = panel.titleNode.attributedText
        let text = panel.textNode.attributedText
        for _ in 0 ..< 3 {
            panel.updateState(size: panel.bounds.size, inset: 0.0, interfaceState: state)
        }
        XCTAssertTrue(panel.titleNode.attributedText === title, "the title was rebuilt by an unchanged layout")
        XCTAssertTrue(panel.textNode.attributedText === text, "the text was rebuilt by an unchanged layout")
    }

    /// Prints the cost of one picker layout's `updateState` (what a keystroke in the comment field
    /// costs the panel). Not an assertion: the numbers go into the commit message.
    func testBenchmarkRepeatedLayout() {
        var lines: [String] = []
        let longText = String(repeating: "A long message line with words. ", count: 120)
        for (count, authors, text) in [(1, 1, nil), (1, 1, longText), (10, 3, nil), (100, 20, nil)] as [(Int, Int, String?)] {
            let (panel, state) = self.makePanel(count: count, authorCount: authors, textForIndex: text.map { value in { _ in value } })
            let size = panel.bounds.size
            for _ in 0 ..< 20 {
                panel.updateState(size: size, inset: 0.0, interfaceState: state)
            }
            var samples: [Double] = []
            for _ in 0 ..< 5 {
                let iterations = 200
                let start = CACurrentMediaTime()
                for _ in 0 ..< iterations {
                    autoreleasepool {
                        panel.updateState(size: size, inset: 0.0, interfaceState: state)
                    }
                }
                samples.append((CACurrentMediaTime() - start) / Double(iterations))
            }
            let best = samples.min()! * 1_000_000.0
            lines.append("messages=\(count) authors=\(authors) long=\(text != nil) updateState=\(String(format: "%.1f", best)) us")
        }
        print("FORWARD_PANEL_BENCH\n" + lines.joined(separator: "\n"))
    }
}
