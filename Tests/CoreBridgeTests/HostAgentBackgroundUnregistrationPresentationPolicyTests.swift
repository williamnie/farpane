import Foundation
import XCTest

@testable import CoreBridge

final class HostAgentBackgroundUnregistrationPresentationPolicyTests: XCTestCase {
    func testResponsePolicyMapsOnlyExplicitButtonDecision() {
        XCTAssertEqual(
            HostAgentBackgroundUnregistrationSheetResponsePolicy.intent(confirmed: true),
            .confirmBackgroundUnregistration)
        XCTAssertEqual(
            HostAgentBackgroundUnregistrationSheetResponsePolicy.intent(confirmed: false),
            .cancelBackgroundUnregistration)
    }

    func testPromptAndBusyPresentationDoNotClaimCompletion() throws {
        let owner = makeUnregistrationOwner(result: successfulUnregistrationResult())
        XCTAssertTrue(owner.apply(.requestBackgroundUnregistration))
        let prompt = presentation(for: owner.snapshot())
        XCTAssertEqual(prompt.statusText, "等待确认关闭后台连接")
        XCTAssertEqual(prompt.errorText, "")
        XCTAssertEqual(prompt.tone, .attention)
        XCTAssertFalse(prompt.isBusy)

        let recorder = UnregistrationViewRecorder()
        let busyOwner = makeUnregistrationOwner(
            result: successfulUnregistrationResult(), observer: { recorder.append($0) })
        XCTAssertTrue(busyOwner.apply(.requestBackgroundUnregistration))
        XCTAssertTrue(busyOwner.apply(.confirmBackgroundUnregistration))
        let busy = presentation(
            for: try XCTUnwrap(recorder.views.first { $0.phase == .unregistering }))
        XCTAssertEqual(busy.statusText, "正在关闭后台连接…")
        XCTAssertEqual(busy.tone, .progress)
        XCTAssertTrue(busy.isBusy)
    }

    func testSuccessAndCancellationRemainDistinct() {
        let successOwner = makeUnregistrationOwner(result: successfulUnregistrationResult())
        XCTAssertTrue(successOwner.apply(.requestBackgroundUnregistration))
        XCTAssertTrue(successOwner.apply(.confirmBackgroundUnregistration))
        let success = presentation(for: successOwner.snapshot())
        XCTAssertEqual(success.statusText, "后台连接已关闭")
        XCTAssertEqual(success.errorText, "")
        XCTAssertEqual(success.tone, .success)

        let cancelOwner = makeUnregistrationOwner(result: successfulUnregistrationResult())
        XCTAssertTrue(cancelOwner.apply(.requestBackgroundUnregistration))
        XCTAssertTrue(cancelOwner.apply(.cancelBackgroundUnregistration))
        let cancelled = presentation(for: cancelOwner.snapshot())
        XCTAssertEqual(cancelled.statusText, "已取消关闭后台连接")
        XCTAssertEqual(cancelled.errorText, "")
        XCTAssertEqual(cancelled.tone, .neutral)
    }

    func testFailuresUseBoundedSanitizedCopy() {
        let failures: [(HostAgentBackgroundUnregistrationUXFailure, String)] = [
            (.mutation(.serviceUnavailable), "后台组件状态"),
            (.mutation(.unregistrationNotEffective), "仍处于注册状态"), (.invalidMutationResult, "状态异常"),
            (.generationExhausted, "状态异常"),
        ]

        for (failure, fragment) in failures {
            let output = presentation(
                for: HostAgentBackgroundUnregistrationUXView(
                    generation: 1, phase: .failed(failure), registration: nil))
            XCTAssertEqual(output.statusText, "后台连接关闭失败")
            XCTAssertTrue(output.errorText.contains(fragment))
            XCTAssertLessThanOrEqual(output.errorText.count, 64)
            XCTAssertEqual(output.tone, .failure)
            XCTAssertFalse(output.isBusy)
            XCTAssertTrue(output.canRetry)
        }
    }

}

private func presentation(for view: HostAgentBackgroundUnregistrationUXView)
    -> HostAgentBackgroundUnregistrationPresentation
{ HostAgentBackgroundUnregistrationPresentationPolicy.presentation(for: view) }

private func makeUnregistrationOwner(
    result: (Bool, HostAgentBackgroundRegistrationMutationView),
    observer: @escaping HostAgentBackgroundUnregistrationUXOwner.Observer = { _ in }
) -> HostAgentBackgroundUnregistrationUXOwner {
    HostAgentBackgroundUnregistrationUXOwner(performUnregistration: { result }, observer: observer)
}

private func successfulUnregistrationResult() -> (Bool, HostAgentBackgroundRegistrationMutationView)
{
    (
        true,
        HostAgentBackgroundRegistrationMutationView(
            generation: 1, phase: .unregistered, registration: .notRegistered)
    )
}

private final class UnregistrationViewRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostAgentBackgroundUnregistrationUXView] = []

    var views: [HostAgentBackgroundUnregistrationUXView] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ view: HostAgentBackgroundUnregistrationUXView) {
        lock.lock()
        storage.append(view)
        lock.unlock()
    }
}
