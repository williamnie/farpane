import CoreBridge
import XCTest

final class CoreBridgeContractTests: XCTestCase {
    private func hostEvent(
        payload: [String: Any],
        eventType: String = "mediaControl",
        schemaVersion: Int = 1
    ) throws -> HostCoreEvent? {
        let envelope: [String: Any] = [
            "schemaVersion": schemaVersion,
            "eventId": 0,
            "eventType": eventType,
            "hostInstanceId": "test-host-instance",
            "sentAt": 1,
            "payload": payload,
        ]
        return HostCoreEvent(rawJSON: try JSONSerialization.data(withJSONObject: envelope))
    }

    func testPinsRustDesk149Commit() {
        XCTAssertEqual(RustDeskCoreClient.abiVersion, 7)
        XCTAssertEqual(
            RustDeskCoreClient.expectedUpstreamCommit,
            "6c578292e8ebbbec708b76986ba8c4bc7c509747"
        )
    }

    func testHostEventAndSnapshotSchemaVersionsAreIndependent() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridgeURL = repositoryRoot
            .appendingPathComponent("CoreBridge/RustDeskPatch/rdn_host_bridge.rs")
        let bridge = try String(contentsOf: bridgeURL, encoding: .utf8)

        XCTAssertTrue(bridge.contains("const EVENT_SCHEMA_VERSION: u32 = 1;"))
        XCTAssertTrue(bridge.contains("const SNAPSHOT_SCHEMA_VERSION: u32 = 8;"))
        XCTAssertTrue(bridge.contains("\"schemaVersion\": EVENT_SCHEMA_VERSION"))
        XCTAssertTrue(bridge.contains(
            "map.insert(\"schemaVersion\".into(), json!(SNAPSHOT_SCHEMA_VERSION));"
        ))
    }

    func testHostStoragePreflightPrecedesConfigMutationAndIdentityAccess() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridgeURL = repositoryRoot
            .appendingPathComponent("CoreBridge/RustDeskPatch/rdn_host_bridge.rs")
        let bridge = try String(contentsOf: bridgeURL, encoding: .utf8)
        let start = try XCTUnwrap(bridge.range(
            of: "pub unsafe extern \"C\" fn rdn_host_start"
        ))
        let startBody = bridge[start.lowerBound...]
        let preflight = try XCTUnwrap(startBody.range(of: "preflight_host_storage()"))
        let startingMutation = try XCTUnwrap(startBody.range(
            of: "host.state = RdnHostState::Starting"
        ))
        let configMutation = try XCTUnwrap(startBody.range(of: "config::Config::set_option("))
        let identityAccess = try XCTUnwrap(startBody.range(of: "config::Config::get_id()"))
        let persistenceReadback = try XCTUnwrap(startBody.range(
            of: "verify_host_start_storage(host)"
        ))
        let mediaBinding = try XCTUnwrap(startBody.range(of: "bind_media_host(host)"))
        let runtimeStart = try XCTUnwrap(startBody.range(of: "HostRuntime::start("))

        XCTAssertLessThan(preflight.lowerBound, startingMutation.lowerBound)
        XCTAssertLessThan(preflight.lowerBound, configMutation.lowerBound)
        XCTAssertLessThan(preflight.lowerBound, identityAccess.lowerBound)
        XCTAssertGreaterThan(persistenceReadback.lowerBound, identityAccess.lowerBound)
        XCTAssertLessThan(persistenceReadback.lowerBound, mediaBinding.lowerBound)
        XCTAssertLessThan(persistenceReadback.lowerBound, runtimeStart.lowerBound)
        XCTAssertTrue(startBody.contains("configuration.storagePreflightFailed"))
        XCTAssertTrue(startBody.contains("configuration.storagePersistenceFailed"))
        XCTAssertTrue(startBody.contains("return RDN_HOST_ERR_STORAGE;"))
    }

    func testPermanentPasswordSuccessRequiresDiskReadbackAndMismatchStopsHost() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridgeURL = repositoryRoot
            .appendingPathComponent("CoreBridge/RustDeskPatch/rdn_host_bridge.rs")
        let bridge = try String(contentsOf: bridgeURL, encoding: .utf8)

        let setterStart = try XCTUnwrap(bridge.range(
            of: "pub unsafe extern \"C\" fn rdn_host_set_permanent_password"
        ))
        let setterTail = bridge[setterStart.lowerBound...]
        let setterEnd = try XCTUnwrap(setterTail.range(
            of: "pub unsafe extern \"C\" fn rdn_host_copy_snapshot"
        ))
        let setter = setterTail[..<setterEnd.lowerBound]
        let setterMutation = try XCTUnwrap(setter.range(
            of: "config::Config::set_permanent_password(password)"
        ))
        let setterReadback = try XCTUnwrap(setter.range(
            of: "verify_host_password_storage()"
        ))
        let setterSuccess = try XCTUnwrap(setter.range(
            of: "\"permanent-password-set\""
        ))
        XCTAssertLessThan(setterMutation.lowerBound, setterReadback.lowerBound)
        XCTAssertLessThan(setterReadback.lowerBound, setterSuccess.lowerBound)

        let clearStart = try XCTUnwrap(bridge.range(
            of: "\"clearPermanentPassword\" => {"
        ))
        let clearTail = bridge[clearStart.lowerBound...]
        let clearEnd = try XCTUnwrap(clearTail.range(of: "\"approveConnection\" => {"))
        let clear = clearTail[..<clearEnd.lowerBound]
        let clearMutation = try XCTUnwrap(clear.range(
            of: "config::Config::set_permanent_password(\"\")"
        ))
        let clearReadback = try XCTUnwrap(clear.range(
            of: "verify_host_password_storage()"
        ))
        let clearSuccess = try XCTUnwrap(clear.range(
            of: "host.emit_command_result(command_id, \"ok\", detail)"
        ))
        XCTAssertLessThan(clearMutation.lowerBound, clearReadback.lowerBound)
        XCTAssertLessThan(clearReadback.lowerBound, clearSuccess.lowerBound)

        XCTAssertTrue(bridge.contains(
            "config::Config::get_local_permanent_password_storage_and_salt()"
        ))
        XCTAssertTrue(bridge.contains("struct WipedHostStorageString(String);"))
        XCTAssertTrue(bridge.contains("password_matches: Some(true)"))
        let failureStart = try XCTUnwrap(bridge.range(
            of: "fn fail_host_after_password_persistence_mismatch"
        ))
        let failureTail = bridge[failureStart.lowerBound...]
        let failureEnd = try XCTUnwrap(failureTail.range(of: "fn parse_envelope"))
        let failure = failureTail[..<failureEnd.lowerBound]
        XCTAssertTrue(failure.contains("unbind_media_host()"))
        XCTAssertTrue(failure.contains("host.runtime.take()"))
        XCTAssertTrue(failure.contains("password_security::update_temporary_password()"))
        XCTAssertTrue(failure.contains("configuration.passwordPersistenceFailed"))
    }

    func testHostRuntimeReconnectUsesBoundedBackoffWithoutIdentityReset() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bridgeURL = repositoryRoot
            .appendingPathComponent("CoreBridge/RustDeskPatch/rdn_host_bridge.rs")
        let bridge = try String(contentsOf: bridgeURL, encoding: .utf8)

        XCTAssertTrue(bridge.contains(
            "const HOST_RUNTIME_RECONNECT_BASE_DELAY_MS: u64 = 250;"
        ))
        XCTAssertTrue(bridge.contains(
            "const HOST_RUNTIME_RECONNECT_MAX_DELAY_MS: u64 = 5_000;"
        ))
        XCTAssertTrue(bridge.contains(
            "jitter_upper_bound = nominal / 4"
        ))
        XCTAssertTrue(bridge.contains(
            "HOST_RUNTIME_RECONNECT_STOP_POLL_MS"
        ))

        let runtimeStart = try XCTUnwrap(bridge.range(of: "impl HostRuntime {"))
        let runtimeTail = bridge[runtimeStart.lowerBound...]
        let runtimeEnd = try XCTUnwrap(runtimeTail.range(of: "impl RdnHost {"))
        let runtime = runtimeTail[..<runtimeEnd.lowerBound]
        let connectionStarted = try XCTUnwrap(runtime.range(
            of: "let connection_started = Instant::now();"
        ))
        let rendezvousStart = try XCTUnwrap(runtime.range(
            of: "crate::RendezvousMediator::start("
        ))
        let delay = try XCTUnwrap(runtime.range(
            of: "reconnect_backoff.delay_after_exit("
        ))
        let interruptibleWait = try XCTUnwrap(runtime.range(
            of: "wait_for_host_runtime_retry(&thread_stop, retry_delay)"
        ))
        XCTAssertLessThan(connectionStarted.lowerBound, rendezvousStart.lowerBound)
        XCTAssertLessThan(rendezvousStart.lowerBound, delay.lowerBound)
        XCTAssertLessThan(delay.lowerBound, interruptibleWait.lowerBound)
        XCTAssertFalse(runtime.contains("Duration::from_secs(1)"))
        XCTAssertFalse(runtime.contains("Config::set_id"))
    }

    func testNativeHostUsesCanonicalCGSessionOnConsoleKey() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let patchURL = repositoryRoot
            .appendingPathComponent("CoreBridge/RustDeskPatch/upstream-1.4.9.patch")
        let patch = try String(contentsOf: patchURL, encoding: .utf8)

        XCTAssertTrue(patch.contains("\"kCGSSessionOnConsoleKey\""))
        XCTAssertFalse(patch.contains("\"kCGSessionOnConsoleKey\""))
    }

    func testHostAgentModeDispatchPrecedesNSApplicationBootstrap() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let dispatch = try XCTUnwrap(source.range(
            of: "RustDeskNativeProcessModePolicy.resolve(arguments: CommandLine.arguments)"
        ))
        let appKitBootstrap = try XCTUnwrap(source.range(of: "NSApplication.shared"))

        XCTAssertLessThan(dispatch.lowerBound, appKitBootstrap.lowerBound)
        XCTAssertTrue(source.contains("exit(HostAgentProcessBootstrap.run())"))
        XCTAssertFalse(source.contains(
            "HostAgentProcessTerminalReporter.report(.unavailable)"
        ))
        XCTAssertFalse(source.contains("unavailableExitCode"))
        XCTAssertFalse(source.contains(
            "fputs(\"FarPane HostAgent runtime is not available"
        ))
    }

    func testHostAgentProcessRuntimeUsesOneBootstrapAuthorityAndProductDispatch() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtimeURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/HostAgentProcessRuntime.swift")
        let runtimeSource = try String(contentsOf: runtimeURL, encoding: .utf8)
        let contextPreparation = try XCTUnwrap(runtimeSource.range(
            of: "HostAgentBootstrapContext.prepare(\n"
                + "            expectedAgentBuildID: expectedAgentBuildID"
        ))
        let coreLocation = try XCTUnwrap(runtimeSource.range(
            of: "HostAgentBundledCoreLocator.locate()"
        ))
        let clientCreation = try XCTUnwrap(runtimeSource.range(of: "HostControlClient("))

        XCTAssertLessThan(contextPreparation.lowerBound, coreLocation.lowerBound)
        XCTAssertLessThan(coreLocation.lowerBound, clientCreation.lowerBound)
        XCTAssertLessThan(contextPreparation.lowerBound, clientCreation.lowerBound)
        XCTAssertFalse(runtimeSource.contains("static func start(\n        libraryURL: URL"))
        XCTAssertFalse(runtimeSource.contains("ProcessInfo.processInfo.environment"))
        XCTAssertFalse(runtimeSource.contains("currentDirectoryPath"))
        XCTAssertTrue(runtimeSource.contains("bootstrapOwner: bootstrapContext"))
        XCTAssertTrue(runtimeSource.contains("let configuration = context.configuration"))
        XCTAssertTrue(runtimeSource.contains("configAppName: configuration.hostConfigAppName"))
        XCTAssertTrue(runtimeSource.contains("configOrganization: configuration.hostConfigOrganization"))
        XCTAssertTrue(runtimeSource.contains("rendezvousServer: configuration.rendezvousServer"))
        XCTAssertTrue(runtimeSource.contains("serverPublicKey: configuration.serverPublicKey"))

        let appURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let appSource = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertFalse(appSource.contains("HostAgentProcessRuntime.start("))
        XCTAssertTrue(appSource.contains("exit(HostAgentProcessBootstrap.run())"))
    }

    func testHostAgentStartupClassifierIsStructuredAndUsesProductDispatch() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let startupURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/HostAgentProcessStartup.swift")
        let startupSource = try String(contentsOf: startupURL, encoding: .utf8)

        XCTAssertTrue(startupSource.contains("HostAgentProcessStartupRunner.start("))
        XCTAssertTrue(startupSource.contains("HostAgentProcessRuntime.start("))
        XCTAssertTrue(startupSource.contains("HostAgentSingleWriterLeaseError"))
        XCTAssertTrue(startupSource.contains("HostAgentBootstrapConfigurationError"))
        XCTAssertTrue(startupSource.contains("HostAgentBundledCoreLocatorError"))
        XCTAssertTrue(startupSource.contains("HostControlError"))
        XCTAssertTrue(startupSource.contains(
            "case .alreadyHeld:\n                return HostAgentStartupFailure(kind: .alreadyRunning)"
        ))
        XCTAssertTrue(startupSource.contains(
            "default:\n                return HostAgentStartupFailure(kind: .runtimeOwnershipUnavailable)"
        ))
        XCTAssertTrue(startupSource.contains(
            "if error is HostAgentBundledCoreLocatorError {\n            return HostAgentStartupFailure(kind: .coreUnavailable)"
        ))
        XCTAssertTrue(startupSource.contains(
            "case .configRoot(_), .create(_), .start(_):\n                return HostAgentStartupFailure(kind: .runtimeStartupFailed)"
        ))
        for kind in [
            "configurationUnavailable",
            "runtimeOwnershipUnavailable",
            "alreadyRunning",
            "coreUnavailable",
            "runtimeStartupFailed",
            "internalFailure",
        ] {
            XCTAssertTrue(startupSource.contains("kind: .\(kind)"))
        }
        XCTAssertFalse(startupSource.contains("localizedDescription"))
        XCTAssertFalse(startupSource.contains("String(describing:"))
        XCTAssertFalse(startupSource.contains("error.description"))

        let appURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let appSource = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertFalse(appSource.contains("HostAgentProcessStartup.prepare("))
        XCTAssertTrue(appSource.contains("exit(HostAgentProcessBootstrap.run())"))
    }

    func testHostAgentStartupSuccessOwnsLifetimeGateButInstallsNoSignals() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let startupURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/HostAgentProcessStartup.swift")
        let startupSource = try String(contentsOf: startupURL, encoding: .utf8)
        XCTAssertTrue(startupSource.contains(
            ") -> Result<HostAgentProcessLifetime, HostAgentStartupFailure>"
        ))
        XCTAssertTrue(startupSource.contains(
            "let runtime = try HostAgentProcessRuntime.start("
        ))
        XCTAssertTrue(startupSource.contains(
            "return HostAgentProcessLifetime("
        ))
        XCTAssertTrue(startupSource.contains(
            "prepareTermination: prepareTermination"
        ))

        let lifetimeURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/HostAgentProcessLifetime.swift")
        let lifetimeSource = try String(contentsOf: lifetimeURL, encoding: .utf8)
        XCTAssertTrue(lifetimeSource.contains(
            "HostAgentProcessLifetimeGate<HostAgentProcessRuntime>"
        ))
        XCTAssertTrue(lifetimeSource.contains("try runtime.stop(reason: reason)"))
        XCTAssertTrue(lifetimeSource.contains("requestTermination(reason:"))
        XCTAssertTrue(lifetimeSource.contains("waitUntilTerminated()"))
        XCTAssertFalse(lifetimeSource.contains("DispatchSource.makeSignalSource"))
        XCTAssertFalse(lifetimeSource.contains("signal("))
    }

    func testHostAgentSignalIngressUsesDispatchSourcesAndProductDispatch() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let signalURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentProcessSignalController.swift"
        )
        let signalSource = try String(contentsOf: signalURL, encoding: .utf8)

        XCTAssertTrue(signalSource.contains("HostAgentTerminationRequestLatch"))
        XCTAssertTrue(signalSource.contains("DispatchSource.makeSignalSource("))
        XCTAssertTrue(signalSource.contains("SIGTERM"))
        XCTAssertTrue(signalSource.contains("SIGINT"))
        XCTAssertTrue(signalSource.contains("sigaction(signalNumber,"))
        XCTAssertTrue(signalSource.contains("__sa_handler = SIG_IGN"))
        XCTAssertTrue(signalSource.contains("source.cancel()"))
        XCTAssertTrue(signalSource.contains("restoreSignalDispositions()"))
        XCTAssertTrue(signalSource.contains(
            "lifetime.requestTermination(reason: .appExit)"
        ))
        XCTAssertFalse(signalSource.contains("Darwin.signal("))
        XCTAssertFalse(signalSource.contains("__sa_sigaction"))

        let appURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let appSource = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertFalse(appSource.contains("HostAgentProcessSignalController("))
        XCTAssertTrue(appSource.contains("exit(HostAgentProcessBootstrap.run())"))
    }

    func testHostAgentProcessRunnerComposesLifecycleAndUsesProductDispatch() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let processURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentProcess.swift"
        )
        let processSource = try String(contentsOf: processURL, encoding: .utf8)

        XCTAssertTrue(processSource.contains("HostAgentProcessRunner.run("))
        XCTAssertTrue(processSource.contains(
            "installTerminationIngress: {\n                try HostAgentProcessSignalController()"
        ))
        XCTAssertTrue(processSource.contains("HostAgentProcessStartup.prepare("))
        XCTAssertTrue(processSource.contains("controller.bind(lifetime: lifetime)"))
        XCTAssertTrue(processSource.contains(
            "lifetime.requestTermination(reason: reason)"
        ))
        XCTAssertTrue(processSource.contains("lifetime.waitUntilTerminated()"))
        XCTAssertTrue(processSource.contains("controller.cancel()"))
        XCTAssertFalse(processSource.contains("fputs("))
        XCTAssertFalse(processSource.contains("exit("))

        let appURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let appSource = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertFalse(appSource.contains("HostAgentProcess.run("))
        XCTAssertTrue(appSource.contains("exit(HostAgentProcessBootstrap.run())"))
    }

    func testHostAgentProcessJournalsBeforeInternalConsumers() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let processURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentProcess.swift"
        )
        let processSource = try String(contentsOf: processURL, encoding: .utf8)

        XCTAssertTrue(processSource.contains("eventState: HostAgentEventState"))
        XCTAssertTrue(processSource.contains(
            "eventState.consume(event) { event, sequence in"
        ))
        XCTAssertTrue(processSource.contains(
            "expectedAgentBuildID: expectedAgentBuildID,\n"
                + "                    eventState: eventState"
        ))
        let journal = try XCTUnwrap(processSource.range(
            of: "eventState.consume(event) { event, sequence in"
        ))
        let snapshotRefresh = try XCTUnwrap(processSource.range(
            of: "snapshotCoordinator.requestRefresh("
        ))
        let mediaControl = try XCTUnwrap(processSource.range(
            of: "mediaState.consume("
        ))
        let mediaDiagnostic = try XCTUnwrap(processSource.range(
            of: "mediaPipelineOwner.consume(event)"
        ))
        XCTAssertLessThan(journal.lowerBound, snapshotRefresh.lowerBound)
        XCTAssertLessThan(journal.lowerBound, mediaControl.lowerBound)
        XCTAssertLessThan(journal.lowerBound, mediaDiagnostic.lowerBound)

        let appURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let appSource = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertFalse(appSource.contains("HostAgentEventState("))
        XCTAssertFalse(appSource.contains("HostAgentProcess.run("))
        XCTAssertTrue(appSource.contains("exit(HostAgentProcessBootstrap.run())"))
    }

    func testHostAgentProcessPublishesSanitizedSnapshotsWithProductDispatch() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let snapshotURL = repositoryRoot.appendingPathComponent(
            "Sources/CoreBridge/HostAgentSnapshotState.swift"
        )
        let snapshotSource = try String(contentsOf: snapshotURL, encoding: .utf8)
        XCTAssertTrue(snapshotSource.contains("HostAgentSnapshotProjection"))
        XCTAssertTrue(snapshotSource.contains(
            "temporaryPasswordPolicy = \"redacted\""
        ))
        XCTAssertFalse(snapshotSource.contains("snapshot.rawJSON"))
        XCTAssertFalse(snapshotSource.contains("snapshot.revealedTemporaryPassword"))

        let processURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentProcess.swift"
        )
        let processSource = try String(contentsOf: processURL, encoding: .utf8)
        XCTAssertTrue(processSource.contains("snapshotState: HostAgentSnapshotState"))
        XCTAssertTrue(processSource.contains("HostAgentSnapshotRefreshCoordinator("))
        XCTAssertTrue(processSource.contains("event, sequence in"))
        XCTAssertTrue(processSource.contains("snapshotCoordinator.requestRefresh("))
        XCTAssertTrue(processSource.contains("[weak lifetime]"))
        XCTAssertTrue(processSource.contains("lifetime.copySnapshot()"))
        XCTAssertFalse(processSource.contains("onEvent(event)"))
        XCTAssertFalse(processSource.contains("onEvent: @escaping"))
        XCTAssertTrue(processSource.contains("mediaPipelineOwner.consume(event)"))

        let runtimeURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentProcessRuntime.swift"
        )
        let runtimeSource = try String(contentsOf: runtimeURL, encoding: .utf8)
        XCTAssertTrue(runtimeSource.contains("ownedRuntime.copySnapshot()"))
        XCTAssertTrue(runtimeSource.contains("snapshotState: HostAgentSnapshotState"))
        XCTAssertTrue(runtimeSource.contains("snapshotState: snapshotState"))
        let lifetimeURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentProcessLifetime.swift"
        )
        let lifetimeSource = try String(contentsOf: lifetimeURL, encoding: .utf8)
        XCTAssertTrue(lifetimeSource.contains("gate.withRunningRuntime"))

        let appURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let appSource = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertFalse(appSource.contains("HostAgentSnapshotState("))
        XCTAssertFalse(appSource.contains("HostAgentProcess.run("))
        XCTAssertTrue(appSource.contains("exit(HostAgentProcessBootstrap.run())"))
    }

    func testHostAgentSnapshotPollingIsCancelledBeforeCoreStopWithProductDispatch() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pollingURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentSnapshotPollingOwner.swift"
        )
        let pollingSource = try String(contentsOf: pollingURL, encoding: .utf8)
        XCTAssertTrue(pollingSource.contains("DispatchSource.makeTimerSource("))
        XCTAssertTrue(pollingSource.contains("repeating: .milliseconds(500)"))
        XCTAssertTrue(pollingSource.contains("leeway: .milliseconds(50)"))
        XCTAssertTrue(pollingSource.contains("gate.beginTick()"))
        XCTAssertTrue(pollingSource.contains("snapshotCoordinator.requestPoll()"))
        XCTAssertTrue(pollingSource.contains("gate.cancelAndWait()"))
        XCTAssertTrue(pollingSource.contains("snapshotCoordinator.cancelAndWait()"))
        XCTAssertTrue(pollingSource.contains("timer.cancel()"))

        let processURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentProcess.swift"
        )
        let processSource = try String(contentsOf: processURL, encoding: .utf8)
        XCTAssertTrue(processSource.contains("HostAgentSnapshotPollingOwner("))
        XCTAssertTrue(processSource.contains("prepareTermination: {"))
        XCTAssertTrue(processSource.contains("pollingOwner.cancel()"))
        XCTAssertTrue(processSource.contains("pollingOwner.start()"))

        let appURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let appSource = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertFalse(appSource.contains("HostAgentSnapshotPollingOwner("))
        XCTAssertFalse(appSource.contains("HostAgentProcess.run("))
        XCTAssertTrue(appSource.contains("exit(HostAgentProcessBootstrap.run())"))
    }

    func testHostAgentOwnsOrderedMediaControlIngressWithProductDispatch() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let processURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentProcess.swift"
        )
        let processSource = try String(contentsOf: processURL, encoding: .utf8)
        XCTAssertTrue(processSource.contains("mediaState: HostAgentMediaControlState"))
        XCTAssertFalse(processSource.contains("onMediaControl:"))
        XCTAssertFalse(processSource.contains("onMediaControl(control)"))
        XCTAssertTrue(processSource.contains("mediaState.consume("))
        XCTAssertTrue(processSource.contains("eventSequence: sequence"))
        XCTAssertTrue(processSource.contains(
            "onAccepted: { control in\n"
                + "                                    mediaPipelineOwner.handle(control)"
        ))
        let mediaCancel = try XCTUnwrap(processSource.range(
            of: "mediaState.cancelAndWait()"
        ))
        let pollingCancel = try XCTUnwrap(processSource.range(
            of: "pollingOwner.cancel()"
        ))
        XCTAssertLessThan(mediaCancel.lowerBound, pollingCancel.lowerBound)

        let ownerURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentMediaPipelineOwner.swift"
        )
        let ownerSource = try String(contentsOf: ownerURL, encoding: .utf8)
        XCTAssertTrue(ownerSource.contains(
            "HostAgentMediaControlDeliveryGate()"
        ))
        XCTAssertTrue(ownerSource.contains(
            "HostMediaPipelineRecoveryOwner("
        ))
        XCTAssertTrue(ownerSource.contains(
            "HostMediaPipelineRecoveryPollingOwner.makeProduct("
        ))
        XCTAssertTrue(ownerSource.contains("controlDeliveryGate.submit(control)"))
        XCTAssertTrue(ownerSource.contains("controlDeliveryGate.activate"))
        XCTAssertTrue(ownerSource.contains("controlDeliveryGate.cancelAndWait()"))
        XCTAssertTrue(ownerSource.contains("controlIngress: controlDeliveryGate.snapshot()"))
        let mediaControlActivation = try XCTUnwrap(
            ownerSource.range(of: "controlDeliveryGate.activate")
        )
        let capabilityProbeStart = try XCTUnwrap(
            ownerSource.range(of: "capabilityInFlight = true")
        )
        XCTAssertLessThan(
            mediaControlActivation.lowerBound,
            capabilityProbeStart.lowerBound
        )
        let mediaControlCancel = try XCTUnwrap(
            ownerSource.range(of: "controlDeliveryGate.cancelAndWait()")
        )
        let mediaRecoveryCancel = try XCTUnwrap(
            ownerSource.range(of: "recoveryOwner.cancelAndWait()")
        )
        XCTAssertLessThan(
            mediaControlCancel.lowerBound,
            mediaRecoveryCancel.lowerBound
        )
        XCTAssertFalse(ownerSource.contains(
            "guard case .active = state else {\n            condition.unlock()\n            return\n        }\n        condition.unlock()\n\n        switch control.command"
        ))

        let appURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let appSource = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertFalse(appSource.contains("HostAgentMediaControlState("))
        XCTAssertFalse(appSource.contains("HostAgentProcess.run("))
        XCTAssertTrue(appSource.contains("exit(HostAgentProcessBootstrap.run())"))
    }

    func testHostAgentOwnsRealMediaPipelineWithProductDispatch() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ownerURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentMediaPipelineOwner.swift"
        )
        let ownerSource = try String(contentsOf: ownerURL, encoding: .utf8)
        XCTAssertTrue(ownerSource.contains("HostMediaPipelineRouteOwner("))
        XCTAssertTrue(ownerSource.contains("HostHardwareEncoderCapabilityDiscovery.discover("))
        XCTAssertTrue(ownerSource.contains("CGGetActiveDisplayList("))
        XCTAssertTrue(ownerSource.contains("lifetime.setMediaCapabilities("))
        XCTAssertTrue(ownerSource.contains("lifetime.submit(accessUnit:"))
        XCTAssertTrue(ownerSource.contains("lifetime.reportEncoderState("))
        XCTAssertTrue(ownerSource.contains("framing: .avcc"))
        XCTAssertTrue(ownerSource.contains("recoveryOwner.reconfigure("))
        XCTAssertTrue(ownerSource.contains("recoveryOwner.requestKeyframe("))
        XCTAssertTrue(ownerSource.contains("recoveryOwner.stop(route:"))
        XCTAssertTrue(ownerSource.contains("recoveryOwner.pauseAndFlushForSleep()"))
        XCTAssertTrue(ownerSource.contains("func beginMediaRecoveryAfterWake("))
        XCTAssertTrue(ownerSource.contains("suspended.status == .suspended"))
        XCTAssertTrue(ownerSource.contains("suspended.epoch == epoch"))
        XCTAssertTrue(ownerSource.contains("recoveryOwner.resumeAfterWake()"))
        XCTAssertTrue(ownerSource.contains(
            "recoveryPollingOwner.start("
        ))
        XCTAssertTrue(ownerSource.contains(
            "outcome == .converged"
        ))
        XCTAssertTrue(ownerSource.contains(
            "recoveryPollingOwner.stateSnapshot()"
        ))
        XCTAssertFalse(ownerSource.contains(
            "func resumeMediaControlIngressAfterWake()"
        ))
        XCTAssertFalse(ownerSource.contains(
            "func pollMediaRecoveryConvergence()"
        ))
        XCTAssertFalse(ownerSource.contains(
            "func startMediaRecoveryConvergencePolling("
        ))
        let recoveryEpochCheck = try XCTUnwrap(ownerSource.range(
            of: "suspended.epoch == epoch"
        ))
        let recoveryResume = try XCTUnwrap(ownerSource.range(
            of: "recoveryOwner.resumeAfterWake()"
        ))
        let recoveryPollStart = try XCTUnwrap(ownerSource.range(
            of: "recoveryPollingOwner.start("
        ))
        XCTAssertLessThan(recoveryEpochCheck.lowerBound, recoveryResume.lowerBound)
        XCTAssertLessThan(recoveryResume.lowerBound, recoveryPollStart.lowerBound)
        XCTAssertTrue(ownerSource.contains("recoveryOwner.cancelAndWait()"))
        XCTAssertTrue(ownerSource.contains("HostMediaPipelineLiveLogCoordinator()"))
        XCTAssertTrue(ownerSource.contains("lifecycleObserver: liveLogCoordinator.lifecycleObserver"))
        XCTAssertTrue(ownerSource.contains("HostAgentMediaLiveLogPollingOwner("))
        XCTAssertTrue(ownerSource.contains("liveLogPollingOwner.start()"))
        let liveLogPollCancel = try XCTUnwrap(ownerSource.range(
            of: "liveLogPollingOwner.cancel()"
        ))
        let recoveryPollCancel = try XCTUnwrap(ownerSource.range(
            of: "recoveryPollingOwner.cancelAndWait()"
        ))
        let displayEvidenceCancel = try XCTUnwrap(ownerSource.range(
            of: "displayEvidenceOwner.cancelAndWait()"
        ))
        let recoveryCancel = try XCTUnwrap(ownerSource.range(
            of: "recoveryOwner.cancelAndWait()"
        ))
        let liveLogSeal = try XCTUnwrap(ownerSource.range(
            of: "liveLogCoordinator.cancel()"
        ))
        XCTAssertLessThan(displayEvidenceCancel.lowerBound, recoveryPollCancel.lowerBound)
        XCTAssertLessThan(recoveryPollCancel.lowerBound, recoveryCancel.lowerBound)
        XCTAssertLessThan(recoveryPollCancel.lowerBound, liveLogPollCancel.lowerBound)
        XCTAssertLessThan(liveLogPollCancel.lowerBound, recoveryCancel.lowerBound)
        XCTAssertLessThan(recoveryCancel.lowerBound, liveLogSeal.lowerBound)

        let liveLogPollingURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentMediaLiveLogPollingOwner.swift"
        )
        let liveLogPollingSource = try String(
            contentsOf: liveLogPollingURL,
            encoding: .utf8
        )
        XCTAssertTrue(liveLogPollingSource.contains("repeating: .seconds(1)"))
        XCTAssertTrue(liveLogPollingSource.contains("gate.beginTick()"))
        XCTAssertTrue(liveLogPollingSource.contains("gate.cancelAndWait()"))
        XCTAssertTrue(liveLogPollingSource.contains("coordinator.recordPeriodic()"))

        let processURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentProcess.swift"
        )
        let processSource = try String(contentsOf: processURL, encoding: .utf8)
        XCTAssertTrue(processSource.contains(
            "HostAgentMediaPipelineOwner(\n"
                + "            recoveryEvidenceOwner: recoveryEvidenceOwner"
        ))
        XCTAssertTrue(processSource.contains("mediaPipelineOwner.handle"))
        XCTAssertTrue(processSource.contains("mediaPipelineOwner.start("))
        let pipelineCancel = try XCTUnwrap(processSource.range(
            of: "mediaPipelineOwner.cancelAndWait()"
        ))
        let pollingCancel = try XCTUnwrap(processSource.range(
            of: "pollingOwner.cancel()"
        ))
        let evidenceCancel = try XCTUnwrap(processSource.range(
            of: "recoveryEvidenceOwner.cancelAndWait()"
        ))
        XCTAssertLessThan(pipelineCancel.lowerBound, evidenceCancel.lowerBound)
        XCTAssertLessThan(pipelineCancel.lowerBound, pollingCancel.lowerBound)

        let appURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let appSource = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertFalse(appSource.contains("HostAgentMediaPipelineOwner("))
        XCTAssertFalse(appSource.contains("HostAgentProcess.run("))
        XCTAssertTrue(appSource.contains("exit(HostAgentProcessBootstrap.run())"))
    }

    func testHostAgentOwnsRouteScopedMediaDiagnosticsWithProductDispatch() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ownerURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentMediaPipelineOwner.swift"
        )
        let ownerSource = try String(contentsOf: ownerURL, encoding: .utf8)
        XCTAssertTrue(ownerSource.contains("func consume(_ event: HostCoreEvent)"))
        XCTAssertTrue(ownerSource.contains("event.mediaDiagnostic"))
        XCTAssertTrue(ownerSource.contains("event.mediaQueueDiagnostic"))
        XCTAssertTrue(ownerSource.contains("event.mediaWriterDiagnostic"))
        XCTAssertTrue(ownerSource.contains("event.mediaNetworkDiagnostic"))
        XCTAssertTrue(ownerSource.contains("event.mediaTransportDiagnostic"))
        XCTAssertTrue(ownerSource.contains("routeOwner.recordEncodedQueueDepth("))
        XCTAssertTrue(ownerSource.contains("routeOwner.recordWriterTiming("))
        XCTAssertTrue(ownerSource.contains("routeOwner.recordNetworkMetrics("))
        XCTAssertTrue(ownerSource.contains("routeOwner.recordTransportMetrics("))
        XCTAssertTrue(ownerSource.contains("func snapshot() -> HostAgentMediaPipelineSnapshot"))

        let processURL = repositoryRoot.appendingPathComponent(
            "Sources/RustDeskNative/HostAgentProcess.swift"
        )
        let processSource = try String(contentsOf: processURL, encoding: .utf8)
        let diagnosticConsume = try XCTUnwrap(processSource.range(
            of: "mediaPipelineOwner.consume(event)"
        ))
        let journal = try XCTUnwrap(processSource.range(
            of: "eventState.consume(event) { event, sequence in"
        ))
        XCTAssertLessThan(journal.lowerBound, diagnosticConsume.lowerBound)
        XCTAssertFalse(processSource.contains("onEvent(event)"))

        let appURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let appSource = try String(contentsOf: appURL, encoding: .utf8)
        XCTAssertFalse(appSource.contains("HostAgentMediaPipelineSnapshot("))
        XCTAssertFalse(appSource.contains("HostAgentProcess.run("))
        XCTAssertTrue(appSource.contains("exit(HostAgentProcessBootstrap.run())"))
    }

    func testProductAppPublishesOnlyAfterCanonicalCatalogReadOrSave() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/RustDeskNative/RustDeskNativeApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(
            "catalog = try catalogStore.load()\n            reconcileHostAgentBootstrap()"
        ))
        let sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let catalogSaveLines = sourceLines.indices.filter {
            sourceLines[$0].contains("catalogStore.save(")
        }
        XCTAssertFalse(catalogSaveLines.isEmpty)
        for saveLine in catalogSaveLines {
            let endLine = min(sourceLines.endIndex, saveLine + 5)
            XCTAssertTrue(
                sourceLines[saveLine..<endLine].contains {
                    $0.contains("reconcileHostAgentBootstrap()")
                },
                "canonical catalog save at line \(saveLine + 1) must reconcile afterward"
            )
        }
        XCTAssertTrue(source.contains(
            ".reconcileSavedCatalog(\n"
                + "                from: catalogStore,\n"
                + "                clipboardPolicy: currentHostClipboardPolicy()"
        ))
        XCTAssertTrue(source.contains(
            "hostAgentBootstrapState == .degraded"
        ))
        XCTAssertTrue(source.contains(
            "errorText: combinedHostErrorText"
        ))
    }

    func testConnectionConfigDoesNotPersistPassword() {
        let config = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1",
            serverPublicKey: "public-key",
            peerID: "123456789",
            password: "one-time-password"
        )
        XCTAssertEqual(config.password, "one-time-password")
        XCTAssertFalse(config.forceRelay)
        XCTAssertFalse(config.receiveClipboardText)
        XCTAssertFalse(config.sendClipboardText)
        XCTAssertFalse(config.receiveClipboardRichText)
        XCTAssertFalse(config.sendClipboardRichText)
    }

    func testHostClipboardDirectionsDefaultOffAndRemainIndependent() {
        let disabled = HostServerConfiguration(
            rendezvousServer: "192.0.2.1",
            serverPublicKey: "public-key"
        )
        XCTAssertFalse(disabled.clipboardReadEnabled)
        XCTAssertFalse(disabled.clipboardWriteEnabled)

        let readOnly = HostServerConfiguration(
            rendezvousServer: "192.0.2.1",
            serverPublicKey: "public-key",
            clipboardReadEnabled: true
        )
        XCTAssertTrue(readOnly.clipboardReadEnabled)
        XCTAssertFalse(readOnly.clipboardWriteEnabled)

        let writeOnly = HostServerConfiguration(
            rendezvousServer: "192.0.2.1",
            serverPublicKey: "public-key",
            clipboardWriteEnabled: true
        )
        XCTAssertFalse(writeOnly.clipboardReadEnabled)
        XCTAssertTrue(writeOnly.clipboardWriteEnabled)
    }

    func testViewerClipboardDirectionsAreExplicitAndIndependent() {
        let receiveOnly = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1",
            serverPublicKey: "public-key",
            peerID: "123456789",
            receiveClipboardText: true
        )
        XCTAssertTrue(receiveOnly.receiveClipboardText)
        XCTAssertFalse(receiveOnly.sendClipboardText)
        XCTAssertFalse(receiveOnly.receiveClipboardRichText)
        XCTAssertFalse(receiveOnly.sendClipboardRichText)

        let sendOnly = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1",
            serverPublicKey: "public-key",
            peerID: "123456789",
            sendClipboardText: true
        )
        XCTAssertFalse(sendOnly.receiveClipboardText)
        XCTAssertTrue(sendOnly.sendClipboardText)
        XCTAssertFalse(sendOnly.receiveClipboardRichText)
        XCTAssertFalse(sendOnly.sendClipboardRichText)

        let receiveRichOnly = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1",
            serverPublicKey: "public-key",
            peerID: "123456789",
            receiveClipboardRichText: true
        )
        XCTAssertFalse(receiveRichOnly.receiveClipboardText)
        XCTAssertFalse(receiveRichOnly.sendClipboardText)
        XCTAssertTrue(receiveRichOnly.receiveClipboardRichText)
        XCTAssertFalse(receiveRichOnly.sendClipboardRichText)

        let sendRichOnly = CoreConnectionConfig(
            rendezvousServer: "192.0.2.1",
            serverPublicKey: "public-key",
            peerID: "123456789",
            sendClipboardRichText: true
        )
        XCTAssertFalse(sendRichOnly.receiveClipboardText)
        XCTAssertFalse(sendRichOnly.sendClipboardText)
        XCTAssertFalse(sendRichOnly.receiveClipboardRichText)
        XCTAssertTrue(sendRichOnly.sendClipboardRichText)
    }

    func testViewerClipboardDeliveryStopsBeforeCoreDisconnect() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources/CoreBridge/CoreBridge.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(
            "guard clipboardLifecycleLock.withLock({ clipboardDeliveryEnabled }) else { return }"
        ))
        XCTAssertTrue(source.contains("box.deliverClipboardText(text)"))
        XCTAssertTrue(source.contains("box.deliverClipboardRichText(CoreClipboardRichTextPayload("))
        let stop = try XCTUnwrap(source.range(of: "callbackBox.stopClipboardDelivery()"))
        let disconnect = try XCTUnwrap(source.range(
            of: "rdn_shim_client_disconnect(library, client)"
        ))
        XCTAssertLessThan(stop.lowerBound, disconnect.lowerBound)
    }

    func testPhase3InputTypesStaySemantic() {
        let pointer = CorePointerEvent(
            kind: .down,
            x: 1919,
            y: 1079,
            buttons: .left,
            modifiers: [.shift, .command]
        )
        XCTAssertEqual(pointer.kind, .down)
        XCTAssertEqual(pointer.buttons, .left)
        XCTAssertEqual(pointer.modifiers, [.shift, .command])
        XCTAssertEqual(CorePointerKind.preciseScroll.rawValue, 4)
        XCTAssertEqual(CoreKey.character("a"), .character("a"))
        XCTAssertEqual(CoreKey.special(.return), .special(.return))
        XCTAssertEqual(CoreKey.physical(0), .physical(0))
    }

    func testOnlyEncodedQueueBackpressureRequiresKeyframeRecovery() {
        let backpressure = HostControlError.media(-8) // RDN_HOST_ERR_BACKPRESSURE
        XCTAssertTrue(backpressure.isExpectedMediaDrop)
        XCTAssertTrue(backpressure.requiresMediaKeyframeRecovery)
        XCTAssertEqual(backpressure.mediaSubmissionDropReason, .networkBackpressure)

        for (error, reason) in [
            (HostControlError.media(-7), HostMediaSubmissionDropReason.reconfigure),
            (HostControlError.media(-3), HostMediaSubmissionDropReason.shutdown),
        ] {
            XCTAssertTrue(error.isExpectedMediaDrop)
            XCTAssertFalse(error.requiresMediaKeyframeRecovery)
            XCTAssertEqual(error.mediaSubmissionDropReason, reason)
        }
        for code in [-1, -2, -4, -5, -9, -10, -11, -12] {
            let validationError = HostControlError.media(Int32(code))
            XCTAssertFalse(validationError.isExpectedMediaDrop)
            XCTAssertEqual(validationError.mediaSubmissionDropReason, .invalidFrame)
        }
        XCTAssertNil(HostControlError.media(-6).mediaSubmissionDropReason)
        XCTAssertFalse(HostControlError.start(-1).requiresMediaKeyframeRecovery)
        XCTAssertNil(HostControlError.start(-1).mediaSubmissionDropReason)
    }

    func testHostJSONCommandEnvelopeRejectsSensitiveAndReservedPayloads() throws {
        let safe = try HostCommandEnvelopePolicy.envelope(
            commandName: "setApprovalMode",
            commandID: "command-1",
            payload: [
                "approvalMode": "manualOnly",
                "capabilities": [["name": "viewDisplay", "enabled": true]],
            ]
        )
        XCTAssertEqual(safe["commandId"] as? String, "command-1")
        XCTAssertEqual(safe["name"] as? String, "setApprovalMode")
        XCTAssertEqual(safe["approvalMode"] as? String, "manualOnly")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: safe))

        XCTAssertNoThrow(try HostCommandEnvelopePolicy.envelope(
            commandName: "clearPermanentPassword",
            commandID: "command-2",
            payload: [:]
        ))

        for payload in [
            ["password": "must-never-enter-json"],
            ["nested": ["Permanent_Password": "must-never-enter-json"]],
            ["credentials": ["value": "must-never-enter-json"]],
            ["opaque": Data([1, 2, 3])],
            ["name": "disableHost"],
            ["command_id": "replacement"],
        ] {
            XCTAssertThrowsError(try HostCommandEnvelopePolicy.envelope(
                commandName: "futureCommand",
                commandID: "command-3",
                payload: payload
            ))
        }

        XCTAssertThrowsError(try HostCommandEnvelopePolicy.envelope(
            commandName: "setPermanentPassword",
            commandID: "command-4",
            payload: [:]
        )) { error in
            XCTAssertFalse(String(describing: error).contains("must-never-enter-json"))
            guard case HostControlError.sensitiveCommandRequiresDedicatedABI = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testHostSecretBufferPolicyWipesSuccessAndThrownPaths() throws {
        var success = Data("canary-success".utf8)
        let count = HostSecretBufferPolicy.withMutableBytes(&success) { bytes, count in
            XCTAssertNotNil(bytes)
            return count
        }
        XCTAssertEqual(count, "canary-success".utf8.count)
        XCTAssertEqual(success, Data(repeating: 0, count: count))

        enum SyntheticFailure: Error { case rejected }
        var rejected = Data("canary-rejected".utf8)
        XCTAssertThrowsError(try HostSecretBufferPolicy.withMutableBytes(&rejected) { _, _ in
            throw SyntheticFailure.rejected
        })
        XCTAssertEqual(rejected, Data(repeating: 0, count: "canary-rejected".utf8.count))
    }

    func testPermanentPasswordABIErrorsAreClassifiedSemantically() {
        XCTAssertEqual(HostControlError.permanentPassword(-13).permanentPasswordFailure, .invalidUTF8)
        XCTAssertEqual(HostControlError.permanentPassword(-14).permanentPasswordFailure, .empty)
        XCTAssertEqual(HostControlError.permanentPassword(-15).permanentPasswordFailure, .tooShort)
        XCTAssertEqual(HostControlError.permanentPassword(-16).permanentPasswordFailure, .tooLong)
        XCTAssertEqual(
            HostControlError.permanentPassword(-17).permanentPasswordFailure,
            .forbiddenCharacter)
        XCTAssertEqual(
            HostControlError.permanentPassword(-18).permanentPasswordFailure,
            .outerWhitespace)
        XCTAssertEqual(
            HostControlError.permanentPassword(-19).permanentPasswordFailure,
            .changeDisabled)
        XCTAssertEqual(HostControlError.permanentPassword(-20).permanentPasswordFailure, .storage)
        XCTAssertEqual(HostControlError.permanentPassword(-999).permanentPasswordFailure, .unknown)
        XCTAssertNil(HostControlError.command(-20).permanentPasswordFailure)
    }

    func testSleepRecoveryABIErrorsAreClassifiedSemantically() {
        let cases: [(Int32, HostSleepRecoveryFailure)] = [
            (-1, .invalidEpoch),
            (-7, .staleEpoch),
            (-3, .invalidState),
            (-4, .unsupported),
            (-6, .internalFailure),
            (-999, .unknown),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(
                HostControlError.sleepRecovery(.beginSleep, code)
                    .sleepRecoveryFailure,
                expected
            )
        }
        XCTAssertNil(HostControlError.stop(-7).sleepRecoveryFailure)
    }

    func testNetworkPathRecoveryABIErrorsAreClassifiedSemantically() {
        let cases: [(Int32, HostNetworkPathRecoveryFailure)] = [
            (-27, .staleGeneration),
            (-3, .invalidState),
            (-4, .unsupported),
            (-6, .internalFailure),
            (-1, .unknown),
            (-999, .unknown),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(
                HostControlError.networkPathRecovery(code)
                    .networkPathRecoveryFailure,
                expected
            )
        }
        XCTAssertNil(
            HostControlError.sleepRecovery(.beginSleep, -27)
                .networkPathRecoveryFailure
        )
    }

    func testApprovalDecisionErrorsAreClassifiedSemantically() {
        XCTAssertEqual(HostControlError.command(-21).approvalDecisionFailure, .notFound)
        XCTAssertEqual(
            HostControlError.command(-22).approvalDecisionFailure,
            .alreadyFinalized
        )
        XCTAssertEqual(HostControlError.command(-23).approvalDecisionFailure, .expired)
        XCTAssertNil(HostControlError.command(-5).approvalDecisionFailure)
        XCTAssertNil(HostControlError.snapshot(-21).approvalDecisionFailure)
    }

    func testActiveSessionCommandsAreTypedAndErrorsAreClassified() {
        XCTAssertEqual(
            HostSessionRevocableCapability.keyboardAndMouse.commandName,
            "disableInputForActiveSession"
        )
        XCTAssertEqual(
            HostSessionRevocableCapability.clipboardRead.commandName,
            "disableClipboardReadForActiveSession"
        )
        XCTAssertEqual(
            HostSessionRevocableCapability.clipboardWrite.commandName,
            "disableClipboardWriteForActiveSession"
        )
        XCTAssertEqual(
            HostSessionRevocableCapability.clipboard.commandName,
            "disableClipboardForActiveSession"
        )
        XCTAssertEqual(
            HostSessionRevocableCapability.systemAudio.commandName,
            "disableAudioForActiveSession"
        )
        XCTAssertEqual(
            HostSessionRevocableCapability.clipboardRead.snapshotCapabilityNames,
            ["readClipboard"]
        )
        XCTAssertEqual(
            HostSessionRevocableCapability.clipboardWrite.snapshotCapabilityNames,
            ["writeClipboard"]
        )
        XCTAssertEqual(
            HostSessionRevocableCapability.clipboard.snapshotCapabilityNames,
            ["readClipboard", "writeClipboard"]
        )
        XCTAssertEqual(HostControlError.command(-24).sessionCommandFailure, .notFound)
        XCTAssertEqual(HostControlError.command(-25).sessionCommandFailure, .staleConnection)
        XCTAssertEqual(HostControlError.command(-26).sessionCommandFailure, .unavailable)
        XCTAssertNil(HostControlError.command(-5).sessionCommandFailure)
        XCTAssertNil(HostControlError.snapshot(-24).sessionCommandFailure)
    }

    func testHostSessionCommandGateWaitsForAuthoritativeSnapshotConvergence() {
        var gate = HostSessionCommandGate()
        let allCapabilities = [
            "viewDisplay", "controlKeyboardMouse", "readClipboard",
            "writeClipboard", "hearSystemAudio",
        ]

        gate.observe(connectionID: nil, activeCapabilities: [])
        XCTAssertFalse(gate.begin(
            connectionID: "host:1",
            intent: .disable(.keyboardAndMouse)
        ))

        gate.observe(connectionID: "host:1", activeCapabilities: allCapabilities)
        XCTAssertFalse(gate.begin(
            connectionID: "host:stale",
            intent: .disable(.keyboardAndMouse)
        ))
        XCTAssertTrue(gate.begin(
            connectionID: "host:1",
            intent: .disable(.keyboardAndMouse)
        ))
        XCTAssertFalse(gate.begin(connectionID: "host:1", intent: .disconnect))
        XCTAssertEqual(
            gate.resolvingIntent(connectionID: "host:1"),
            .disable(.keyboardAndMouse)
        )

        // Command acceptance is not completion. The gate remains closed until
        // the capability actually disappears from the Rust snapshot.
        gate.observe(connectionID: "host:1", activeCapabilities: allCapabilities)
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        gate.observe(
            connectionID: "host:1",
            activeCapabilities: allCapabilities.filter { $0 != "controlKeyboardMouse" }
        )
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        XCTAssertTrue(gate.begin(
            connectionID: "host:1",
            intent: .disable(.clipboardRead)
        ))
        let withoutKeyboard = allCapabilities.filter { $0 != "controlKeyboardMouse" }
        gate.observe(
            connectionID: "host:1",
            activeCapabilities: withoutKeyboard.filter { $0 != "readClipboard" }
        )
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        XCTAssertTrue(gate.begin(
            connectionID: "host:1",
            intent: .disable(.clipboardWrite)
        ))
        gate.observe(
            connectionID: "host:1",
            activeCapabilities: withoutKeyboard.filter { $0 != "writeClipboard" }
        )
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        // Exercise the legacy two-direction alias from a fresh bidirectional
        // snapshot; the preceding directional cases are independent fixtures.
        gate.observe(connectionID: "host:1", activeCapabilities: withoutKeyboard)
        XCTAssertTrue(gate.begin(
            connectionID: "host:1",
            intent: .disable(.clipboard)
        ))
        gate.observe(
            connectionID: "host:1",
            activeCapabilities: withoutKeyboard.filter { $0 != "readClipboard" }
        )
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        let viewAndAudio = withoutKeyboard.filter {
            $0 != "readClipboard" && $0 != "writeClipboard"
        }
        gate.observe(connectionID: "host:1", activeCapabilities: viewAndAudio)
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        XCTAssertTrue(gate.begin(
            connectionID: "host:1",
            intent: .disable(.systemAudio)
        ))
        gate.complete(connectionID: "host:stale", intent: .disable(.systemAudio))
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        gate.complete(connectionID: "host:1", intent: .disable(.systemAudio))
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        XCTAssertTrue(gate.begin(connectionID: "host:1", intent: .disconnect))
        gate.observe(
            connectionID: "host:1",
            activeCapabilities: viewAndAudio
        )
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        gate.observe(connectionID: nil, activeCapabilities: [])
        XCTAssertFalse(gate.isResolving(connectionID: "host:1"))

        gate.observe(connectionID: "host:2", activeCapabilities: ["viewDisplay"])
        XCTAssertFalse(gate.begin(
            connectionID: "host:2",
            intent: .disable(.systemAudio)
        ))
        XCTAssertTrue(gate.begin(connectionID: "host:2", intent: .disconnect))
        gate.reset()
        XCTAssertNil(gate.currentConnectionID)
        XCTAssertNil(gate.resolvingIntent(connectionID: "host:2"))
    }

    func testHostSnapshotRecoversPendingApprovalAndActiveSessionAndFailsClosed() throws {
        let pending: [String: Any] = [
            "connectionId": "host-instance:7",
            "remoteId": "123456789",
            "remoteName": "Remote Mac",
            "remotePlatform": "macOS",
            "remoteMetadataTrust": "untrusted",
            "requestedAt": 1_700_000_000_000 as UInt64,
            "expiresAt": 1_700_000_030_000 as UInt64,
            "requestedCapabilities": ["viewDisplay", "controlKeyboardMouse"],
            "transport": "unknown",
            "authenticationMethod": "localApproval",
            "riskAlerts": [],
        ]
        let activeSession: [String: Any] = [
            "connectionId": "host-instance:9",
            "remoteId": "987654321",
            "remoteName": "Controlled Mac",
            "remotePlatform": "macOS",
            "remoteMetadataTrust": "untrusted",
            "startedAt": 1_700_000_000_500 as UInt64,
            "initialCapabilities": [
                "viewDisplay", "controlKeyboardMouse", "readClipboard", "writeClipboard",
            ],
            "activeCapabilities": ["viewDisplay", "controlKeyboardMouse"],
            "inputAvailability": "available",
            "inputUnavailableReason": NSNull(),
        ]
        func document(
            pendingApproval: Any,
            activeSession: Any = NSNull(),
            sessionAvailability: String = "available",
            sessionUnavailableReason: Any = NSNull(),
            hostState: String = "ready",
            registrationStatus: String = "ready",
            recoveryEpoch: Any = 0,
            recoveryStatus: String = "running",
            authenticatedConnectionCount: Any = 1
        ) -> [String: Any] {
            [
                "schemaVersion": 8,
                "hostInstanceId": "host-instance",
                "hostState": hostState,
                "localId": "987654321",
                "authenticatedConnectionCount": authenticatedConnectionCount,
                "sessionAvailability": sessionAvailability,
                "sessionUnavailableReason": sessionUnavailableReason,
                "registrationStatus": registrationStatus,
                "recoveryEpoch": recoveryEpoch,
                "recoveryStatus": recoveryStatus,
                "pendingApproval": pendingApproval,
                "activeSession": activeSession,
                "temporaryPasswordPresentation": ["policy": "redacted"],
                "passwordPolicy": [
                    "localPasswordSet": false,
                    "effectivePasswordSet": false,
                    "usingPresetPassword": false,
                    "changeAllowed": true,
                    "strengthPolicy": [
                        "version": 1,
                        "minimumCharacters": 6,
                        "maximumCharacters": 128,
                        "maximumUtf8Bytes": 512,
                        "rejectsControlCharacters": true,
                        "rejectsOuterWhitespace": true,
                    ],
                ],
                "lastError": NSNull(),
                "observedAt": 1_700_000_001_000 as UInt64,
            ]
        }

        let data = try JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: pending,
                activeSession: activeSession
            )
        )
        let snapshot = try HostCoreSnapshot(rawJSON: data)
        XCTAssertEqual(snapshot.schemaVersion, 8)
        XCTAssertEqual(snapshot.authenticatedConnectionCount, 1)
        XCTAssertEqual(snapshot.sessionAvailability, .available)
        XCTAssertNil(snapshot.sessionUnavailableReason)
        XCTAssertEqual(snapshot.recoveryEpoch, 0)
        XCTAssertEqual(snapshot.recoveryStatus, .running)
        XCTAssertEqual(snapshot.pendingApproval?.connectionId, "host-instance:7")
        XCTAssertEqual(snapshot.pendingApproval?.remoteName, "Remote Mac")
        XCTAssertEqual(
            snapshot.pendingApproval?.requestedCapabilities,
            ["viewDisplay", "controlKeyboardMouse"]
        )
        XCTAssertEqual(snapshot.activeSession?.connectionId, "host-instance:9")
        XCTAssertEqual(snapshot.activeSession?.remoteName, "Controlled Mac")
        XCTAssertEqual(
            snapshot.activeSession?.initialCapabilities,
            ["viewDisplay", "controlKeyboardMouse", "readClipboard", "writeClipboard"]
        )
        XCTAssertEqual(
            snapshot.activeSession?.activeCapabilities,
            ["viewDisplay", "controlKeyboardMouse"]
        )
        XCTAssertEqual(snapshot.activeSession?.inputAvailability, .available)
        XCTAssertNil(snapshot.activeSession?.inputUnavailableReason)

        let noPending = try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(pendingApproval: NSNull())
        ))
        XCTAssertNil(noPending.pendingApproval)
        XCTAssertNil(noPending.activeSession)

        var missingCount = document(pendingApproval: NSNull())
        missingCount.removeValue(forKey: "authenticatedConnectionCount")
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: missingCount
        )))
        for invalidCount in [true as Any, 1.5 as Any] {
            XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
                withJSONObject: document(
                    pendingApproval: NSNull(),
                    authenticatedConnectionCount: invalidCount
                )
            )))
        }
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: activeSession,
                authenticatedConnectionCount: 0
            )
        )))

        var invalidPending = pending
        invalidPending["remoteMetadataTrust"] = "trusted"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(pendingApproval: invalidPending)
        )))
        invalidPending = pending
        invalidPending["requestedCapabilities"] = ["viewDisplay", "futureCapability"]
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(pendingApproval: invalidPending)
        )))
        invalidPending = pending
        invalidPending["password"] = "must-not-be-accepted"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(pendingApproval: invalidPending)
        )))
        invalidPending = pending
        invalidPending["riskAlerts"] = ["futureRiskCode"]
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(pendingApproval: invalidPending)
        )))

        var invalidSession = activeSession
        invalidSession["remoteMetadataTrust"] = "trusted"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay", "hearSystemAudio"]
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay", "futureCapability"]
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["connectionId"] = "other-host:9"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = [
            "viewDisplay", "controlKeyboardMouse", "readClipboard",
        ]
        let readOnlyClipboard = try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        ))
        XCTAssertEqual(
            readOnlyClipboard.activeSession?.activeCapabilities,
            ["viewDisplay", "controlKeyboardMouse", "readClipboard"]
        )
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = [
            "viewDisplay", "controlKeyboardMouse", "writeClipboard",
        ]
        let writeOnlyClipboard = try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        ))
        XCTAssertEqual(
            writeOnlyClipboard.activeSession?.activeCapabilities,
            ["viewDisplay", "controlKeyboardMouse", "writeClipboard"]
        )
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay"]
        invalidSession["inputAvailability"] = "available"
        invalidSession["inputUnavailableReason"] = NSNull()
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay"]
        invalidSession["inputAvailability"] = "limited"
        invalidSession["inputUnavailableReason"] = "sessionUnavailable"
        let limitedSnapshot = try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        ))
        XCTAssertEqual(limitedSnapshot.activeSession?.inputAvailability, .limited)
        XCTAssertEqual(
            limitedSnapshot.activeSession?.inputUnavailableReason,
            .sessionUnavailable
        )
        let limitedHostSnapshot = try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                sessionAvailability: "limited",
                sessionUnavailableReason: "sessionUnavailable"
            )
        ))
        XCTAssertEqual(limitedHostSnapshot.sessionAvailability, .limited)
        XCTAssertEqual(
            limitedHostSnapshot.sessionUnavailableReason,
            .sessionUnavailable
        )
        for invalidTuple in [
            ("available", "sessionUnavailable" as Any),
            ("limited", NSNull() as Any),
            ("future", NSNull() as Any),
        ] {
            XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
                withJSONObject: document(
                    pendingApproval: NSNull(),
                    sessionAvailability: invalidTuple.0,
                    sessionUnavailableReason: invalidTuple.1
                )
            )))
        }
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay"]
        invalidSession["inputAvailability"] = "disabled"
        invalidSession["inputUnavailableReason"] = "accessibilityDenied"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["activeCapabilities"] = ["viewDisplay"]
        invalidSession["inputAvailability"] = "limited"
        invalidSession["inputUnavailableReason"] = "futureReason"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        invalidSession = activeSession
        invalidSession["password"] = "must-not-be-accepted"
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                activeSession: invalidSession
            )
        )))
        var oldSchema = document(pendingApproval: NSNull())
        oldSchema["schemaVersion"] = 6
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: oldSchema
        )))
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                recoveryStatus: "futureStatus"
            )
        )))
        XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                hostState: "starting",
                registrationStatus: "suspending",
                recoveryEpoch: 0,
                recoveryStatus: "suspending"
            )
        )))
        for invalidEpoch: Any in [-1, 1.5] {
            XCTAssertThrowsError(try HostCoreSnapshot(rawJSON: JSONSerialization.data(
                withJSONObject: document(
                    pendingApproval: NSNull(),
                    recoveryEpoch: invalidEpoch
                )
            )))
        }
        let suspended = try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: document(
                pendingApproval: NSNull(),
                hostState: "starting",
                registrationStatus: "suspended",
                recoveryEpoch: 7,
                recoveryStatus: "suspended"
            )
        ))
        XCTAssertEqual(suspended.recoveryEpoch, 7)
        XCTAssertEqual(suspended.recoveryStatus, .suspended)
    }

    func testHostApprovalDecisionGateRejectsStaleAndDuplicateActions() {
        var gate = HostApprovalDecisionGate()
        XCTAssertFalse(gate.observe(connectionID: nil))

        XCTAssertTrue(gate.observe(connectionID: "host:1"))
        XCTAssertFalse(gate.observe(connectionID: "host:1"))
        XCTAssertFalse(gate.beginDecision(connectionID: "host:stale"))
        XCTAssertTrue(gate.beginDecision(connectionID: "host:1"))
        XCTAssertFalse(gate.beginDecision(connectionID: "host:1"))
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))

        XCTAssertFalse(gate.observe(connectionID: "host:1"))
        XCTAssertTrue(gate.isResolving(connectionID: "host:1"))
        XCTAssertFalse(gate.observe(connectionID: nil))
        XCTAssertNil(gate.decisionInFlightConnectionID)
        XCTAssertFalse(gate.beginDecision(connectionID: "host:1"))

        XCTAssertTrue(gate.observe(connectionID: "host:2"))
        XCTAssertTrue(gate.beginDecision(connectionID: "host:2"))
        gate.completeDecision(connectionID: "host:stale")
        XCTAssertTrue(gate.isResolving(connectionID: "host:2"))
        gate.completeDecision(connectionID: "host:2")
        XCTAssertNil(gate.decisionInFlightConnectionID)

        gate.reset()
        XCTAssertNil(gate.currentConnectionID)
        XCTAssertTrue(gate.observe(connectionID: "host:2"))
    }

    func testHostMediaControlEnvelopeFailsClosedAndTracksRouteEpochs() throws {
        let reconfigure = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1920,
            "height": 1080,
            "fps": 30,
            "bitrate": 8_000_000,
        ])?.mediaControl)
        XCTAssertEqual(reconfigure.command, .reconfigure)
        XCTAssertEqual(reconfigure.codec, .h264)
        XCTAssertEqual(reconfigure.width, 1920)

        let h265Reconfigure = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 10,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h265",
            "width": 1920,
            "height": 1080,
            "fps": 30,
            "bitrate": 8_000_000,
        ])?.mediaControl)
        XCTAssertEqual(h265Reconfigure.codec, .h265)
        XCTAssertEqual(h265Reconfigure.codecEpoch, 10)

        let matchingStop = try XCTUnwrap(try hostEvent(payload: [
            "command": "stopCapture",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
        ])?.mediaControl)
        XCTAssertTrue(reconfigure.matchesRoute(matchingStop))

        let staleRefresh = try XCTUnwrap(try hostEvent(payload: [
            "command": "requestIdr",
            "connectionEpoch": 6,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
        ])?.mediaControl)
        XCTAssertFalse(reconfigure.matchesRoute(staleRefresh))

        XCTAssertNil(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1920,
            "height": 1080,
            "fps": 0,
        ])?.mediaControl)
        XCTAssertNil(try hostEvent(payload: [
            "command": "requestIdr",
            "connectionEpoch": 0,
            "codecEpoch": 9,
            "displayId": 0,
        ])?.mediaControl)
        XCTAssertNil(try hostEvent(payload: [:], schemaVersion: 2))
    }

    func testDisplayReconfigureMarkerAndControlProvenanceFailClosed() throws {
        let markerPayload: [String: Any] = [
            "displayReconfigureGeneration": 4,
            "displayId": 0,
            "previousDisplayRevision": 2,
            "previousConnectionEpoch": 7,
            "previousCodecEpoch": 9,
        ]
        let started = try XCTUnwrap(try hostEvent(
            payload: markerPayload,
            eventType: "mediaDisplayReconfigureStarted"
        )?.displayReconfigureStarted)
        XCTAssertEqual(started.generation, 4)
        XCTAssertEqual(started.displayID, 0)
        XCTAssertEqual(started.previousDisplayRevision, 2)
        XCTAssertEqual(started.previousConnectionEpoch, 7)
        XCTAssertEqual(started.previousCodecEpoch, 9)

        let provenance: [String: Any] = [
            "displayReconfigureGeneration": 4,
            "previousDisplayRevision": 2,
            "previousConnectionEpoch": 7,
            "previousCodecEpoch": 9,
        ]
        let replacement = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 8,
            "codecEpoch": 10,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1_920,
            "height": 1_080,
            "fps": 30,
            "displayReconfigure": provenance,
        ])?.mediaControl)
        XCTAssertEqual(replacement.displayReconfigure, .init(
            generation: 4,
            previousDisplayRevision: 2,
            previousConnectionEpoch: 7,
            previousCodecEpoch: 9
        ))

        for invalid in [
            [
                "displayReconfigureGeneration": 0,
                "previousDisplayRevision": 2,
                "previousConnectionEpoch": 7,
                "previousCodecEpoch": 9,
            ],
            [
                "displayReconfigureGeneration": 4,
                "previousDisplayRevision": 3,
                "previousConnectionEpoch": 7,
                "previousCodecEpoch": 9,
            ],
            [
                "displayReconfigureGeneration": 4,
                "previousDisplayRevision": 2,
                "previousConnectionEpoch": 8,
                "previousCodecEpoch": 9,
            ],
        ] {
            XCTAssertNil(try hostEvent(payload: [
                "command": "reconfigure",
                "connectionEpoch": 8,
                "codecEpoch": 10,
                "displayId": 0,
                "displayRevision": 3,
                "codec": "h264",
                "width": 1_920,
                "height": 1_080,
                "fps": 30,
                "displayReconfigure": invalid,
            ])?.mediaControl)
        }
        var malformedMarker = markerPayload
        malformedMarker["previousCodecEpoch"] = true
        XCTAssertNil(try hostEvent(
            payload: malformedMarker,
            eventType: "mediaDisplayReconfigureStarted"
        )?.displayReconfigureStarted)
        XCTAssertNil(try hostEvent(payload: [
            "command": "stopCapture",
            "connectionEpoch": 8,
            "codecEpoch": 10,
            "displayId": 0,
            "displayReconfigure": provenance,
        ])?.mediaControl)
    }

    func testHostMediaDiagnosticIsSanitizedAndFailsClosed() throws {
        let payload: [String: Any] = [
            "kind": "firstPacketAcknowledged",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "framing": "avcc",
            "ptsUs": 42_999,
            "keyframe": true,
            "hasParameterSets": true,
            "subscriberCount": 1,
        ]
        let diagnostic = try XCTUnwrap(try hostEvent(
            payload: payload,
            eventType: "mediaDiagnostic"
        )?.mediaDiagnostic)
        XCTAssertEqual(diagnostic.kind, .firstPacketAcknowledged)
        XCTAssertEqual(diagnostic.codec, .h264)
        XCTAssertEqual(diagnostic.framing, .avcc)
        XCTAssertEqual(diagnostic.presentationTimeUS, 42_999)
        XCTAssertTrue(diagnostic.isKeyframe)
        XCTAssertTrue(diagnostic.hasParameterSets)
        XCTAssertEqual(diagnostic.subscriberCount, 1)

        let route = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1920,
            "height": 1080,
            "fps": 30,
        ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))
        let staleRoute = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 8,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1920,
            "height": 1080,
            "fps": 30,
        ])?.mediaControl)
        XCTAssertFalse(diagnostic.matchesRoute(staleRoute))

        var invalid = payload
        invalid["subscriberCount"] = 0
        XCTAssertNil(try hostEvent(
            payload: invalid,
            eventType: "mediaDiagnostic"
        )?.mediaDiagnostic)
        invalid = payload
        invalid["connectionEpoch"] = true
        XCTAssertNil(try hostEvent(
            payload: invalid,
            eventType: "mediaDiagnostic"
        )?.mediaDiagnostic)
        invalid = payload
        invalid["framing"] = "unknown"
        XCTAssertNil(try hostEvent(
            payload: invalid,
            eventType: "mediaDiagnostic"
        )?.mediaDiagnostic)

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("peerId"))
        XCTAssertFalse(text.contains("data"))
        XCTAssertFalse(text.contains("password"))
        XCTAssertFalse(text.contains("server"))
    }

    func testHostMediaQueueDiagnosticIsBoundedSanitizedAndRouteScoped() throws {
        let payload: [String: Any] = [
            "kind": "routeStopped",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "currentDepth": 1,
            "maximumDepth": 3,
            "capacity": 3,
        ]
        let diagnostic = try XCTUnwrap(try hostEvent(
            payload: payload,
            eventType: "mediaQueueDiagnostic"
        )?.mediaQueueDiagnostic)
        XCTAssertEqual(diagnostic.kind, .routeStopped)
        XCTAssertEqual(diagnostic.currentDepth, 1)
        XCTAssertEqual(diagnostic.maximumDepth, 3)
        XCTAssertEqual(diagnostic.capacity, 3)

        let route = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1920,
            "height": 1080,
            "fps": 30,
        ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))

        let invalidMutations: [(inout [String: Any]) -> Void] = [
            { $0["connectionEpoch"] = true },
            { $0["currentDepth"] = 4 },
            { $0["maximumDepth"] = 4 },
            { $0["capacity"] = 0 },
            { $0["maximumDepth"] = 1.5 },
            { $0["kind"] = "unknown" },
        ]
        for mutation in invalidMutations {
            var invalid = payload
            mutation(&invalid)
            XCTAssertNil(try hostEvent(
                payload: invalid,
                eventType: "mediaQueueDiagnostic"
            )?.mediaQueueDiagnostic)
        }

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["peer", "server", "password", "publicKey", "payload", "data"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testHostMediaWriterDiagnosticIsConsistentSanitizedAndRouteScoped() throws {
        let payload: [String: Any] = [
            "kind": "routeStopped",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "cycles": 3,
            "subscriberDispatches": 5,
            "dispatchWallTotalUs": 120,
            "maximumDispatchWallUs": 70,
            "confirmationWaitTotalUs": 900,
            "maximumConfirmationWaitUs": 400,
            "completedConfirmations": 2,
            "timedOutConfirmations": 1,
        ]
        let diagnostic = try XCTUnwrap(try hostEvent(
            payload: payload,
            eventType: "mediaWriterDiagnostic"
        )?.mediaWriterDiagnostic)
        XCTAssertEqual(diagnostic.kind, .routeStopped)
        XCTAssertEqual(diagnostic.cycles, 3)
        XCTAssertEqual(diagnostic.subscriberDispatches, 5)
        XCTAssertEqual(diagnostic.maximumDispatchWallUS, 70)
        XCTAssertEqual(diagnostic.maximumConfirmationWaitUS, 400)

        let route = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h265",
            "width": 1920,
            "height": 1080,
            "fps": 30,
        ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))

        let invalidMutations: [(inout [String: Any]) -> Void] = [
            { $0["connectionEpoch"] = true },
            { $0["subscriberDispatches"] = 2 },
            { $0["maximumDispatchWallUs"] = 121 },
            { $0["maximumConfirmationWaitUs"] = 901 },
            { $0["completedConfirmations"] = 3 },
            { $0["cycles"] = 1.5 },
            { $0["kind"] = "unknown" },
        ]
        for mutation in invalidMutations {
            var invalid = payload
            mutation(&invalid)
            XCTAssertNil(try hostEvent(
                payload: invalid,
                eventType: "mediaWriterDiagnostic"
            )?.mediaWriterDiagnostic)
        }

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["peer", "server", "password", "publicKey", "payload", "data"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testHostMediaNetworkDiagnosticPreservesUnavailableSamplesAndRouteScope() throws {
        let payload: [String: Any] = [
            "kind": "routeStopped",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "subscriberCount": 2,
            "qosSubscriberCount": 2,
            "delaySampledSubscribers": 2,
            "rttSampledSubscribers": 1,
            "responseDelayedSubscribers": 1,
            "worstNetworkDelayMs": 180,
            "worstRttMs": 42,
        ]
        let diagnostic = try XCTUnwrap(try hostEvent(
            payload: payload,
            eventType: "mediaNetworkDiagnostic"
        )?.mediaNetworkDiagnostic)
        XCTAssertEqual(diagnostic.kind, .routeStopped)
        XCTAssertEqual(diagnostic.subscriberCount, 2)
        XCTAssertEqual(diagnostic.qosSubscriberCount, 2)
        XCTAssertEqual(diagnostic.delaySampledSubscribers, 2)
        XCTAssertEqual(diagnostic.rttSampledSubscribers, 1)
        XCTAssertEqual(diagnostic.responseDelayedSubscribers, 1)
        XCTAssertEqual(diagnostic.worstNetworkDelayMS, 180)
        XCTAssertEqual(diagnostic.worstRTTMS, 42)

        let route = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h265",
            "width": 1920,
            "height": 1080,
            "fps": 30,
        ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))

        var unsampled = payload
        unsampled["delaySampledSubscribers"] = 0
        unsampled["rttSampledSubscribers"] = 0
        unsampled["responseDelayedSubscribers"] = 0
        unsampled["worstNetworkDelayMs"] = NSNull()
        unsampled["worstRttMs"] = NSNull()
        let unavailable = try XCTUnwrap(try hostEvent(
            payload: unsampled,
            eventType: "mediaNetworkDiagnostic"
        )?.mediaNetworkDiagnostic)
        XCTAssertNil(unavailable.worstNetworkDelayMS)
        XCTAssertNil(unavailable.worstRTTMS)

        let invalidMutations: [(inout [String: Any]) -> Void] = [
            { $0["connectionEpoch"] = true },
            { $0["qosSubscriberCount"] = 3 },
            { $0["delaySampledSubscribers"] = 3 },
            { $0["rttSampledSubscribers"] = 3 },
            { $0["responseDelayedSubscribers"] = 3 },
            { $0["worstNetworkDelayMs"] = NSNull() },
            { $0.removeValue(forKey: "worstRttMs") },
            { $0["worstRttMs"] = 1.5 },
            { $0["kind"] = "unknown" },
        ]
        for mutation in invalidMutations {
            var invalid = payload
            mutation(&invalid)
            XCTAssertNil(try hostEvent(
                payload: invalid,
                eventType: "mediaNetworkDiagnostic"
            )?.mediaNetworkDiagnostic)
        }

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["peer", "server", "password", "publicKey", "payload", "data"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testHostMediaTransportDiagnosticPreservesUnknownAndFailsClosed() throws {
        let payload: [String: Any] = [
            "kind": "routeStopped",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "subscriberCount": 4,
            "directSubscribers": 2,
            "relaySubscribers": 1,
            "unknownSubscribers": 1,
        ]
        let diagnostic = try XCTUnwrap(try hostEvent(
            payload: payload,
            eventType: "mediaTransportDiagnostic"
        )?.mediaTransportDiagnostic)
        XCTAssertEqual(diagnostic.kind, .routeStopped)
        XCTAssertEqual(diagnostic.subscriberCount, 4)
        XCTAssertEqual(diagnostic.directSubscribers, 2)
        XCTAssertEqual(diagnostic.relaySubscribers, 1)
        XCTAssertEqual(diagnostic.unknownSubscribers, 1)

        let route = try XCTUnwrap(try hostEvent(payload: [
            "command": "reconfigure",
            "connectionEpoch": 7,
            "codecEpoch": 9,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1920,
            "height": 1080,
            "fps": 30,
        ])?.mediaControl)
        XCTAssertTrue(diagnostic.matchesRoute(route))

        let invalidMutations: [(inout [String: Any]) -> Void] = [
            { $0["connectionEpoch"] = true },
            { $0["unknownSubscribers"] = 0 },
            { $0["directSubscribers"] = -1 },
            { $0["relaySubscribers"] = 1.5 },
            { $0.removeValue(forKey: "subscriberCount") },
            { $0["kind"] = "unknown" },
        ]
        for mutation in invalidMutations {
            var invalid = payload
            mutation(&invalid)
            XCTAssertNil(try hostEvent(
                payload: invalid,
                eventType: "mediaTransportDiagnostic"
            )?.mediaTransportDiagnostic)
        }

        let encoded = try JSONSerialization.data(withJSONObject: payload)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for forbidden in ["peer", "server", "password", "publicKey", "payload", "data"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testLoadsBuiltCoreAndVerifiesABIWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["RDN_CORE_LIBRARY"] else {
            throw XCTSkip("set RDN_CORE_LIBRARY for the built-core smoke test")
        }
        let client = try RustDeskCoreClient(
            libraryURL: URL(fileURLWithPath: path),
            onState: { _ in },
            onVideo: { _ in },
            onMetrics: { _ in }
        )
        XCTAssertEqual(client.upstreamCommit, RustDeskCoreClient.expectedUpstreamCommit)
        client.disconnect()
    }
}
