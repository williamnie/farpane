#[derive(Clone, Debug, Eq, PartialEq)]
struct NativeApprovalRequest {
    connection_id: String,
    core_connection_id: i32,
    remote_id: String,
    remote_name: String,
    remote_platform: String,
    requested_at_ms: u64,
    expires_at_ms: u64,
    requested_capabilities: Vec<String>,
}

impl NativeApprovalRequest {
    fn event_payload(&self) -> Value {
        json!({
            "connectionId": self.connection_id,
            "remoteId": self.remote_id,
            "remoteName": self.remote_name,
            "remotePlatform": self.remote_platform,
            "remoteMetadataTrust": "untrusted",
            "requestedAt": self.requested_at_ms,
            "expiresAt": self.expires_at_ms,
            "requestedCapabilities": self.requested_capabilities,
            "transport": "unknown",
            "authenticationMethod": "localApproval",
            "riskAlerts": [],
        })
    }
}

struct PendingNativeApproval {
    request: NativeApprovalRequest,
    deadline: Instant,
    decision_sender: tokio::sync::mpsc::UnboundedSender<crate::ipc::Data>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NativeApprovalFinalStatus {
    Approved,
    Rejected,
    Expired,
    Cancelled,
}

impl NativeApprovalFinalStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Approved => "approved",
            Self::Rejected => "rejected",
            Self::Expired => "expired",
            Self::Cancelled => "cancelled",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeApprovalStartResult {
    Accepted,
    Existing,
    Busy,
    Finalized,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeApprovalDecision {
    Approve,
    Reject,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum NativeApprovalResolveResult {
    Approved,
    Rejected,
    Expired,
    AlreadyFinal,
    NotFound,
}

struct NativeApprovalCompletion {
    pending: PendingNativeApproval,
    status: NativeApprovalFinalStatus,
}

#[derive(Default)]
struct NativeApprovalBroker {
    pending: Option<PendingNativeApproval>,
    last_finalized: Option<(String, NativeApprovalFinalStatus)>,
}

impl NativeApprovalBroker {
    fn begin(&mut self, pending: PendingNativeApproval) -> NativeApprovalStartResult {
        if self
            .last_finalized
            .as_ref()
            .map(|(connection_id, _)| connection_id == &pending.request.connection_id)
            .unwrap_or(false)
        {
            return NativeApprovalStartResult::Finalized;
        }
        if let Some(current) = self.pending.as_ref() {
            return if current.request.connection_id == pending.request.connection_id {
                NativeApprovalStartResult::Existing
            } else {
                NativeApprovalStartResult::Busy
            };
        }
        self.pending = Some(pending);
        NativeApprovalStartResult::Accepted
    }

    fn resolve(
        &mut self,
        connection_id: &str,
        decision: NativeApprovalDecision,
        now: Instant,
    ) -> (
        NativeApprovalResolveResult,
        Option<NativeApprovalCompletion>,
    ) {
        let Some(pending) = self.pending.as_ref() else {
            let already_final = self
                .last_finalized
                .as_ref()
                .map(|(finalized_id, _)| finalized_id == connection_id)
                .unwrap_or(false);
            return (
                if already_final {
                    NativeApprovalResolveResult::AlreadyFinal
                } else {
                    NativeApprovalResolveResult::NotFound
                },
                None,
            );
        };
        if pending.request.connection_id != connection_id {
            return (NativeApprovalResolveResult::NotFound, None);
        }

        let (status, result) = if now >= pending.deadline {
            (
                NativeApprovalFinalStatus::Expired,
                NativeApprovalResolveResult::Expired,
            )
        } else {
            match decision {
                NativeApprovalDecision::Approve => (
                    NativeApprovalFinalStatus::Approved,
                    NativeApprovalResolveResult::Approved,
                ),
                NativeApprovalDecision::Reject => (
                    NativeApprovalFinalStatus::Rejected,
                    NativeApprovalResolveResult::Rejected,
                ),
            }
        };
        let Some(pending) = self.pending.take() else {
            return (NativeApprovalResolveResult::NotFound, None);
        };
        self.last_finalized = Some((pending.request.connection_id.clone(), status));
        (result, Some(NativeApprovalCompletion { pending, status }))
    }

    fn expire(&mut self, connection_id: &str, now: Instant) -> Option<NativeApprovalCompletion> {
        let should_expire = self
            .pending
            .as_ref()
            .map(|pending| {
                pending.request.connection_id == connection_id && now >= pending.deadline
            })
            .unwrap_or(false);
        if !should_expire {
            return None;
        }
        let pending = self.pending.take()?;
        self.last_finalized = Some((
            pending.request.connection_id.clone(),
            NativeApprovalFinalStatus::Expired,
        ));
        Some(NativeApprovalCompletion {
            pending,
            status: NativeApprovalFinalStatus::Expired,
        })
    }

    fn cancel(&mut self, core_connection_id: i32) -> Option<NativeApprovalCompletion> {
        let matches = self
            .pending
            .as_ref()
            .map(|pending| pending.request.core_connection_id == core_connection_id)
            .unwrap_or(false);
        if !matches {
            return None;
        }
        let pending = self.pending.take()?;
        self.last_finalized = Some((
            pending.request.connection_id.clone(),
            NativeApprovalFinalStatus::Cancelled,
        ));
        Some(NativeApprovalCompletion {
            pending,
            status: NativeApprovalFinalStatus::Cancelled,
        })
    }

    fn reset(&mut self) -> Option<PendingNativeApproval> {
        self.last_finalized = None;
        self.pending.take()
    }

    fn snapshot(
        &mut self,
        now: Instant,
    ) -> (
        Option<NativeApprovalRequest>,
        Option<NativeApprovalCompletion>,
    ) {
        let expired_connection_id = self
            .pending
            .as_ref()
            .filter(|pending| now >= pending.deadline)
            .map(|pending| pending.request.connection_id.clone());
        let completion = expired_connection_id
            .as_deref()
            .and_then(|connection_id| self.expire(connection_id, now));
        let request = self.pending.as_ref().map(|pending| pending.request.clone());
        (request, completion)
    }
}
