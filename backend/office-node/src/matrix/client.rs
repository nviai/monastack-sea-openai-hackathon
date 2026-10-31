use super::*;

#[derive(Clone)]
pub struct Bridge {
    pub public_url: String,
    pub(super) server_name: String,
    pub(super) admin_url: String,
    pub(super) admin_token: String,
    pub(super) admin_user: String,
    pub(super) jwt_secret: String,
    pub(super) client: reqwest::Client,
    pub(super) resources:
        Arc<std::sync::Mutex<std::collections::BTreeMap<String, Arc<tokio::sync::Mutex<()>>>>>,
    pub(super) gate: Arc<tokio::sync::Mutex<()>>,
}
pub type Config = Option<Arc<Bridge>>;
impl Bridge {
    pub fn from_env() -> Result<Config, Box<dyn std::error::Error>> {
        if std::env::var("MONASTACK_MATRIX_DISABLED").as_deref() == Ok("1") {
            return Ok(None);
        }
        let Some(dir) = std::env::var_os("MONASTACK_MATRIX_DIR") else {
            return Ok(None);
        };
        let dir = std::path::PathBuf::from(dir);
        let credentials: Value = serde_json::from_slice(&std::fs::read(dir.join("bridge.json"))?)?;
        let server_name = credentials["server_name"]
            .as_str()
            .ok_or("missing Matrix server name")?
            .to_owned();
        let public = match std::env::var("MONASTACK_MATRIX_PUBLIC_URL") {
            Ok(url) => url,
            Err(_) => {
                let address: Value = serde_json::from_slice(&std::fs::read(
                    crate::runtime_paths::directory()?.join("server-address.json"),
                )?)?;
                format!(
                    "http://{}:8008",
                    address["host"].as_str().ok_or("missing server address")?
                )
            }
        };
        let public_url = crate::runtime_paths::advertised_url(&public, "http")?;
        let admin_url = credentials["admin_url"]
            .as_str()
            .ok_or("missing Matrix admin URL")?
            .to_owned();
        let url = reqwest::Url::parse(&admin_url)?;
        if url.scheme() != "http"
            || !url
                .host_str()
                .and_then(|h| h.parse::<std::net::IpAddr>().ok())
                .is_some_and(|ip| ip.is_loopback())
            || url.path() != "/"
            || url.query().is_some()
            || !url.username().is_empty()
        {
            return Err("Matrix admin must be loopback HTTP".into());
        }
        Ok(Some(Arc::new(Self {
            public_url,
            server_name,
            admin_url: admin_url.trim_end_matches('/').into(),
            admin_token: credentials["admin_token"]
                .as_str()
                .ok_or("missing admin token")?
                .into(),
            admin_user: credentials["admin_user"]
                .as_str()
                .ok_or("missing admin user")?
                .into(),
            jwt_secret: credentials["jwt_secret"]
                .as_str()
                .ok_or("missing JWT secret")?
                .into(),
            client: reqwest::Client::builder()
                .no_proxy()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(20))
                .build()?,
            resources: Arc::default(),
            gate: Arc::new(tokio::sync::Mutex::new(())),
        })))
    }
    pub(super) async fn resource_gate(&self, key: String) -> tokio::sync::OwnedMutexGuard<()> {
        let gate = {
            self.resources
                .lock()
                .unwrap()
                .entry(key)
                .or_default()
                .clone()
        };
        gate.lock_owned().await
    }
    pub(super) async fn call(
        &self,
        method: Method,
        path: &str,
        body: Value,
    ) -> Result<Value, ApiError> {
        let response = self
            .client
            .request(method, format!("{}{}", self.admin_url, path))
            .bearer_auth(&self.admin_token)
            .json(&body)
            .send()
            .await
            .map_err(|_| unavailable())?;
        let status = response.status();
        // Deliberately never log the URL, token or Synapse response body.
        if !status.is_success() {
            let operation = if path.contains("/state/") {
                "room state"
            } else if path.contains("/join/") {
                "membership"
            } else if path.contains("/users/") {
                "identity"
            } else if path.ends_with("/members") {
                "membership read"
            } else if path.ends_with("/createRoom") {
                "room creation"
            } else {
                "bridge"
            };
            let error = response.json::<Value>().await.ok();
            let reason = match error.as_ref().and_then(|v| v["errcode"].as_str()) {
                Some("M_LIMIT_EXCEEDED") => "rate limit",
                Some("M_BAD_JSON" | "M_NOT_JSON") => "invalid JSON",
                Some("M_FORBIDDEN") => "forbidden",
                Some("M_INVALID_PARAM") => "invalid parameter",
                Some(_) => "other Matrix error",
                None => "non-Matrix response",
            };
            eprintln!(
                "Matrix {operation} request failed with HTTP {} ({reason})",
                status.as_u16()
            );
            return Err(unavailable());
        }
        response.json().await.map_err(|_| unavailable())
    }
}
