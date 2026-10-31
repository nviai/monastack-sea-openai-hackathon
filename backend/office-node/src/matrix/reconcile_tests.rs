//! Fault injection at the HTTP boundary: SQLite and reconcile are real.
use super::*;
use axum::{body::Bytes, http::Uri, routing::any, Router};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Mutex,
};

type Calls = Arc<Mutex<Vec<(String, Value)>>>;

async fn fixture() -> (
    Bridge,
    Db,
    Calls,
    Arc<AtomicBool>,
    tokio::task::JoinHandle<()>,
) {
    let calls: Calls = Arc::new(Mutex::new(Vec::new()));
    let fail = Arc::new(AtomicBool::new(true));
    let recorded = calls.clone();
    let failing = fail.clone();
    let router = Router::new().fallback(any(move |method: Method, uri: Uri, body: Bytes| {
        let calls = recorded.clone();
        let fail = failing.clone();
        async move {
            let path = uri.path().to_string();
            let body: Value = serde_json::from_slice(&body).unwrap_or(json!({}));
            calls.lock().unwrap().push((path.clone(), body.clone()));
            if fail.load(Ordering::SeqCst)
                && (path.contains("bad")
                    || (path.ends_with("/kick") && body["user_id"] == "@a:local")
                    || (method == Method::PUT && path.contains("/users/")))
            {
                return (StatusCode::SERVICE_UNAVAILABLE, Json(json!({})));
            }
            let result = if path.ends_with("/members") {
                json!({"members":["@a:local","@z:local"]})
            } else if path.ends_with("/devices") {
                json!({"devices":[]})
            } else {
                json!({})
            };
            (StatusCode::OK, Json(result))
        }
    }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let task = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let bridge = Bridge {
        public_url: "http://127.0.0.1:8008".into(),
        server_name: "local".into(),
        admin_url: format!("http://{address}"),
        admin_token: "test".into(),
        admin_user: "@admin:local".into(),
        jwt_secret: "test".into(),
        client: reqwest::Client::builder().no_proxy().build().unwrap(),
        resources: Arc::default(),
        gate: Arc::new(tokio::sync::Mutex::new(())),
    };
    let db = crate::tests::setup();
    {
        let conn = db.lock().unwrap();
        conn.execute("INSERT INTO matrix_users VALUES ('an','@an:local',0)", [])
            .unwrap();
        // Pre-reserve all mappings to keep the test focused on membership, not
        // alias allocation. The first room fails; later rooms still revoke.
        conn.execute(
            "INSERT INTO matrix_rooms SELECT id, '!' || id || ':local', 'alias-' || id FROM rooms",
            [],
        )
        .unwrap();
        conn.execute(
            "UPDATE matrix_rooms SET room_id='!bad:local' WHERE office_room='lobby'",
            [],
        )
        .unwrap();
    }
    (bridge, db, calls, fail, task)
}

#[tokio::test]
async fn revokes_before_failed_provisioning_and_continues_after_room_and_user_errors() {
    let (bridge, db, calls, fail, task) = fixture().await;
    assert!(bridge.reconcile(&db).await.is_err());
    {
        let calls = calls.lock().unwrap();
        let first_user = calls
            .iter()
            .position(|(p, _)| p.contains("/users/"))
            .unwrap();
        let kicks: Vec<_> = calls[..first_user]
            .iter()
            .filter(|(p, _)| p.ends_with("/kick"))
            .collect();
        assert!(
            kicks.len() >= 2,
            "one broken room must not abort later revokes"
        );
        let first_a = kicks
            .iter()
            .position(|(_, b)| b["user_id"] == "@a:local")
            .unwrap();
        assert_eq!(
            kicks[first_a + 1].1["user_id"],
            "@z:local",
            "failed member must not abort next kick"
        );
    }
    let pending: bool = db
        .lock()
        .unwrap()
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM matrix_intents WHERE done=0)",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(pending);
    fail.store(false, Ordering::SeqCst);
    assert!(
        bridge.reconcile(&db).await.is_ok(),
        "next pass repairs failures"
    );
    let pending: bool = db
        .lock()
        .unwrap()
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM matrix_intents WHERE done=0)",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert!(!pending);
    task.abort();
}

#[tokio::test]
async fn caller_rooms_neither_waits_for_global_gate_nor_provisions_other_humans() {
    let (bridge, db, calls, fail, task) = fixture().await;
    fail.store(false, Ordering::SeqCst);
    db.lock()
        .unwrap()
        .execute("INSERT INTO matrix_users VALUES ('van','@van:local',0)", [])
        .unwrap();
    let _guard = bridge.gate.lock().await;
    assert!(
        tokio::time::timeout(Duration::from_secs(2), bridge.caller_rooms(&db, "an"))
            .await
            .unwrap()
            .is_ok()
    );
    let calls = calls.lock().unwrap();
    assert!(calls
        .iter()
        .any(|(p, b)| p.contains("/join/") && b["user_id"] == "@an:local"));
    assert!(!calls
        .iter()
        .any(|(p, b)| p.contains("van") || b["user_id"] == "@van:local"));
    task.abort();
}
