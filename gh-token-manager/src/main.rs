use std::{
    error::Error,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

use clap::Parser;
use http::header::ACCEPT;
use octocrab::auth::{DeviceCodes, OAuth};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};

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
    repository_id: Option<u64>,
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

#[derive(Serialize, Deserialize)]
struct TokenCache {
    client_id: String,
    #[serde(default)]
    username: String,
    #[serde(default)]
    repository_id: Option<u64>,
    access_token: String,
    expires_at: Option<u64>,
    refresh_token: Option<String>,
    refresh_token_expires_at: Option<u64>,
}

impl TokenCache {
    fn from_oauth(
        client_id: &str,
        username: &str,
        repository_id: Option<u64>,
        oauth: &OAuth,
    ) -> Self {
        let now = unix_time();
        Self {
            client_id: client_id.to_owned(),
            username: username.to_owned(),
            repository_id,
            access_token: oauth.access_token.expose_secret().to_owned(),
            expires_at: oauth.expires_in.map(|seconds| now + seconds as u64),
            refresh_token: oauth
                .refresh_token
                .as_ref()
                .map(|token| token.expose_secret().to_owned()),
            refresh_token_expires_at: oauth
                .refresh_token_expires_in
                .map(|seconds| now + seconds as u64),
        }
    }

    fn access_token_valid(&self) -> bool {
        self.expires_at
            .is_none_or(|expiry| expiry > unix_time() + 60)
    }

    fn refresh_token_valid(&self) -> bool {
        self.refresh_token.is_some()
            && self
                .refresh_token_expires_at
                .is_none_or(|expiry| expiry > unix_time())
    }

    fn matches_request(&self, client_id: &str, username: &str, repository_id: Option<u64>) -> bool {
        self.client_id == client_id
            && self.username.eq_ignore_ascii_case(username)
            && self.repository_id == repository_id
    }
}

#[derive(Serialize)]
struct RefreshRequest<'a> {
    client_id: &'a str,
    grant_type: &'static str,
    refresh_token: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    repository_id: Option<u64>,
}

#[derive(Serialize)]
struct DevicePollRequest<'a> {
    client_id: &'a str,
    device_code: &'a str,
    grant_type: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    repository_id: Option<u64>,
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
) -> Result<TokenCache, Box<dyn Error>> {
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

    if args.reauthenticate {
        match fs::remove_file(cache_path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    let cached = if args.reauthenticate {
        None
    } else {
        read_cache(cache_path)?.filter(|cache| {
            cache.matches_request(&args.client_id, &args.username, args.repository_id)
        })
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
                        repository_id: args.repository_id,
                    }),
                ),
            )
            .await??;
            if reply.error.as_deref() == Some("bad_refresh_token") {
                (device_authorize(crab, args).await?, true)
            } else {
                let oauth = reply.into_oauth()?;
                (
                    TokenCache::from_oauth(
                        &args.client_id,
                        &args.username,
                        args.repository_id,
                        &oauth,
                    ),
                    true,
                )
            }
        }
        _ => (device_authorize(crab, args).await?, true),
    };

    let login = verify_username(&cache, &args.username, api_base).await?;
    let mut cache = cache;
    cache.username = login;
    if changed {
        write_cache(cache_path, &cache)?;
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
) -> Result<TokenCache, Box<dyn Error>> {
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
    let oauth = poll_for_token(crab, &client_id, &codes, args.repository_id).await?;
    Ok(TokenCache::from_oauth(
        &args.client_id,
        &args.username,
        args.repository_id,
        &oauth,
    ))
}

#[derive(Deserialize)]
struct GitHubUser {
    login: String,
}

async fn verify_username(
    cache: &TokenCache,
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
    repository_id: Option<u64>,
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

fn read_cache(path: &Path) -> Result<Option<TokenCache>, Box<dyn Error>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_file() {
        return Err("token cache must be a regular file".into());
    }
    #[cfg(unix)]
    fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(0o600))?;

    let mut contents = Vec::new();
    File::open(path)?.read_to_end(&mut contents)?;
    Ok(Some(serde_json::from_slice(&contents)?))
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

