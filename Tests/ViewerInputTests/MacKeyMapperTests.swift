import AppKit
import CoreBridge
import CoreGraphics
import XCTest
import ViewerInput

final class MacKeyMapperTests: XCTestCase {
    func testMapsBasicTextNavigationAndModifiers() {
        XCTAssertEqual(MacKeyMapper.key(keyCode: 0, charactersIgnoringModifiers: "a"), .character("a"))
        XCTAssertEqual(MacKeyMapper.key(keyCode: 36, charactersIgnoringModifiers: "\r"), .special(.return))
        XCTAssertEqual(MacKeyMapper.key(keyCode: 48, charactersIgnoringModifiers: "\t"), .special(.tab))
        XCTAssertEqual(MacKeyMapper.key(keyCode: 49, charactersIgnoringModifiers: " "), .special(.space))
        XCTAssertEqual(MacKeyMapper.key(keyCode: 123, charactersIgnoringModifiers: nil), .special(.left))
        XCTAssertEqual(MacKeyMapper.key(keyCode: 55, charactersIgnoringModifiers: nil), .special(.command))
    }

    func testMapsCommonModifierFlags() {
        let modifiers = MacKeyMapper.modifiers(from: [.shift, .control, .option, .command, .capsLock])
        XCTAssertEqual(modifiers, [.shift, .control, .option, .command])
        XCTAssertEqual(MacKeyMapper.modifierIsDown(keyCode: 56, flags: [.shift]), true)
        XCTAssertEqual(
            MacKeyMapper.modifierIsDown(keyCode: 56, flags: NSEvent.ModifierFlags()),
            false
        )
    }

    func testMapsExclusiveHardwareKeysWithoutAppKitTextInput() {
        XCTAssertEqual(MacKeyMapper.keyFromHardwareCode(0), .character("a"))
        XCTAssertEqual(MacKeyMapper.keyFromHardwareCode(18), .character("1"))
        XCTAssertEqual(MacKeyMapper.keyFromHardwareCode(49), .special(.space))
        XCTAssertEqual(MacKeyMapper.keyFromHardwareCode(48), .special(.tab))
        XCTAssertNil(MacKeyMapper.keyFromHardwareCode(110))

        let flags: CGEventFlags = [.maskCommand, .maskShift]
        XCTAssertEqual(MacKeyMapper.modifiers(from: flags), [.command, .shift])
        XCTAssertEqual(MacKeyMapper.modifierIsDown(keyCode: 55, flags: flags), true)
        XCTAssertEqual(MacKeyMapper.modifierIsDown(keyCode: 56, flags: flags), true)
        XCTAssertEqual(MacKeyMapper.modifierIsDown(keyCode: 58, flags: flags), false)
    }
}
