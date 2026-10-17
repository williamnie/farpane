use super::viewer::State;
use crate::{client::QualityStatus, ui_session_interface::InvokeUiSession};
use base::message_proto::*;
use farpane_protocol::{Display, EventKind, Phase};
use hbb_common::rendezvous_proto::ConnType;
use std::sync::{atomic::Ordering, Arc};

#[derive(Clone, Default)]
pub struct NativeUi(pub Arc<State>);
impl NativeUi {
    fn unavailable(&self, name: &str) {
        self.0.emit(EventKind::Log {
            level: "info".into(),
            message: format!("当前原生 Viewer 不支持：{name}"),
        });
    }
    fn displays(&self, values: &[DisplayInfo], selected: Option<i32>) {
        if values.len() > 64 || values.iter().any(|d| d.width <= 0 || d.height <= 0) {
            self.0.fail("Invalid remote display catalog");
            return;
        }
        let catalog: Vec<_> = values
            .iter()
            .enumerate()
            .map(|(i, d)| Display {
                index: i as i32,
                x: d.x,
                y: d.y,
                width: d.width as u32,
                height: d.height as u32,
                name: d
                    .name
                    .chars()
                    .filter(|c| !c.is_control())
                    .take(128)
                    .collect(),
            })
            .collect();
        let selected = selected.unwrap_or(self.0.selected.load(Ordering::Acquire));
        self.0.selected.store(selected, Ordering::Release);
        *self.0.displays.lock().unwrap() = catalog.clone();
        self.0.emit(EventKind::Displays {
            displays: catalog,
            selected,
        });
    }
}
impl InvokeUiSession for NativeUi {
    fn set_cursor_data(&self, cd: CursorData) {
        // Bound JSON cursor payloads below the control packet limit.
        if cd.width <= 0
            || cd.height <= 0
            || cd.width > 96
            || cd.height > 96
            || cd.hotx < 0
            || cd.hoty < 0
            || cd.hotx >= cd.width
            || cd.hoty >= cd.height
            || cd.colors.len() != cd.width as usize * cd.height as usize * 4
        {
            self.set_cursor_id(cd.id.to_string());
            self.unavailable("远端光标形状超过当前范围");
            return;
        }
        self.0.emit(EventKind::Cursor {
            id: cd.id,
            x: 0,
            y: 0,
            width: cd.width as u32,
            height: cd.height as u32,
            hot_x: cd.hotx,
            hot_y: cd.hoty,
            rgba: hbb_common::base64::encode(cd.colors),
            premultiplied: self.0.cursor_premultiplied.load(Ordering::Acquire),
        });
    }
    fn set_cursor_id(&self, id: String) {
        if let Ok(id) = id.parse() {
            self.0.emit(EventKind::Cursor {
                id,
                x: 0,
                y: 0,
                width: 0,
                height: 0,
                hot_x: 0,
                hot_y: 0,
                rgba: String::new(),
                premultiplied: self.0.cursor_premultiplied.load(Ordering::Acquire),
            });
        }
    }
    fn set_cursor_position(&self, cp: CursorPosition) {
        self.0.emit(EventKind::CursorPosition { x: cp.x, y: cp.y });
    }
    fn set_display(&self, _x: i32, _y: i32, _w: i32, _h: i32, _embedded: bool, _scale: f64) {
        /* The authenticated catalog carries geometry. */
    }
    fn switch_display(&self, display: &SwitchDisplay) {
        self.0.selected.store(display.display, Ordering::Release);
        self.0.emit(EventKind::Displays {
            displays: self.0.displays.lock().unwrap().clone(),
            selected: display.display,
        });
    }
    fn set_peer_info(&self, pi: &PeerInfo) {
        let mut name = String::new();
        for c in pi.hostname.chars().filter(|c| !c.is_control()) {
            if name.len() + c.len_utf8() > 128 {
                break;
            }
            name.push(c);
        }
        self.0.emit(EventKind::Peer {
            name: name.trim().into(),
        });
        // Linux cursor capture preserves premultiplied ARGB channel values.
        // macOS exports NSColor components with a separate alpha component.
        self.0
            .cursor_premultiplied
            .store(pi.platform.eq_ignore_ascii_case("linux"), Ordering::Release);
        self.displays(&pi.displays, Some(pi.current_display));
    }
    fn set_displays(&self, displays: &Vec<DisplayInfo>) {
        self.displays(displays, None);
    }
    fn set_platform_additions(&self, _data: &str) { /* No platform extension is advertised. */
    }
    fn on_connected(&self, _kind: ConnType) {
        self.0.auth_challenge.store(0, Ordering::Release);
        self.0.authenticated.store(true, Ordering::Release);
        self.0.emit(EventKind::Permissions(
            self.0.permissions.lock().unwrap().clone(),
        ));
        if self.0.file_only.load(Ordering::Acquire) {
            self.0.phase(Phase::FilesReady, "文件连接已建立");
        } else {
            self.0.phase(Phase::AwaitingFrame, "认证通过，等待第一帧");
        }
    }
    fn update_privacy_mode(&self) { /* This Viewer never changes remote privacy/display modes. */
    }
    fn set_permission(&self, name: &str, value: bool) {
        let mut permissions = self.0.permissions.lock().unwrap();
        match name {
            "keyboard" => {
                permissions.keyboard = value;
                if !value {
                    self.0.release_input.store(true, Ordering::Release);
                }
            }
            "clipboard" => permissions.clipboard = value,
            "audio" => permissions.audio = value,
            "file" => permissions.file = value,
            _ => return,
        }
        let snapshot = permissions.clone();
        drop(permissions);
        if name == "audio" {
            self.0.audio.permit(value);
        }
        if name == "clipboard" && !value {
            super::viewer_clipboard::revoke(&self.0);
        }
        self.0.emit(EventKind::Permissions(snapshot));
    }
    fn close_success(&self) { /* Only the GTK renderer can attest local presentation. */
    }
    fn update_quality_status(&self, qs: QualityStatus) {
        if let Some(delay) = qs.delay {
            self.0.metrics.lock().unwrap().delay_ms = u32::try_from(delay).ok();
            *self.0.delay_at.lock().unwrap() = Some(std::time::Instant::now());
        }
    }
    fn set_connection_type(&self, secured: bool, direct: bool, _stream: &str) {
        self.0.metrics.lock().unwrap().relay = Some(!direct);
        self.0.phase(
            Phase::Authenticating,
            if secured {
                "加密传输已建立，等待认证"
            } else {
                "传输已建立，等待认证"
            },
        );
    }
    fn set_fingerprint(&self, _fingerprint: String) { /* Expose with diagnostics after renderer integration. */
    }
    fn job_error(&self, id: i32, _error: String, _file_num: i32) {
        self.0.emit(EventKind::Transfer {
            job: id,
            name: String::new(),
            done: 0,
            total: 0,
            status: "failed".into(),
            needs_confirmation: false,
        });
    }
    fn job_done(&self, id: i32, _file_num: i32) {
        self.0.emit(EventKind::Transfer {
            job: id,
            name: String::new(),
            done: 0,
            total: 0,
            status: "completed".into(),
            needs_confirmation: false,
        });
    }
    fn clear_all_jobs(&self) { /* No job is automatically restored in read-only mode. */
    }
    fn new_message(&self, _message: String) {
        self.unavailable("聊天");
    }
    fn update_transfer_list(&self) {
        self.unavailable("文件任务列表");
    }
    fn load_last_job(&self, _count: i32, _json: &str, _auto: bool) {
        self.0
            .fail("Viewer tried to restore an unrequested file job");
    }
    fn update_folder_files(
        &self,
        _id: i32,
        _entries: &Vec<FileEntry>,
        _path: String,
        _local: bool,
        _only_count: bool,
    ) {
        self.unavailable("文件目录");
    }
    fn confirm_delete_files(&self, _id: i32, _index: i32, _name: String) {
        self.unavailable("删除文件");
    }
    fn override_file_confirm(
        &self,
        _id: i32,
        _file_num: i32,
        _to: String,
        _upload: bool,
        _same: bool,
    ) {
        self.unavailable("覆盖文件");
    }
    fn update_block_input_state(&self, _on: bool) {
        self.unavailable("屏蔽远端本机输入");
    }
    fn job_progress(&self, id: i32, _file_num: i32, _speed: f64, finished: f64) {
        self.0.emit(EventKind::Transfer {
            job: id,
            name: String::new(),
            done: finished.max(0.0) as u64,
            total: 0,
            status: "transferring".into(),
            needs_confirmation: false,
        });
    }
    fn adapt_size(&self) { /* Actual frame dimensions drive the viewport. */
    }
    fn on_rgba(&self, _display: usize, _rgba: &mut scrap::ImageRgb) {
        self.0.fail("Unexpected legacy Viewer pixel callback");
    }
    fn msgbox(&self, kind: &str, title: &str, text: &str, _link: &str, retry: bool) {
        if kind.contains("input-password") {
            self.0.auth_challenge.store(1, Ordering::Release);
            self.0.phase(
                Phase::PasswordRequired,
                if kind.starts_with("re-") {
                    "密码不正确，请重新输入"
                } else {
                    "请输入远端密码"
                },
            );
        } else if kind.contains("input-2fa") {
            self.0.auth_challenge.store(2, Ordering::Release);
            self.0.emit(EventKind::AuthenticationChallenge {
                two_factor: true,
                insecure: false,
                detail: "请输入远端要求的验证码".into(),
            });
        } else if kind.contains("insecure-connection") {
            self.0.auth_challenge.store(3, Ordering::Release);
            self.0.emit(EventKind::AuthenticationChallenge {
                two_factor: false,
                insecure: true,
                detail: "对端无法建立端到端加密，是否继续此连接？".into(),
            });
        } else if kind.starts_with("wait-remote-accept") {
            self.0.auth_challenge.store(0, Ordering::Release);
            self.0.phase(Phase::Authenticating, "等待远端允许连接…");
        } else if kind == "success" {
            self.0.phase(Phase::AwaitingFrame, "认证通过，等待第一帧");
        } else if kind.contains("error") || kind.contains("hasclose") {
            let message = format!("{title} {text}").to_ascii_lowercase();
            let detail = if message.contains("timeout") || message.contains("timed out") {
                "远程连接超时"
            } else if message.contains("offline") || message.contains("not exist") {
                "远端设备离线或 ID 不存在"
            } else if message.contains("key") {
                "服务器或远端身份校验失败"
            } else {
                "远程连接失败或已关闭"
            };
            self.0.emit(EventKind::ConnectionEnded { retryable: retry });
            self.0.phase(Phase::Failed, detail);
        }
    }
    fn cancel_msgbox(&self, _tag: &str) {}
    fn switch_back(&self, _id: &str) {
        self.unavailable("交换控制方向");
    }
    fn portable_service_running(&self, _running: bool) {
        self.unavailable("远端提权");
    }
    fn on_voice_call_started(&self) {
        self.unavailable("语音通话");
    }
    fn on_voice_call_closed(&self, _reason: &str) {
        self.unavailable("语音通话");
    }
    fn on_voice_call_waiting(&self) {
        self.unavailable("语音通话");
    }
    fn on_voice_call_incoming(&self) {
        self.unavailable("语音通话");
    }
    fn get_rgba(&self, _display: usize) -> *const u8 {
        std::ptr::null()
    }
    fn next_rgba(&self, _display: usize) {}
    fn set_multiple_windows_session(&self, _sessions: Vec<WindowsSession>) {
        self.unavailable("远端多用户会话选择");
    }
    fn set_current_display(&self, index: i32) {
        self.0.selected.store(index, Ordering::Release);
    }
    fn update_record_status(&self, start: bool) {
        if start {
            self.0.fail("Viewer recording is not enabled");
        }
    }
    fn printer_request(&self, _id: i32, _path: String) {
        self.unavailable("打印");
    }
    fn handle_screenshot_resp(&self, _id: String, _message: String) {
        self.unavailable("远端截图命令");
    }
    fn handle_terminal_response(&self, _response: TerminalResponse) {
        self.unavailable("远端终端");
    }
}
