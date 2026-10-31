//! Own leave requests and explicitly scoped HR decisions. No leave balances.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};
pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS leave_requests(id TEXT PRIMARY KEY, requester TEXT NOT NULL REFERENCES actors(id), start_date TEXT NOT NULL, end_date TEXT NOT NULL, reason TEXT NOT NULL, state TEXT NOT NULL, version INTEGER NOT NULL, created INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS leave_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), request TEXT NOT NULL REFERENCES leave_requests(id), action TEXT NOT NULL, created INTEGER NOT NULL);")
}
fn hr(db: &Connection, who: &str) -> Result<bool, ApiError> {
    let mut stmt = db
        .prepare("SELECT role FROM actor_roles WHERE actor=?1")
        .map_err(db_error)?;
    let roles = stmt
        .query_map([who], |r| r.get::<_, String>(0))
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    Ok(monastack_core::access::can_manage_hr(&roles))
}
fn valid_id(s: &str) -> bool {
    s.len() >= 16
        && s.len() <= 80
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn replay(tx: &Transaction<'_>, op: &str, payload: &str, who: &str) -> Result<bool, ApiError> {
    let old: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM leave_audit WHERE op=?1",
            [op],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_error)?;
    match old {
        None => Ok(false),
        Some((digest, owner)) if digest == hash(payload) && owner == who => Ok(true),
        Some(_) => Err(err(StatusCode::CONFLICT, "operation id conflict")),
    }
}
fn audit(
    tx: &Transaction<'_>,
    op: &str,
    payload: &str,
    who: &str,
    id: &str,
    action: &str,
) -> Result<(), ApiError> {
    tx.execute("INSERT INTO leave_audit(op,request_hash,actor,request,action,created) VALUES (?1,?2,?3,?4,?5,?6)",params![op,hash(payload),who,id,action,now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct Leave {
    id: String,
    requester: String,
    start_date: String,
    end_date: String,
    reason: String,
    state: String,
    version: i64,
}
pub async fn list(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<Leave>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    let is_hr = hr(&db, &who)?;
    let mut stmt=db.prepare("SELECT id,requester,start_date,end_date,reason,state,version FROM leave_requests WHERE requester=?1 OR ?2=1 ORDER BY rowid DESC LIMIT 200").map_err(db_error)?;
    let rows = stmt
        .query_map(params![who, is_hr], |r| {
            Ok(Leave {
                id: r.get(0)?,
                requester: r.get(1)?,
                start_date: r.get(2)?,
                end_date: r.get(3)?,
                reason: r.get(4)?,
                state: r.get(5)?,
                version: r.get(6)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}

#[derive(Deserialize)]
pub struct CalendarQuery {
    month: String,
}
#[derive(Serialize)]
pub struct CalendarItem {
    id: String,
    requester: String,
    start_date: String,
    end_date: String,
    state: String,
}
#[derive(Serialize)]
pub struct Calendar {
    month: String,
    items: Vec<CalendarItem>,
    truncated: bool,
}
/// Only approved leave (including pending cancellations) appears. Reasons are
/// deliberately omitted, and current HR scope is checked on every request.
pub async fn calendar(
    State(state): State<Db>,
    headers: HeaderMap,
    Query(query): Query<CalendarQuery>,
) -> Result<Json<Calendar>, ApiError> {
    let (first, last) = monastack_core::access::leave_month_bounds(&query.month)
        .ok_or(err(StatusCode::BAD_REQUEST, "invalid month"))?;
    let mut db = state.lock().unwrap();
    let tx = db.transaction().map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let is_hr = hr(&tx, &who)?;
    let mut stmt = tx.prepare("SELECT id,requester,start_date,end_date,state FROM leave_requests WHERE (requester=?1 OR ?2=1) AND state IN ('approved','cancellation_pending') AND start_date<=?3 AND end_date>=?4 ORDER BY start_date,id LIMIT 501").map_err(db_error)?;
    let mut items = stmt
        .query_map(params![who, is_hr, last, first], |r| {
            Ok(CalendarItem {
                id: r.get(0)?,
                requester: r.get(1)?,
                start_date: r.get(2)?,
                end_date: r.get(3)?,
                state: r.get(4)?,
            })
        })
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    let truncated = items.len() > 500;
    items.truncate(500);
    drop(stmt);
    tx.commit().map_err(db_error)?;
    Ok(Json(Calendar {
        month: query.month,
        items,
        truncated,
    }))
}
#[derive(Deserialize, Serialize)]
pub struct NewLeave {
    id: String,
    start_date: String,
    end_date: String,
    reason: String,
    op: String,
}
pub async fn create(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(l): Json<NewLeave>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&l.id)
        || !valid_id(&l.op)
        || !monastack_core::access::valid_leave(&l.start_date, &l.end_date, &l.reason)
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid leave request"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let payload = serde_json::to_string(&l).unwrap();

    if replay(&tx, &l.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM leave_requests WHERE id=?1)",
            [&l.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "request id exists"));
    }
    tx.execute(
        "INSERT INTO leave_requests VALUES (?1,?2,?3,?4,?5,'proposed',1,?6)",
        params![l.id, who, l.start_date, l.end_date, l.reason, now()],
    )
    .map_err(db_error)?;
    audit(&tx, &l.op, &payload, &who, &l.id, "proposed")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
#[derive(Deserialize, Serialize)]
pub struct Decision {
    action: String,
    expected_version: i64,
    op: String,
}
pub async fn decision(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(d): Json<Decision>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&d.op)
        || !matches!(
            d.action.as_str(),
            "approve"
                | "reject"
                | "withdraw"
                | "request_cancel"
                | "cancel_withdraw"
                | "cancel_approve"
                | "cancel_reject"
        )
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid decision"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let requester_action = matches!(
        d.action.as_str(),
        "withdraw" | "request_cancel" | "cancel_withdraw"
    );
    let payload = format!("{}:{}", id, serde_json::to_string(&d).unwrap());

    if !requester_action && !hr(&tx, &who)? {
        return Err(err(StatusCode::FORBIDDEN, "HR access required"));
    }
    let row: Option<(String, String, i64)> = tx
        .query_row(
            "SELECT requester,state,version FROM leave_requests WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (requester, state, version) = row.ok_or(err(StatusCode::NOT_FOUND, "request not found"))?;
    if requester_action && who != requester {
        return Err(err(StatusCode::NOT_FOUND, "request not found"));
    }
    if !requester_action && who == requester {
        return Err(err(StatusCode::FORBIDDEN, "self decision denied"));
    }
    if replay(&tx, &d.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    if version != d.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale request version"));
    }
    let result = monastack_core::access::leave_next_state(&state, &d.action)
        .ok_or(err(StatusCode::CONFLICT, "invalid leave transition"))?;
    tx.execute(
        "UPDATE leave_requests SET state=?1,version=version+1 WHERE id=?2",
        params![result, id],
    )
    .map_err(db_error)?;
    audit(&tx, &d.op, &payload, &who, &id, &d.action)?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}
#[derive(Serialize)]
pub struct AuditEvent {
    actor: String,
    action: String,
    created: i64,
}
pub async fn history(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Vec<AuditEvent>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    let owner: Option<String> = db
        .query_row(
            "SELECT requester FROM leave_requests WHERE id=?1",
            [&id],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_error)?;
    let owner = owner.ok_or(err(StatusCode::NOT_FOUND, "request not found"))?;
    if owner != who && !hr(&db, &who)? {
        return Err(err(StatusCode::NOT_FOUND, "request not found"));
    }
    let mut stmt = db
        .prepare("SELECT actor,action,created FROM leave_audit WHERE request=?1 ORDER BY seq")
        .map_err(db_error)?;
    let rows = stmt
        .query_map([id], |r| {
            Ok(AuditEvent {
                actor: r.get(0)?,
                action: r.get(1)?,
                created: r.get(2)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
