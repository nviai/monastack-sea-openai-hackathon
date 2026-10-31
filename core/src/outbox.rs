//! Durable local command queue for explicitly allowed task and chat routes.
//! This stores no credentials or cached snapshots; callers use separate files.
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::time::Duration;

#[derive(Debug, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Operation {
    Enqueue {
        actor: String,
        op: String,
        route: String,
        body: serde_json::Value,
    },
    List {
        actor: String,
    },
    Mark {
        actor: String,
        op: String,
        state: String,
        reason: Option<String>,
    },
}
#[derive(Serialize, Debug)]
pub struct Entry {
    pub op: String,
    pub route: String,
    pub body: serde_json::Value,
    pub state: String,
    pub reason: Option<String>,
}
fn valid_actor(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 160
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn valid_id(value: &str) -> bool {
    value.len() >= 16
        && value.len() <= 80
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn valid_route(value: &str) -> bool {
    let s: Vec<&str> = value.split('/').collect();
    match s.as_slice() {
        ["", "v1", "projects"] => true,
        ["", "v1", "projects", id, "tasks"] => valid_id(id),
        ["", "v1", "tasks", id, action] => {
            valid_id(id) && matches!(*action, "transition" | "assign" | "comments")
        }
        ["", "v1", "messages", scope] => {
            let target = scope
                .strip_prefix("room%3A")
                .or_else(|| scope.strip_prefix("dm%3A"));
            target.is_some_and(|s| {
                !s.is_empty()
                    && s.len() <= 80
                    && s.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            })
        }
        _ => false,
    }
}
fn storage(_: rusqlite::Error) -> &'static str {
    "storage_error"
}
pub fn open(path: &str) -> Result<Connection, &'static str> {
    let db = Connection::open(path).map_err(storage)?;
    #[cfg(unix)]
    if path != ":memory:" {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| "storage_error")?;
    }
    db.busy_timeout(Duration::from_secs(2)).map_err(storage)?;
    db.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS task_outbox(op TEXT PRIMARY KEY, actor TEXT NOT NULL, route TEXT NOT NULL, body TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','rejected','delivered','discarded')), reason TEXT, created INTEGER NOT NULL DEFAULT (unixepoch())); CREATE INDEX IF NOT EXISTS task_outbox_owner ON task_outbox(actor,state,created);").map_err(storage)?;
    Ok(db)
}
pub fn apply(db: &mut Connection, op: Operation) -> Result<Vec<Entry>, &'static str> {
    match op {
        Operation::Enqueue {
            actor,
            op,
            route,
            body,
        } => {
            if !valid_actor(&actor)
                || !valid_id(&op)
                || !valid_route(&route)
                || body.get("op").and_then(|v| v.as_str()) != Some(op.as_str())
                || (route.starts_with("/v1/messages/")
                    && (body.get("id").and_then(|v| v.as_str()) != Some(op.as_str())
                        || body
                            .get("body")
                            .and_then(|v| v.as_str())
                            .is_none_or(|s| s.trim().is_empty() || s.len() > 4000)))
            {
                return Err("invalid_command");
            }
            let encoded = serde_json::to_string(&body).map_err(|_| "invalid_command")?;
            if encoded.len() > 16_000 {
                return Err("invalid_command");
            }
            let tx = db.transaction().map_err(storage)?;
            let old: Option<(String, String, String)> = tx
                .query_row(
                    "SELECT actor,route,body FROM task_outbox WHERE op=?1",
                    [&op],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )
                .optional()
                .map_err(storage)?;
            match old {
                Some((a, r, b)) if a == actor && r == route && b == encoded => {}
                Some(_) => return Err("operation_conflict"),
                None => {
                    let count:i64=tx.query_row("SELECT COUNT(*) FROM task_outbox WHERE actor=?1 AND state IN ('pending','rejected')",[&actor],|r|r.get(0)).map_err(storage)?;
                    if count >= 1000 {
                        return Err("queue_full");
                    }
                    tx.execute("INSERT INTO task_outbox(op,actor,route,body,state) VALUES (?1,?2,?3,?4,'pending')",params![op,actor,route,encoded]).map_err(storage)?;
                }
            }
            tx.commit().map_err(storage)?;
            Ok(vec![])
        }
        Operation::List { actor } => {
            if !valid_actor(&actor) {
                return Err("invalid_command");
            }
            let mut stmt=db.prepare("SELECT op,route,body,state,reason FROM task_outbox WHERE actor=?1 AND state IN ('pending','rejected') ORDER BY rowid LIMIT 1000").map_err(storage)?;
            let rows = stmt
                .query_map([actor], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, Option<String>>(4)?,
                    ))
                })
                .map_err(storage)?;
            let mut result = Vec::new();
            for row in rows {
                let (op, route, body, state, reason) = row.map_err(storage)?;
                result.push(Entry {
                    op,
                    route,
                    body: serde_json::from_str(&body).map_err(|_| "storage_error")?,
                    state,
                    reason,
                });
            }
            Ok(result)
        }
        Operation::Mark {
            actor,
            op,
            state,
            reason,
        } => {
            if !valid_actor(&actor)
                || !valid_id(&op)
                || !matches!(state.as_str(), "delivered" | "rejected" | "discarded")
                || reason.as_ref().is_some_and(|s| s.len() > 200)
            {
                return Err("invalid_command");
            }
            let count=db.execute("UPDATE task_outbox SET state=?1,reason=?2 WHERE actor=?3 AND op=?4 AND (state='pending' OR (?1='discarded' AND state='rejected'))",params![state,reason,actor,op]).map_err(storage)?;
            if count == 0 {
                return Err("not_pending");
            }
            Ok(vec![])
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn enqueue(actor: &str, route: &str, op: &str) -> Operation {
        Operation::Enqueue {
            actor: actor.into(),
            op: op.into(),
            route: route.into(),
            body: serde_json::json!({"op":op,"name":"test"}),
        }
    }
    #[test]
    fn same_actor_on_different_authorities_is_isolated() {
        let mut db = open(":memory:").unwrap();
        apply(
            &mut db,
            enqueue("authority_a_an", "/v1/projects", "0123456789abcdef"),
        )
        .unwrap();
        assert!(apply(
            &mut db,
            Operation::List {
                actor: "authority_b_an".into()
            }
        )
        .unwrap()
        .is_empty());
        assert_eq!(
            apply(
                &mut db,
                Operation::List {
                    actor: "authority_a_an".into()
                }
            )
            .unwrap()
            .len(),
            1
        );
    }
    #[test]
    fn chat_queue_binds_message_id_and_scope() {
        let mut db = open(":memory:").unwrap();
        let command = |route: &str, id: &str, body: &str| Operation::Enqueue {
            actor: "authority_an".into(),
            op: "0123456789abcdef".into(),
            route: route.into(),
            body: serde_json::json!({"op":"0123456789abcdef","id":id,"body":body}),
        };
        assert!(apply(
            &mut db,
            command("/v1/messages/room%3Alobby", "other-message-id", "hello")
        )
        .is_err());
        assert!(apply(
            &mut db,
            command(
                "/v1/messages/room%3A../../other",
                "0123456789abcdef",
                "hello"
            )
        )
        .is_err());
        assert!(apply(
            &mut db,
            command("/v1/messages/dm%3Avan", "0123456789abcdef", " ")
        )
        .is_err());
        apply(
            &mut db,
            command("/v1/messages/dm%3Avan", "0123456789abcdef", "hello"),
        )
        .unwrap();
        apply(
            &mut db,
            command("/v1/messages/dm%3Avan", "0123456789abcdef", "hello"),
        )
        .unwrap();
        assert_eq!(
            apply(
                &mut db,
                Operation::List {
                    actor: "authority_an".into()
                }
            )
            .unwrap()
            .len(),
            1
        );
    }
    #[test]
    fn persists_deduplicates_and_scopes_entries() {
        let dir = std::env::temp_dir().join(format!(
            "monastack-outbox-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("outbox.sqlite3");
        let path = path.to_str().unwrap();
        let id = "0123456789abcdef";
        {
            let mut db = open(path).unwrap();
            apply(&mut db, enqueue("an", "/v1/projects", id)).unwrap();
            apply(&mut db, enqueue("an", "/v1/projects", id)).unwrap();
            assert_eq!(
                apply(&mut db, enqueue("van", "/v1/projects", id)).unwrap_err(),
                "operation_conflict"
            );
        }
        {
            let mut db = open(path).unwrap();
            assert_eq!(
                apply(&mut db, Operation::List { actor: "an".into() })
                    .unwrap()
                    .len(),
                1
            );
            assert!(apply(
                &mut db,
                Operation::List {
                    actor: "van".into()
                }
            )
            .unwrap()
            .is_empty());
            assert!(apply(&mut db, enqueue("an", "/v1/expenses", "abcdef0123456789")).is_err());
            apply(
                &mut db,
                Operation::Mark {
                    actor: "an".into(),
                    op: id.into(),
                    state: "rejected".into(),
                    reason: Some("conflict".into()),
                },
            )
            .unwrap();
            assert_eq!(
                apply(&mut db, Operation::List { actor: "an".into() }).unwrap()[0].state,
                "rejected"
            );
            assert!(apply(
                &mut db,
                Operation::Mark {
                    actor: "van".into(),
                    op: id.into(),
                    state: "discarded".into(),
                    reason: None
                }
            )
            .is_err());
            apply(
                &mut db,
                Operation::Mark {
                    actor: "an".into(),
                    op: id.into(),
                    state: "discarded".into(),
                    reason: None,
                },
            )
            .unwrap();
            assert!(apply(&mut db, Operation::List { actor: "an".into() })
                .unwrap()
                .is_empty());
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
}
