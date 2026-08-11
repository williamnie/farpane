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


def ordered(source: str, *markers: str) -> bool:
    offset = 0
    for marker in markers:
        offset = source.find(marker, offset)
        if offset < 0:
            return False
        offset += len(marker)
    return True


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
        "display_evidence_owner": (
            repository
            / "Sources/VideoPipeline/HostDisplayReconfigureEvidenceOwner.swift"
        ),
        "evidence_writer": (
            repository
            / "Sources/VideoPipeline/HostRecoveryTransitionEvidence.swift"
        ),
        "host_process": (
            repository / "Sources/RustDeskNative/HostAgentProcess.swift"
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
    evidence = {
        "pinnedMonitorEmitsMarkerOnlyForDisplayInequality": (
            ordered(
                native_run,
                "let display = display_service::get_display_info(display_idx)",
                "while sp.ok()",
                "display_service::get_display_info(display_idx).as_ref() != Some(&display)",
                "native_media_mark_display_reconfigure(&route.0)",
                "make_display_changed_msg(display_idx, None, VideoSource::Monitor)",
                'bail!("SWITCH")',
            )
            and native_run.count("native_media_mark_display_reconfigure") == 1
        ),
        "rustMarkerRequiresExactActiveRouteAndRejectsDuplicates": all(
            marker in sources["bridge"]
            for marker in (
                "pub(crate) fn native_media_mark_display_reconfigure(",
                "current.connection_epoch != route.connection_epoch",
                "current.codec_epoch != route.codec_epoch",
                "current.display_revision != route.display_revision",
                "pending_display_reconfigures",
                "route.display_revision == u64::MAX",
                "NEXT_DISPLAY_RECONFIGURE_GENERATION",
                '"mediaDisplayReconfigureStarted"',
            )
        ),
        "replacementConsumesTypedProvenanceExactlyOnce": all(
            marker in begin_route
            for marker in (
                "broker.pending_display_reconfigures.remove(&display_id)",
                ".previous_display_revision",
                ".checked_add(1)",
                "display_revisions",
                ".unwrap_or(1)",
                'start_payload["displayReconfigure"] = provenance.payload()',
                'reconfigure_payload["displayReconfigure"] = provenance.payload()',
            )
        ),
        "swiftStrictlyDecodesMarkerAndReplacementProvenance": all(
            marker in sources["client"]
            for marker in (
                'guard eventType == "mediaDisplayReconfigureStarted"',
                '"displayReconfigureGeneration"',
                'if let rawProvenance = payload["displayReconfigure"]',
                "previousDisplayRevision < UInt64.max",
                "displayRevision == previousDisplayRevision + 1",
                "connectionEpoch > previousConnectionEpoch",
                "codecEpoch > previousCodecEpoch",
                "CFGetTypeID(number) != CFBooleanGetTypeID()",
            )
        ),
        "controlStateCorrelatesStartAndReconfigureExactly": all(
            marker in sources["control_state"]
            for marker in (
                "pendingDisplayReconfigure = control.displayReconfigure",
                "pendingDisplayReconfigure == control.displayReconfigure",
                "return .displayProvenanceMismatch",
                "pendingDisplayReconfigure = nil",
            )
        ),
        "productOwnerConnectsMarkerControlsAndExactRouteConvergence": all(
            marker in sources["media_owner"]
            for marker in (
                'case "mediaDisplayReconfigureStarted":',
                "displayEvidenceOwner.accept(",
                "displayEvidenceOwner.observeStart(",
                "displayEvidenceOwner.observeReconfigure(",
                "snapshot.pendingOperationCount == 0",
                "snapshot.desiredRoute == route",
                "snapshot.activeRoute == route",
                "displayEvidenceOwner.cancelAndWait()",
            )
        ),
        "displayStateMachineFailsClosedAndPollsBoundedly": all(
            marker in sources["display_evidence_owner"]
            for marker in (
                "HostMediaPipelineRecoveryPollingOwner.makeProduct(",
                "acceptDisplayReconfigure(",
                "observeStart(",
                "observeReconfigure(",
                "recordDisplayReconfigureCompleted(",
                "discardDisplayReconfigure(",
                "pollingOwner.cancelAndWait()",
            )
        ),
        "processEvidenceRequiresExactReplacementAndDrains": all(
            marker in sources["evidence_owner"]
            for marker in (
                "pendingDisplayReconfigureAcceptance",
                "acceptDisplayReconfigure(",
                "recordDisplayReconfigureCompleted(",
                "replacementDisplayRevision == previousDisplayRevision + 1",
                "replacementConnectionEpoch > previousConnectionEpoch",
                "replacementCodecEpoch > previousCodecEpoch",
                "displayReconfigureAcceptanceInFlight || recordInFlight",
            )
        ),
        "processTeardownDrainsProducerBeforeEvidenceWriter": ordered(
            sources["host_process"],
            "mediaPipelineOwner.cancelAndWait()",
            "recoveryEvidenceOwner.cancelAndWait()",
        ),
        "currentABIVersionsAreSynchronized": (
            rust_host_abi == header_host_abi == 19
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
        "displayMarker": line_number(
            patch, "native_media_mark_display_reconfigure(&route.0)"
        ),
        "freshConnectionEpoch": line_number(
            sources["bridge"],
            "next_native_media_epoch(&NEXT_CONNECTION_EPOCH)",
        ),
        "controlDecoder": line_number(
            sources["client"], "var mediaControl: HostMediaControl?"
        ),
        "controlProvenanceAdmission": line_number(
            sources["control_state"],
            "pendingDisplayReconfigure == control.displayReconfigure",
        ),
        "displayEvidenceCompletion": line_number(
            sources["evidence_owner"],
            "recordDisplayReconfigureCompleted(",
        ),
    }

    target_contract = {
        "versioning": {
            "hostControlABI": 19,
            "hostEventEnvelopeSchema": 1,
            "hostMediaABI": 1,
            "rule": (
                "Host ABI v13 introduced the event semantics; current v16 retains "
                "them while the encoded-packet C structs remain unchanged"
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
        "status": "display-callback-implemented" if not missing else "contract-drift",
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
