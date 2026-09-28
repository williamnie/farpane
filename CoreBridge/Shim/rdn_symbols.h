// 单一符号清单同时生成字段和动态加载检查，函数类型来自公共 ABI 头文件。

#define RDN_VIEWER_SYMBOLS(X) \
    X(client_create, rdn_client_create) \
    X(client_destroy, rdn_client_destroy) \
    X(client_connect, rdn_client_connect) \
    X(client_disconnect, rdn_client_disconnect) \
    X(client_request_keyframe, rdn_client_request_keyframe) \
    X(client_select_display, rdn_client_select_display) \
    X(client_send_pointer, rdn_client_send_pointer) \
    X(client_send_key, rdn_client_send_key) \
    X(client_send_text, rdn_client_send_text) \
    X(client_send_clipboard_text, rdn_client_send_clipboard_text) \
    X(client_send_clipboard_rich_text, rdn_client_send_clipboard_rich_text) \
    X(client_send_clipboard_image, rdn_client_send_clipboard_image) \
    X(client_file_transfer_cancel, rdn_client_file_transfer_cancel) \
    X(client_file_transfer_list_root, rdn_client_file_transfer_list_root) \
    X(client_file_transfer_manifest_root, rdn_client_file_transfer_manifest_root) \
    X(client_file_transfer_download_start, rdn_client_file_transfer_download_start) \
    X(client_file_transfer_upload_start, rdn_client_file_transfer_upload_start) \
    X(abi_version, rdn_core_abi_version) \
    X(upstream_commit, rdn_core_upstream_commit)

#define RDN_HOST_SYMBOLS(X) \
    X(host_abi_version, rdn_host_abi_version) \
    X(host_upstream_commit, rdn_host_upstream_commit) \
    X(host_set_config_root, rdn_host_set_config_root) \
    X(host_create, rdn_host_create) \
    X(host_start, rdn_host_start) \
    X(host_stop, rdn_host_stop) \
    X(host_recover_network_path, rdn_host_recover_network_path) \
    X(host_begin_sleep, rdn_host_begin_sleep) \
    X(host_finish_sleep, rdn_host_finish_sleep) \
    X(host_resume_after_wake, rdn_host_resume_after_wake) \
    X(host_command, rdn_host_command) \
    X(host_set_permanent_password, rdn_host_set_permanent_password) \
    X(host_copy_snapshot, rdn_host_copy_snapshot) \
    X(host_free_bytes, rdn_host_free_bytes) \
    X(host_destroy, rdn_host_destroy) \
    X(host_media_abi_version, rdn_host_media_abi_version) \
    X(host_media_set_capabilities, rdn_host_media_set_capabilities) \
    X(host_media_submit_access_unit, rdn_host_media_submit_access_unit) \
    X(host_media_report_encoder_state, rdn_host_media_report_encoder_state)
