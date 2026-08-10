#!/usr/bin/env python3
"""Audit H6.3b file-transfer trust boundaries without enabling the product."""

from __future__ import annotations

import json
from pathlib import Path


SCHEMA = "farpane-host-file-transfer-security-boundary-audit"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(source: str, needle: str) -> int:
    offset = source.find(needle)
    return 0 if offset < 0 else source.count("\n", 0, offset) + 1


def main() -> int:
    repository = Path(__file__).resolve().parent.parent
    paths = {
        "design": repository / "docs/host-mode-design.md",
        "header": repository / "CoreBridge/include/rustdesk_native.h",
        "host_bridge": repository / "CoreBridge/RustDeskPatch/rdn_host_bridge.rs",
        "host_control": repository / "Sources/CoreBridge/HostControlClient.swift",
        "app": repository / "Sources/RustDeskNative/RustDeskNativeApp.swift",
        "agent": repository / "Sources/RustDeskNative/HostAgentProcessRuntime.swift",
        "connection": repository / "Vendor/rustdesk/src/server/connection.rs",
        "fs": repository / "Vendor/rustdesk/libs/hbb_common/src/fs.rs",
        "safe_root": repository
        / "CoreBridge/RustDeskPatch/rdn_host_file_transfer.rs",
        "build_core": repository / "Scripts/build-rust-core.sh",
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
    header = sources["header"]
    host_bridge = sources["host_bridge"]
    host_control = sources["host_control"]
    product = sources["app"] + sources["agent"]
    connection = sources["connection"]
    fs = sources["fs"]
    safe_root = sources["safe_root"]
    build_core = sources["build_core"]

    established = {
        "designRequiresUntrustedFileInputBoundary": all(
            marker in design
            for marker in (
                "远端文件名/UTI/payload 视为不可信输入",
                "H6.3b Host file-transfer security boundary audit",
            )
        ),
        "filePermissionDefaultsOffAtHostABI": all(
            marker in (header + host_control + host_bridge)
            for marker in (
                "bool enable_file_transfer;",
                "fileTransferEnabled: Bool = false",
                "file_transfer_enabled: (*options).enable_file_transfer",
                "native_host_file_transfer_option(file_transfer_enabled)",
            )
        ),
        "dedicatedLoginChecksPermissionBeforeScope": all(
            marker in connection
            for marker in (
                "Some(login_request::Union::FileTransfer(ft))",
                "keys::OPTION_ENABLE_FILE_TRANSFER",
                'self.send_login_error("No permission of file transfer")',
                "self.file_transfer = Some((ft.dir, ft.show_hidden));",
            )
        ),
        "authorizedScopeAllowsOnlyFileMessages": all(
            marker in connection
            for marker in (
                "AuthConnType::FileTransfer => Self::is_file_transfer_scoped_message(msg)",
                "Some(message::Union::FileAction(_)) | Some(message::Union::FileResponse(_))",
            )
        ),
        "relativeNamesRejectTraversalAbsoluteAndNUL": all(
            marker in fs
            for marker in (
                "fn validate_file_name_no_traversal",
                'bail!("file name contains null bytes")',
                'bail!("path traversal detected in file name")',
                'bail!("absolute path detected in file name")',
                "set_files_rejects_mixed_entries_when_one_is_traversal",
                "path_traversal_e2e_write_rejects_absolute_path",
            )
        ),
        "existingSymlinkComponentsAreRejected": all(
            marker in fs
            for marker in (
                "fn validate_no_symlink_components",
                "std::fs::symlink_metadata(&current)",
                'bail!("symlink path component is not allowed")',
                "path_traversal_e2e_write_rejects_symlink_escape",
            )
        ),
        "unsafeFileListRejectsWholeWriteJob": all(
            marker in fs
            for marker in (
                "fn validate_transfer_file_names",
                "self.set_files(files)?;",
                "set_files_rejects_empty_name_in_multi_file_transfer",
            )
        ),
        "fileBlocksHaveMatchingWireAndDecodedHardLimit": all(
            marker in fs
            for marker in (
                "MAX_FILE_TRANSFER_BLOCK_BYTES: usize = 128 * 1024",
                "validated_file_transfer_block_payload(&block)?",
                "decompress_with_limit(&block.data, MAX_FILE_TRANSFER_BLOCK_BYTES)",
            )
        ),
        "nativeHostHasDescriptorRelativeReceiveRootPrimitive": all(
            marker in safe_root
            for marker in (
                "struct NativeFileTransferRoot",
                "libc::O_DIRECTORY | libc::O_NOFOLLOW",
                "pub(crate) fn create_new_file",
                "pub(crate) fn open_existing_file_for_resume",
                "open_root_descriptor_survives_path_replacement",
            )
        ),
        "nativeHostHasDescriptorRelativeSafeRootMutations": all(
            marker in safe_root
            for marker in (
                "fn create_directory",
                "fn remove_file",
                "fn remove_empty_directory",
                "fn rename_entry",
                "libc::AT_SYMLINK_NOFOLLOW",
                "libc::RENAME_EXCL",
            )
        ),
        "productCallersStillDoNotOptIn": (
            "fileTransferEnabled:" not in product
            and "fileTransferEnabled: true" not in product
        ),
        "releaseOmitsClipboardFilePromiseFeature": (
            "rdn-native-core,rdn-native-host" in build_core
            and "unix-file-copy-paste" not in build_core
        ),
    }

    gaps = {
        "writeOpenHasDocumentedSymlinkTOCTOU": all(
            marker in fs
            for marker in (
                "known TOCTOU window for symlink races",
                "openat(2) / O_NOFOLLOW",
                "File::create(&path).await?",
            )
        ),
        "managementPathsOnlyRejectEmptyAndNUL": all(
            marker in fs
            for marker in (
                "fn validate_fs_path_argument",
                "pub fn remove_file(file: &str)",
                "pub fn create_dir(dir: &str)",
            )
        ) and "allowed_file_transfer_root" not in fs,
        "nativeHostDropsExternalCMReceiver": all(
            marker in connection
            for marker in (
                "if !connection_manager_required()",
                "self.start_cm_ipc_para.take();",
                "fn send_fs(&mut self, data: ipc::FS)",
                "self.send_to_cm(ipc::Data::FS(data));",
            )
        ),
        "receiveAndMutationsStillDependOnCMChannel": all(
            marker in connection
            for marker in (
                "self.send_fs(ipc::FS::NewWrite",
                "self.send_fs(ipc::FS::RemoveDir",
                "self.send_fs(ipc::FS::RemoveFile",
                "self.send_fs(ipc::FS::CreateDir",
                "self.send_fs(ipc::FS::Rename",
            )
        ),
        "nativeFileServiceOwnerCoreIsNotConnected": (
            "NativeHostFileServiceOwner" in safe_root
            and "NativeHostFileServiceOwner" not in connection
            and "native_host_handle_fs" not in connection
            and "native_host_handle_fs" not in host_bridge
        ),
        "noProductDestinationOrOverwriteUXExists": (
            "fileTransferEnabled:" not in product
            and "HostFileTransfer" not in product
        ),
    }

    source_lines = {
        "designMilestone": line_number(
            design, "H6.3b Host file-transfer security boundary audit"
        ),
        "permissionDefault": line_number(
            host_control, "fileTransferEnabled: Bool = false"
        ),
        "dedicatedLogin": line_number(
            connection, "Some(login_request::Union::FileTransfer(ft))"
        ),
        "scopeGate": line_number(
            connection,
            "AuthConnType::FileTransfer => Self::is_file_transfer_scoped_message(msg)",
        ),
        "nameValidation": line_number(fs, "fn validate_file_name_no_traversal"),
        "symlinkValidation": line_number(fs, "fn validate_no_symlink_components"),
        "boundedDecompression": line_number(
            fs,
            "decompress_with_limit(&block.data, MAX_FILE_TRANSFER_BLOCK_BYTES)",
        ),
        "safeReceiveRoot": line_number(safe_root, "struct NativeFileTransferRoot"),
        "safeRootMutations": line_number(
            safe_root, "pub(crate) fn create_directory"
        ),
        "toctouAcknowledgement": line_number(
            fs, "known TOCTOU window for symlink races"
        ),
        "nativeCMDrop": line_number(connection, "self.start_cm_ipc_para.take();"),
        "receiveCMDispatch": line_number(
            connection, "self.send_fs(ipc::FS::NewWrite"
        ),
    }
    missing_established = [
        name for name, present in established.items() if not present
    ]
    missing_expected_gaps = [name for name, present in gaps.items() if not present]
    missing_lines = [name for name, number in source_lines.items() if number <= 0]
    status = (
        "audited-not-product-ready"
        if not missing_established and not missing_expected_gaps and not missing_lines
        else "audit-failed"
    )
    result = {
        "schema": SCHEMA,
        "schemaVersion": 1,
        "coverageScope": "h6-host-file-transfer-security-and-runtime-boundary",
        "status": status,
        "establishedGuards": established,
        "openGaps": gaps,
        "sourceLines": source_lines,
        "missingEstablishedGuards": missing_established,
        "missingExpectedGaps": missing_expected_gaps,
        "missingSourceLines": missing_lines,
        "claims": {
            "productEnablementSafe": False,
            "nativeHostFileTransferFunctional": False,
            "pathTraversalGuardPresent": True,
            "symlinkRaceClosed": False,
            "compressedPayloadBounded": True,
            "safeReceiveRootPrimitiveImplemented": True,
            "safeRootMutationsImplemented": True,
            "nativeHostFileServiceOwnerCoreImplemented": True,
            "clipboardFilePromiseEnabled": False,
            "twoMacAcceptanceComplete": False,
        },
        "nextImplementationBoundary": "host-file-transfer-connection-mutation-dispatch",
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0 if status == "audited-not-product-ready" else 1


if __name__ == "__main__":
    raise SystemExit(main())
