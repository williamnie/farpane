#!/usr/bin/env python3
"""Audit H6.3e3 Native Host file-mutation connection dispatch."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-connection-mutation-dispatch-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "architecture": repository / "docs/architecture.md",
        "bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "vendor_bridge": repository / "Vendor/rustdesk/src/rdn_host_bridge.rs",
        "owner": repository / "CoreBridge/RustDeskPatch/rdn_host_file_transfer.rs",
        "vendor_owner": repository / "Vendor/rustdesk/src/rdn_host_file_transfer.rs",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "patch": repository
        / "CoreBridge/RustDeskPatch/h6-file-transfer-mutation-dispatch.patch",
        "bootstrap": repository / "Scripts/bootstrap-rustdesk-core.sh",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository
        / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
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
    architecture = sources["architecture"]
    bridge = sources["bridge"]
    owner = sources["owner"]
    connection = sources["connection"]
    patch = sources["patch"]
    bootstrap = sources["bootstrap"]
    product = sources["app"] + sources["agent"]

    file_action = connection.find("Some(message::Union::FileAction(fa))")
    file_scope = connection.find("let mut handle_fa = self.file_transfer.is_some()", file_action)
    scope_gate = connection.find("if handle_fa {", file_scope)
    dispatch = connection.find("send_native_host_file_mutation_response", scope_gate)
    write_job = connection.find("self.send_fs(ipc::FS::NewWrite", scope_gate)

    evidence = {
        "designRecordsH63e3Boundary": all(
            marker in design
            for marker in (
                "H6.3e3 Native Host connection mutation dispatch",
                "host-file-transfer-native-write-job-lifecycle",
            )
        ),
        "ownerIsSharedOnlyAcrossBoundHostLifetime": all(
            marker in bridge
            for marker in (
                "file_service_owner: Option<Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>>",
                "broker.file_service_owner = host.file_service_owner.clone();",
                "broker.file_service_owner = None;",
            )
        ),
        "dispatchRequiresBoundHostAndAdmittedOwner": all(
            marker in bridge
            for marker in (
                "pub(crate) fn native_host_dispatch_file_mutation",
                "if broker.binding.is_none()",
                "HOST_INSTANCE_LIVE.load(Ordering::Acquire)",
                "let Some(owner) = broker.file_service_owner.as_deref()",
                "NativeHostFileMutationOutcome::Unavailable",
                "NativeHostFileMutationOutcome::NotNativeHost",
            )
        ),
        "adapterRoutesOnlySafeOwnerMutations": all(
            marker in bridge
            for marker in (
                "NativeHostFileMutation::CreateDirectory",
                "owner.create_directory(Path::new(path))",
                "NativeHostFileMutation::RemoveFile",
                "owner.remove_file(Path::new(path))",
                "NativeHostFileMutation::RemoveDirectory",
                "owner.remove_directory(Path::new(path), recursive)",
                "NativeHostFileMutation::Rename",
                "owner.rename_entry(Path::new(path), &destination)",
            )
        ),
        "renameIsSameParentSingleComponentNoReplace": all(
            marker in bridge + owner
            for marker in (
                "let Component::Normal(new_name) = components.next()?",
                "if components.next().is_some()",
                "Path::new(path).parent().map(|parent| parent.join(new_name))",
                "libc::RENAME_EXCL",
            )
        ),
        "recursiveRemoveStillFailsBeforeMutation": all(
            marker in owner
            for marker in (
                "if recursive {",
                "NativeFileTransferRootError::RecursiveRemovalUnsupported",
            )
        ),
        "connectionDispatchOccursInsideDedicatedFileScope": (
            file_action >= 0
            and file_scope > file_action
            and scope_gate > file_scope
            and dispatch > scope_gate
            and write_job > scope_gate
        ),
        "allFourMutationActionsUseNativeDispatch": all(
            marker in connection
            for marker in (
                "NativeHostFileMutation::RemoveDirectory",
                "NativeHostFileMutation::RemoveFile",
                "NativeHostFileMutation::CreateDirectory",
                "NativeHostFileMutation::Rename",
            )
        ),
        "remoteResponsesAreFixedAndPathFree": all(
            marker in connection
            for marker in (
                '"native-file-operation-rejected"',
                '"native-file-operation-unavailable"',
                "NativeHostFileMutationOutcome::Succeeded => Some(fs::new_done(id, file_num))",
                "NativeHostFileMutationOutcome::Rejected => Some(fs::new_error(",
                "NativeHostFileMutationOutcome::Unavailable => Some(fs::new_error(",
            )
        ),
        "nonNativeBuildRetainsLegacyCMFallback": (
            connection.count("let handled_by_native_host = false;") >= 4
            and connection.count("if !handled_by_native_host {") >= 4
            and all(
                marker in connection
                for marker in (
                    "self.send_fs(ipc::FS::RemoveDir",
                    "self.send_fs(ipc::FS::RemoveFile",
                    "self.send_fs(ipc::FS::CreateDir",
                    "self.send_fs(ipc::FS::Rename",
                )
            )
        ),
        "nativeWriteLifecycleIncludesVerifiedSingleFileResume": all(
            marker in connection + bridge
            for marker in (
                "native_host_write_jobs: Vec<crate::rdn_host_bridge::NativeHostWriteJob>",
                "begin_native_host_write_job",
                "write_native_host_file_block",
                "finish_native_host_write_job",
                "NativeHostWriteJobError::ResumeUnsupported",
                "confirm_native_host_file_digest",
                "file_transfer_send_confirm_request::Union::OffsetBlk(offset)",
                "self.send_fs(ipc::FS::NewWrite",
            )
        ),
        "focusedRustTestCoversMutationAndLifecycleOutcomes": all(
            marker in bridge
            for marker in (
                "fn native_host_file_mutation_adapter_is_relative_bounded_and_no_replace",
                'new_name: "../escape.txt"',
                "recursive: true",
                "NativeHostFileMutationOutcome::Succeeded",
                "NativeHostFileMutationOutcome::Rejected",
                "NativeHostFileMutationOutcome::Unavailable",
            )
        ),
        "canonicalPatchIsRegisteredAndReplayChecked": all(
            marker in patch + bootstrap
            for marker in (
                "h6-file-transfer-mutation-dispatch.patch",
                'apply --check --reverse "$file_transfer_mutation_patch_file"',
                "send_native_host_file_mutation_response",
            )
        ),
        "canonicalHostSourcesMatchVendorCheckout": (
            bridge == sources["vendor_bridge"]
            and owner == sources["vendor_owner"]
        ),
        "productCallersRemainDisabled": (
            "farpane.host.fileTransfer.enabled" in product and "return .disabled" in product
            and "farpane.host.fileTransfer.enabled" in product and "return .disabled" in product
        ),
        "architectureRecordsMutationOnlyBoundary": all(
            marker in architecture
            for marker in (
                "Native Host mutation dispatch",
                "Native Host new-file write jobs",
                "single-file resume",
                "App/Agent",
            )
        ),
    }
    source_lines = {
        "designMilestone": line_number(
            design, "H6.3e3 Native Host connection mutation dispatch"
        ),
        "mutationEnum": line_number(bridge, "pub(crate) enum NativeHostFileMutation"),
        "boundDispatch": line_number(
            bridge, "pub(crate) fn native_host_dispatch_file_mutation"
        ),
        "ownerBind": line_number(
            bridge, "broker.file_service_owner = host.file_service_owner.clone();"
        ),
        "ownerUnbind": line_number(bridge, "broker.file_service_owner = None;"),
        "connectionResponse": line_number(
            connection, "fn native_host_file_mutation_response"
        ),
        "connectionDispatch": line_number(
            connection, "async fn send_native_host_file_mutation_response"
        ),
        "focusedTest": line_number(
            bridge,
            "fn native_host_file_mutation_adapter_is_relative_bounded_and_no_replace",
        ),
        "canonicalPatch": line_number(
            patch, "NATIVE_HOST_FILE_OPERATION_REJECTED"
        ),
    }
    missing = [name for name, present in evidence.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "native-file-mutations-dispatched-write-jobs-off"
        if not missing and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-connection-mutation-dispatch",
        "status": status,
        "evidence": evidence,
        "sourceLines": source_lines,
        "missingEvidence": missing,
        "missingSourceLines": missing_lines,
        "claims": {
            "safeMutationConnectionDispatchImplemented": True,
            "recursiveRemovalImplemented": False,
            "nativeNewFileWriteLifecycleImplemented": True,
            "nativeResumeDigestLifecycleImplemented": True,
            "productFileTransferEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": "host-file-transfer-native-existing-target-decision-lifecycle",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "native-file-mutations-dispatched-write-jobs-off" else 1


if __name__ == "__main__":
    raise SystemExit(main())
