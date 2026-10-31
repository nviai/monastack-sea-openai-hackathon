//! Shared host-side runtime layout. Explicit environment paths remain supported.
use std::{
    env,
    path::{Path, PathBuf},
};

fn project_root(start: &Path) -> PathBuf {
    start
        .ancestors()
        .find(|dir| dir.join("data/seed/nviai/seed.v1.json").is_file())
        .unwrap_or(start)
        .to_path_buf()
}
pub fn directory() -> std::io::Result<PathBuf> {
    let cwd = env::current_dir()?;
    Ok(env::var_os("MONASTACK_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| project_root(&cwd).join("runtime")))
}
pub fn load_env() -> Result<(), Box<dyn std::error::Error>> {
    if let Some(path) = env::var_os("MONASTACK_ENV_FILE") {
        dotenvy::from_path(path)?;
    } else {
        let path = directory()?.join(".env");
        if path.is_file() {
            dotenvy::from_path(path)?;
        } else {
            // Compatibility for installations still using a root .env.
            match dotenvy::dotenv() {
                Ok(_) => (),
                Err(dotenvy::Error::Io(error)) if error.kind() == std::io::ErrorKind::NotFound => {
                    ()
                }
                Err(error) => return Err(error.into()),
            }
        }
    }
    Ok(())
}
pub fn database() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Some(path) = env::var_os("MONASTACK_DB") {
        return Ok(path.into());
    }
    let root = project_root(&env::current_dir()?);
    let path = directory()?.join("db/office.sqlite3");
    if !path.exists()
        && [
            "office.sqlite3",
            "client-office.sqlite3",
            "server-office.sqlite3",
        ]
        .iter()
        .any(|name| root.join(name).is_file())
    {
        return Err("legacy database found at repository root; stop the node and migrate it to runtime/db/office.sqlite3, or set MONASTACK_DB explicitly".into());
    }
    Ok(path)
}
pub fn create_parent(path: &Path) -> std::io::Result<()> {
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    Ok(())
}
/// Validate an advertised client URL independently from internal control traffic.
pub fn advertised_url(value: &str, scheme: &str) -> Result<String, Box<dyn std::error::Error>> {
    let prefix = format!("{scheme}://");
    let address: std::net::SocketAddr = value
        .strip_prefix(&prefix)
        .ok_or("invalid advertised URL scheme")?
        .parse()?;
    let allowed = address.ip().is_loopback()
        || matches!(address.ip(), std::net::IpAddr::V4(ip) if ip.is_private());
    if !allowed || address.port() == 0 {
        return Err(
            "advertised URL must use loopback or a private LAN address and nonzero port".into(),
        );
    }
    Ok(format!("{prefix}{address}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn advertised_addresses_accept_lan_but_reject_invalid_destinations() {
        assert_eq!(
            advertised_url("http://192.168.224.217:47831", "http").unwrap(),
            "http://192.168.224.217:47831"
        );
        assert!(advertised_url("ws://192.168.224.217:7880", "ws").is_ok());
        for value in [
            "http://8.8.8.8:80",
            "http://0.0.0.0:80",
            "http://192.168.224.217:0",
            "http://192.168.224.217:80/path",
            "http://user@192.168.224.217:80",
        ] {
            assert!(advertised_url(value, "http").is_err());
        }
    }

    #[test]
    fn discovers_root_from_nested_working_directories() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .unwrap();
        assert_eq!(project_root(&root.join("backend/office-node")), root);
        assert_eq!(
            project_root(Path::new("/no-monastack-here")),
            PathBuf::from("/no-monastack-here")
        );
    }
}
