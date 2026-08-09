#!/usr/bin/env python3
"""Audit and freeze the section 15.2 item 10 combined-role evidence boundary."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-combined-role-evidence-audit"


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
        "metrics": repository / "Sources/VideoPipeline/PipelineMetrics.swift",
        "sampler": repository / "Scripts/sample-farpane-host-performance.sh",
        "combined_sampler": (
            repository / "Scripts/sample-farpane-host-combined-role.py"
        ),
        "matrix": (
            repository / "Scripts/validate-farpane-host-performance-matrix.py"
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
    metrics = sources["metrics"]
    sampler = sources["sampler"]
    combined_sampler = sources["combined_sampler"]
    matrix = sources["matrix"]
    h4_audit = sources["h4_audit"]

    evidence = {
        "sectionSpecRequiresReadyViewerAndDualActiveCombinedBudget": (
            "HostAgent 后台 ready 时运行 outbound Viewer" in design
            and "Host + Viewer 双 active session 的合并资源预算" in design
        ),
        "v1AcceptanceRequiresFiveConcurrencyCasesAndSplitReporting": (
            "Host ready 时发起 outbound Viewer" in design
            and "Viewer 会话中接收入站请求" in design
            and "Host 活动会话中启动/停止 Viewer" in design
            and "两侧同时断线/恢复" in design
            and "重启 App 不改变 Host ID" in design
            and "资源预算分开报 Viewer、HostAgent、WindowServer 和媒体进程"
            in design
        ),
        "processModesUseExactSeparateRoleFlag": all(
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
                "guard stopHostMode(",
                "try launchViewer(",
            )
        ),
        "backgroundHostHasCoherentRuntimeStateAuthority": all(
            marker in app
            for marker in (
                "coherentHostAgentBackgroundActivationView?.projection",
                "let backgroundPayload: HostAgentXPCWireSnapshotPayload?",
                "let authenticatedConnectionCount = usesLegacyHost",
                "let backgroundRouteActive = backgroundPayload?.activeSession != nil",
                "recordHostRuntimeStateEvidence()",
            )
        ),
        "viewerHasStreamingAndProcessResourceReport": all(
            marker in metrics
            for marker in (
                "public let source: String",
                "processCPUPercent:",
                "peakResidentMB:",
                "decodedFrames:",
                "presentedFrames:",
                "coreStateTransitions:",
            )
        ) and all(
            marker in app
            for marker in (
                'source: fixture == nil ? "rustdesk-live" : "fixture"',
                "let report = metrics.snapshot(",
                "try data.write(to: url, options: .atomic)",
            )
        ),
        "currentSamplerAdmitsCombinedLabelsButOnlyOnePID": (
            "host-ready-viewer|host-viewer-dual" in sampler
            and "SCENARIO DURATION OUTPUT_PREFIX HOST_PID" in sampler
            and "HOST_PID must be a process ID greater than 1" in sampler
            and "viewer_cpu_percent" not in sampler
            and "VIEWER_PID" not in sampler
        ),
        "currentSamplerMislabelsSplitModeAsCombinedProcess": (
            '"hostRole": "combined-host-agent-native-app"' in sampler
        ),
        "currentSamplerAggregatesSharedSystemMediaServices": all(
            marker in sampler
            for marker in (
                "pgrep -x WindowServer",
                "pgrep -x videotoolboxd",
                "pgrep -x VTEncoderXPCService",
            )
        ),
        "splitSamplerRequiresExactDistinctRolePIDs": all(
            marker in combined_sampler
            for marker in (
                "HOST_AGENT_PID VIEWER_PID",
                'raise SampleError("HOST_AGENT_PID and VIEWER_PID must be distinct")',
                'HOST_AGENT_FLAG = "--host-agent"',
                'expected_flag_count = 1 if role == "host-agent" else 0',
                '"roleProcessScope": "exact-pid-per-second"',
            )
        ),
        "splitSamplerPinsProcessAndBuildIdentityForFullWindow": all(
            marker in combined_sampler
            for marker in (
                "proc_pidpath = libproc.proc_pidpath",
                "KERN_PROCARGS2 = 49",
                '"argumentsSHA256": identity.arguments_sha256',
                'document.get("CFBundleVersion")',
                "require_runtime_matches(host_agent, host_runtime)",
                "require_process_identity_unchanged(host_agent, host_after)",
                '"sameExecutableSHA256":',
                '"sameBuildIdentifier":',
            )
        ),
        "splitSamplerSeparatesRoleCombinedAndSharedResourceScopes": all(
            marker in combined_sampler
            for marker in (
                '"host_agent_cpu_percent"',
                '"viewer_cpu_percent"',
                '"farpane_combined_cpu_percent"',
                '"sharedSystemScope": [',
                '"sharedSystemScopeAssignedToRole": False',
                '"energyImpactUnit": "top-relative-not-joules"',
            )
        ),
        "splitSamplerPublishesSafelyWithoutClaimingItemTenPass": all(
            marker in combined_sampler
            for marker in (
                "validate_output_prefix",
                "has_symlink_component(parent)",
                "require_outputs_absent(final_paths)",
                "publish_triplet_no_replace(",
                '"hostRuntimeStateBound": False',
                '"viewerStreamingReportBound": False',
                '"combinedBudgetThresholdEvaluated": False',
                '"section15_2Item10Complete": False',
            )
        ),
        "baseMatrixExplicitlyLeavesItemTenOpen": (
            '"coveredSection15_2Items": [1, 2, 3, 4, 5, 6, 8]' in matrix
            and '"uncoveredSection15_2Items": [7, 9, 10]' in matrix
        ),
        "h4AuditExplicitlyLeavesLiveCombinedEvidenceOpen": (
            "Code-ready; no real concurrent-session evidence" in h4_audit
            and "Manual/live evidence missing" in h4_audit
            and "Combined performance must report Viewer, HostAgent, WindowServer"
            in h4_audit
        ),
        "combinedManifestValidatorDoesNotExist": not (
            repository
            / "Scripts/validate-farpane-host-combined-role.py"
        ).exists(),
    }
    missing = [name for name, present in evidence.items() if not present]

    source_lines = {
        "itemTenSpec": line_number(
            design, "HostAgent 后台 ready 时运行 outbound Viewer"
        ),
        "v1AcceptanceMatrix": line_number(
            design, "V1 并存验收至少包含"
        ),
        "processModePolicy": line_number(
            process_mode, 'contains("--host-agent") ? .hostAgent : .application'
        ),
        "viewerLegacyQuiescence": line_number(
            app, "if hostRuntimeActive || hostClient != nil"
        ),
        "backgroundProjectionAuthority": line_number(
            app, "coherentHostAgentBackgroundActivationView?.projection"
        ),
        "backgroundConnectionAuthority": line_number(
            app, "let authenticatedConnectionCount = usesLegacyHost"
        ),
        "viewerLiveSource": line_number(
            app, 'source: fixture == nil ? "rustdesk-live" : "fixture"'
        ),
        "viewerReportWrite": line_number(
            app, "try data.write(to: url, options: .atomic)"
        ),
        "viewerProcessCPU": line_number(metrics, "processCPUPercent:"),
        "viewerStreamingFrames": line_number(metrics, "presentedFrames:"),
        "samplerCombinedLabels": line_number(
            sampler, "host-ready-viewer|host-viewer-dual"
        ),
        "samplerSinglePIDUsage": line_number(
            sampler, "SCENARIO DURATION OUTPUT_PREFIX HOST_PID"
        ),
        "samplerFalseCombinedRole": line_number(
            sampler, '"hostRole": "combined-host-agent-native-app"'
        ),
        "samplerSharedWindowServer": line_number(
            sampler, "pgrep -x WindowServer"
        ),
        "splitSamplerUsage": line_number(
            combined_sampler, "HOST_AGENT_PID VIEWER_PID"
        ),
        "splitSamplerDarwinExecutableAuthority": line_number(
            combined_sampler, "proc_pidpath = libproc.proc_pidpath"
        ),
        "splitSamplerArgumentAuthority": line_number(
            combined_sampler, "KERN_PROCARGS2 = 49"
        ),
        "splitSamplerBuildAuthority": line_number(
            combined_sampler, 'document.get("CFBundleVersion")'
        ),
        "splitSamplerHostColumns": line_number(
            combined_sampler, '"host_agent_cpu_percent"'
        ),
        "splitSamplerViewerColumns": line_number(
            combined_sampler, '"viewer_cpu_percent"'
        ),
        "splitSamplerCombinedColumns": line_number(
            combined_sampler, '"farpane_combined_cpu_percent"'
        ),
        "splitSamplerSharedScope": line_number(
            combined_sampler, '"sharedSystemScopeAssignedToRole": False'
        ),
        "splitSamplerNoPassClaim": line_number(
            combined_sampler, '"section15_2Item10Complete": False'
        ),
        "matrixUncoveredItems": line_number(
            matrix, '"uncoveredSection15_2Items": [7, 9, 10]'
        ),
        "h4ManualBoundary": line_number(
            h4_audit, "Combined performance must report Viewer, HostAgent"
        ),
    }
    missing_source_lines = [
        name for name, number in source_lines.items() if number <= 0
    ]

    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "section15_2Item": 10,
        "status": (
            "split-sampler-implemented"
            if not missing and not missing_source_lines
            else "audit-failed"
        ),
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_source_lines,
        "targetContract": {
            "requiredRuns": {
                "hostReadyViewer": {
                    "scenario": "host-ready-viewer",
                    "minimumConcurrentDurationSeconds": 600,
                    "requiresHostReadyWithZeroAuthenticatedConnections": True,
                    "requiresHostMediaRouteAndPipelineInactive": True,
                    "requiresViewerAuthenticatedStreaming": True,
                },
                "hostViewerDualActive": {
                    "scenario": "host-viewer-dual",
                    "minimumConcurrentDurationSeconds": 600,
                    "requiresHostAuthenticatedConnectionAndActiveMedia": True,
                    "requiresViewerAuthenticatedStreaming": True,
                },
            },
            "roleIdentity": {
                "requiresExactHostAgentPIDWithHostAgentFlag": True,
                "requiresExactViewerPIDWithoutHostAgentFlag": True,
                "requiresDistinctPIDs": True,
                "requiresSameExecutableSHA256AndBuildID": True,
                "requiresStableRolePIDsForFullWindow": True,
            },
            "overlapAuthority": {
                "requiresUTCAndMonotonicWindows": True,
                "requiresFullWindowHostRuntimeStateCoverage": True,
                "requiresFullWindowViewerStreamingCoverage": True,
                "requiresExactEvidenceSHA256Binding": True,
            },
            "resourceReporting": {
                "requiresPerSecondHostAgentCPUResidentThreadsAndEnergy": True,
                "requiresPerSecondViewerCPUResidentThreadsAndEnergy": True,
                "requiresIndividualAndCombinedProcessBudgets": True,
                "reportsWindowServerAndMediaAsSharedSystemScope": True,
                "forbidsAssigningSharedSystemScopeToEitherRole": True,
            },
            "inputSafety": {
                "requiresSafeRelativePaths": True,
                "rejectsPathEscapeSymlinkDuplicateAndOverwrite": True,
            },
            "forbiddenInference": [
                "scenario-label-without-role-and-overlap-proof",
                "pid-alive-or-window-visible-as-ready-or-streaming",
                "single-farpane-pid-as-split-role-budget",
                "shared-windowserver-or-media-cost-assigned-to-one-role",
                "historical-viewer-report-without-concurrent-host-state",
            ],
        },
        "remainingBoundary": {
            "combinedManifestValidatorStillRequiresImplementation": True,
            "combinedBudgetThresholdStillRequiresDefinition": True,
            "installedAppAgentTwoMachineRunsStillRequireExecution": True,
            "fiveV1ConcurrencyCasesAndStableHostIDStillRequireExecution": True,
            "noSection15_2ItemTenPassIsClaimed": True,
        },
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result["status"] == "split-sampler-implemented" else 1


if __name__ == "__main__":
    raise SystemExit(main())
