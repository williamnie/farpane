#!/usr/bin/env python3
"""Audit the evidence boundary for the five V1 Host/Viewer coexistence cases."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-v1-concurrency-evidence-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    if offset < 0:
        return 0
    return source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "process_mode": (
            repository / "Sources/CoreBridge/RustDeskNativeProcessMode.swift"
        ),
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "activation": (
            repository
            / "Sources/CoreBridge/HostAgentBackgroundActivationOwner.swift"
        ),
        "registration": (
            repository
            / "Sources/CoreBridge/"
            / "HostAgentBackgroundRegistrationMutationOwner.swift"
        ),
        "runtime_state": (
            repository
            / "Sources/VideoPipeline/HostRuntimeStateEvidence.swift"
        ),
        "viewer_metrics": (
            repository / "Sources/VideoPipeline/PipelineMetrics.swift"
        ),
        "recovery_evidence": (
            repository
            / "Sources/VideoPipeline/HostRecoveryTransitionEvidence.swift"
        ),
        "recovery_validator": (
            repository
            / "Scripts/validate-farpane-host-performance-recovery.py"
        ),
        "xpc_reconnect": (
            repository / "Sources/CoreBridge/HostAgentXPCReconnectOwner.swift"
        ),
        "xpc_client": (
            repository / "Sources/CoreBridge/HostAgentXPCSnapshotClient.swift"
        ),
        "xpc_handshake": (
            repository / "Sources/CoreBridge/HostAgentXPCWireHandshake.swift"
        ),
        "xpc_snapshot": (
            repository / "Sources/CoreBridge/HostAgentXPCWireSnapshot.swift"
        ),
        "projection": (
            repository
            / "Sources/CoreBridge/HostAgentBackgroundProjectionAuthority.swift"
        ),
        "combined_validator": (
            repository / "Scripts/validate-farpane-host-combined-role.py"
        ),
        "pair_validator": (
            repository
            / "Scripts/validate-farpane-host-combined-role-pair.py"
        ),
        "lifecycle_writer": (
            repository
            / "Sources/VideoPipeline/HostViewerConcurrencyEvidence.swift"
        ),
        "lifecycle_process_owner": (
            repository
            / "Sources/VideoPipeline/"
            / "HostViewerConcurrencyEvidenceProcessOwner.swift"
        ),
        "host_agent_process": (
            repository / "Sources/RustDeskNative/HostAgentProcess.swift"
        ),
        "h4_audit": (
            repository
            / "Evidence/HostMode/2026-08-09/"
            / "h4-config-isolation-concurrency-audit.md"
        ),
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
    except (OSError, UnicodeError) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "status": "audit-failed",
            "error": str(error),
        }))
        return 1

    design = sources["design"]
    process_mode = sources["process_mode"]
    app = sources["app"]
    activation = sources["activation"]
    registration = sources["registration"]
    runtime_state = sources["runtime_state"]
    viewer_metrics = sources["viewer_metrics"]
    recovery_evidence = sources["recovery_evidence"]
    recovery_validator = sources["recovery_validator"]
    xpc_reconnect = sources["xpc_reconnect"]
    xpc_client = sources["xpc_client"]
    xpc_handshake = sources["xpc_handshake"]
    xpc_snapshot = sources["xpc_snapshot"]
    projection = sources["projection"]
    combined_validator = sources["combined_validator"]
    pair_validator = sources["pair_validator"]
    lifecycle_writer = sources["lifecycle_writer"]
    lifecycle_process_owner = sources["lifecycle_process_owner"]
    host_agent_process = sources["host_agent_process"]
    h4_audit = sources["h4_audit"]

    target_validator = (
        repository / "Scripts/validate-farpane-host-v1-concurrency.py"
    )
    saved_results = list(
        (repository / "Evidence/HostMode").rglob(
            "*v1-concurrency-result*.json"
        )
    )

    evidence = {
        "designRequiresFiveOrderedCoexistenceCases": all(
            marker in design
            for marker in (
                "Host ready 时发起 outbound Viewer",
                "Viewer 会话中接收入站请求",
                "Host 活动会话中启动/停止 Viewer",
                "两侧同时断线/恢复",
                "重启 App 不改变 Host ID",
            )
        ),
        "designRequiresSplitRoleAndSharedSystemResources": (
            "资源预算分开报 Viewer、HostAgent、WindowServer 和媒体进程"
            in design
            and "不以 ABI 符号可并存替代真实双会话" in design
        ),
        "productUsesSeparateHostAgentAndApplicationProcesses": all(
            marker in process_mode
            for marker in (
                "case application",
                "case hostAgent",
                'contains("--host-agent") ? .hostAgent : .application',
            )
        ),
        "viewerLaunchQuiescesOnlyLegacyInProcessHost": all(
            marker in app
            for marker in (
                "if hostRuntimeActive || hostClient != nil",
                "|| !hostRuntimeQuiescenceConfirmed",
                "try launchViewer(",
            )
        ),
        "appTerminationCancelsMonitoringWithoutImplicitUnregistration": (
            "case .applicationWillTerminate:" in activation
            and "return stop(phase: .terminated, terminal: true)" in activation
            and "runtime?.cancelMonitoring()" in activation
            and "case .unregisterBackgroundAgent:" in registration
            and "try? unregisterService()" in registration
            and "applicationWillTerminate" not in registration
        ),
        "hostRuntimeHistoryHasOrderingButNoViewerLifecycle": all(
            marker in runtime_state
            for marker in (
                "let sequence: UInt64",
                "let capturedAt: Date",
                "let monotonicNanoseconds: UInt64",
                "let authenticatedConnectionCount: UInt64?",
                "let mediaRouteActive: Bool",
                "let mediaPipelineActive: Bool",
            )
        ) and "viewer" not in runtime_state.lower(),
        "viewerReportHasWindowButUntimedTransitionStrings": all(
            marker in viewer_metrics
            for marker in (
                "public let measurementStartedMonotonicNanoseconds: UInt64",
                "public let measurementCompletedMonotonicNanoseconds: UInt64",
                "public let coreStateTransitions: [String]",
            )
        ) and "coreStateTransitionEvents" not in viewer_metrics,
        "combinedRunValidatorProvesStatesButNotCrossRoleOrdering": all(
            marker in combined_validator
            for marker in (
                '"authenticatedConnectionMode": "zero"',
                '"authenticatedConnectionMode": "positive"',
                '"mediaActive": False',
                '"mediaActive": True',
                "Host runtime-state does not bracket the system window",
                "Viewer measurement does not contain the system window",
            )
        ),
        "pairValidatorCompletesOnlyItemTen": all(
            marker in pair_validator
            for marker in (
                'RUN_NAMES = ("hostReadyViewer", "hostViewerDual")',
                '"coverageScope": "section-15.2-item-10"',
                '"section15_2Item10Complete": status == "pass"',
                '"v1ConcurrencyRecoveryMatrixComplete": False',
            )
        ),
        "hostRecoveryEvidenceDoesNotProveDualRoleRecovery": all(
            marker in recovery_evidence
            for marker in (
                "case sleepWake",
                "case networkPath",
                "case displayReconfigure",
                "let hostInstanceScopeSHA256: String",
                "let buildIdentitySHA256: String",
            )
        ) and "viewer" not in recovery_evidence.lower(),
        "recoveryAggregateIsOnlySectionItemSeven": all(
            marker in recovery_validator
            for marker in (
                'RECOVERY_KINDS = ("sleepWake", "networkPath", "displayReconfigure")',
                '"fullSection15_2Item7Complete": status == "pass"',
            )
        ) and "v1ConcurrencyRecoveryMatrixComplete" not in recovery_validator,
        "xpcIdentityContinuityIsOnlyProcessMemory": all(
            marker in xpc_reconnect
            for marker in (
                "_ previousPeerIdentity:",
                "binding.previousPeerIdentity",
                "projectionAuthority.beginSession()",
            )
        ) and all(
            marker in projection
            for marker in (
                "let previousPeerIdentity = lastPeerIdentity",
                "previousPeerIdentity: previousPeerIdentity",
            )
        ) and all(
            marker in xpc_client
            for marker in (
                "private let previousPeerIdentity:",
                "knownHostInstanceID: previousPeerIdentity?.hostInstanceID",
                "knownAgentBootID: previousPeerIdentity?.agentBootID",
            )
        ),
        "existingH4AuditExplicitlyLeavesLiveMatrixOpen": all(
            marker in h4_audit
            for marker in (
                "V1 dual-active matrix and stable Host ID",
                "Manual/live evidence missing",
                "The five dual-session/recovery scenarios and stable Host ID require",
            )
        ),
        "lifecycleWriterDefinesStrictProcessAndEventSchema": all(
            marker in lifecycle_writer
            for marker in (
                '"farpane-host-viewer-concurrency-lifecycle"',
                "let sequence: UInt64",
                "let capturedAt: Date",
                "let monotonicNanoseconds: UInt64",
                "case processStarted",
                "case processTerminating",
                "case host(HostViewerConcurrencyHostObservation)",
                "case viewer(HostViewerConcurrencyViewerObservation)",
            )
        ),
        "lifecycleWriterBindsOnlySanitizedIdentityAuthority": all(
            marker in lifecycle_writer
            for marker in (
                '"farpane.v1-concurrency.process-start.v1"',
                '"farpane.v1-concurrency.build.v1"',
                '"farpane.v1-concurrency.host-scope.v1"',
                '"farpane.v1-concurrency.scenario.v1"',
                "observerProcessStartIdentitySHA256",
                "observerBuildIdentitySHA256",
                "scenarioCorrelationSHA256",
                "hostAgentProcessStartIdentitySHA256",
                "agentBootID.uuidString.lowercased()",
                "observation.configRevision > 0",
            )
        ),
        "lifecycleWriterEnforcesRoleAndTerminalStateMachine": all(
            marker in lifecycle_writer
            for marker in (
                "App and HostAgent deliberately write separate files",
                "case (.initial, .processStarted)",
                "case (.running, .processTerminating)",
                "(.terminated, _):",
                "identity.role == .application",
                "identity.role == .hostAgent",
                "observation.transitionGeneration > 0",
            )
        ),
        "lifecycleWriterIsDefaultOffBoundedAndNoOverwrite": all(
            marker in lifecycle_writer
            for marker in (
                '"FARPANE_HOST_VIEWER_CONCURRENCY_OUTPUT"',
                "guard let path = environment[outputEnvironmentKey] else { return nil }",
                "maximumRecordCount: UInt64 = 512",
                "safeAbsolutePathComponents",
                "hasSymlinkComponent",
                "isTrustedParent",
                "isTrustedOutput",
                "options: .withoutOverwriting",
                "try outputHandle.synchronize()",
            )
        ),
        "applicationProcessOwnerDerivesSanitizedSystemIdentity": all(
            marker in lifecycle_process_owner
            for marker in (
                '"FARPANE_HOST_VIEWER_CONCURRENCY_SCENARIO"',
                'Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")',
                "PROC_PIDTBSDINFO",
                "info.pbi_start_tvsec > 0",
                "HostViewerConcurrencyEvidenceDigest.processStartIdentity(",
                "HostViewerConcurrencyEvidenceDigest.buildIdentity(",
                "HostViewerConcurrencyEvidenceDigest.scenarioCorrelation(",
                "role: .application",
            )
        ),
        "applicationProcessOwnerIsDefaultOffAndBestEffort": all(
            marker in lifecycle_process_owner
            for marker in (
                "A missing output key reaches",
                "status = .disabled",
                "status = .unavailable",
                "incrementSaturating(&configurationFailures)",
                "incrementSaturating(&recordFailures)",
                "@discardableResult\n  public func configureApplication(",
                "@discardableResult\n  public func terminateAndWait()",
            )
        ),
        "applicationProcessOwnerRecordsOneTerminalLifecycle": all(
            marker in lifecycle_process_owner
            for marker in (
                "try candidate.record(\n            .processStarted",
                "try writer.record(\n          .processTerminating",
                "processStartedRecords = 1",
                "processTerminatingRecords = 1",
                "status = .terminated",
            )
        ),
        "applicationProductOwnsEvidenceAcrossEveryRunExit": (
            all(
                marker in app
                for marker in (
                    "HostViewerConcurrencyEvidenceProcessOwner()",
                    "_ = delegate.hostViewerConcurrencyEvidenceOwner",
                    ".configureApplication()",
                    "_ = hostViewerConcurrencyEvidenceOwner.terminateAndWait()",
                    "func applicationWillTerminate(",
                )
            )
            and app.count(
                "_ = hostViewerConcurrencyEvidenceOwner.terminateAndWait()"
            ) == 2
            and app.find("exit(HostAgentProcessBootstrap.run())")
            < app.find("let delegate = AppDelegate()")
            < app.find(".configureApplication()")
            < app.find("application.delegate = delegate")
            < app.find("application.run()")
        ),
        "applicationViewerOwnerEnforcesEpochAndRecoveryGeneration": all(
            marker in lifecycle_process_owner
            for marker in (
                "committedEpoch < UInt64.max",
                "case .starting:",
                "state: .authenticatedStreaming",
                "case .disconnected(let generation):",
                "state: .recoveredStreaming",
                "case .streaming:",
                "state: .disconnected",
                "transitionGeneration: nextGeneration",
                "currentSession.epoch == sessionEpoch",
            )
        ),
        "applicationViewerOwnerSerializesAndFailsEvidenceOnly": all(
            marker in lifecycle_process_owner
            for marker in (
                "while status == .active && recordInFlight",
                "try writer.record(\n        .viewer(transition.observation)",
                "incrementSaturating(&viewerRecords)",
                "incrementSaturating(&recordFailures)",
                "self.writer = nil",
                "status = .unavailable",
            )
        ),
        "applicationViewerUsesCoreAndTeardownAuthorities": all(
            marker in app
            for marker in (
                "hostViewerConcurrencyEvidenceOwner.beginViewerSession()",
                "case .streaming:",
                ".observeViewerStreaming(",
                "case .passwordRequired, .authenticationFailed,",
                ".observeViewerTerminal(",
                "private func stopViewerLifecycleEvidence()",
                ".stopViewerSession(",
            )
        ) and app.find("stopViewerLifecycleEvidence()")
        < app.find("coreClient?.disconnect()"),
        "applicationViewerRecoveryRequiresSameEpochCoreStreaming": all(
            marker in lifecycle_process_owner
            for marker in (
                "currentSession.epoch == sessionEpoch",
                "case .disconnected(let generation):",
                "state: .recoveredStreaming",
            )
        ) and all(
            marker in app
            for marker in (
                "let evidenceSessionEpoch =",
                "case .streaming:",
                "sessionEpoch: evidenceSessionEpoch",
                "showHomeUI(error: Self.connectionStateText(event))",
            )
        ),
        "applicationProjectionCarriesValidatedHostScopeAndRuntime": (
            all(
                marker in projection
                for marker in (
                    "let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity",
                    "let payload: HostAgentXPCWireSnapshotPayload",
                    "let generation: UInt64",
                )
            )
            and all(
                marker in xpc_client
                for marker in (
                    "let agentBuildID: String",
                    "let hostInstanceID: String",
                    "let agentBootID: String",
                )
            )
            and all(
                marker in xpc_snapshot
                for marker in (
                    "let hostState: String",
                    "let authenticatedConnectionCount: UInt64",
                    "let activeSession: HostAgentXPCWireActiveSession?",
                    "let observedAt: UInt64",
                )
            )
        ),
        "applicationConfigCoherenceBindsLiveAgentToRevision": all(
            marker in app
            for marker in (
                "observation.bootstrap.configRevision ==",
                "publishedConfigRevision",
                "liveAgentBuildID:",
                "available.peerIdentity.agentBuildID",
                "liveAgentBootID:",
                "available.peerIdentity.agentBootID",
            )
        ),
        "hostObservationSchemaRequiresExactAgentProcessIdentity": all(
            marker in lifecycle_writer
            for marker in (
                "let hostAgentProcessID: Int32",
                "let hostAgentProcessStartIdentitySHA256: String",
                "let hostAgentBuildIdentitySHA256: String",
                "observation.hostAgentProcessID == identity.processID",
                "observation.hostAgentProcessStartIdentitySHA256",
            )
        ),
        "applicationXPCIdentityOmitsAgentPIDAndProcessStart": (
            all(
                marker in xpc_handshake
                for marker in (
                    "package struct HostAgentXPCWireAgentIdentity",
                    "package let agentBuildID: String",
                    "package let hostInstanceID: String",
                    "package let agentBootID: String",
                )
            )
            and "agentProcessID" not in xpc_handshake
            and "agentProcessStartIdentity" not in xpc_handshake
            and "agentProcessID" not in xpc_snapshot
            and "agentProcessStartIdentity" not in xpc_snapshot
            and "agentProcessID" not in xpc_client
            and "agentProcessStartIdentity" not in xpc_client
        ),
        "applicationHostEvidenceCompositionRemainsFailClosed": (
            "recordHostRuntimeStateEvidence(force: true)" in app
            and "HostViewerConcurrencyHostObservation"
                not in lifecycle_process_owner
            and "HostViewerConcurrencyEvidenceDigest.hostInstanceScope("
                not in app
        ),
        "hostAgentProcessOwnerUsesPreflightedBuildAndRole": all(
            marker in lifecycle_process_owner
            for marker in (
                "public func configureHostAgent(",
                "expectedAgentBuildID: String",
                "role: .hostAgent",
                "explicitBuildIdentity: expectedAgentBuildID",
                "configuredRole = role",
            )
        ),
        "hostAgentProcessOwnerRejectsViewerEventsWithoutFailure": all(
            marker in lifecycle_process_owner
            for marker in (
                "configuredRole == .application",
                "let writer,",
                ".viewer(transition.observation)",
            )
        ),
        "hostAgentProductOwnsEvidenceAcrossRunResult": (
            all(
                marker in host_agent_process
                for marker in (
                    "HostViewerConcurrencyEvidenceProcessOwner()",
                    ".configureHostAgent(",
                    "expectedAgentBuildID: expectedAgentBuildID",
                    "defer {",
                    "_ = concurrencyEvidenceOwner.terminateAndWait()",
                    "HostAgentProcessRunner.run(",
                )
            )
            and host_agent_process.find(".configureHostAgent(")
            < host_agent_process.find("HostAgentProcessRunner.run(")
        ),
        "fiveScenarioMatrixValidatorIsStillMissing": (
            not target_validator.exists()
        ),
        "repositoryContainsNoSavedPassingV1MatrixResult": not saved_results,
    }
    missing = [name for name, present in evidence.items() if not present]

    source_lines = {
        "fiveScenarioSpec": line_number(
            design, "V1 并存验收至少包含"
        ),
        "splitResourceSpec": line_number(
            design,
            "资源预算分开报 Viewer、HostAgent、WindowServer 和媒体进程",
        ),
        "processRoleSelector": line_number(
            process_mode,
            'contains("--host-agent") ? .hostAgent : .application',
        ),
        "viewerLegacyHostGate": line_number(
            app, "if hostRuntimeActive || hostClient != nil"
        ),
        "appTerminationIntent": line_number(
            activation, "case .applicationWillTerminate:"
        ),
        "explicitAgentUnregistration": line_number(
            registration, "case .unregisterBackgroundAgent:"
        ),
        "hostStateMonotonicTime": line_number(
            runtime_state, "let monotonicNanoseconds: UInt64"
        ),
        "hostConnectionState": line_number(
            runtime_state, "let authenticatedConnectionCount: UInt64?"
        ),
        "viewerMeasurementWindow": line_number(
            viewer_metrics,
            "public let measurementStartedMonotonicNanoseconds: UInt64",
        ),
        "viewerUntimedTransitions": line_number(
            viewer_metrics, "public let coreStateTransitions: [String]"
        ),
        "combinedReadyState": line_number(
            combined_validator, '"authenticatedConnectionMode": "zero"'
        ),
        "combinedDualState": line_number(
            combined_validator, '"authenticatedConnectionMode": "positive"'
        ),
        "pairItemTenScope": line_number(
            pair_validator, '"coverageScope": "section-15.2-item-10"'
        ),
        "pairBroaderMatrixBoundary": line_number(
            pair_validator, '"v1ConcurrencyRecoveryMatrixComplete": False'
        ),
        "lifecycleWriterSchema": line_number(
            lifecycle_writer,
            '"farpane-host-viewer-concurrency-lifecycle"',
        ),
        "lifecycleWriterDefaultOff": line_number(
            lifecycle_writer,
            '"FARPANE_HOST_VIEWER_CONCURRENCY_OUTPUT"',
        ),
        "lifecycleWriterProcessStart": line_number(
            lifecycle_writer, "case (.initial, .processStarted)"
        ),
        "lifecycleWriterProcessTermination": line_number(
            lifecycle_writer, "case (.running, .processTerminating)"
        ),
        "lifecycleWriterHostState": line_number(
            lifecycle_writer, 'try container.encode("hostState"'
        ),
        "lifecycleWriterViewerState": line_number(
            lifecycle_writer, 'try container.encode("viewerState"'
        ),
        "lifecycleWriterDomainSeparatedDigest": line_number(
            lifecycle_writer,
            '"farpane.v1-concurrency.process-start.v1"',
        ),
        "lifecycleWriterNoOverwrite": line_number(
            lifecycle_writer, "options: .withoutOverwriting"
        ),
        "applicationOwnerScenarioAuthority": line_number(
            lifecycle_process_owner,
            '"FARPANE_HOST_VIEWER_CONCURRENCY_SCENARIO"',
        ),
        "applicationOwnerBuildAuthority": line_number(
            lifecycle_process_owner,
            'Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")',
        ),
        "applicationOwnerProcessStartAuthority": line_number(
            lifecycle_process_owner, "PROC_PIDTBSDINFO"
        ),
        "applicationOwnerDefaultOff": line_number(
            lifecycle_process_owner, "status = .disabled"
        ),
        "applicationOwnerStartRecord": line_number(
            lifecycle_process_owner, ".processStarted"
        ),
        "applicationOwnerTerminationRecord": line_number(
            lifecycle_process_owner, ".processTerminating"
        ),
        "applicationOwnerUnavailable": line_number(
            lifecycle_process_owner, "status = .unavailable"
        ),
        "applicationProductOwner": line_number(
            app, "HostViewerConcurrencyEvidenceProcessOwner()"
        ),
        "applicationProductConfigure": line_number(
            app, ".configureApplication()"
        ),
        "applicationStartupFailureTermination": line_number(
            app, "RustDeskNative startup failed:"
        ),
        "applicationWillTerminateEvidence": line_number(
            app, "func applicationWillTerminate(_ notification: Notification)"
        ),
        "applicationViewerEpochAuthority": line_number(
            lifecycle_process_owner, "committedViewerSessionEpoch"
        ),
        "applicationViewerBegin": line_number(
            lifecycle_process_owner, "public func beginViewerSession()"
        ),
        "applicationViewerStreaming": line_number(
            lifecycle_process_owner,
            "public func observeViewerStreaming(sessionEpoch: UInt64)",
        ),
        "applicationViewerTerminal": line_number(
            lifecycle_process_owner,
            "public func observeViewerTerminal(sessionEpoch: UInt64)",
        ),
        "applicationViewerStop": line_number(
            lifecycle_process_owner,
            "public func stopViewerSession(sessionEpoch: UInt64)",
        ),
        "applicationViewerRecovery": line_number(
            lifecycle_process_owner, "state: .recoveredStreaming"
        ),
        "applicationProductViewerBegin": line_number(
            app, "hostViewerConcurrencyEvidenceOwner.beginViewerSession()"
        ),
        "applicationProductCoreStreaming": line_number(
            app, ".observeViewerStreaming("
        ),
        "applicationProductViewerStop": line_number(
            app, "private func stopViewerLifecycleEvidence()"
        ),
        "applicationProjectionHostIdentity": line_number(
            projection,
            "let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity",
        ),
        "applicationProjectionHostPayload": line_number(
            projection, "let payload: HostAgentXPCWireSnapshotPayload"
        ),
        "applicationAgentBuildIdentity": line_number(
            xpc_client, "let agentBuildID: String"
        ),
        "applicationAgentBootIdentity": line_number(
            xpc_client, "let agentBootID: String"
        ),
        "applicationHostState": line_number(
            xpc_snapshot, "let hostState: String"
        ),
        "applicationHostConnectionCount": line_number(
            xpc_snapshot, "let authenticatedConnectionCount: UInt64"
        ),
        "applicationHostActiveSession": line_number(
            xpc_snapshot, "let activeSession: HostAgentXPCWireActiveSession?"
        ),
        "applicationConfigRevisionCoherence": line_number(
            app, "observation.bootstrap.configRevision =="
        ),
        "wireAgentIdentityContract": line_number(
            xpc_handshake, "package struct HostAgentXPCWireAgentIdentity"
        ),
        "requiredHostAgentProcessIdentity": line_number(
            lifecycle_writer,
            "let hostAgentProcessStartIdentitySHA256: String",
        ),
        "separateHostRuntimeEvidencePath": line_number(
            app, "private func recordHostRuntimeStateEvidence("
        ),
        "hostAgentOwnerConfiguration": line_number(
            lifecycle_process_owner, "public func configureHostAgent("
        ),
        "hostAgentOwnerRole": line_number(
            lifecycle_process_owner, "role: .hostAgent"
        ),
        "hostAgentOwnerPreflightedBuild": line_number(
            lifecycle_process_owner,
            "explicitBuildIdentity: expectedAgentBuildID",
        ),
        "hostAgentViewerRoleGate": line_number(
            lifecycle_process_owner, "configuredRole == .application"
        ),
        "hostAgentProductEvidenceOwner": line_number(
            host_agent_process,
            "HostViewerConcurrencyEvidenceProcessOwner()",
        ),
        "hostAgentProductEvidenceConfigure": line_number(
            host_agent_process, ".configureHostAgent("
        ),
        "hostAgentProductEvidenceTermination": line_number(
            host_agent_process,
            "_ = concurrencyEvidenceOwner.terminateAndWait()",
        ),
        "hostRecoveryKinds": line_number(
            recovery_evidence, "case sleepWake"
        ),
        "hostRecoveryScopeDigest": line_number(
            recovery_evidence, "let hostInstanceScopeSHA256: String"
        ),
        "recoveryItemSevenScope": line_number(
            recovery_validator,
            '"fullSection15_2Item7Complete": status == "pass"',
        ),
        "reconnectPreviousIdentity": line_number(
            xpc_reconnect, "binding.previousPeerIdentity"
        ),
        "clientKnownHostIdentity": line_number(
            xpc_client,
            "knownHostInstanceID: previousPeerIdentity?.hostInstanceID",
        ),
        "projectionInMemoryIdentity": line_number(
            projection, "let previousPeerIdentity = lastPeerIdentity"
        ),
        "h4LiveEvidenceBoundary": line_number(
            h4_audit, "Manual/live evidence missing"
        ),
    }
    missing_source_lines = [
        name for name, number in source_lines.items() if number <= 0
    ]

    required_scenarios = {
        "hostReadyThenOutboundViewer": {
            "orderedStates": [
                "host-ready-zero-inbound",
                "viewer-authenticated-streaming",
                "host-remains-ready-zero-inbound",
            ],
            "requiresItemTenResourceRun": "host-ready-viewer",
        },
        "viewerThenInboundHost": {
            "orderedStates": [
                "viewer-authenticated-streaming",
                "host-inbound-authenticated",
                "both-media-active",
            ],
            "requiresItemTenResourceRun": "host-viewer-dual",
        },
        "activeHostViewerStartStop": {
            "orderedStates": [
                "host-inbound-media-active",
                "viewer-started-and-streaming",
                "viewer-stopped",
                "host-inbound-media-still-active",
            ],
            "requiresItemTenResourceRun": "host-viewer-dual",
        },
        "dualDisconnectRecover": {
            "orderedStates": [
                "both-media-active",
                "host-and-viewer-disconnected",
                "host-and-viewer-independently-recovered",
                "both-media-active-again",
            ],
            "requiresRecoveryCorrelation": True,
        },
        "appRestartStableHostID": {
            "orderedStates": [
                "first-app-observes-ready-host",
                "first-app-process-terminates",
                "second-app-process-starts",
                "second-app-observes-ready-host",
            ],
            "requiresSameHostInstanceScopeDigest": True,
            "requiresSameHostAgentProcessStartIdentity": True,
            "requiresDistinctAppProcessStartIdentities": True,
        },
    }

    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "sections-18-and-20.3-v1-coexistence",
        "status": (
            "host-agent-process-owner-implemented"
            if not missing and not missing_source_lines
            else "audit-failed"
        ),
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_source_lines,
        "targetContract": {
            "requiredScenarioOrder": list(required_scenarios),
            "requiredScenarios": required_scenarios,
            "eventAuthority": {
                "requiresWallAndBootMonotonicTime": True,
                "requiresContiguousPerProcessSequence": True,
                "requiresExactRolePIDAndProcessStartIdentity": True,
                "requiresHostInstanceAndBuildDomainSeparatedDigests": True,
                "requiresAgentBootAndConfigRevisionBinding": True,
                "requiresViewerLifecycleTransitionTimestamps": True,
                "requiresHostRuntimeTransitionTimestamps": True,
                "forbidsCredentialsPeerIDsAndMediaPayloads": True,
            },
            "aggregation": {
                "requiresExactlyFivePassingScenarioResults": True,
                "requiresSameMachineArchitectureMacOSAndBuild": True,
                "requiresSafeRelativeHashBoundUniqueSources": True,
                "requiresNoOverwritePublication": True,
                "mayReusePassingItemTenPairForResourceAuthorityOnly": True,
            },
            "forbiddenInference": [
                "item-ten-overlap-pair-as-full-v1-matrix",
                "simultaneous-active-snapshots-as-event-ordering",
                "untimed-viewer-transition-strings-as-ordering-proof",
                "host-only-recovery-as-dual-role-recovery",
                "same-process-xpc-reconnect-as-app-restart-proof",
                "repeated-visible-host-id-without-distinct-app-lifetimes",
                "process-liveness-or-window-visibility-as-session-state",
            ],
        },
        "nextImplementationBoundary": (
            "versioned-host-agent-process-identity-wire-contract"
        ),
        "remainingBoundary": {
            "applicationHostObservationRequiresVersionedAgentProcessIdentity": (
                True
            ),
            "authoritativeLifecycleCompositionStillRequiresImplementation": True,
            "fiveScenarioManifestValidatorStillRequiresImplementation": True,
            "installedAppAgentTwoMachineExecutionStillRequiresExecution": True,
            "noV1ConcurrencyMatrixPassIsClaimed": True,
        },
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    expected_status = "host-agent-process-owner-implemented"
    return 0 if result["status"] == expected_status else 1


if __name__ == "__main__":
    raise SystemExit(main())
