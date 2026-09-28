// Process-global guards. `CONFIG_ROOT_SET` enforces the one-time early entry;
// `HOST_INSTANCE_LIVE` enforces the single-instance/exclusion contract and
// will also gate viewer-core coexistence checks (§18 rule 1).
static CONFIG_ROOT_SET: AtomicBool = AtomicBool::new(false);
static HOST_INSTANCE_LIVE: AtomicBool = AtomicBool::new(false);

pub struct RdnHost {
    instance_id: String,
    state: RdnHostState,
    local_id: String,
    registration_status: &'static str,
    recovery_epoch: u64,
    recovery_state: HostRecoveryState,
    network_path_generation: u64,
    reveal_temporary_password: bool,
    last_error: Option<String>,
    event_id: Arc<AtomicU64>,
    callbacks: RdnHostCallbacks,
    rendezvous_server: String,
    relay_server: String,
    server_public_key: String,
    clipboard_transfer_policy: NativeClipboardTransferPolicy,
    audio_enabled: bool,
    audio_input_device: String,
    file_transfer_enabled: bool,
    #[cfg(target_os = "macos")]
    file_service_owner: Option<Arc<rdn_host_file_transfer::NativeHostFileServiceOwner>>,
    runtime: Option<HostRuntime>,
}

struct HostRuntime {
    stop_requested: Arc<AtomicBool>,
    finished: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

struct RuntimeFinished(Arc<AtomicBool>);

const HOST_RUNTIME_RECONNECT_BASE_DELAY_MS: u64 = 250;
const HOST_RUNTIME_RECONNECT_MAX_DELAY_MS: u64 = 5_000;
const HOST_RUNTIME_RECONNECT_STABLE_CONNECTION_MS: u64 = 30_000;
const HOST_RUNTIME_RECONNECT_STOP_POLL_MS: u64 = 50;
const HOST_RUNTIME_REGISTRATION_STALL_TIMEOUT_MS: u64 = 15_000;

#[derive(Default)]
struct HostRuntimeReconnectBackoff {
    consecutive_failures: u32,
}

#[derive(Default)]
struct HostRuntimeRegistrationWatchdog {
    unhealthy_since: Option<Instant>,
}

impl HostRuntimeRegistrationWatchdog {
    fn should_restart(&mut self, now: Instant, registration_healthy: bool) -> bool {
        if registration_healthy {
            self.unhealthy_since = None;
            return false;
        }
        let unhealthy_since = self.unhealthy_since.get_or_insert(now);
        now.saturating_duration_since(*unhealthy_since)
            >= Duration::from_millis(HOST_RUNTIME_REGISTRATION_STALL_TIMEOUT_MS)
    }
}

#[derive(Debug, PartialEq, Eq)]
enum HostRuntimeRegistrationWatchdogOutcome {
    RegistrationStalled,
    StopRequested,
}

impl HostRuntimeReconnectBackoff {
    fn delay_after_exit(&mut self, connection_lifetime: Duration, jitter_sample: u64) -> Duration {
        if connection_lifetime >= Duration::from_millis(HOST_RUNTIME_RECONNECT_STABLE_CONNECTION_MS)
        {
            self.consecutive_failures = 0;
        }
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        let doublings = self.consecutive_failures.saturating_sub(1).min(5);
        let nominal = HOST_RUNTIME_RECONNECT_BASE_DELAY_MS
            .saturating_mul(1_u64 << doublings)
            .min(HOST_RUNTIME_RECONNECT_MAX_DELAY_MS);
        let jitter_upper_bound = nominal / 4;
        let jitter = if jitter_upper_bound == 0 {
            0
        } else {
            jitter_sample % (jitter_upper_bound + 1)
        };
        Duration::from_millis(
            nominal
                .saturating_add(jitter)
                .min(HOST_RUNTIME_RECONNECT_MAX_DELAY_MS),
        )
    }
}

/// Caller-owned secret bytes borrowed across the C ABI. Every return path
/// after a valid pointer/length pair reaches this guard and wipes the complete
/// caller buffer with libsodium before Rust releases the borrow.
struct SecretBuffer<'a> {
    bytes: &'a mut [u8],
}

impl SecretBuffer<'_> {
    unsafe fn from_raw_parts(pointer: *mut u8, length: usize) -> Self {
        Self {
            bytes: std::slice::from_raw_parts_mut(pointer, length),
        }
    }

    fn bytes(&self) -> &[u8] {
        self.bytes
    }
}

impl Drop for SecretBuffer<'_> {
    fn drop(&mut self) {
        password_security::memzero_secret(self.bytes);
    }
}

#[derive(Clone, Copy)]
struct PasswordPolicyRejection {
    code: i32,
    detail: &'static str,
}

fn validate_permanent_password(bytes: &[u8]) -> Result<&str, PasswordPolicyRejection> {
    if bytes.is_empty() {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_EMPTY,
            detail: "permanent-password-empty",
        });
    }
    if bytes.len() > PERMANENT_PASSWORD_MAX_UTF8_BYTES {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_TOO_LONG,
            detail: "permanent-password-too-long",
        });
    }
    let password = std::str::from_utf8(bytes).map_err(|_| PasswordPolicyRejection {
        code: RDN_HOST_ERR_SECRET_INVALID_UTF8,
        detail: "permanent-password-invalid-utf8",
    })?;
    let character_count = password.chars().count();
    if character_count < PERMANENT_PASSWORD_MIN_CHARACTERS {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_TOO_SHORT,
            detail: "permanent-password-too-short",
        });
    }
    if character_count > PERMANENT_PASSWORD_MAX_CHARACTERS {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_TOO_LONG,
            detail: "permanent-password-too-long",
        });
    }
    if password.chars().any(char::is_control) {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_FORBIDDEN_CHARACTER,
            detail: "permanent-password-forbidden-character",
        });
    }
    if password
        .chars()
        .next()
        .map(char::is_whitespace)
        .unwrap_or(false)
        || password
            .chars()
            .next_back()
            .map(char::is_whitespace)
            .unwrap_or(false)
    {
        return Err(PasswordPolicyRejection {
            code: RDN_HOST_ERR_SECRET_OUTER_WHITESPACE,
            detail: "permanent-password-outer-whitespace",
        });
    }
    Ok(password)
}
