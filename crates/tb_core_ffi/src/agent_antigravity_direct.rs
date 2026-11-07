//! agy's quota without starting agy.
//!
//! `agy --print /usage` is not safe to run unattended: when its silent
//! keyring auth does not finish within ten seconds (a slow TLS handshake to
//! the token endpoint is enough), print mode falls through to an interactive
//! consumer OAuth flow and opens a browser tab. A once-a-minute quota poll
//! turned every network hiccup into a browser tab.
//!
//! This route reads agy's own login item (the same `gemini` / `antigravity`
//! go-keyring item `capture` reads), refreshes an access token in memory with
//! the OAuth client that issued it, and asks Code Assist for the same grouped
//! allowances `/usage` prints. Nothing here can open a browser: the worst
//! outcome of any failure is a fixed error code.
//!
//! What crosses each boundary:
//! - agy's item is read with `-w` only when its login marker (the
//!   attributes-only `mdat`, which raises no dialog) differs from the one the
//!   cached login was read under. A read that fails other than "not found"
//!   (a timeout, a denied Keychain dialog) pauses the route until the marker
//!   changes, so a denied dialog is not reopened every poll.
//! - agy's item is never written, and nothing is persisted: the refresh token,
//!   the client and the access token live only in this process.
//! - Errors are fixed codes (`DirectError::code`); no token, `sub`, email,
//!   `security` output or Google error text leaves this module.

use super::*;

/// An access token is reused until this long before its expiry.
const DIRECT_TOKEN_MARGIN_SECS: i64 = 5 * 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DirectError {
    /// agy has no login item (exit 44).
    NotSignedIn,
    /// The attributes-only marker query failed or timed out.
    KeychainUnavailable,
    /// agy's item could not be read (a timeout or a denied dialog). Stays
    /// until agy's login changes or the app restarts.
    Paused,
    LoginUnreadable,
    LoginMissingIdentity,
    OAuthClientNotFound,
    OAuthClientRejected,
    /// Google refused agy's refresh token: agy has to be signed in again.
    RefreshRejected,
    /// A transport failure, 429 or 5xx. Retried on the next poll.
    Network,
    /// Code Assist rejected the access token (401).
    AuthExpired,
    /// Code Assist answered, but with nothing this route can show.
    UnsupportedResponse,
}

impl DirectError {
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::NotSignedIn => "not_signed_in",
            Self::KeychainUnavailable => "keychain_unavailable",
            Self::Paused => "paused",
            Self::LoginUnreadable => "agy_login_unreadable",
            Self::LoginMissingIdentity => "agy_login_missing_identity",
            Self::OAuthClientNotFound => "oauth_client_not_found",
            Self::OAuthClientRejected => "oauth_client_rejected",
            Self::RefreshRejected => "refresh_rejected",
            Self::Network => "network",
            Self::AuthExpired => "auth_expired",
            Self::UnsupportedResponse => "unsupported_response",
        }
    }
}

pub(crate) struct DirectLogin {
    marker: String,
    refresh_token: String,
    client: OAuthClient,
    access: Option<CachedToken>,
    project: Option<String>,
}

#[derive(Default)]
pub(crate) enum DirectState {
    #[default]
    Empty,
    Ready(DirectLogin),
    /// Failures that a retry under the same login would only repeat.
    Stopped {
        marker: String,
        error: DirectError,
    },
}

pub(crate) type DirectCell = tokio::sync::Mutex<DirectState>;

static DIRECT_STATE: std::sync::LazyLock<DirectCell> =
    std::sync::LazyLock::new(|| tokio::sync::Mutex::new(DirectState::Empty));

/// One Code Assist POST, as the body text or a classified failure.
pub(crate) trait CodeAssistIo {
    async fn post(
        &self,
        method: &'static str,
        body: &Value,
        access_token: &str,
    ) -> Result<String, DirectError>;
}

pub(crate) struct SystemCodeAssistIo;

impl CodeAssistIo for SystemCodeAssistIo {
    async fn post(
        &self,
        method: &'static str,
        body: &Value,
        access_token: &str,
    ) -> Result<String, DirectError> {
        let client = captured_http_client().map_err(|_| DirectError::Network)?;
        code_assist_post(&client, method, body, access_token, None, false)
            .await
            .map_err(|failure| match failure {
                CodeAssistPostFailure::Failure(ProviderFetchFailure::Terminal { display })
                    if display == ANTIGRAVITY_AUTH_EXPIRED =>
                {
                    DirectError::AuthExpired
                }
                CodeAssistPostFailure::Failure(ProviderFetchFailure::Transient { .. }) => {
                    DirectError::Network
                }
                _ => DirectError::UnsupportedResponse,
            })
    }
}

