#!/usr/bin/env python3
"""Audit the fail-closed provenance boundary for Host display recovery."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


SCHEMA = "farpane-host-display-recovery-provenance-audit"
PINNED_RUSTDESK_COMMIT = "6c578292e8ebbbec708b76986ba8c4bc7c509747"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def section(source: str, start: str, end: str) -> str:
    start_offset = source.find(start)
    end_offset = source.find(end, start_offset + len(start))
    if start_offset < 0 or end_offset <= start_offset:
        return ""
    return source[start_offset:end_offset]


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    if offset < 0:
        return 0
    return source.count("\n", 0, offset) + 1


def integer_constant(source: str, pattern: str) -> int:
    match = re.search(pattern, source)
    if match is None:
        raise ValueError(f"missing integer constant: {pattern}")
    return int(match.group(1))


def pinned_service_source(repository: Path) -> str:
    vendor = repository / "Vendor/rustdesk"
    if not (vendor / ".git").is_dir():
        raise ValueError("missing pinned Vendor/rustdesk checkout")
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=vendor,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    if commit != PINNED_RUSTDESK_COMMIT:
        raise ValueError(
            f"RustDesk checkout mismatch: expected={PINNED_RUSTDESK_COMMIT} actual={commit}"
        )
    return subprocess.run(
        ["git", "show", f"{PINNED_RUSTDESK_COMMIT}:src/server/service.rs"],
        cwd=vendor,
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "patch": repository / "CoreBridge/RustDeskPatch/upstream-1.4.9.patch",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "client": repository / "Sources/CoreBridge/HostControlClient.swift",
        "control_state": (
            repository / "Sources/CoreBridge/HostAgentMediaControlState.swift"
        ),
        "media_owner": (
            repository
            / "Sources/RustDeskNative/HostAgentMediaPipelineOwner.swift"
        ),
        "route_owner": (
            repository
            / "Sources/VideoPipeline/HostMediaPipelineRouteOwner.swift"
        ),
        "evidence_owner": (
            repository
            / "Sources/VideoPipeline/HostRecoveryTransitionEvidenceProcessOwner.swift"
        ),
        "evidence_writer": (
            repository
            / "Sources/VideoPipeline/HostRecoveryTransitionEvidence.swift"
        ),
    }
    try:
        sources = {name: read(path) for name, path in paths.items()}
        sources["service"] = pinned_service_source(repository)
        rust_host_abi = integer_constant(
            sources["bridge"], r"const HOST_ABI_VERSION: u32 = (\d+);"
        )
        header_host_abi = integer_constant(
            sources["header"], r"#define RDN_HOST_ABI_VERSION (\d+)u"
        )
        rust_media_abi = integer_constant(
            sources["bridge"], r"const HOST_MEDIA_ABI_VERSION: u32 = (\d+);"
        )
        header_media_abi = integer_constant(
            sources["header"], r"#define RDN_HOST_MEDIA_ABI_VERSION (\d+)u"
        )
    except (
        OSError,
        UnicodeError,
        ValueError,
        subprocess.CalledProcessError,
    ) as error:
        print(json.dumps({
            "schema": SCHEMA,
            "status": "audit-failed",
            "error": str(error),
        }))
        return 1

    patch = sources["patch"]
    native_run = section(
        patch,
        "fn run_native(vs: VideoService)",
        "#[cfg(all(test, feature = \"rdn-native-host\"))]",
    )
    begin_route = section(
        sources["bridge"],
        "pub(crate) fn native_media_begin_route(",
        "pub(crate) fn native_media_record_dequeued",
    )
    media_decoder = section(
        sources["client"],
        "public struct HostMediaControl",
        "public struct HostMediaDiagnostic",
    ) + section(
        sources["client"],
        "var mediaControl: HostMediaControl?",
        "var mediaDiagnostic: HostMediaDiagnostic?",
    )

    evidence = {
        "pinnedMonitorServiceOwnsDisplayChangeDecision": all(
            marker in native_run
            for marker in (
                "let display = display_service::get_display_info(display_idx)",
                "while sp.ok()",
                "display_service::get_display_info(display_idx).as_ref() != Some(&display)",
                "make_display_changed_msg(display_idx, None, VideoSource::Monitor)",
                'bail!("SWITCH")',
            )
        ),
        "displayCodecAndSubscriberRestartShareGenericSwitch": (
            native_run.count('bail!("SWITCH")') >= 3
            and "codec_format != Encoder::negotiated_codec()" in native_run
            and "snapshot.has_subscribes()" in native_run
        ),
        "displayRevisionIsCurrentlyHardCoded": (
            "display_idx as u64,\n+        1,\n+        codec," in native_run
            and "NEXT_DISPLAY_REVISION" not in sources["bridge"]
        ),
        "replacementRoutesOnlyProveFreshGenericEpochs": all(
            marker in begin_route
            for marker in (
                "next_native_media_epoch(&NEXT_CONNECTION_EPOCH)",
                "next_native_media_epoch(&NEXT_CODEC_EPOCH)",
                '"command": "startCapture"',
                '"command": "reconfigure"',
                '"displayRevision": display_revision',
            )
        ),
        "currentControlEnvelopeCarriesNoTypedDisplayProvenance": (
            "public let reason: String?" in media_decoder
            and "displayReconfigureGeneration" not in media_decoder
            and "previousConnectionEpoch" not in media_decoder
            and "previousCodecEpoch" not in media_decoder
            and "previousDisplayRevision" not in media_decoder
        ),
        "controlStateOnlyOrdersGenericRouteIdentity": (
            all(
                marker in sources["control_state"]
                for marker in (
                    "route.connectionEpoch > highestConnectionEpoch",
                    "route.codecEpoch > highestCodecEpoch",
                    "pendingRoute == route",
                    "activeRoute = route",
                )
            )
            and "displayReconfigureGeneration" not in sources["control_state"]
        ),
        "mediaOwnerCannotCompleteDisplayEvidence": (
            "recoveryOwner.reconfigure(route)" in sources["media_owner"]
            and "recordDisplayReconfigureCompleted" not in sources["media_owner"]
            and "acceptDisplayReconfigure" not in sources["media_owner"]
        ),
        "routeOwnerHasExactAsynchronousConvergenceState": all(
            marker in sources["route_owner"]
            for marker in (
                "pendingOperationCount",
                "desiredRoute",
                "activeRoute",
                "current?.generation == callbackGeneration",
            )
        ),
        "writerAlreadyRejectsStaleReplacementEpochs": all(
            marker in sources["evidence_writer"]
            for marker in (
                "case displayReconfigure(",
                "replacementConnectionEpoch > previousConnectionEpoch",
                "replacementCodecEpoch > previousCodecEpoch",
                "let freshRouteConverged = true",
            )
        ),
        "processEvidenceOwnerHasNoDisplayPendingState": (
            "pendingSleepWakeAcceptance" in sources["evidence_owner"]
            and "pendingNetworkPathAcceptance" in sources["evidence_owner"]
            and "pendingDisplayReconfigureAcceptance" not in sources["evidence_owner"]
            and "acceptDisplayReconfigure" not in sources["evidence_owner"]
        ),
        "currentABIVersionsAreSynchronized": (
            rust_host_abi == header_host_abi == 11
            and rust_media_abi == header_media_abi == 1
        ),
    }
    missing = [name for name, present in evidence.items() if not present]

    source_lines = {
        "displayBaseline": line_number(
            patch, "let display = display_service::get_display_info(display_idx)"
        ),
        "codecSwitch": line_number(
            patch, "codec_format != Encoder::negotiated_codec()"
        ),
        "displaySwitch": line_number(
            patch,
            "display_service::get_display_info(display_idx).as_ref() != Some(&display)",
        ),
        "subscriberSwitch": line_number(patch, "snapshot.has_subscribes()"),
        "hardCodedDisplayRevision": line_number(
            patch, "display_idx as u64,\n+        1,\n+        codec,"
        ),
        "freshConnectionEpoch": line_number(
            sources["bridge"],
            "next_native_media_epoch(&NEXT_CONNECTION_EPOCH)",
        ),
        "controlDecoder": line_number(
            sources["client"], "var mediaControl: HostMediaControl?"
        ),
        "genericRouteAdmission": line_number(
            sources["control_state"],
            "route.connectionEpoch > highestConnectionEpoch",
        ),
        "displayWriterValidation": line_number(
            sources["evidence_writer"],
            "replacementConnectionEpoch > previousConnectionEpoch",
        ),
    }

    target_contract = {
        "versioning": {
            "hostControlABI": 12,
            "hostEventEnvelopeSchema": 1,
            "hostMediaABI": 1,
            "rule": (
                "Host ABI bump is required because the event semantics change; "
                "the encoded-packet C structs do not change"
            ),
        },
        "rustAuthority": {
            "acceptedEventType": "mediaDisplayReconfigureStarted",
            "acceptedOnlyAfter": "display-info inequality on the active exact route",
            "generation": "boot-lifetime exact-next nonzero UInt64",
            "displayRevision": "same-display exact-next nonzero UInt64",
            "pendingCardinality": "at most one marker per display route",
        },
        "acceptedPayload": [
            "displayReconfigureGeneration",
            "displayId",
            "previousDisplayRevision",
            "previousConnectionEpoch",
            "previousCodecEpoch",
        ],
        "replacementControlProvenance": {
            "container": "displayReconfigure",
            "requiredOn": ["startCapture", "reconfigure"],
            "fields": [
                "displayReconfigureGeneration",
                "previousDisplayRevision",
                "previousConnectionEpoch",
                "previousCodecEpoch",
            ],
            "mustMatchAcceptedMarkerExactly": True,
            "replacementDisplayRevisionMustEqualPreviousPlusOne": True,
            "replacementConnectionAndCodecEpochsMustStrictlyIncrease": True,
        },
        "swiftCompletion": {
            "acceptedAt": "after strict decoding and exact pending-marker admission",
            "completedAt": (
                "only after the matching replacement route is both desired and active "
                "with zero pending route-owner operations"
            ),
            "writerCorrelation": "existing displayReconfigure schema v1",
            "observationOnly": True,
        },
        "lifecycle": {
            "duplicateOrMismatchedMarker": "reject without writing",
            "genericCodecSubscriberOrRetryRoute": "never infer display recovery",
            "routeFailureOrReplacementStop": "discard pending marker without writing",
            "teardown": "close admission, drain accepted clock/write, then release writer",
            "generationOrRevisionExhaustion": "fail closed without wrapping",
        },
        "forbiddenInference": [
            "generic SWITCH",
            "fresh connectionEpoch/codecEpoch alone",
            "reconfigure drop count",
            "stopCapture/startCapture adjacency",
            "route absence or disconnect",
        ],
    }

    document = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "status": "abi-checkpoint-required" if not missing else "contract-drift",
        "pinnedRustDeskCommit": PINNED_RUSTDESK_COMMIT,
        "implementation": {
            "hostControlABI": rust_host_abi,
            "hostEventEnvelopeSchema": 1,
            "hostMediaABI": rust_media_abi,
            "evidence": evidence,
            "sourceLines": source_lines,
        },
        "targetContract": target_contract,
        "missingEvidence": missing,
        "remainingBoundary": {
            "sharedHostABIImplementationRequiresNextCheckpoint": True,
            "displayEvidenceCallbackRemainsUnimplemented": True,
            "recoveryManifestValidatorRemainsUnimplemented": True,
            "installedMacDisplayTransitionStillRequired": True,
            "postTransitionTenMinute1080p30RunStillRequired": True,
            "noSection15_2ItemSevenPassIsClaimed": True,
        },
    }
    print(json.dumps(document, sort_keys=True))
    return 0 if not missing and all(source_lines.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
