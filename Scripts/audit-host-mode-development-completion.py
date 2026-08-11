#!/usr/bin/env python3
"""Audit H0-H6 development completion without claiming release acceptance."""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path


SCHEMA = "farpane-host-mode-development-completion-audit"
REQUIRED_AUDITS = {
    "audit-host-agent-xpc-process-identity-contract.py": (
        "farpane-host-agent-xpc-process-identity-contract-audit",
        "viewer-automatic-recovery-composed",
    ),
    "audit-host-battery-thermal-evidence.py": (
        "farpane-host-battery-thermal-evidence-audit",
        "checkpoint-required",
    ),
    "audit-host-combined-role-evidence.py": (
        "farpane-host-combined-role-evidence-audit",
        "pair-validator-implemented",
    ),
    "audit-host-display-reconfigure-contract.py": (
        "farpane-host-display-reconfigure-contract-audit",
        "ownership-frozen",
    ),
    "audit-host-display-recovery-provenance.py": (
        "farpane-host-display-recovery-provenance-audit",
        "display-callback-implemented",
    ),
    "audit-host-idle-authenticated-connection-authority.py": (
        "farpane-host-idle-authenticated-connection-authority-audit",
        "implemented",
    ),
    "audit-host-network-path-recovery-contract.py": (
        "farpane-host-network-path-recovery-contract-audit",
        "trigger-contract-implemented",
    ),
    "audit-host-network-restart-abi-contract.py": (
        "farpane-host-network-restart-abi-contract-audit",
        "contract-implemented",
    ),
    "audit-host-performance-recovery-evidence.py": (
        "farpane-host-performance-recovery-evidence-audit",
        "manifest-validator-implemented",
    ),
    "audit-host-physical-energy-authority.py": (
        "farpane-host-physical-energy-authority-audit",
        "raw-capture-implemented",
    ),
    "audit-host-session-availability-contract.py": (
        "farpane-host-session-availability-contract-audit",
        "same-session-recovery-ownership-verified",
    ),
    "audit-host-sleep-recovery-contract.py": (
        "farpane-host-sleep-recovery-contract-audit",
        "contract-implemented",
    ),
    "audit-host-v1-concurrency-capture-orchestration.py": (
        "farpane-host-v1-concurrency-capture-orchestration-audit",
        "capture-orchestrator-implemented",
    ),
    "audit-host-v1-concurrency-evidence.py": (
        "farpane-host-v1-concurrency-evidence-audit",
        "five-scenario-concurrency-validator-implemented",
    ),
    "audit-host-audio-product-development-completion.py": (
        "farpane-host-audio-product-development-completion-audit",
        "product-development-complete",
    ),
    "audit-host-clipboard-product-development-completion.py": (
        "farpane-host-clipboard-product-development-completion-audit",
        "product-development-complete",
    ),
    "audit-host-file-transfer-product-development-completion.py": (
        "farpane-host-file-transfer-product-development-completion-audit",
        "product-development-complete",
    ),
    "audit-host-multi-display-product-development-completion.py": (
        "farpane-host-multi-display-product-development-completion-audit",
        "product-development-complete",
    ),
}


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, marker: str) -> int:
    offset = source.find(marker)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def define_version(source: str, name: str) -> int:
    match = re.search(rf"^#define {re.escape(name)} (\d+)u$", source, re.MULTILINE)
    if match is None:
        raise ValueError(f"missing {name}")
    return int(match.group(1))