fn capture_error(error: CaptureError) -> DirectError {
    match error {
        CaptureError::AgyLoginUnreadable => DirectError::LoginUnreadable,
        CaptureError::AgyLoginMissingIdentity => DirectError::LoginMissingIdentity,
        CaptureError::OAuthClientNotFound => DirectError::OAuthClientNotFound,
        CaptureError::OAuthClientRejected => DirectError::OAuthClientRejected,
        CaptureError::RefreshUnreachable => DirectError::Network,
        _ => DirectError::RefreshRejected,
    }
}

fn cached_token(json: &Value, now: DateTime<Utc>) -> Option<CachedToken> {
    let access_token = non_empty_str(json, "access_token")?.to_string();
    let expires_in = json.get("expires_in").and_then(Value::as_i64)?;
    Some(CachedToken {
        access_token,
        expires_at: now + chrono::Duration::seconds(expires_in),
    })
}

/// agy's grouped allowances, normalized to the field names `agy /usage`
/// prints (`groups[].buckets[].{id, window, remaining_fraction, reset_time}`)
/// so the caller decodes both with the same code and keeps window identity.
fn normalized_summary(body: &str) -> Option<Value> {
    let response: Value = serde_json::from_str(body).ok()?;
    let mut groups = Vec::new();
    for group in response.get("groups")?.as_array()? {
        let mut buckets = Vec::new();
        for bucket in group
            .get("buckets")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let Some(id) = non_empty_str(bucket, "bucketId") else {
                continue;
            };
            buckets.push(json!({
                "id": id,
                "name": bucket.get("displayName").and_then(Value::as_str).unwrap_or(""),
                "window": bucket.get("window").and_then(Value::as_str).unwrap_or(""),
                "remaining_fraction": bucket.get("remainingFraction").cloned().unwrap_or(Value::Null),
                "reset_time": bucket.get("resetTime").cloned().unwrap_or(Value::Null),
            }));
        }
        groups.push(json!({
            "name": group.get("displayName").and_then(Value::as_str).unwrap_or(""),
            "buckets": buckets,
        }));
    }
    let has_bucket = groups
        .iter()
        .any(|group| group["buckets"].as_array().is_some_and(|b| !b.is_empty()));
    has_bucket.then(|| json!({ "groups": groups }))
}

pub(super) struct DirectAgyLogin {
    pub(super) refresh_token: String,
    /// The issuing client's id, when the item still carries an `id_token`.
    pub(super) aud: Option<String>,
}

/// agy's go-keyring item. Builds since late 2026 store `id_token_email` and
/// no `id_token`, so unlike capture this route does not require an identity:
/// it never names the account, it only needs the refresh token.
pub(super) fn parse_direct_login(stdout: &[u8]) -> Result<DirectAgyLogin, DirectError> {
    use base64::Engine as _;
    match parse_agy_login(stdout) {
        Ok(login) => Ok(DirectAgyLogin {
            refresh_token: login.refresh_token,
            aud: Some(login.aud),
        }),
        Err(CaptureError::AgyLoginMissingIdentity) => {
            let login: Value = std::str::from_utf8(stdout)
                .ok()
                .and_then(|text| text.trim().strip_prefix("go-keyring-base64:"))
                .and_then(|encoded| {
                    base64::engine::general_purpose::STANDARD
                        .decode(encoded)
                        .ok()
                })
                .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                .ok_or(DirectError::LoginUnreadable)?;
            let refresh_token = login
                .get("token")
                .and_then(|token| non_empty_str(token, "refresh_token"))
                .ok_or(DirectError::LoginUnreadable)?
                .to_string();
            Ok(DirectAgyLogin {
                refresh_token,
                aud: None,
            })
        }
        Err(error) => Err(capture_error(error)),
    }
}

/// The clients a refresh may try: those named by `aud` when it is known,
/// otherwise every id/secret pair found in the same artifact.
fn candidate_clients(aud: Option<&str>, artifacts: Vec<Vec<u8>>) -> Vec<OAuthClient> {
    if let Some(aud) = aud {
        return clients_for_aud(aud, artifacts);
    }
    let mut clients: Vec<OAuthClient> = Vec::new();
    for data in artifacts {
        let secrets = scan_client_secrets(&data);
        for id in scan_client_ids(&data) {
            for secret in &secrets {
                let client = OAuthClient {
                    id: id.clone(),
                    secret: secret.clone(),
                };
                if !clients.contains(&client) {
                    clients.push(client);
                }
            }
        }
    }
    clients
}

