import CoreBridge
import ViewerInput
import XCTest

final class ExclusiveKeyboardStateMachineTests: XCTestCase {
    func testInactiveModePassesEventsToTheLocalSystem() {
        var machine = ExclusiveKeyboardStateMachine()
        let decision = machine.handle(keyCode: 49, isDown: true, modifiers: [.command])

        XCTAssertEqual(machine.state, .inactive)
        XCTAssertFalse(decision.suppressLocally)
        XCTAssertFalse(decision.forwardRemotely)
    }

    func testActiveModeSuppressesAndForwardsReservedMacShortcuts() {
        var machine = ExclusiveKeyboardStateMachine()
        machine.activate()

        for keyCode: UInt16 in [49, 48] {
            let down = machine.handle(keyCode: keyCode, isDown: true, modifiers: [.command])
            let up = machine.handle(keyCode: keyCode, isDown: false, modifiers: [.command])
            XCTAssertTrue(down.suppressLocally)
            XCTAssertTrue(down.forwardRemotely)
            XCTAssertTrue(up.suppressLocally)
            XCTAssertTrue(up.forwardRemotely)
        }
    }

    func testExitChordReleasesOnlyAfterEveryChordKeyIsUp() {
        var machine = ExclusiveKeyboardStateMachine()
        machine.activate()

        _ = machine.handle(keyCode: 59, isDown: true, modifiers: [.control])
        _ = machine.handle(keyCode: 58, isDown: true, modifiers: [.control, .option])
        _ = machine.handle(keyCode: 56, isDown: true, modifiers: [.control, .option, .shift])
        let escape = machine.handle(
            keyCode: ExclusiveKeyboardStateMachine.exitKeyCode,
            isDown: true,
            modifiers: ExclusiveKeyboardStateMachine.exitModifiers
        )

        XCTAssertEqual(machine.state, .releasingExitChord)
        XCTAssertTrue(escape.beganExit)
        XCTAssertTrue(escape.suppressLocally)
        XCTAssertFalse(escape.forwardRemotely)

        for keyCode: UInt16 in [53, 56, 58] {
            let release = machine.handle(keyCode: keyCode, isDown: false, modifiers: [])
            XCTAssertFalse(release.completedExit)
            XCTAssertTrue(release.suppressLocally)
        }
        let finalRelease = machine.handle(keyCode: 59, isDown: false, modifiers: [])
        XCTAssertTrue(finalRelease.completedExit)
        XCTAssertEqual(machine.state, .inactive)
    }

    func testManualDeactivateClearsPartialExitChord() {
        var machine = ExclusiveKeyboardStateMachine()
        machine.activate()
        _ = machine.handle(keyCode: 59, isDown: true, modifiers: [.control])
        machine.deactivate()

        let release = machine.handle(keyCode: 59, isDown: false, modifiers: [])
        XCTAssertEqual(machine.state, .inactive)
        XCTAssertFalse(release.suppressLocally)
    }
}