fn print_token(cache: &TokenCache) -> Result<(), Box<dyn Error>> {
    let output = TokenOutput {
        username: &cache.username,
        access_token: &cache.access_token,
        expires_at: cache.expires_at,
        refresh_token: cache.refresh_token.as_deref(),
        refresh_token_expires_at: cache.refresh_token_expires_at,
    };
    println!("{}", serde_json::to_string(&output)?);
    Ok(())
}

fn unix_time() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        path::PathBuf,
        process::Command,
        sync::mpsc,
        thread,
        time::Duration,
    };

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    use super::{
        Args, DeviceCodes, TokenCache, client, obtain_token, parse_scope, poll_for_token,
        read_cache, unix_time, write_cache,
    };

    const TOKEN: &str = r#"{"access_token":"rotated-access","token_type":"bearer","scope":"offline_access","expires_in":3600,"refresh_token":"rotated-refresh","refresh_token_expires_in":86400}"#;
    const USER: &str = r#"{"login":"alice"}"#;

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

    fn test_args(repository_id: Option<u64>) -> Args {
        Args {
            client_id: "app-id".into(),
            username: "alice".into(),
            scope: "offline_access".into(),
            repository_id,
            reauthenticate: false,
        }
    }

    fn test_cache_path(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("{name}-{}", std::process::id()))
            .join("token.json")
    }

    fn expired_cache(repository_id: Option<u64>) -> TokenCache {
        TokenCache {
            client_id: "app-id".into(),
            username: "alice".into(),
            repository_id,
            access_token: "old-access".into(),
            expires_at: Some(unix_time()),
            refresh_token: Some("old-refresh".into()),
            refresh_token_expires_at: Some(unix_time() + 3600),
        }
    }

    #[test]
    fn only_github_app_device_flow_scope_is_accepted() {
        assert_eq!(parse_scope("offline_access").unwrap(), "offline_access");
        assert!(parse_scope("repo").is_err());
        assert!(parse_scope("offline_access repo").is_err());
    }

    #[test]
    fn cached_token_expiry_and_persistence_are_respected() {
        let now = unix_time();
        let cache = TokenCache {
            client_id: "app-id".into(),
            username: "user".into(),
            repository_id: None,
            access_token: "access".into(),
            expires_at: Some(now + 120),
            refresh_token: Some("refresh".into()),
            refresh_token_expires_at: Some(now + 600),
        };
        assert!(cache.access_token_valid());
        assert!(cache.refresh_token_valid());
        assert!(cache.matches_request("app-id", "USER", None));
        assert!(!cache.matches_request("app-id", "user", Some(42)));
        assert!(!cache.matches_request("other-app", "user", None));

        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target")
            .join(format!("cache-test-{}", std::process::id()))
            .join("token.json");
        write_cache(&path, &cache).unwrap();
        let restored = read_cache(&path).unwrap().unwrap();
        assert_eq!(restored.access_token, "access");
        assert_eq!(restored.refresh_token.as_deref(), Some("refresh"));
        #[cfg(unix)]
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );

        let expired = TokenCache {
            expires_at: Some(now),
            refresh_token_expires_at: Some(now),
            ..restored
        };
        assert!(!expired.access_token_valid());
        assert!(!expired.refresh_token_valid());
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn concurrent_refresh_processes_keep_rotated_cache_and_repository_restriction() {
        let (base, seen, release, server) =
            mock_server(vec![(200, TOKEN), (200, USER), (200, USER)], true);
        let path = test_cache_path("process-lock-test");
        let _ = fs::remove_dir_all(path.parent().unwrap());
        write_cache(&path, &expired_cache(Some(42))).unwrap();
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
        assert!(refresh.contains(r#""repository_id":42"#));
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
            read_cache(&path).unwrap().unwrap().refresh_token.as_deref(),
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
        let token = obtain_token(&test_args(Some(42)), &client(&base).unwrap(), &base, &path)
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
        write_cache(&path, &expired_cache(Some(42))).unwrap();
        let args = test_args(Some(42));
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
        assert!(requests[2].contains(r#""repository_id":42"#));
        server.join().unwrap();
        fs::remove_dir_all(path.parent().unwrap()).unwrap();
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
        let mut cache = expired_cache(None);
        cache.access_token = "valid-access".into();
        cache.expires_at = Some(unix_time() + 3600);
        cache.refresh_token = None;
        write_cache(&path, &cache).unwrap();
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
        write_cache(&path, &expired_cache(None)).unwrap();
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
}
