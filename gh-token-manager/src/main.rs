#![cfg_attr(coverage, feature(coverage_attribute))]

use std::{
    collections::HashMap,
    error::Error,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    time::Duration,
};

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

use clap::Parser;
use http::header::ACCEPT;
use octocrab::auth::{DeviceCodes, OAuth};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use time::{Duration as TimeDuration, OffsetDateTime};

#[derive(Parser)]
#[command(about = "Issue and refresh a GitHub App user access token")]
struct Args {
    /// GitHub App client ID (not the App ID or client secret)
    #[arg(long, env = "GITHUB_APP_CLIENT_ID")]
    client_id: String,
    /// GitHub username expected to authorize the token
    #[arg(long)]
    username: String,
    /// GitHub App device-flow scope. GitHub Apps support only `offline_access` here.
    #[arg(long, default_value = "offline_access", value_parser = parse_scope)]
    scope: String,
    /// Restrict the token to one repository ID
    #[arg(long)]
    repository_id: Option<String>,
    /// Ignore a cached token and start a new device authorization
    #[arg(long)]
    reauthenticate: bool,
}

fn parse_scope(scope: &str) -> Result<String, String> {
    if scope == "offline_access" {
        Ok(scope.to_owned())
    } else {
        Err("GitHub App device flow only accepts the offline_access scope".into())
    }
}

#[derive(Default, Serialize, Deserialize)]
struct TokenCache {
    #[serde(default)]
    clients: HashMap<String, ClientTokens>,
}

#[derive(Default, Serialize, Deserialize)]
struct ClientTokens {
    #[serde(default)]
    users: HashMap<String, UserTokens>,
}

#[derive(Default, Serialize, Deserialize)]
struct UserTokens {
    token: Option<CachedToken>,
    #[serde(default)]
    repository_tokens: HashMap<String, CachedToken>,
}

#[derive(Clone, Serialize, Deserialize)]
struct CachedToken {
    verified_username: String,
    access_token: String,
    #[serde(with = "time::serde::timestamp::option")]
    expires_at: Option<OffsetDateTime>,
    refresh_token: Option<String>,
    #[serde(with = "time::serde::timestamp::option")]
    refresh_token_expires_at: Option<OffsetDateTime>,
}

impl CachedToken {
    fn from_oauth(verified_username: &str, oauth: &OAuth) -> Result<Self, Box<dyn Error>> {
        let now = OffsetDateTime::now_utc();
        Ok(Self {
            verified_username: verified_username.to_owned(),
            access_token: oauth.access_token.expose_secret().to_owned(),
            expires_at: token_expiry(now, oauth.expires_in)?,
            refresh_token: oauth
                .refresh_token
                .as_ref()
                .map(|token| token.expose_secret().to_owned()),
            refresh_token_expires_at: token_expiry(now, oauth.refresh_token_expires_in)?,
        })
    }

    fn access_token_valid(&self) -> bool {
        self.expires_at.is_none_or(|expiry| {
            expiry > OffsetDateTime::now_utc().saturating_add(TimeDuration::seconds(60))
        })
    }

    fn refresh_token_valid(&self) -> bool {
        self.refresh_token.is_some()
            && self
                .refresh_token_expires_at
                .is_none_or(|expiry| expiry > OffsetDateTime::now_utc())
    }
}

impl TokenCache {
    fn get(
        &self,
        client_id: &str,
        username: &str,
        repository_id: Option<&str>,
    ) -> Option<&CachedToken> {
        let user = self
            .clients
            .get(client_id)?
            .users
            .get(&username.to_ascii_lowercase())?;
        match repository_id {
            Some(repository_id) => user.repository_tokens.get(repository_id),
            None => user.token.as_ref(),
        }
    }

    fn insert(
        &mut self,
        client_id: &str,
        username: &str,
        repository_id: Option<&str>,
        token: CachedToken,
    ) {
        let user = self
            .clients
            .entry(client_id.to_owned())
            .or_default()
            .users
            .entry(username.to_ascii_lowercase())
            .or_default();
        match repository_id {
            Some(repository_id) => {
                user.repository_tokens
                    .insert(repository_id.to_owned(), token);
            }
            None => user.token = Some(token),
        }
    }

    fn remove(&mut self, client_id: &str, username: &str, repository_id: Option<&str>) {
        let Some(user) = self
            .clients
            .get_mut(client_id)
            .and_then(|client| client.users.get_mut(&username.to_ascii_lowercase()))
        else {
            return;
        };
        match repository_id {
            Some(repository_id) => {
                user.repository_tokens.remove(repository_id);
            }
            None => user.token = None,
        }
    }
}

#[derive(Serialize)]
struct RefreshRequest<'a> {
    client_id: &'a str,
    grant_type: &'static str,
    refresh_token: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    repository_id: Option<&'a str>,
}

