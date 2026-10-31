//! Durable client outbox commands. Each call opens the queue file, applies one
//! operation and closes it, so no connection outlives a Dart isolate.
use super::{CoreError, CoreErrorKind};
use crate::outbox::{self, Operation};

pub struct OutboxEntry {
    pub op: String,
    pub route: String,
    /// The original JSON request body.
    pub body_json: String,
    pub state: String,
    pub reason: Option<String>,
}

fn run(db_path: &str, operation: Operation) -> Result<Vec<OutboxEntry>, CoreError> {
    let mut db =
        outbox::open(db_path).map_err(|e| CoreError::new(CoreErrorKind::Outbox, e.to_string()))?;
    let entries = outbox::apply(&mut db, operation)
        .map_err(|e| CoreError::new(CoreErrorKind::Outbox, e.to_string()))?;
    Ok(entries
        .into_iter()
        .map(|e| OutboxEntry {
            op: e.op,
            route: e.route,
            body_json: e.body.to_string(),
            state: e.state,
            reason: e.reason,
        })
        .collect())
}

pub fn outbox_enqueue(
    db_path: String,
    actor: String,
    op: String,
    route: String,
    body_json: String,
) -> Result<(), CoreError> {
    let body = serde_json::from_str(&body_json)
        .map_err(|_| CoreError::new(CoreErrorKind::Outbox, "invalid_command".to_string()))?;
    run(
        &db_path,
        Operation::Enqueue {
            actor,
            op,
            route,
            body,
        },
    )
    .map(|_| ())
}

/// Pending and rejected entries for the actor, oldest first.
pub fn outbox_list(db_path: String, actor: String) -> Result<Vec<OutboxEntry>, CoreError> {
    run(&db_path, Operation::List { actor })
}

pub fn outbox_mark(
    db_path: String,
    actor: String,
    op: String,
    state: String,
    reason: Option<String>,
) -> Result<(), CoreError> {
    run(
        &db_path,
        Operation::Mark {
            actor,
            op,
            state,
            reason,
        },
    )
    .map(|_| ())
}