def run_required_audits(repository: Path) -> dict[str, dict[str, object]]:
    documents: dict[str, dict[str, object]] = {}
    for script, (schema, status) in REQUIRED_AUDITS.items():
        completed = subprocess.run(
            ["python3", f"Scripts/{script}"],
            cwd=repository,
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
        )
        document = json.loads(completed.stdout)
        missing_lists_are_empty = all(
            not value
            for key, value in document.items()
            if key.startswith("missing") and isinstance(value, list)
        )
        if (
            completed.returncode != 0
            or not isinstance(document, dict)
            or document.get("schema") != schema
            or document.get("status") != status
            or not missing_lists_are_empty
        ):
            raise ValueError(f"required Host Mode audit failed: {script}")
        documents[script] = document
    return documents


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "h0": repository / "docs/host-mode-h0.md",
        "readme": repository / "README.md",
        "notices": repository / "THIRD_PARTY_NOTICES.md",
        "build": repository / "Scripts/build-universal.sh",
        "verifier": repository / "Scripts/verify-rustdesk-core-source.sh",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "host_bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "host_control": repository / "Sources/CoreBridge/HostControlClient.swift",
        "host_pipeline": repository / "Sources/VideoPipeline/HostMediaPipeline.swift",
        "capture": repository / "Sources/VideoPipeline/HostScreenCapture.swift",
        "hardware_probe": repository / "Sources/VideoPipeline/HostHardwareEncoderProbe.swift",
        "h264": repository / "Sources/VideoPipeline/HostH264Encoder.swift",
        "hevc": repository / "Sources/VideoPipeline/HostHEVCEncoder.swift",
        "telemetry": repository / "Sources/VideoPipeline/HostMediaTelemetry.swift",
        "signposts": repository / "Sources/VideoPipeline/HostMediaSignposts.swift",
        "cadence": repository / "Sources/VideoPipeline/HostCaptureCadence.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "home": repository / "Sources/RustDeskNative/HomeView.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcess.swift",
        "agent_bootstrap": repository / "Sources/RustDeskNative/HostAgentProcessBootstrap.swift",
        "mode": repository / "Sources/CoreBridge/RustDeskNativeProcessMode.swift",
        "registration": repository / "Sources/CoreBridge/HostAgentBackgroundRegistrationMutationOwner.swift",
        "readiness": repository / "Sources/CoreBridge/HostAgentBackgroundReadinessPolicy.swift",
        "xpc_gate": repository / "Sources/CoreBridge/HostAgentXPCPeerAdmissionGate.swift",
        "xpc_session": repository / "Sources/CoreBridge/HostAgentXPCSnapshotService.swift",
        "bootstrap_reader": repository / "Sources/ConnectionCatalog/HostAgentBootstrapConfigurationReader.swift",
        "single_writer": repository / "Sources/ConnectionCatalog/HostAgentSingleWriterLease.swift",
        "launch_agent": repository / "App/LaunchAgents/io.rustdesknative.viewer.host-agent.plist",
        "sleep": repository / "Sources/RustDeskNative/HostAgentSleepWakeRecoveryProcessOwner.swift",
        "network": repository / "Sources/RustDeskNative/HostAgentNetworkPathRecoveryProcessOwner.swift",
        "display": repository / "Sources/RustDeskNative/HostAgentDisplayTCCRecoveryAuthority.swift",
        "session_policy": repository / "Sources/CoreBridge/HostApplicationLifecyclePolicy.swift",
        "performance_runner": repository / "Scripts/run-farpane-host-performance-scenario.sh",
        "performance_validator": repository / "Scripts/validate-farpane-host-performance.py",
        "idle_runner": repository / "Scripts/run-farpane-host-idle-scenario.sh",
        "concurrency_runner": repository / "Scripts/run-farpane-host-v1-concurrency-capture.py",
    }
    evidence_paths = tuple(repository / relative for relative in (
        "Evidence/HostMode/2026-08-07/h1a-registration.md",
        "Evidence/HostMode/2026-08-07/h1b-media.md",
        "Evidence/HostMode/2026-08-07/h1c-framing.md",
        "Evidence/HostMode/2026-08-08/h2-automatic-live-telemetry-log.md",
        "Evidence/HostMode/2026-08-08/h2-host-idle-performance-contract.md",
        "Evidence/HostMode/2026-08-08/h2-stability-performance-contract.md",
        "Evidence/HostMode/2026-08-08/h3-permanent-password-ui.md",
        "Evidence/HostMode/2026-08-08/h3-active-session-input-availability.md",
        "Evidence/HostMode/2026-08-08/h3-mini-input-acceptance.md",
        "Evidence/HostMode/2026-08-09/h4-host-agent-real-dispatch.md",
        "Evidence/HostMode/2026-08-09/h4-background-command-product-smoke.md",
        "Evidence/HostMode/2026-08-09/h4-password-persistence-readback.md",
        "Evidence/HostMode/2026-08-09/h5-same-session-recovery-ownership.md",
        "Evidence/HostMode/2026-08-10/h5-v1-concurrency-capture-orchestrator.md",
        "Evidence/HostMode/2026-08-10/h5-native-architecture-package-readiness.md",
        "Evidence/HostMode/2026-08-11/h6-host-audio-product-development-completion-audit.md",
        "Evidence/HostMode/2026-08-11/h6-host-clipboard-product-development-completion-audit.md",
        "Evidence/HostMode/2026-08-11/h6-host-file-transfer-product-development-completion-audit.md",
        "Evidence/HostMode/2026-08-11/h6-multi-display-product-development-completion-audit.md",
    ))
    try:
        sources = {name: read(path) for name, path in paths.items()}
        audits = run_required_audits(repository)
        viewer_abi = define_version(sources["header"], "RDN_ABI_VERSION")
        host_abi = define_version(sources["header"], "RDN_HOST_ABI_VERSION")
        media_abi = define_version(sources["header"], "RDN_HOST_MEDIA_ABI_VERSION")
    except (
        OSError,
        UnicodeError,
        ValueError,
        json.JSONDecodeError,
        subprocess.TimeoutExpired,
    ) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "schemaVersion": 1,
            "status": "audit-failed",
            "error": str(error),
        }, sort_keys=True, separators=(",", ":")))
        return 1

    scope = all(marker in sources["design"] for marker in (
        "当前开发完成口径（2026-08-11）",
        "不再阻塞\n开发步骤或整体开发完成",
        "不把未执行的双机检查写成已通过",
        "不替代未来发布、兼容性、\n性能或 notarization 验收",
    ))
    h0 = all(marker in sources["h0"] + sources["readme"] + sources["notices"] + sources["build"] + sources["verifier"] for marker in (
        "H0.1 AGPL 合规清单",
        "GNU Affero General Public License v3.0",
        "6c578292e8ebbbec708b76986ba8c4bc7c509747",
        "rdn-native-host",
        "FarPane-AGPL-3.0.txt",
        "RUSTDESK_CORE_SOURCE_VERIFIED",
    ))
    h1 = all(marker in sources["header"] + sources["host_bridge"] + sources["host_control"] + sources["host_pipeline"] + sources["h264"] + sources["hevc"] for marker in (
        "int32_t rdn_host_start(RdnHost *host);",
        "pub unsafe extern \"C\" fn rdn_host_start",
        "public struct HostServerConfiguration",
        "public final class HostMediaPipeline",
        "UsingHardwareAcceleratedVideoEncoder",
        "public func requestKeyframe()",
    ))
    h2 = all(marker in sources["telemetry"] + sources["signposts"] + sources["cadence"] + sources["capture"] + sources["host_pipeline"] + sources["hardware_probe"] + sources["host_bridge"] + sources["performance_runner"] + sources["performance_validator"] + sources["idle_runner"] for marker in (
        "public final class HostMediaTelemetry",
        "os_signpost(",
        "public struct HostCaptureCadenceController",
        "attachments[.dirtyRects]",
        "static var capacity: Int { 2 }",
        "markDropReasonsInstrumented",
        "public static func probe(",
        "MEDIA_QUEUE_CAPACITY",
        "connected-static",
        "stability",
        "host-ready-no-screen-route",
    ))
    h3 = all(marker in sources["header"] + sources["host_bridge"] + sources["connection"] + sources["home"] for marker in (
        "rdn_host_set_permanent_password",
        "native_host_begin_approval",
        "NativeSessionCommand::DisableInput",
        "native_host_platform_input_authorities",
        "NormalizedMouseInput",
        "NormalizedKeyInput",
        "LOGIN_FAILURE_TOTAL_COOLDOWN_MINUTES",
        "setHostPermanentPassword",
        "approveHostConnection",
        "disconnectHostSession",
    ))
    h4 = all(marker in sources["app"] + sources["mode"] + sources["agent_bootstrap"] + sources["agent"] + sources["registration"] + sources["readiness"] + sources["xpc_gate"] + sources["xpc_session"] + sources["bootstrap_reader"] + sources["single_writer"] + sources["launch_agent"] + sources["host_bridge"] for marker in (
        "exit(HostAgentProcessBootstrap.run())",
        "arguments.dropFirst().contains(\"--host-agent\")",
        "HostAgentProcessProductEntry.run",
        "HostAgentProcessRunner.run",
        "SMAppService.agent(",
        "try service.register()",
        "try service.unregister()",
        "HostAgentXPCPeerAdmissionStatus",
        "Per-connection snapshot-first state machine",
        "HostAgentBootstrapConfigurationReader",
        "HostAgentSingleWriterLease",
        "configuration.storagePersistenceFailed",
        "configuration.passwordPersistenceFailed",
        "case ready",
        "io.rustdesknative.viewer.host-agent",
    ))
    h5 = all(marker in sources["sleep"] + sources["network"] + sources["display"] + sources["session_policy"] + sources["concurrency_runner"] for marker in (
        "final class HostAgentSleepWakeRecoveryProcessOwner",
        "final class HostAgentNetworkPathRecoveryProcessOwner",
        "final class HostAgentDisplayTCCRecoveryAuthority",
        "case (.limited, .sessionUnavailable)",
        "installed App",
    ))
    h6_audits = (
        "audit-host-audio-product-development-completion.py",
        "audit-host-clipboard-product-development-completion.py",
        "audit-host-file-transfer-product-development-completion.py",
        "audit-host-multi-display-product-development-completion.py",
    )
    h5_audits = tuple(name for name in REQUIRED_AUDITS if name not in h6_audits)
    h6 = all(
        audits[name].get("claims", {}).get(key) is True
        for name, key in (
            (h6_audits[0], "audioProductDevelopmentComplete"),
            (h6_audits[1], "clipboardProductDevelopmentComplete"),
            (h6_audits[2], "fileTransferProductDevelopmentComplete"),
            (h6_audits[3], "multiDisplayProductDevelopmentComplete"),
        )
    )
    evidence = {
        "developmentCompletionScopeIsExplicitAndNonDeceptive": scope,
        "h0LicenseBaselinePatchAndConfigBoundaryComplete": h0,
        "h1HostControlGoldenMediaAndDualCodecPathComplete": h1,
        "h2TelemetryAdaptiveBackpressureAndPerformanceToolingComplete": h2,
        "h3AuthenticationApprovalPermissionAndInputProductComplete": h3,
        "h4BackgroundAgentRegistrationXPCAndPersistenceProductComplete": h4,
        "h5RecoverySessionBoundaryAndEvidenceToolingComplete": h5,
        "h5MachineAuditsPassWithoutClaimingLiveMatrix": all(name in audits for name in h5_audits),
        "h6IndependentOptionalProductsComplete": h6,
        "allRequiredMachineAuditsPass": len(audits) == len(REQUIRED_AUDITS),
        "stagedEvidenceChainExists": all(path.is_file() for path in evidence_paths),
        "abiVersionsMatchCurrentProduct": viewer_abi == 18 and host_abi == 19 and media_abi == 1,
        "bundleIdentityAndMinimumOSRemainStable": all(marker in sources["build"] + sources["readme"] for marker in (
            "io.rustdesknative.viewer",
            "RustDeskNative",
            "macOS 13",
        )),
    }
    source_lines = {
        "developmentScope": line_number(sources["design"], "当前开发完成口径（2026-08-11）"),
        "h0Status": line_number(sources["design"], "H0 完成"),
        "h0License": line_number(sources["h0"], "H0.1 AGPL 合规清单"),
        "noticesHostPatch": line_number(sources["notices"], "Host Mode additionally introduces"),
        "packagedLicense": line_number(sources["build"], "FarPane-AGPL-3.0.txt"),
        "h1Status": line_number(sources["design"], "H1 完成"),
        "hostStartABI": line_number(sources["header"], "int32_t rdn_host_start(RdnHost *host);"),
        "hostMediaPipeline": line_number(sources["host_pipeline"], "public final class HostMediaPipeline"),
        "h264Encoder": line_number(sources["h264"], "public final class HostH264Encoder"),
        "hevcEncoder": line_number(sources["hevc"], "public final class HostHEVCEncoder"),
        "h2Telemetry": line_number(sources["telemetry"], "public final class HostMediaTelemetry"),
        "h2Signpost": line_number(sources["signposts"], "os_signpost("),
        "h2Cadence": line_number(sources["cadence"], "public struct HostCaptureCadenceController"),
        "h2DirtyRects": line_number(sources["capture"], "attachments[.dirtyRects]"),
        "h2RawQueue": line_number(sources["host_pipeline"], "static var capacity: Int { 2 }"),
        "h2DropLedger": line_number(sources["host_pipeline"], "markDropReasonsInstrumented"),
        "h2HardwareProbe": line_number(sources["hardware_probe"], "public static func probe("),
        "h2EncodedQueue": line_number(sources["host_bridge"], "MEDIA_QUEUE_CAPACITY"),
        "h2Runner": line_number(sources["performance_runner"], "static-1080p30"),
        "passwordABI": line_number(sources["header"], "rdn_host_set_permanent_password"),
        "approvalBroker": line_number(sources["host_bridge"], "native_host_begin_approval"),
        "inputAuthority": line_number(sources["connection"], "native_host_platform_input_authorities"),
        "inputSemantic": line_number(sources["connection"], "NormalizedMouseInput"),
        "loginCooldown": line_number(sources["connection"], "LOGIN_FAILURE_TOTAL_COOLDOWN_MINUTES"),
        "hostAgentDispatch": line_number(sources["app"], "exit(HostAgentProcessBootstrap.run())"),
        "hostAgentRuntime": line_number(sources["agent"], "HostAgentProcessRunner.run"),
        "serviceRegistration": line_number(sources["registration"], "try service.register()"),
        "backgroundReadiness": line_number(sources["readiness"], "case ready"),
        "xpcAdmission": line_number(sources["xpc_gate"], "HostAgentXPCPeerAdmissionStatus"),
        "xpcSnapshotFirst": line_number(sources["xpc_session"], "Per-connection snapshot-first state machine"),
        "bootstrapReader": line_number(sources["bootstrap_reader"], "HostAgentBootstrapConfigurationReader"),
        "singleWriterLease": line_number(sources["single_writer"], "HostAgentSingleWriterLease"),
        "storageReadback": line_number(sources["host_bridge"], "configuration.storagePersistenceFailed"),
        "passwordReadback": line_number(sources["host_bridge"], "configuration.passwordPersistenceFailed"),
        "sleepRecovery": line_number(sources["sleep"], "final class HostAgentSleepWakeRecoveryProcessOwner"),
        "networkRecovery": line_number(sources["network"], "final class HostAgentNetworkPathRecoveryProcessOwner"),
        "displayRecovery": line_number(sources["display"], "final class HostAgentDisplayTCCRecoveryAuthority"),
        "sessionBoundary": line_number(sources["session_policy"], "case (.limited, .sessionUnavailable)"),
        "concurrencyCapture": line_number(sources["concurrency_runner"], "installed App"),
        "h6AudioCompletion": line_number(sources["design"], "H6.1h Host audio product development completion audit"),
        "h6ClipboardCompletion": line_number(sources["design"], "H6.2l clipboard product development completion audit"),
        "h6FileCompletion": line_number(sources["design"], "H6.3 产品开发代码无剩余缺口"),
        "h6DisplayCompletion": line_number(sources["design"], "H6.4g multi-display product development completion audit"),
    }
    remaining_gaps = [name for name, present in evidence.items() if not present]
    complete = not remaining_gaps and all(source_lines.values())
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": "development-complete-acceptance-pending" if complete else "audit-failed",
        "coverageScope": "host-mode-h0-through-h6-development-completion",
        "currentABI": {"viewer": viewer_abi, "host": host_abi, "hostMedia": media_abi},
        "requiredAudits": sorted(REQUIRED_AUDITS),
        "evidence": evidence,
        "sourceLines": source_lines,
        "claims": {
            "h0DevelopmentComplete": h0,
            "h1DevelopmentComplete": h1,
            "h2DevelopmentComplete": h2,
            "h3DevelopmentComplete": h3,
            "h4DevelopmentComplete": h4,
            "h5DevelopmentComplete": h5 and all(name in audits for name in h5_audits),
            "h6DevelopmentComplete": h6,
            "hostModeDevelopmentComplete": complete,
            "installedCurrentBuildSingleMacSmokeComplete": False,
            "dualMacAcceptanceComplete": False,
            "performanceAcceptanceComplete": False,
            "notarizedCleanMachineAcceptanceComplete": False,
            "releaseAcceptanceComplete": False,
        },
        "remainingDevelopmentGaps": remaining_gaps,
        "nonBlockingAcceptanceGaps": [
            "installedCurrentBuildSingleMacGUIAndHostAgentSmoke",
            "dualMacScreenInputClipboardFileTransferAndMultiDisplay",
            "directRelayAndTwoActiveSessionLiveMatrix",
            "real1080pAnd4kPerformanceWindows",
            "thirtyMinuteAppleSiliconAndIntelStability",
            "sleepWakeNetworkDisplayAndSessionTransitionLiveAcceptance",
            "DeveloperIDNotarizationStaplingQuarantineAndFirewall",
            "crossVersionInteroperabilityAndReleaseQualification",
        ],
        "nextImplementationBoundary": None if complete else "first-reported-development-gap",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if complete else 1


if __name__ == "__main__":
    raise SystemExit(main())