#[derive(Serialize)]
struct DevicePollRequest<'a> {
    client_id: &'a str,
    device_code: &'a str,
    grant_type: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    repository_id: Option<&'a str>,
}

#[derive(Deserialize)]
struct OAuthReply {
    access_token: Option<String>,
    token_type: Option<String>,
    scope: Option<String>,
    expires_in: Option<usize>,
    refresh_token: Option<String>,
    refresh_token_expires_in: Option<usize>,
    error: Option<String>,
    error_description: Option<String>,
}

impl OAuthReply {
    fn into_oauth(self) -> Result<OAuth, String> {
        if let Some(error) = self.error {
            return Err(self.error_description.unwrap_or(error));
        }
        Ok(OAuth {
            access_token: SecretString::from(self.access_token.ok_or("missing access_token")?),
            token_type: self.token_type.ok_or("missing token_type")?,
            scope: self
                .scope
                .ok_or("missing scope")?
                .split(',')
                .map(str::to_owned)
                .collect(),
            expires_in: self.expires_in,
            refresh_token: self.refresh_token.map(SecretString::from),
            refresh_token_expires_in: self.refresh_token_expires_in,
        })
    }
}

#[derive(Serialize)]
struct TokenOutput<'a> {
    username: &'a str,
    access_token: &'a str,
    expires_at: Option<u64>,
    refresh_token: Option<&'a str>,
    refresh_token_expires_at: Option<u64>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let args = Args::parse();
    let cache_path = cache_path()?;
    let crab = client("https://github.com")?;
    let cache = obtain_token(&args, &crab, "https://api.github.com", &cache_path).await?;
    print_token(&cache)?;
    Ok(())
}

async fn obtain_token(
    args: &Args,
    crab: &octocrab::Octocrab,
    api_base: &str,
    cache_path: &Path,
) -> Result<CachedToken, Box<dyn Error>> {
    let parent = cache_path
        .parent()
        .ok_or("cache path has no parent directory")?;
    fs::create_dir_all(parent)?;
    #[cfg(unix)]
    fs::set_permissions(parent, std::os::unix::fs::PermissionsExt::from_mode(0o700))?;
    let lock_path = cache_path.with_extension("lock");
    let mut lock_options = OpenOptions::new();
    lock_options.read(true).write(true).create(true);
    #[cfg(unix)]
    lock_options.mode(0o600);
    let lock = lock_options.open(lock_path)?;
    lock.lock()?;

    let mut token_cache = read_cache(cache_path)?;
    let user_key = args.username.to_ascii_lowercase();
    let cached = if args.reauthenticate {
        token_cache.remove(&args.client_id, &user_key, args.repository_id.as_deref());
        write_cache(cache_path, &token_cache)?;
        None
    } else {
        token_cache
            .get(&args.client_id, &user_key, args.repository_id.as_deref())
            .cloned()
    };
    let (cache, changed) = match cached {
        Some(cache) if cache.access_token_valid() => (cache, false),
        Some(cache) if cache.refresh_token_valid() => {
            let refresh_token = cache.refresh_token.as_deref().expect("validated above");
            let reply: OAuthReply = tokio::time::timeout(
                Duration::from_secs(10),
                crab.post(
                    "/login/oauth/access_token",
                    Some(&RefreshRequest {
                        client_id: &args.client_id,
                        grant_type: "refresh_token",
                        refresh_token,
                        repository_id: args.repository_id.as_deref(),
                    }),
                ),
            )
            .await??;
            if reply.error.as_deref() == Some("bad_refresh_token") {
                (device_authorize(crab, args).await?, true)
            } else {
                let oauth = reply.into_oauth()?;
                let rotated = CachedToken::from_oauth(&cache.verified_username, &oauth)?;
                token_cache.insert(
                    &args.client_id,
                    &user_key,
                    args.repository_id.as_deref(),
                    rotated.clone(),
                );
                write_cache(cache_path, &token_cache)?;
                (rotated, false)
            }
        }
        _ => (device_authorize(crab, args).await?, true),
    };

    let login = verify_username(&cache, &args.username, api_base).await?;
    let mut cache = cache;
    cache.verified_username = login;
    if changed {
        token_cache.insert(
            &args.client_id,
            &user_key,
            args.repository_id.as_deref(),
            cache.clone(),
        );
        write_cache(cache_path, &token_cache)?;
    }
    Ok(cache)
}

fn client(base_uri: &str) -> Result<octocrab::Octocrab, Box<dyn Error>> {
    Ok(octocrab::Octocrab::builder()
        .base_uri(base_uri)?
        .add_header(ACCEPT, "application/json".to_owned())
        .build()?)
}