/// One refresh of agy's token, trying candidate clients in order;
/// `invalid_client` / `unauthorized_client` moves to the next, any other
/// rejection stops.
pub(super) async fn refresh_with_candidate_clients<I: CapturedIo>(
    io: &I,
    login: &DirectAgyLogin,
) -> Result<(OAuthClient, Value), DirectError> {
    let clients = candidate_clients(login.aud.as_deref(), io.client_artifacts(true).await);
    if clients.is_empty() {
        return Err(DirectError::OAuthClientNotFound);
    }
    for client in clients {
        let (status, body) = io
            .token_post(&client, &login.refresh_token, None)
            .await
            .map_err(|_| DirectError::Network)?;
        match token_response(status, &body) {
            Ok(json) => return Ok((client, json)),
            Err(TokenRejection::WrongClient) => continue,
            Err(TokenRejection::Other) => return Err(DirectError::RefreshRejected),
        }
    }
    Err(DirectError::OAuthClientRejected)
}

pub(crate) async fn direct_quota_with<I: CapturedIo, Q: CodeAssistIo>(
    io: &I,
    code_assist: &Q,
    cell: &DirectCell,
    now: DateTime<Utc>,
) -> Result<Value, DirectError> {
    let mut state = cell.lock().await;
    let marker = login_marker_with(io)
        .await
        .ok_or(DirectError::KeychainUnavailable)?;
    if marker == "absent" {
        *state = DirectState::Empty;
        return Err(DirectError::NotSignedIn);
    }
    if let DirectState::Stopped {
        marker: stopped,
        error,
    } = &*state
    {
        if *stopped == marker {
            return Err(*error);
        }
    }

    if !matches!(&*state, DirectState::Ready(login) if login.marker == marker) {
        let previous = std::mem::take(&mut *state);
        let stop = |state: &mut DirectState, error: DirectError| {
            *state = DirectState::Stopped {
                marker: marker.clone(),
                error,
            };
            Err(error)
        };
        let item = match io
            .security(
                SecurityCall {
                    argv: security_argv(AGY_ITEM_READ),
                    stdin: None,
                },
                AGY_ITEM_READ_TIMEOUT,
            )
            .await
        {
            Some(SecurityExit {
                code: Some(0),
                stdout,
            }) => stdout,
            Some(SecurityExit {
                code: Some(SECURITY_ITEM_NOT_FOUND),
                ..
            }) => return Err(DirectError::NotSignedIn),
            _ => return stop(&mut state, DirectError::Paused),
        };
        let login = match parse_direct_login(&item) {
            Ok(login) => login,
            Err(error) => return stop(&mut state, error),
        };
        drop(item);
        // agy rewrote its item without changing the refresh token (it
        // refreshed its own access token): keep the client and our token.
        let reused = match previous {
            DirectState::Ready(old) if old.refresh_token == login.refresh_token => Some(old),
            _ => None,
        };
        let ready = match reused {
            Some(old) => DirectLogin {
                marker: marker.clone(),
                ..old
            },
            None => match refresh_with_candidate_clients(io, &login).await {
                Ok((client, json)) => DirectLogin {
                    marker: marker.clone(),
                    refresh_token: login.refresh_token.clone(),
                    client,
                    access: cached_token(&json, now),
                    project: None,
                },
                Err(DirectError::Network) => return Err(DirectError::Network),
                Err(error) => return stop(&mut state, error),
            },
        };
        *state = DirectState::Ready(ready);
    }

    let DirectState::Ready(login) = &mut *state else {
        unreachable!("the login was just read");
    };
    let fresh = login.access.as_ref().filter(|token| {
        token.expires_at - chrono::Duration::seconds(DIRECT_TOKEN_MARGIN_SECS) > now
    });
    let access_token = match fresh {
        Some(token) => token.access_token.clone(),
        None => {
            let (status, body) = io
                .token_post(&login.client, &login.refresh_token, None)
                .await
                .map_err(|_| DirectError::Network)?;
            let Ok(json) = token_response(status, &body) else {
                *state = DirectState::Stopped {
                    marker,
                    error: DirectError::RefreshRejected,
                };
                return Err(DirectError::RefreshRejected);
            };
            let token = cached_token(&json, now).ok_or(DirectError::RefreshRejected)?;
            let access_token = token.access_token.clone();
            login.access = Some(token);
            access_token
        }
    };

    let result = async {
        if login.project.is_none() {
            let body = code_assist
                .post(
                    "loadCodeAssist",
                    &json!({
                        "metadata": { "ideType": "ANTIGRAVITY", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI" }
                    }),
                    &access_token,
                )
                .await?;
            let code_assist: Value =
                serde_json::from_str(&body).map_err(|_| DirectError::UnsupportedResponse)?;
            login.project = project_id(&code_assist);
        }
        let body = match login.project.as_deref() {
            Some(project) => json!({ "project": project }),
            None => json!({}),
        };
        let response = code_assist
            .post("retrieveUserQuotaSummary", &body, &access_token)
            .await?;
        normalized_summary(&response).ok_or(DirectError::UnsupportedResponse)
    }
    .await;
    if result == Err(DirectError::AuthExpired) {
        // Not reused for the rest of its lifetime; the next poll refreshes.
        login.access = None;
    }
    result
}

/// The production route: the system Keychain, the installed agy/Antigravity
/// artifacts for the OAuth client, and Google's endpoints.
pub(crate) async fn direct_quota(now: DateTime<Utc>) -> Result<Value, DirectError> {
    direct_quota_with(&SystemCapturedIo, &SystemCodeAssistIo, &DIRECT_STATE, now).await
}

#[cfg(test)]
mod tests {
    use super::super::captured_test_support::*;
    use super::*;
    use std::cell::{Cell, RefCell};

    const MARKER_A: &str = "    \"mdat\"<timedate>=0x3230323631313037  \"20261107083219Z\\000\"\n";
    const MARKER_B: &str = "    \"mdat\"<timedate>=0x3230323631313038  \"20261107093219Z\\000\"\n";

    fn now() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-11-07T09:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
    }

    const SUMMARY: &str = r#"{"groups":[{"displayName":"Gemini Models","buckets":[
        {"bucketId":"gemini-weekly","displayName":"Weekly","remainingFraction":0.75,"resetTime":"2026-11-10T00:00:00Z","window":"weekly"},
        {"bucketId":"gemini-5h","displayName":"5 hours","remainingFraction":1,"window":"5h"}]}]}"#;

    struct FakeCodeAssist {
        calls: RefCell<Vec<(&'static str, Value, String)>>,
        summary: Cell<Result<&'static str, DirectError>>,
    }

    impl FakeCodeAssist {
        fn new() -> Self {
            Self {
                calls: RefCell::new(Vec::new()),
                summary: Cell::new(Ok(SUMMARY)),
            }
        }
        fn methods(&self) -> Vec<&'static str> {
            self.calls.borrow().iter().map(|call| call.0).collect()
        }
    }

    impl CodeAssistIo for FakeCodeAssist {
        async fn post(
            &self,
            method: &'static str,
            body: &Value,
            access_token: &str,
        ) -> Result<String, DirectError> {
            self.calls
                .borrow_mut()
                .push((method, body.clone(), access_token.to_string()));
            match method {
                "loadCodeAssist" => Ok(r#"{"cloudaicompanionProject":"proj-1"}"#.to_string()),
                "retrieveUserQuotaSummary" => self.summary.get().map(str::to_string),
                other => panic!("unexpected method {other}"),
            }
        }
    }

    fn signed_in_io(refresh_token: &str) -> FakeIo {
        let mut io = FakeIo::new("direct-quota");
        io.agy_item = Some(agy_item(
            refresh_token,
            Some(json!({ "sub": "sub-a", "aud": AUD, "email": "a@example.com" })),
        ));
        io.agy_attributes = MARKER_A.to_string();
        io.artifacts = vec![format!("agy\0{AUD}\0{}\0", secret('a')).into_bytes()];
        io
    }

    fn secret_reads(io: &FakeIo) -> usize {
        io.security_calls
            .borrow()
            .iter()
            .filter(|call| call.argv.last().map(String::as_str) == Some("-w"))
            .count()
    }

    #[tokio::test]
    async fn returns_agy_shaped_groups_and_reuses_login_and_token() {
        let io = signed_in_io("1//rt-a");
        let api = FakeCodeAssist::new();
        let cell = DirectCell::default();

        let value = direct_quota_with(&io, &api, &cell, now()).await.unwrap();
        assert_eq!(
            value,
            json!({ "groups": [{ "name": "Gemini Models", "buckets": [
                { "id": "gemini-weekly", "name": "Weekly", "window": "weekly", "remaining_fraction": 0.75, "reset_time": "2026-11-10T00:00:00Z" },
                { "id": "gemini-5h", "name": "5 hours", "window": "5h", "remaining_fraction": 1, "reset_time": null },
            ]}]})
        );
        assert_eq!(
            api.methods(),
            ["loadCodeAssist", "retrieveUserQuotaSummary"]
        );
        assert_eq!(api.calls.borrow()[1].1, json!({ "project": "proj-1" }));
        assert_eq!(api.calls.borrow()[1].2, "ya29.fresh");

        // Same marker, token still fresh: no secret read, no token request,
        // no loadCodeAssist.
        direct_quota_with(&io, &api, &cell, now() + chrono::Duration::minutes(1))
            .await
            .unwrap();
        assert_eq!(secret_reads(&io), 1);
        assert_eq!(io.token_calls.borrow().len(), 1);
        assert_eq!(io.artifact_calls.get(), 1);
        assert_eq!(api.methods().len(), 3);
        assert!(
            io.writes().is_empty(),
            "agy's item and ours are never written"
        );

        // Past the token's margin: one refresh with the pinned client, still
        // without reading the secret or rescanning artifacts.
        direct_quota_with(&io, &api, &cell, now() + chrono::Duration::minutes(56))
            .await
            .unwrap();
        assert_eq!(secret_reads(&io), 1);
        assert_eq!(io.artifact_calls.get(), 1);
        assert_eq!(io.token_calls.borrow().len(), 2);
        assert_eq!(io.token_calls.borrow()[1].2, "1//rt-a");
    }

    #[tokio::test]
    async fn a_rewritten_item_with_the_same_refresh_token_keeps_the_client() {
        let mut io = signed_in_io("1//rt-a");
        let api = FakeCodeAssist::new();
        let cell = DirectCell::default();
        direct_quota_with(&io, &api, &cell, now()).await.unwrap();
        io.agy_attributes = MARKER_B.to_string();
        direct_quota_with(&io, &api, &cell, now()).await.unwrap();
        assert_eq!(secret_reads(&io), 2, "a new marker rereads the item");
        assert_eq!(io.artifact_calls.get(), 1, "same refresh token: no rescan");
        assert_eq!(io.token_calls.borrow().len(), 1);
    }

    #[tokio::test]
    async fn a_login_without_id_token_tries_every_client_until_one_fits() {
        let mut io = signed_in_io("1//rt-a");
        io.agy_item = Some(agy_item("1//rt-a", None));
        io.artifacts = vec![format!("agy\0{OTHER}\0{AUD}\0{}\0", secret('a')).into_bytes()];
        io.token = Box::new(|client, _| {
            if client.id == AUD {
                Ok(token_ok("ya29.fresh", json!({})))
            } else {
                Ok((401, r#"{"error":"unauthorized_client"}"#.to_string()))
            }
        });
        let api = FakeCodeAssist::new();
        let cell = DirectCell::default();
        direct_quota_with(&io, &api, &cell, now()).await.unwrap();
        let ids: Vec<String> = io
            .token_calls
            .borrow()
            .iter()
            .map(|c| c.0.clone())
            .collect();
        assert_eq!(ids, [OTHER, AUD]);
        // The fitting client is pinned for later refreshes.
        direct_quota_with(&io, &api, &cell, now() + chrono::Duration::minutes(56))
            .await
            .unwrap();
        assert_eq!(io.token_calls.borrow().last().unwrap().0, AUD);
        assert_eq!(io.token_calls.borrow().len(), 3);
    }

    #[tokio::test]
    async fn signed_out_agy_reads_no_secret_and_makes_no_request() {
        let mut io = FakeIo::new("direct-signed-out");
        io.agy_item = None;
        let api = FakeCodeAssist::new();
        let cell = DirectCell::default();
        assert_eq!(
            direct_quota_with(&io, &api, &cell, now()).await,
            Err(DirectError::NotSignedIn)
        );
        assert_eq!(secret_reads(&io), 0);
        assert_eq!(io.network_calls(), 0);
        assert!(api.methods().is_empty());
    }

    #[tokio::test]
    async fn a_failed_secret_read_pauses_until_the_login_changes() {
        let mut io = signed_in_io("1//rt-a");
        io.agy_read_exit = Some(Some(128));
        let api = FakeCodeAssist::new();
        let cell = DirectCell::default();
        for _ in 0..3 {
            assert_eq!(
                direct_quota_with(&io, &api, &cell, now()).await,
                Err(DirectError::Paused)
            );
        }
        assert_eq!(secret_reads(&io), 1, "a denied dialog is not reopened");
        io.agy_read_exit = None;
        io.agy_attributes = MARKER_B.to_string();
        assert!(direct_quota_with(&io, &api, &cell, now()).await.is_ok());
        assert_eq!(secret_reads(&io), 2);
    }

    #[tokio::test]
    async fn a_rejected_refresh_token_stops_until_the_login_changes() {
        let mut io = signed_in_io("1//rt-a");
        io.token = Box::new(|_, _| Ok((400, r#"{"error":"invalid_grant"}"#.to_string())));
        let api = FakeCodeAssist::new();
        let cell = DirectCell::default();
        assert_eq!(
            direct_quota_with(&io, &api, &cell, now()).await,
            Err(DirectError::RefreshRejected)
        );
        assert_eq!(
            direct_quota_with(&io, &api, &cell, now()).await,
            Err(DirectError::RefreshRejected)
        );
        assert_eq!(io.token_calls.borrow().len(), 1, "not retried every poll");
        assert!(api.methods().is_empty());
    }

    #[tokio::test]
    async fn network_failures_are_retried_on_the_next_poll() {
        let mut io = signed_in_io("1//rt-a");
        let failing = std::rc::Rc::new(Cell::new(true));
        let flag = failing.clone();
        io.token = Box::new(move |_, _| {
            if flag.get() {
                Err(ProviderFetchFailure::terminal("unreachable"))
            } else {
                Ok(token_ok("ya29.fresh", json!({})))
            }
        });
        let api = FakeCodeAssist::new();
        let cell = DirectCell::default();
        assert_eq!(
            direct_quota_with(&io, &api, &cell, now()).await,
            Err(DirectError::Network)
        );
        failing.set(false);
        assert!(direct_quota_with(&io, &api, &cell, now()).await.is_ok());
    }

    #[tokio::test]
    async fn a_401_drops_the_access_token_for_the_next_poll() {
        let io = signed_in_io("1//rt-a");
        let api = FakeCodeAssist::new();
        let cell = DirectCell::default();
        direct_quota_with(&io, &api, &cell, now()).await.unwrap();
        api.summary.set(Err(DirectError::AuthExpired));
        assert_eq!(
            direct_quota_with(&io, &api, &cell, now()).await,
            Err(DirectError::AuthExpired)
        );
        api.summary.set(Ok(SUMMARY));
        direct_quota_with(&io, &api, &cell, now()).await.unwrap();
        assert_eq!(io.token_calls.borrow().len(), 2);
    }

    #[test]
    fn the_native_card_reads_the_direct_summary_like_agy_usage() {
        let value = normalized_summary(SUMMARY).unwrap();
        let body = json!({ "status": "SUCCESS", "command": { "name": "usage", "data": value } });
        let fetched = parse_agy_usage(body.to_string().as_bytes(), now()).unwrap();
        let labels: Vec<&str> = fetched.windows.iter().map(|w| w.label_for_test()).collect();
        assert_eq!(
            labels,
            ["Gemini Models · Weekly", "Gemini Models · 5 hours"]
        );
    }

    #[tokio::test]
    async fn an_empty_summary_is_unsupported() {
        let io = signed_in_io("1//rt-a");
        let api = FakeCodeAssist::new();
        api.summary.set(Ok(r#"{"groups":[]}"#));
        let cell = DirectCell::default();
        assert_eq!(
            direct_quota_with(&io, &api, &cell, now()).await,
            Err(DirectError::UnsupportedResponse)
        );
    }
}

/// Live smoke against this Mac's agy login and Google. Prints only counts or
/// the fixed error code. `cargo test -p tb_core_ffi direct_live -- --ignored`
#[cfg(test)]
#[tokio::test]
#[ignore = "reads the real agy login and reaches Google"]
async fn direct_live_smoke() {
    match direct_quota(Utc::now()).await {
        Ok(value) => {
            let groups = value["groups"].as_array().map_or(0, Vec::len);
            let buckets: usize = value["groups"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|group| group["buckets"].as_array().map_or(0, Vec::len))
                .sum();
            println!("direct_quota ok groups={groups} buckets={buckets}");
        }
        Err(error) => panic!("direct_quota failed: {}", error.code()),
    }
}
