impl Drop for RuntimeFinished {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}

async fn wait_for_host_runtime_retry(stop_requested: &AtomicBool, delay: Duration) -> bool {
    let deadline = Instant::now() + delay;
    loop {
        if stop_requested.load(Ordering::Acquire) {
            return false;
        }
        let now = Instant::now();
        if now >= deadline {
            return true;
        }
        hbb_common::tokio::time::sleep(
            deadline
                .saturating_duration_since(now)
                .min(Duration::from_millis(HOST_RUNTIME_RECONNECT_STOP_POLL_MS)),
        )
        .await;
    }
}

async fn wait_for_host_runtime_registration_watchdog(
    stop_requested: &AtomicBool,
) -> HostRuntimeRegistrationWatchdogOutcome {
    let mut watchdog = HostRuntimeRegistrationWatchdog::default();
    loop {
        if stop_requested.load(Ordering::Acquire) {
            return HostRuntimeRegistrationWatchdogOutcome::StopRequested;
        }
        let registration_healthy =
            config::Config::get_key_confirmed() && config::get_online_state() > 0;
        if watchdog.should_restart(Instant::now(), registration_healthy) {
            return HostRuntimeRegistrationWatchdogOutcome::RegistrationStalled;
        }
        hbb_common::tokio::time::sleep(Duration::from_millis(HOST_RUNTIME_RECONNECT_STOP_POLL_MS))
            .await;
    }
}

impl HostRuntime {
    fn start(rendezvous_server: String) -> Result<Self, ()> {
        let stop_requested = Arc::new(AtomicBool::new(false));
        let finished = Arc::new(AtomicBool::new(false));
        let thread_stop = stop_requested.clone();
        let thread_finished = finished.clone();
        let thread = std::thread::Builder::new()
            .name("farpane-host-rendezvous".to_owned())
            .spawn(move || {
                let _finished = RuntimeFinished(thread_finished);
                let Ok(runtime) = hbb_common::tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                else {
                    return;
                };
                runtime.block_on(async move {
                    let server = crate::server::new();
                    let mut reconnect_backoff = HostRuntimeReconnectBackoff::default();
                    while !thread_stop.load(Ordering::Acquire) {
                        crate::RendezvousMediator::prepare_native_host_runtime();
                        let connection_started = Instant::now();
                        let rendezvous = crate::RendezvousMediator::start(
                            server.clone(),
                            rendezvous_server.clone(),
                        );
                        hbb_common::tokio::pin!(rendezvous);
                        let watchdog_outcome = hbb_common::tokio::select! {
                            _ = &mut rendezvous => None,
                            outcome = wait_for_host_runtime_registration_watchdog(&thread_stop) => {
                                Some(outcome)
                            }
                        };
                        if watchdog_outcome
                            == Some(HostRuntimeRegistrationWatchdogOutcome::StopRequested)
                            || thread_stop.load(Ordering::Acquire)
                        {
                            break;
                        }
                        config::Config::reset_online();
                        let retry_delay = reconnect_backoff.delay_after_exit(
                            connection_started.elapsed(),
                            u64::from(hbb_common::time_based_rand()),
                        );
                        if !wait_for_host_runtime_retry(&thread_stop, retry_delay).await {
                            break;
                        }
                    }
                });
            })
            .map_err(|_| ())?;
        Ok(Self {
            stop_requested,
            finished,
            thread: Some(thread),
        })
    }

    fn is_finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
    }

    fn request_stop(&self) {
        self.stop_requested.store(true, Ordering::Release);
        crate::RendezvousMediator::stop_native_host_runtime();
    }

    fn join(&mut self) -> bool {
        let joined = self
            .thread
            .take()
            .map(|thread| thread.join().is_ok())
            .unwrap_or(true);
        config::Config::reset_online();
        joined
    }

    fn stop(&mut self) -> bool {
        self.request_stop();
        self.join()
    }
}