async fn device_authorize(
    crab: &octocrab::Octocrab,
    args: &Args,
) -> Result<CachedToken, Box<dyn Error>> {
    let client_id = SecretString::from(args.client_id.clone());
    let codes = tokio::time::timeout(
        Duration::from_secs(10),
        crab.authenticate_as_device(&client_id, [&args.scope]),
    )
    .await??;
    eprintln!(
        "Open {} and enter code {}",
        codes.verification_uri, codes.user_code
    );
    let oauth = poll_for_token(crab, &client_id, &codes, args.repository_id.as_deref()).await?;
    CachedToken::from_oauth(&args.username, &oauth)
}

#[derive(Deserialize)]
struct GitHubUser {
    login: String,
}

async fn verify_username(
    cache: &CachedToken,
    requested: &str,
    api_base: &str,
) -> Result<String, Box<dyn Error>> {
    let api = octocrab::Octocrab::builder()
        .base_uri(api_base)?
        .personal_token(SecretString::from(cache.access_token.clone()))
        .build()?;
    let user: GitHubUser =
        tokio::time::timeout(Duration::from_secs(10), api.get("/user", None::<&()>)).await??;
    if !user.login.eq_ignore_ascii_case(requested) {
        return Err(format!(
            "token belongs to GitHub user {}, not requested user {requested}",
            user.login
        )
        .into());
    }
    Ok(user.login)
}

async fn poll_for_token(
    crab: &octocrab::Octocrab,
    client_id: &SecretString,
    codes: &DeviceCodes,
    repository_id: Option<&str>,
) -> Result<OAuth, Box<dyn Error>> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(codes.expires_in);
    let mut interval = Duration::from_secs(codes.interval);

    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("GitHub device code expired before authorization".into());
        }
        tokio::time::sleep(interval.min(remaining)).await;
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("GitHub device code expired before authorization".into());
        }

        let body = DevicePollRequest {
            client_id: client_id.expose_secret(),
            device_code: &codes.device_code,
            grant_type: "urn:ietf:params:oauth:grant-type:device_code",
            repository_id,
        };
        let request = crab.post::<_, OAuthReply>("/login/oauth/access_token", Some(&body));
        let timeout = remaining.min(Duration::from_secs(10));
        let reply = tokio::time::timeout(timeout, request).await??;
        match reply.error.as_deref() {
            None => return Ok(reply.into_oauth()?),
            Some("authorization_pending") => {}
            Some("slow_down") => interval += Duration::from_secs(5),
            Some(error) => {
                return Err(format!("GitHub device authorization failed: {error}").into());
            }
        }
    }
}

fn cache_path() -> Result<PathBuf, Box<dyn Error>> {
    let data_dir = dirs::state_dir()
        .or_else(dirs::data_local_dir)
        .ok_or("could not determine a user state or local data directory")?;
    Ok(data_dir.join("gh-token-manager/token.json"))
}

fn read_cache(path: &Path) -> Result<TokenCache, Box<dyn Error>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(TokenCache::default());
        }
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_file() {
        return Err("token cache must be a regular file".into());
    }
    #[cfg(unix)]
    fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(0o600))?;

    let mut contents = Vec::new();
    File::open(path)?.read_to_end(&mut contents)?;
    Ok(serde_json::from_slice(&contents)?)
}

