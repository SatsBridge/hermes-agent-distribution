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
use octocrab::auth::{Continue, DeviceCodes, OAuth, TokenResponse};
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};

#[derive(Parser)]
#[command(about = "Issue and refresh a GitHub App user access token")]
struct Args {
    /// GitHub App client ID (not the App ID or client secret)
    #[arg(long, env = "GITHUB_APP_CLIENT_ID")]
    client_id: String,
    /// GitHub App device-flow scope. GitHub Apps support only offline_access here.
    #[arg(long, default_value = "offline_access", value_parser = parse_scope)]
    scope: String,
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
    access_token: String,
    expires_at: Option<u64>,
    refresh_token: Option<String>,
    refresh_token_expires_at: Option<u64>,
}

impl TokenCache {
    fn from_oauth(client_id: &str, oauth: OAuth) -> Self {
        let now = unix_time();
        Self {
            client_id: client_id.to_owned(),
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
}

#[derive(Serialize)]
struct RefreshRequest<'a> {
    client_id: &'a str,
    grant_type: &'static str,
    refresh_token: &'a str,
}

#[derive(Serialize)]
struct TokenOutput<'a> {
    access_token: &'a str,
    expires_at: Option<u64>,
    refresh_token: Option<&'a str>,
    refresh_token_expires_at: Option<u64>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    let args = Args::parse();
    let cache_path = cache_path()?;
    let crab = octocrab::Octocrab::builder()
        .base_uri("https://github.com")?
        .add_header(ACCEPT, "application/json".to_owned())
        .build()?;

    let cached = if args.reauthenticate {
        None
    } else {
        read_cache(&cache_path)?.filter(|cache| cache.client_id == args.client_id)
    };
    let cache = match cached {
        Some(cache) if cache.access_token_valid() => cache,
        Some(cache) if cache.refresh_token_valid() => {
            let refresh_token = cache.refresh_token.as_deref().expect("validated above");
            let oauth = crab
                .post(
                    "/login/oauth/access_token",
                    Some(&RefreshRequest {
                        client_id: &args.client_id,
                        grant_type: "refresh_token",
                        refresh_token,
                    }),
                )
                .await?;
            TokenCache::from_oauth(&args.client_id, oauth)
        }
        _ => {
            let client_id = SecretString::from(args.client_id.clone());
            let codes = crab
                .authenticate_as_device(&client_id, [&args.scope])
                .await?;
            eprintln!(
                "Open {} and enter code {}",
                codes.verification_uri, codes.user_code
            );
            let oauth = poll_for_token(&crab, &client_id, &codes).await?;
            TokenCache::from_oauth(&args.client_id, oauth)
        }
    };

    write_cache(&cache_path, &cache)?;
    print_token(&cache)?;
    Ok(())
}

async fn poll_for_token(
    crab: &octocrab::Octocrab,
    client_id: &SecretString,
    codes: &DeviceCodes,
) -> Result<OAuth, Box<dyn Error>> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(codes.expires_in);
    let mut interval = Duration::from_secs(codes.interval);

    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err("GitHub device code expired before authorization".into());
        }
        tokio::time::sleep(interval.min(remaining)).await;
        if tokio::time::Instant::now() >= deadline {
            return Err("GitHub device code expired before authorization".into());
        }

        match codes.poll_once(crab, client_id).await? {
            TokenResponse::Ok(oauth) => return Ok(oauth),
            TokenResponse::Continue {
                error: Continue::AuthorizationPending,
            } => {}
            TokenResponse::Continue {
                error: Continue::SlowDown,
            } => {
                interval += Duration::from_secs(5);
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
    use std::{fs, path::PathBuf};

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    use super::{TokenCache, parse_scope, read_cache, unix_time, write_cache};

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
            access_token: "access".into(),
            expires_at: Some(now + 120),
            refresh_token: Some("refresh".into()),
            refresh_token_expires_at: Some(now + 600),
        };
        assert!(cache.access_token_valid());
        assert!(cache.refresh_token_valid());

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
}