impl RdnHost {
    fn refresh_registration_state(&mut self) {
        match self.recovery_state {
            HostRecoveryState::Suspending => {
                self.registration_status = "suspending";
                return;
            }
            HostRecoveryState::Suspended => {
                self.registration_status = "suspended";
                return;
            }
            HostRecoveryState::Failed => return,
            HostRecoveryState::Running | HostRecoveryState::Resuming => {}
        }
        if !matches!(self.state, RdnHostState::Starting | RdnHostState::Ready) {
            return;
        }
        if config::Config::get_key_confirmed() && config::get_online_state() > 0 {
            self.registration_status = "ready";
            self.state = RdnHostState::Ready;
            self.recovery_state = HostRecoveryState::Running;
            self.last_error = None;
        } else if self
            .runtime
            .as_ref()
            .map(HostRuntime::is_finished)
            .unwrap_or(true)
        {
            self.registration_status = "degraded";
            self.state = RdnHostState::Error;
            if self.recovery_state == HostRecoveryState::Resuming {
                self.recovery_state = HostRecoveryState::Failed;
            }
            self.last_error = Some("registration.runtimeExited".to_owned());
        } else {
            self.registration_status = "pending";
            self.state = RdnHostState::Starting;
        }
    }

    fn emit_event(&self, event_type: &str, payload: Value) {
        emit_bound_event(
            &MediaHostBinding {
                instance_id: self.instance_id.clone(),
                callback: self.callbacks.on_event,
                context: self.callbacks.context as usize,
                event_id: self.event_id.clone(),
            },
            event_type,
            payload,
        );
    }

    fn emit_snapshot_changed(&self) {
        self.emit_event("snapshotChanged", json!({}));
    }

    fn emit_command_result(&self, command_id: &str, status: &str, detail: &str) {
        self.emit_event(
            "commandResult",
            json!({
                "commandId": command_id,
                "status": status,
                "detail": detail,
            }),
        );
    }

    fn snapshot_json(&mut self) -> Value {
        self.refresh_registration_state();
        let (session_availability, session_unavailable_reason) =
            native_host_session_availability_payload(native_host_session_is_available());
        // §8.3 minimal field set; §9.2: password only leaves Rust when the UI
        // explicitly revealed it, and the reveal flag is one-shot.
        let presentation = if self.reveal_temporary_password {
            self.reveal_temporary_password = false;
            json!({ "policy": "revealed", "value": password_security::temporary_password() })
        } else {
            json!({ "policy": "redacted" })
        };
        let mut map = Map::new();
        map.insert("schemaVersion".into(), json!(SNAPSHOT_SCHEMA_VERSION));
        map.insert("hostInstanceId".into(), json!(self.instance_id));
        map.insert("hostState".into(), json!(state_name(self.state)));
        map.insert("localId".into(), json!(self.local_id));
        map.insert(
            "authenticatedConnectionCount".into(),
            json!(crate::server::native_host_authenticated_connection_count()),
        );
        map.insert("sessionAvailability".into(), json!(session_availability));
        map.insert(
            "sessionUnavailableReason".into(),
            json!(session_unavailable_reason),
        );
        map.insert(
            "pendingApproval".into(),
            native_host_pending_approval_snapshot(&self.instance_id).unwrap_or(Value::Null),
        );
        map.insert(
            "activeSession".into(),
            native_host_active_session_snapshot(&self.instance_id).unwrap_or(Value::Null),
        );
        map.insert("temporaryPasswordPresentation".into(), presentation);
        map.insert(
            "passwordPolicy".into(),
            json!({
                "localPasswordSet": config::Config::has_local_permanent_password(),
                "effectivePasswordSet": config::Config::has_permanent_password(),
                "usingPresetPassword": config::Config::is_using_preset_password(),
                "changeAllowed": !config::Config::is_disable_change_permanent_password(),
                "strengthPolicy": {
                    "version": PERMANENT_PASSWORD_POLICY_VERSION,
                    "minimumCharacters": PERMANENT_PASSWORD_MIN_CHARACTERS,
                    "maximumCharacters": PERMANENT_PASSWORD_MAX_CHARACTERS,
                    "maximumUtf8Bytes": PERMANENT_PASSWORD_MAX_UTF8_BYTES,
                    "rejectsControlCharacters": true,
                    "rejectsOuterWhitespace": true,
                },
            }),
        );
        map.insert("registrationStatus".into(), json!(self.registration_status));
        map.insert("recoveryEpoch".into(), json!(self.recovery_epoch));
        map.insert("recoveryStatus".into(), json!(self.recovery_state.name()));
        map.insert(
            "lastError".into(),
            match &self.last_error {
                Some(error) => json!(error),
                None => Value::Null,
            },
        );
        map.insert("observedAt".into(), json!(now_unix_millis()));
        Value::Object(map)
    }
}