fn write_cache(path: &Path, cache: &TokenCache) -> Result<(), Box<dyn Error>> {
    let parent = path.parent().ok_or("cache path has no parent directory")?;
    fs::create_dir_all(parent)?;
    #[cfg(unix)]
    fs::set_permissions(parent, std::os::unix::fs::PermissionsExt::from_mode(0o700))?;

    let temp_path = path.with_extension(format!("tmp.{}", std::process::id()));
    let result = (|| -> Result<(), Box<dyn Error>> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        let mut file = options.open(&temp_path)?;
        serde_json::to_writer(&mut file, cache)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&temp_path, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result?;
    Ok(())
}

fn print_token(cache: &CachedToken) -> Result<(), Box<dyn Error>> {
    let output = TokenOutput {
        username: &cache.verified_username,
        access_token: &cache.access_token,
        expires_at: cache
            .expires_at
            .and_then(|expiry| u64::try_from(expiry.unix_timestamp()).ok()),
        refresh_token: cache.refresh_token.as_deref(),
        refresh_token_expires_at: cache
            .refresh_token_expires_at
            .and_then(|expiry| u64::try_from(expiry.unix_timestamp()).ok()),
    };
    println!("{}", serde_json::to_string(&output)?);
    Ok(())
}

fn token_expiry(
    now: OffsetDateTime,
    seconds: Option<usize>,
) -> Result<Option<OffsetDateTime>, Box<dyn Error>> {
    seconds
        .map(|seconds| {
            let seconds = i64::try_from(seconds)?;
            now.checked_add(TimeDuration::seconds(seconds))
                .ok_or_else(|| "token expiry is out of range".into())
        })
        .transpose()
}

#[cfg(test)]
#[cfg_attr(coverage, coverage(off))]
mod tests {
    use std::{
        fs,
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        path::{Path, PathBuf},
        process::Command,
        sync::mpsc,
        thread,
        time::Duration,
    };

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    use super::{
        Args, CachedToken, DeviceCodes, OAuthReply, TokenCache, cache_path, client, obtain_token,
        parse_scope, poll_for_token, print_token, read_cache, token_expiry, write_cache,
    };
    use time::OffsetDateTime;

    const TOKEN: &str = r#"{"access_token":"rotated-access","token_type":"bearer","scope":"offline_access","expires_in":3600,"refresh_token":"rotated-refresh","refresh_token_expires_in":86400}"#;
    const USER: &str = r#"{"login":"alice"}"#;
    const USER_BOB: &str = r#"{"login":"bob"}"#;

    fn mock_server(
        responses: Vec<(u16, &'static str)>,
        pause_first: bool,
    ) -> (
        String,
        mpsc::Receiver<String>,
        mpsc::Sender<()>,
        thread::JoinHandle<()>,
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = format!("http://{}", listener.local_addr().unwrap());
        let (seen_tx, seen_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let server = thread::spawn(move || {
            for (index, (status, body)) in responses.into_iter().enumerate() {
                let (mut stream, _) = listener.accept().unwrap();
                seen_tx.send(read_request(&mut stream)).unwrap();
                if pause_first && index == 0 {
                    release_rx.recv().unwrap();
                }
                let reason = if status == 200 {
                    "OK"
                } else {
                    "Internal Server Error"
                };
                let _ = write!(
                    stream,
                    "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
            }
        });
        (address, seen_rx, release_tx, server)
    }

    fn read_request(stream: &mut TcpStream) -> String {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut request = Vec::new();
        let mut buffer = [0; 4096];
        loop {
            let count = stream.read(&mut buffer).unwrap();
            assert_ne!(count, 0);
            request.extend_from_slice(&buffer[..count]);
            let text = String::from_utf8_lossy(&request);
            if let Some(end) = text.find("\r\n\r\n") {
                let length = text[..end]
                    .lines()
                    .find_map(|line| {
                        line.to_ascii_lowercase()
                            .strip_prefix("content-length: ")
                            .map(str::to_owned)
                    })
                    .and_then(|value| value.parse::<usize>().ok())
                    .unwrap_or(0);
                if request.len() >= end + 4 + length {
                    return text.into_owned();
                }
            }
        }
    }

    #[test]
    fn request_reader_waits_for_header_and_body_completion() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            read_request(&mut stream)
        });
        let mut stream = TcpStream::connect(address).unwrap();
        stream
            .write_all(b"POST / HTTP/1.1\r\nContent-Length: 5\r\n")
            .unwrap();
        stream.flush().unwrap();
        thread::sleep(Duration::from_millis(50));
        stream.write_all(b"\r\n").unwrap();
        stream.flush().unwrap();
        thread::sleep(Duration::from_millis(50));
        stream.write_all(b"hello").unwrap();
        assert!(server.join().unwrap().ends_with("hello"));
    }

    fn test_args(repository_id: Option<&str>) -> Args {
        Args {
            client_id: "app-id".into(),
            username: "alice".into(),
            scope: "offline_access".into(),
            repository_id: repository_id.map(str::to_owned),
            reauthenticate: false,
        }
    }

    fn test_cache_path(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("{name}-{}", std::process::id()))
            .join("token.json")
    }

    fn write_one_cache(
        path: &Path,
        client_id: &str,
        repository_id: Option<&str>,
        cache: &CachedToken,
    ) {
        let mut token_cache = TokenCache::default();
        token_cache.insert(
            client_id,
            &cache.verified_username,
            repository_id,
            cache.clone(),
        );
        write_cache(path, &token_cache).unwrap();
    }

    fn expired_cache() -> CachedToken {
        CachedToken {
            verified_username: "alice".into(),
            access_token: "old-access".into(),
            expires_at: Some(OffsetDateTime::now_utc()),
            refresh_token: Some("old-refresh".into()),
            refresh_token_expires_at: Some(OffsetDateTime::now_utc() + time::Duration::hours(1)),
        }
    }

    #[test]
    fn only_github_app_device_flow_scope_is_accepted() {
        assert_eq!(parse_scope("offline_access").unwrap(), "offline_access");
        assert!(parse_scope("repo").is_err());
        assert!(parse_scope("offline_access repo").is_err());
    }

    #[test]
    fn oauth_reply_errors_and_missing_fields_are_rejected() {
        for (reply, expected) in [
            (r#"{"error":"access_denied"}"#, "access_denied"),
            (
                r#"{"error":"access_denied","error_description":"user denied"}"#,
                "user denied",
            ),
        ] {
            let reply: OAuthReply = serde_json::from_str(reply).unwrap();
            match reply.into_oauth() {
                Err(error) => assert_eq!(error, expected),
                Ok(_) => panic!("OAuth error response unexpectedly became a token"),
            }
        }

        let reply: OAuthReply =
            serde_json::from_str(r#"{"token_type":"bearer","scope":"offline_access"}"#).unwrap();
        assert!(reply.into_oauth().is_err());
    }

    #[test]
    fn cached_token_expiry_and_persistence_are_respected() {
        let now = OffsetDateTime::now_utc();
        let cache = CachedToken {
            verified_username: "user".into(),
            access_token: "access".into(),
            expires_at: Some(now + time::Duration::seconds(120)),
            refresh_token: Some("refresh".into()),
            refresh_token_expires_at: Some(now + time::Duration::seconds(600)),
        };
        assert!(cache.access_token_valid());
        assert!(cache.refresh_token_valid());
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("cache-test-{}", std::process::id()))
            .join("token.json");
        write_one_cache(&path, "app-id", None, &cache);
        let restored = read_cache(&path)
            .unwrap()
            .get("app-id", "USER", None)
            .unwrap()
            .clone();
        assert_eq!(restored.access_token, "access");
        assert_eq!(restored.refresh_token.as_deref(), Some("refresh"));
        #[cfg(unix)]
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );

        let expired = CachedToken {
            expires_at: Some(now),
            refresh_token_expires_at: Some(now),
            ..restored
        };
        assert!(!expired.access_token_valid());
        assert!(!expired.refresh_token_valid());
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn cache_read_handles_missing_files_and_rejects_directories() {
        let path = test_cache_path("cache-path-test");
        let _ = fs::remove_dir_all(path.parent().unwrap());
        assert!(read_cache(&path).unwrap().clients.is_empty());
        fs::create_dir_all(&path).unwrap();
        assert!(read_cache(&path).is_err());
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn cache_path_and_expiry_conversion_are_bounded() {
        assert!(
            cache_path()
                .unwrap()
                .ends_with("gh-token-manager/token.json")
        );
        let now = OffsetDateTime::now_utc();
        assert!(token_expiry(now, None).unwrap().is_none());
        assert!(token_expiry(now, Some(usize::MAX)).is_err());
    }

    #[test]
    fn cache_removal_is_scoped_to_requested_token() {
        let mut cache = TokenCache::default();
        cache.insert("app", "alice", None, expired_cache());
        cache.insert("app", "alice", Some("repo"), expired_cache());
        cache.remove("app", "alice", Some("repo"));
        assert!(cache.get("app", "alice", Some("repo")).is_none());
        assert!(cache.get("app", "alice", None).is_some());
        cache.remove("app", "alice", None);
        assert!(cache.get("app", "alice", None).is_none());
        cache.remove("missing", "alice", None);
    }

    #[cfg(unix)]
    #[test]
    fn cache_permission_errors_are_not_treated_as_missing() {
        let path = test_cache_path("cache-permission-test");
        let _ = fs::remove_dir_all(path.parent().unwrap());
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::set_permissions(
            path.parent().unwrap(),
            std::os::unix::fs::PermissionsExt::from_mode(0o000),
        )
        .unwrap();
        let result = read_cache(&path);
        fs::set_permissions(
            path.parent().unwrap(),
            std::os::unix::fs::PermissionsExt::from_mode(0o700),
        )
        .unwrap();
        assert!(result.is_err());
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn cache_write_removes_temporary_file_if_rename_fails() {
        let path = test_cache_path("cache-write-failure-test");
        let _ = fs::remove_dir_all(path.parent().unwrap());
        fs::create_dir_all(&path).unwrap();
        let temp_path = path.with_extension(format!("tmp.{}", std::process::id()));
        assert!(write_cache(&path, &TokenCache::default()).is_err());
        assert!(!temp_path.exists());
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn token_output_is_serialized() {
        let cache = expired_cache();
        print_token(&cache).unwrap();
    }

    #[tokio::test]
    async fn cache_keeps_tokens_for_multiple_users() {
        let (base, seen, _release, server) =
            mock_server(vec![(200, USER), (200, USER), (200, USER_BOB)], false);
        let path = test_cache_path("multi-user-cache-test");
        let _ = fs::remove_dir_all(path.parent().unwrap());
        let mut alice = expired_cache();
        alice.access_token = "alice-access".into();
        alice.expires_at = Some(OffsetDateTime::now_utc() + time::Duration::hours(1));
        alice.refresh_token = None;
        let mut alice_repository = expired_cache();
        alice_repository.access_token = "alice-repository-42".into();
        alice_repository.expires_at = Some(OffsetDateTime::now_utc() + time::Duration::hours(1));
        alice_repository.refresh_token = None;
        let mut bob = expired_cache();
        bob.verified_username = "bob".into();
        bob.access_token = "bob-access".into();
        bob.expires_at = Some(OffsetDateTime::now_utc() + time::Duration::hours(1));
        bob.refresh_token = None;
        let mut caches = TokenCache::default();
        caches.insert("app-id", "alice", None, alice);
        caches.insert("app-id", "alice", Some("42"), alice_repository);
        caches.insert("app-id", "bob", None, bob);
        write_cache(&path, &caches).unwrap();
        let serialized = serde_json::to_value(&caches).unwrap();
        assert_eq!(
            serialized["clients"]["app-id"]["users"]["alice"]["token"]["access_token"],
            "alice-access"
        );
        assert_eq!(
            serialized["clients"]["app-id"]["users"]["alice"]["repository_tokens"]["42"]["access_token"],
            "alice-repository-42"
        );

        assert_eq!(
            obtain_token(&test_args(None), &client(&base).unwrap(), &base, &path)
                .await
                .unwrap()
                .access_token,
            "alice-access"
        );
        let repository_args = test_args(Some("42"));
        assert_eq!(
            obtain_token(&repository_args, &client(&base).unwrap(), &base, &path)
                .await
                .unwrap()
                .access_token,
            "alice-repository-42"
        );
        let mut bob_args = test_args(None);
        bob_args.username = "bob".into();
        assert_eq!(
            obtain_token(&bob_args, &client(&base).unwrap(), &base, &path)
                .await
                .unwrap()
                .access_token,
            "bob-access"
        );

        let caches = read_cache(&path).unwrap();
        assert_eq!(caches.clients.len(), 1);
        assert_eq!(caches.clients["app-id"].users.len(), 2);
        assert_eq!(
            caches.get("app-id", "alice", None).unwrap().access_token,
            "alice-access"
        );
        assert_eq!(
            caches
                .get("app-id", "alice", Some("42"))
                .unwrap()
                .access_token,
            "alice-repository-42"
        );
        assert_eq!(
            caches.get("app-id", "bob", None).unwrap().access_token,
            "bob-access"
        );
        for _ in 0..3 {
            assert!(
                seen.recv_timeout(Duration::from_secs(2))
                    .unwrap()
                    .starts_with("GET /user ")
            );
        }
        server.join().unwrap();
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[tokio::test]
    async fn expired_token_without_refresh_and_reauthentication_are_scoped_by_user() {
        let temporary_error = (400, r#"{"message":"invalid request"}"#);
        let (base, seen, _release, server) = mock_server(vec![temporary_error; 2], false);
        let path = test_cache_path("reauth-multi-user-test");
        let _ = fs::remove_dir_all(path.parent().unwrap());
        let mut alice = expired_cache();
        alice.refresh_token = None;
        let mut alice_repository = expired_cache();
        alice_repository.access_token = "alice-repository-42".into();
        alice_repository.expires_at = Some(OffsetDateTime::now_utc() + time::Duration::hours(1));
        let mut bob = expired_cache();
        bob.verified_username = "bob".into();
        bob.access_token = "bob-access".into();
        bob.expires_at = Some(OffsetDateTime::now_utc() + time::Duration::hours(1));
        bob.refresh_token = None;
        let mut caches = TokenCache::default();
        caches.insert("app-id", "alice", None, alice);
        caches.insert("app-id", "alice", Some("42"), alice_repository);
        caches.insert("app-id", "bob", None, bob);
        write_cache(&path, &caches).unwrap();

        assert!(
            obtain_token(&test_args(None), &client(&base).unwrap(), &base, &path)
                .await
                .is_err()
        );
        assert!(
            read_cache(&path)
                .unwrap()
                .get("app-id", "alice", None)
                .is_some()
        );

        let mut args = test_args(None);
        args.reauthenticate = true;
        assert!(
            obtain_token(&args, &client(&base).unwrap(), &base, &path)
                .await
                .is_err()
        );
        let caches = read_cache(&path).unwrap();
        assert!(caches.get("app-id", "alice", None).is_none());
        assert_eq!(
            caches
                .get("app-id", "alice", Some("42"))
                .unwrap()
                .access_token,
            "alice-repository-42"
        );
        assert_eq!(
            caches.get("app-id", "bob", None).unwrap().access_token,
            "bob-access"
        );
        for _ in 0..2 {
            seen.recv_timeout(Duration::from_secs(2)).unwrap();
        }
        server.join().unwrap();
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn concurrent_refresh_processes_keep_rotated_cache_and_repository_restriction() {
        let (base, seen, release, server) =
            mock_server(vec![(200, TOKEN), (200, USER), (200, USER)], true);
        let path = test_cache_path("process-lock-test");
        let _ = fs::remove_dir_all(path.parent().unwrap());
        write_one_cache(&path, "app-id", Some("42"), &expired_cache());
        let spawn = || {
            Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "tests::lock_child_process", "--nocapture"])
                .env("GH_TOKEN_MANAGER_TEST_CHILD", "1")
                .env("GH_TOKEN_MANAGER_TEST_BASE", &base)
                .env("GH_TOKEN_MANAGER_TEST_CACHE", &path)
                .spawn()
                .unwrap()
        };
        let mut first = spawn();
        let refresh = seen.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(refresh.contains(r#""repository_id":"42""#));
        assert!(refresh.contains(r#""refresh_token":"old-refresh""#));
        let mut second = spawn();
        thread::sleep(Duration::from_millis(100));
        release.send(()).unwrap();
        assert!(first.wait().unwrap().success());
        assert!(second.wait().unwrap().success());
        for _ in 0..2 {
            assert!(
                seen.recv_timeout(Duration::from_secs(5))
                    .unwrap()
                    .starts_with("GET /user ")
            );
        }
        server.join().unwrap();
        assert_eq!(
            read_cache(&path)
                .unwrap()
                .get("app-id", "alice", Some("42"))
                .unwrap()
                .refresh_token
                .as_deref(),
            Some("rotated-refresh")
        );
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[tokio::test]
    async fn lock_child_process() {
        if std::env::var_os("GH_TOKEN_MANAGER_TEST_CHILD").is_none() {
            return;
        }
        let base = std::env::var("GH_TOKEN_MANAGER_TEST_BASE").unwrap();
        let path = PathBuf::from(std::env::var("GH_TOKEN_MANAGER_TEST_CACHE").unwrap());
        let token = obtain_token(
            &test_args(Some("42")),
            &client(&base).unwrap(),
            &base,
            &path,
        )
        .await
        .unwrap();
        assert_eq!(token.access_token, "rotated-access");
    }

    #[tokio::test]
    async fn bad_refresh_token_restarts_device_flow_with_repository_id() {
        let (base, seen, _release, server) = mock_server(
            vec![
                (200, r#"{"error":"bad_refresh_token"}"#),
                (
                    200,
                    r#"{"device_code":"device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":30,"interval":0}"#,
                ),
                (200, TOKEN),
                (200, USER),
            ],
            false,
        );
        let path = test_cache_path("bad-refresh-test");
        let _ = fs::remove_dir_all(path.parent().unwrap());
        write_one_cache(&path, "app-id", Some("42"), &expired_cache());
        let args = test_args(Some("42"));
        assert_eq!(
            obtain_token(&args, &client(&base).unwrap(), &base, &path)
                .await
                .unwrap()
                .access_token,
            "rotated-access"
        );
        let requests: Vec<_> = (0..4)
            .map(|_| seen.recv_timeout(Duration::from_secs(2)).unwrap())
            .collect();
        assert!(requests[0].contains(r#""grant_type":"refresh_token""#));
        assert!(requests[1].starts_with("POST /login/device/code "));
        assert!(requests[2].contains(r#""repository_id":"42""#));
        server.join().unwrap();
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[tokio::test]
    async fn device_poll_rejects_expiry_before_and_after_sleep() {
        let client = client("http://127.0.0.1:1").unwrap();
        let client_id = secrecy::SecretString::from("app-id");
        let expired: DeviceCodes = serde_json::from_str(
            r#"{"device_code":"device","user_code":"CODE","verification_uri":"https://github.com/login/device","expires_in":0,"interval":0}"#,
        )
        .unwrap();
        assert!(
            poll_for_token(&client, &client_id, &expired, None)
                .await
                .is_err()
        );

        let expires_after_sleep: DeviceCodes = serde_json::from_str(
            r#"{"device_code":"device","user_code":"CODE","verification_uri":"https://github.com/login/device","expires_in":1,"interval":1}"#,
        )
        .unwrap();
        assert!(
            poll_for_token(&client, &client_id, &expires_after_sleep, None)
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn device_poll_handles_pending_slowdown_and_terminal_error() {
        let (base, seen, _release, server) = mock_server(
            vec![
                (200, r#"{"error":"authorization_pending"}"#),
                (200, r#"{"error":"slow_down"}"#),
                (200, r#"{"error":"access_denied"}"#),
                (200, r#"{"error":"expired_token"}"#),
            ],
            false,
        );
        let codes: DeviceCodes = serde_json::from_str(
            r#"{"device_code":"device","user_code":"CODE","verification_uri":"https://github.com/login/device","expires_in":30,"interval":0}"#,
        )
        .unwrap();
        let client_id = secrecy::SecretString::from("app-id");
        let client = client(&base).unwrap();
        let denied = poll_for_token(&client, &client_id, &codes, None).await;
        let expired = poll_for_token(&client, &client_id, &codes, None).await;
        for (result, expected) in [(denied, true), (expired, false)] {
            assert_eq!(
                matches!(result, Err(error) if error.to_string().contains("access_denied")),
                expected
            );
        }
        for _ in 0..4 {
            assert!(
                seen.recv_timeout(Duration::from_secs(2))
                    .unwrap()
                    .starts_with("POST /login/oauth/access_token ")
            );
        }
        server.join().unwrap();
    }

    #[tokio::test]
    async fn stalled_device_poll_cannot_outlive_device_deadline() {
        let (base, seen, release, server) = mock_server(vec![(200, TOKEN)], true);
        let codes: DeviceCodes = serde_json::from_str(r#"{"device_code":"device","user_code":"CODE","verification_uri":"https://github.com/login/device","expires_in":1,"interval":0}"#).unwrap();
        let client = client(&base).unwrap();
        assert!(
            poll_for_token(
                &client,
                &secrecy::SecretString::from("app-id"),
                &codes,
                None
            )
            .await
            .is_err()
        );
        assert!(
            seen.recv_timeout(Duration::from_secs(2))
                .unwrap()
                .starts_with("POST /login/oauth/access_token ")
        );
        release.send(()).unwrap();
        server.join().unwrap();
    }

    #[tokio::test]
    async fn username_mismatch_keeps_cache_but_refuses_to_return_token() {
        let (base, seen, _release, server) = mock_server(vec![(200, r#"{"login":"bob"}"#)], false);
        let path = test_cache_path("username-test");
        let _ = fs::remove_dir_all(path.parent().unwrap());
        let mut cache = expired_cache();
        cache.access_token = "valid-access".into();
        cache.expires_at = Some(OffsetDateTime::now_utc() + time::Duration::hours(1));
        cache.refresh_token = None;
        write_one_cache(&path, "app-id", None, &cache);
        let before = fs::read(&path).unwrap();
        assert!(
            obtain_token(&test_args(None), &client(&base).unwrap(), &base, &path)
                .await
                .is_err()
        );
        assert!(
            seen.recv_timeout(Duration::from_secs(2))
                .unwrap()
                .starts_with("GET /user ")
        );
        server.join().unwrap();
        assert_eq!(fs::read(&path).unwrap(), before);
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[tokio::test]
    async fn transient_refresh_error_preserves_existing_cache() {
        let (base, seen, _release, server) =
            mock_server(vec![(500, r#"{"message":"temporary failure"}"#)], false);
        let path = test_cache_path("transient-test");
        let _ = fs::remove_dir_all(path.parent().unwrap());
        write_one_cache(&path, "app-id", None, &expired_cache());
        let before = fs::read(&path).unwrap();
        let args = test_args(None);
        assert!(
            obtain_token(&args, &client(&base).unwrap(), &base, &path)
                .await
                .is_err()
        );
        assert!(
            seen.recv_timeout(Duration::from_secs(2))
                .unwrap()
                .contains(r#""grant_type":"refresh_token""#)
        );
        server.join().unwrap();
        assert_eq!(fs::read(&path).unwrap(), before);
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[tokio::test]
    async fn rotated_credentials_survive_identity_verification_failure() {
        let (base, seen, _release, server) = mock_server(
            vec![
                (200, TOKEN),
                (500, r#"{"message":"temporary failure"}"#),
                (500, r#"{"message":"temporary failure"}"#),
                (500, r#"{"message":"temporary failure"}"#),
                (500, r#"{"message":"temporary failure"}"#),
                (200, USER),
            ],
            false,
        );
        let path = test_cache_path("rotated-before-user-test");
        let _ = fs::remove_dir_all(path.parent().unwrap());
        write_one_cache(&path, "app-id", None, &expired_cache());

        assert!(
            obtain_token(&test_args(None), &client(&base).unwrap(), &base, &path)
                .await
                .is_err()
        );
        let rotated_cache = read_cache(&path).unwrap();
        let rotated = rotated_cache.get("app-id", "alice", None).unwrap();
        assert_eq!(rotated.access_token, "rotated-access");
        assert_eq!(rotated.refresh_token.as_deref(), Some("rotated-refresh"));

        assert_eq!(
            obtain_token(&test_args(None), &client(&base).unwrap(), &base, &path)
                .await
                .unwrap()
                .access_token,
            "rotated-access"
        );
        let requests: Vec<_> = (0..6)
            .map(|_| seen.recv_timeout(Duration::from_secs(2)).unwrap())
            .collect();
        assert!(requests[0].contains(r#""refresh_token":"old-refresh""#));
        assert!(
            requests[1..]
                .iter()
                .all(|request| request.starts_with("GET /user "))
        );
        server.join().unwrap();
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }
}
