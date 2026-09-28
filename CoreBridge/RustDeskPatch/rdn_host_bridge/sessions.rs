#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct NativeSessionCapabilities {
    control_keyboard_mouse: bool,
    clipboard: NativeClipboardPolicy,
    system_audio: bool,
}

impl NativeSessionCapabilities {
    pub(crate) fn new(control_keyboard_mouse: bool, clipboard: bool, system_audio: bool) -> Self {
        Self::with_clipboard_policy(
            control_keyboard_mouse,
            NativeClipboardPolicy::bidirectional(clipboard),
            system_audio,
        )
    }

    pub(crate) fn with_clipboard_policy(
        control_keyboard_mouse: bool,
        clipboard: NativeClipboardPolicy,
        system_audio: bool,
    ) -> Self {
        Self {
            control_keyboard_mouse,
            clipboard,
            system_audio,
        }
    }

    fn names(self) -> Vec<&'static str> {
        let mut names = vec!["viewDisplay"];
        if self.control_keyboard_mouse {
            names.push("controlKeyboardMouse");
        }
        if self.clipboard.remote_read {
            names.push("readClipboard");
        }
        if self.clipboard.remote_write {
            names.push("writeClipboard");
        }
        if self.system_audio {
            names.push("hearSystemAudio");
        }
        names
    }

    fn is_subset_of(self, other: Self) -> bool {
        (!self.control_keyboard_mouse || other.control_keyboard_mouse)
            && self.clipboard.is_subset_of(other.clipboard)
            && (!self.system_audio || other.system_audio)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeSessionInputUnavailableReason {
    LocalPolicyDisabled,
    RemoteDisabled,
    AccessibilityDenied,
    SessionUnavailable,
}

impl NativeSessionInputUnavailableReason {
    fn name(self) -> &'static str {
        match self {
            Self::LocalPolicyDisabled => "localPolicyDisabled",
            Self::RemoteDisabled => "remoteDisabled",
            Self::AccessibilityDenied => "accessibilityDenied",
            Self::SessionUnavailable => "sessionUnavailable",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeSessionInputAvailability {
    Available,
    Disabled(NativeSessionInputUnavailableReason),
    Limited(NativeSessionInputUnavailableReason),
}

impl NativeSessionInputAvailability {
    pub(crate) fn available() -> Self {
        Self::Available
    }

    pub(crate) fn disabled(reason: NativeSessionInputUnavailableReason) -> Self {
        debug_assert!(matches!(
            reason,
            NativeSessionInputUnavailableReason::LocalPolicyDisabled
                | NativeSessionInputUnavailableReason::RemoteDisabled
        ));
        Self::Disabled(reason)
    }

    pub(crate) fn limited(reason: NativeSessionInputUnavailableReason) -> Self {
        debug_assert!(matches!(
            reason,
            NativeSessionInputUnavailableReason::AccessibilityDenied
                | NativeSessionInputUnavailableReason::SessionUnavailable
        ));
        Self::Limited(reason)
    }

    fn name(self) -> &'static str {
        match self {
            Self::Available => "available",
            Self::Disabled(_) => "disabled",
            Self::Limited(_) => "limited",
        }
    }

    fn reason(self) -> Option<&'static str> {
        match self {
            Self::Available => None,
            Self::Disabled(reason) | Self::Limited(reason) => Some(reason.name()),
        }
    }

    fn is_valid(self, control_keyboard_mouse: bool) -> bool {
        match self {
            Self::Available => control_keyboard_mouse,
            Self::Disabled(
                NativeSessionInputUnavailableReason::LocalPolicyDisabled
                | NativeSessionInputUnavailableReason::RemoteDisabled,
            ) => !control_keyboard_mouse,
            Self::Limited(
                NativeSessionInputUnavailableReason::AccessibilityDenied
                | NativeSessionInputUnavailableReason::SessionUnavailable,
            ) => !control_keyboard_mouse,
            Self::Disabled(_) | Self::Limited(_) => false,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeSessionSnapshot {
    connection_id: String,
    core_connection_id: i32,
    remote_id: String,
    remote_name: String,
    remote_platform: String,
    started_at_ms: u64,
    initial_capabilities: NativeSessionCapabilities,
    active_capabilities: NativeSessionCapabilities,
    input_availability: NativeSessionInputAvailability,
}

impl NativeSessionSnapshot {
    fn event_payload(&self) -> Value {
        json!({
            "connectionId": self.connection_id,
            "remoteId": self.remote_id,
            "remoteName": self.remote_name,
            "remotePlatform": self.remote_platform,
            "remoteMetadataTrust": "untrusted",
            "startedAt": self.started_at_ms,
            "initialCapabilities": self.initial_capabilities.names(),
            "activeCapabilities": self.active_capabilities.names(),
            "inputAvailability": self.input_availability.name(),
            "inputUnavailableReason": self.input_availability.reason(),
        })
    }
}

struct NativeActiveSession {
    snapshot: NativeSessionSnapshot,
    command_sender: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
    disconnect_requested: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeSessionStartResult {
    Accepted,
    Existing,
    Busy,
    Invalid,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeSessionCommand {
    DisableInput,
    DisableClipboardRead,
    DisableClipboardWrite,
    DisableClipboard,
    DisableAudio,
    Disconnect,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeSessionCommandResult {
    Queued,
    NoChange,
    NotFound,
    Stale,
    Unavailable,
}

#[derive(Default)]
struct NativeSessionBroker {
    active: Option<NativeActiveSession>,
}

impl NativeSessionBroker {
    fn begin(&mut self, session: NativeActiveSession) -> NativeSessionStartResult {
        if !session
            .snapshot
            .active_capabilities
            .is_subset_of(session.snapshot.initial_capabilities)
            || !session
                .snapshot
                .input_availability
                .is_valid(session.snapshot.active_capabilities.control_keyboard_mouse)
        {
            return NativeSessionStartResult::Invalid;
        }
        if let Some(active) = self.active.as_ref() {
            return if active.snapshot.connection_id == session.snapshot.connection_id {
                if active.snapshot == session.snapshot {
                    NativeSessionStartResult::Existing
                } else {
                    NativeSessionStartResult::Invalid
                }
            } else {
                NativeSessionStartResult::Busy
            };
        }
        self.active = Some(session);
        NativeSessionStartResult::Accepted
    }

    fn update_capabilities(
        &mut self,
        core_connection_id: i32,
        active_capabilities: NativeSessionCapabilities,
        input_availability: NativeSessionInputAvailability,
    ) -> Option<NativeSessionSnapshot> {
        let active = self.active.as_mut()?;
        if active.snapshot.core_connection_id != core_connection_id
            || !active_capabilities.is_subset_of(active.snapshot.initial_capabilities)
            || !input_availability.is_valid(active_capabilities.control_keyboard_mouse)
        {
            return None;
        }
        if active.snapshot.active_capabilities == active_capabilities
            && active.snapshot.input_availability == input_availability
        {
            return None;
        }
        active.snapshot.active_capabilities = active_capabilities;
        active.snapshot.input_availability = input_availability;
        Some(active.snapshot.clone())
    }

    fn command(
        &mut self,
        connection_id: &str,
        command: NativeSessionCommand,
    ) -> NativeSessionCommandResult {
        let Some(active) = self.active.as_mut() else {
            return NativeSessionCommandResult::NotFound;
        };
        if active.snapshot.connection_id != connection_id {
            return NativeSessionCommandResult::Stale;
        }

        let data = match command {
            NativeSessionCommand::DisableInput => {
                if !active.snapshot.active_capabilities.control_keyboard_mouse {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "keyboard".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::DisableClipboard => {
                if !active.snapshot.active_capabilities.clipboard.any_enabled() {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::DisableClipboardRead => {
                if !active
                    .snapshot
                    .active_capabilities
                    .clipboard
                    .allows_remote_read()
                {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard-read".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::DisableClipboardWrite => {
                if !active
                    .snapshot
                    .active_capabilities
                    .clipboard
                    .allows_remote_write()
                {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "clipboard-write".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::DisableAudio => {
                if !active.snapshot.active_capabilities.system_audio {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::SwitchPermission {
                    name: "audio".to_owned(),
                    enabled: false,
                }
            }
            NativeSessionCommand::Disconnect => {
                if active.disconnect_requested {
                    return NativeSessionCommandResult::NoChange;
                }
                crate::ipc::Data::Close
            }
        };
        if active.command_sender.send(data).is_err() {
            return NativeSessionCommandResult::Unavailable;
        }
        if command == NativeSessionCommand::Disconnect {
            active.disconnect_requested = true;
        }
        NativeSessionCommandResult::Queued
    }

    fn end(&mut self, core_connection_id: i32) -> Option<NativeActiveSession> {
        let matches = self
            .active
            .as_ref()
            .map(|active| active.snapshot.core_connection_id == core_connection_id)
            .unwrap_or(false);
        matches.then(|| self.active.take()).flatten()
    }

    fn reset(&mut self) -> Option<NativeActiveSession> {
        self.active.take()
    }

    fn snapshot(&self) -> Option<NativeSessionSnapshot> {
        self.active.as_ref().map(|active| active.snapshot.clone())
    }
}
