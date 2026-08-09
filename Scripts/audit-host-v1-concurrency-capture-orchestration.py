#!/usr/bin/env python3
"""Audit the missing installed-process V1 evidence capture orchestration."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-v1-concurrency-capture-orchestration-audit"


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
        "writer": (
            repository
            / "Sources/VideoPipeline/HostViewerConcurrencyEvidence.swift"
        ),
        "owner": (
            repository
            / "Sources/VideoPipeline/"
            / "HostViewerConcurrencyEvidenceProcessOwner.swift"
        ),
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcess.swift",
        "launch_agent": (
            repository
            / "App/LaunchAgents/io.rustdesknative.viewer.host-agent.plist"
        ),
        "registration": (
            repository
            / "Sources/CoreBridge/"
            / "HostAgentBackgroundRegistrationMutationOwner.swift"
        ),
        "combined_sampler": (
            repository / "Scripts/sample-farpane-host-combined-role.py"
        ),
        "pair_validator": (
            repository
            / "Scripts/validate-farpane-host-combined-role-pair.py"
        ),
        "matrix_validator": (
            repository / "Scripts/validate-farpane-host-v1-concurrency.py"
        ),
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
    except (OSError, UnicodeError) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "schemaVersion": 1,
            "status": "audit-failed",
            "error": str(error),
        }, sort_keys=True, separators=(",", ":")))
        return 1

    design = sources["design"]
    writer = sources["writer"]
    owner = sources["owner"]
    app = sources["app"]
    agent = sources["agent"]
    launch_agent = sources["launch_agent"]
    registration = sources["registration"]
    combined_sampler = sources["combined_sampler"]
    pair_validator = sources["pair_validator"]
    matrix_validator = sources["matrix_validator"]
    target_orchestrator = (
        repository / "Scripts/run-farpane-host-v1-concurrency-capture.py"
    )

    evidence = {
        "designRequiresInstalledFiveScenarioExecution": all(
            marker in design
            for marker in (
                "Host ready 时发起 outbound Viewer",
                "Viewer 会话中接收入站请求",
                "Host 活动会话中启动/停止 Viewer",
                "两侧同时断线/恢复",
                "重启 App 不改变 Host ID",
            )
        ),
        "applicationAndAgentReadTheSameEvidenceEnvironmentKeys": (
            "public static let outputEnvironmentKey" in writer
            and '"FARPANE_HOST_VIEWER_CONCURRENCY_OUTPUT"' in writer
            and '"FARPANE_HOST_VIEWER_CONCURRENCY_SCENARIO"' in owner
            and "ProcessInfo.processInfo.environment" in owner
            and ".configureApplication()" in app
            and ".configureHostAgent(" in agent
        ),
        "signedLaunchAgentHasNoEvidenceEnvironment": (
            "<key>Label</key>" in launch_agent
            and "io.rustdesknative.viewer.host-agent" in launch_agent
            and "--host-agent" in launch_agent
            and "EnvironmentVariables" not in launch_agent
            and "FARPANE_HOST_VIEWER_CONCURRENCY" not in launch_agent
        ),
        "productRegistrationUsesImmutableBundledPlist": all(
            marker in registration
            for marker in (
                "SMAppService.agent(",
                "plistName: HostAgentBackgroundServiceObserver.plistName",
                "try service.register()",
                "try service.unregister()",
            )
        ),
        "writerRequiresUniqueRoleLocalNoReplaceFiles": all(
            marker in writer
            for marker in (
                "App and HostAgent deliberately write separate files",
                "options: .withoutOverwriting",
                "isTrustedParent",
                "isTrustedOutput",
                "try outputHandle.synchronize()",
            )
        ),
        "matrixValidatorRequiresExactRoleFilesAndAgentSpan": all(
            marker in matrix_validator
            for marker in (
                '"hostReadyThenOutboundViewer": ("application", "hostAgent")',
                '"appRestartStableHostID": ("application", "application", "hostAgent")',
                "HostAgent does not span the App lifecycle",
                "does not prove two ordered App lifetimes",
                "App Host state lacks prior HostAgent authority",
                "manifest contains a duplicate lifecycle source",
            )
        ),
        "itemTenResourceAuthorityAlreadyHasExactRoleSampler": all(
            marker in combined_sampler
            for marker in (
                "HOST_AGENT_PID and VIEWER_PID must be distinct",
                'HOST_AGENT_FLAG = "--host-agent"',
                '"roleProcessScope": "exact-pid-per-second"',
            )
        ) and all(
            marker in pair_validator
            for marker in (
                '"section15_2Item10Complete": status == "pass"',
                '"v1ConcurrencyRecoveryMatrixComplete": False',
            )
        ),
        "captureOrchestratorIsStillMissing": not target_orchestrator.exists(),
    }
    missing = [name for name, present in evidence.items() if not present]

    source_lines = {
        "fiveScenarioSpec": line_number(
            design, "V1 并存验收至少包含"
        ),
        "outputEnvironment": line_number(
            writer, '"FARPANE_HOST_VIEWER_CONCURRENCY_OUTPUT"'
        ),
        "scenarioEnvironment": line_number(
            owner, '"FARPANE_HOST_VIEWER_CONCURRENCY_SCENARIO"'
        ),
        "ownerProcessEnvironment": line_number(
            owner, "ProcessInfo.processInfo.environment"
        ),
        "applicationConfiguration": line_number(
            app, ".configureApplication()"
        ),
        "agentConfiguration": line_number(agent, ".configureHostAgent("),
        "launchAgentLabel": line_number(
            launch_agent, "io.rustdesknative.viewer.host-agent"
        ),
        "launchAgentMode": line_number(launch_agent, "--host-agent"),
        "smAppServiceAsset": line_number(
            registration,
            "plistName: HostAgentBackgroundServiceObserver.plistName",
        ),
        "writerNoReplace": line_number(
            writer, "options: .withoutOverwriting"
        ),
        "validatorAgentSpan": line_number(
            matrix_validator, "HostAgent does not span the App lifecycle"
        ),
        "validatorRestartLifetime": line_number(
            matrix_validator, "does not prove two ordered App lifetimes"
        ),
        "combinedRolePIDAuthority": line_number(
            combined_sampler,
            "HOST_AGENT_PID and VIEWER_PID must be distinct",
        ),
        "itemTenPairClaim": line_number(
            pair_validator,
            '"section15_2Item10Complete": status == "pass"',
        ),
    }
    missing_source_lines = [
        name for name, number in source_lines.items() if number <= 0
    ]

    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "installed-v1-concurrency-evidence-capture",
        "status": (
            "capture-orchestration-contract-required"
            if not missing and not missing_source_lines
            else "audit-failed"
        ),
        "evidence": evidence,
        "missingEvidence": missing,
        "sourceLines": source_lines,
        "missingSourceLines": missing_source_lines,
        "targetContract": {
            "launchAgentInjection": {
                "serviceTarget": (
                    "gui/<current-uid>/"
                    "io.rustdesknative.viewer.host-agent"
                ),
                "mechanism": "launchctl-debug-next-invocation-environment",
                "requiredCommands": [
                    "/bin/launchctl print <exact-service-target>",
                    (
                        "/bin/launchctl debug <exact-service-target> "
                        "--environment <two-fixed-evidence-keys>"
                    ),
                    "/bin/launchctl kickstart -k -p <exact-service-target>",
                ],
                "requiresExplicitOperatorInvocation": True,
                "mustVerifyReturnedPIDAndExactHostAgentArguments": True,
                "mustTerminateByPinnedPIDAndWaitForTerminalRecord": True,
                "debugConfigurationIsOneInvocationOnly": True,
            },
            "applicationLaunch": {
                "mechanism": "direct-installed-bundle-executable-launch",
                "requiresSeparateApplicationOutput": True,
                "requiresSameScenarioCorrelationValue": True,
                "mustVerifyExactExecutableIdentity": True,
                "mustNotUseOpenOrLaunchServicesEnvironmentInheritance": True,
            },
            "artifactLayout": {
                "requiresNewOperatorOwnedMode0700Directory": True,
                "requiresUniqueScenarioDirectories": True,
                "requiresSeparateApplicationAndHostAgentJSONL": True,
                "restartScenarioRequiresTwoApplicationJSONL": True,
                "requiresPreexistingPassingItemTenPairResult": True,
                "requiresHashBoundManifestAndNoReplaceResult": True,
            },
            "forbiddenMutation": [
                "editing-signed-launch-agent-plist",
                "launchctl-setenv-global-user-environment",
                "unregistering-or-reregistering-background-agent",
                "launching-an-ad-hoc-host-agent-binary",
                "killing-by-process-name-or-unverified-pid",
                "capturing-credentials-peer-ids-or-server-config",
                "auto-advancing-operator-driven-scenario-steps",
                "publishing-a-pass-from-smoke-or-incomplete-lifetimes",
            ],
        },
        "nextImplementationBoundary": (
            "installed-v1-concurrency-capture-orchestrator"
        ),
        "remainingBoundary": {
            "captureOrchestratorStillRequiresImplementation": True,
            "installedTwoMachineExecutionStillRequiresExecution": True,
            "noV1ConcurrencyMatrixPassIsClaimed": True,
        },
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if result["status"] == "capture-orchestration-contract-required" else 1


if __name__ == "__main__":
    raise SystemExit(main())
