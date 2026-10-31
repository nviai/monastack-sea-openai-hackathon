//! Local customer booking records. No invitation or external calendar integration.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::{Deserialize, Serialize};
pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS customer_bookings(id TEXT PRIMARY KEY, customer TEXT NOT NULL REFERENCES customers(id), title TEXT NOT NULL, starts INTEGER NOT NULL, ends INTEGER NOT NULL, creator TEXT NOT NULL REFERENCES actors(id), state TEXT NOT NULL, version INTEGER NOT NULL, created INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS booking_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), booking TEXT NOT NULL REFERENCES customer_bookings(id), action TEXT NOT NULL, created INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS booking_customer_time ON customer_bookings(customer,starts,ends);")
}
fn valid_id(s: &str) -> bool {
    (16..=80).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn manage(db: &Connection, who: &str) -> Result<(), ApiError> {
    let mut s = db
        .prepare("SELECT role FROM actor_roles WHERE actor=?1")
        .map_err(db_error)?;
    let rows = s.query_map([who], |r| r.get(0)).map_err(db_error)?;
    let roles = rows.collect::<Result<Vec<String>, _>>().map_err(db_error)?;
    if !monastack_core::access::can_manage_sales(&roles) {
        return Err(err(StatusCode::FORBIDDEN, "sales access required"));
    }
    Ok(())
}
fn replay(tx: &Transaction<'_>, op: &str, payload: &str, who: &str) -> Result<bool, ApiError> {
    let old: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM booking_audit WHERE op=?1",
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
    tx.execute("INSERT INTO booking_audit(op,request_hash,actor,booking,action,created) VALUES (?1,?2,?3,?4,?5,?6)",params![op,hash(payload),who,id,action,now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct Booking {
    id: String,
    customer: String,
    customer_name: String,
    title: String,
    starts: i64,
    ends: i64,
    creator: String,
    state: String,
    version: i64,
}
pub async fn list(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<Booking>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    super::customers::authorized(&db, &who)?;
    let mut s=db.prepare("SELECT b.id,b.customer,c.name,b.title,b.starts,b.ends,b.creator,b.state,b.version FROM customer_bookings b JOIN customers c ON c.id=b.customer ORDER BY b.starts,b.id LIMIT 200").map_err(db_error)?;
    let rows = s
        .query_map([], |r| {
            Ok(Booking {
                id: r.get(0)?,
                customer: r.get(1)?,
                customer_name: r.get(2)?,
                title: r.get(3)?,
                starts: r.get(4)?,
                ends: r.get(5)?,
                creator: r.get(6)?,
                state: r.get(7)?,
                version: r.get(8)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
pub async fn capabilities(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    super::customers::authorized(&db, &who)?;
    let can_manage = match manage(&db, &who) {
        Ok(()) => true,
        Err((StatusCode::FORBIDDEN, _)) => false,
        Err(error) => return Err(error),
    };
    Ok(Json(serde_json::json!({"can_manage":can_manage})))
}
#[derive(Deserialize, Serialize)]
pub struct NewBooking {
    id: String,
    customer: String,
    title: String,
    starts: i64,
    ends: i64,
    op: String,
}
pub async fn create(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(input): Json<NewBooking>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.id)
        || !valid_id(&input.customer)
        || !valid_id(&input.op)
        || !monastack_core::access::valid_meeting(&input.title, input.starts, input.ends)
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid booking"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    manage(&tx, &who)?;
    let payload = format!("create:{}", serde_json::to_string(&input).unwrap());
    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM customers WHERE id=?1)",
            [&input.customer],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !exists {
        return Err(err(StatusCode::NOT_FOUND, "customer not found"));
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM customer_bookings WHERE id=?1)",
            [&input.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "booking id exists"));
    }
    let overlap:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM customer_bookings WHERE customer=?1 AND state='scheduled' AND starts<?3 AND ends>?2)",params![input.customer,input.starts,input.ends],|r|r.get(0)).map_err(db_error)?;
    if overlap {
        return Err(err(
            StatusCode::CONFLICT,
            "customer already has an overlapping booking",
        ));
    }
    tx.execute(
        "INSERT INTO customer_bookings VALUES (?1,?2,?3,?4,?5,?6,'scheduled',1,?7)",
        params![
            input.id,
            input.customer,
            input.title,
            input.starts,
            input.ends,
            who,
            now()
        ],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &input.id, "scheduled")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
#[derive(Deserialize, Serialize)]
pub struct Reschedule {
    title: String,
    starts: i64,
    ends: i64,
    expected_version: i64,
    op: String,
}
pub async fn reschedule(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Reschedule>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.op)
        || !monastack_core::access::valid_meeting(&input.title, input.starts, input.ends)
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid booking"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    manage(&tx, &who)?;
    let row: Option<(String, String, i64)> = tx
        .query_row(
            "SELECT customer,state,version FROM customer_bookings WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (customer, state, version) = row.ok_or(err(StatusCode::NOT_FOUND, "booking not found"))?;
    let payload = format!(
        "reschedule:{}:{}",
        id,
        serde_json::to_string(&input).unwrap()
    );
    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    if version != input.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale booking version"));
    }
    if state != "scheduled" {
        return Err(err(StatusCode::CONFLICT, "booking already cancelled"));
    }
    let overlap: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM customer_bookings WHERE customer=?1 AND id!=?2 AND state='scheduled' AND starts<?4 AND ends>?3)", params![customer,id,input.starts,input.ends], |r| r.get(0)).map_err(db_error)?;
    if overlap {
        return Err(err(
            StatusCode::CONFLICT,
            "customer already has an overlapping booking",
        ));
    }
    tx.execute(
        "UPDATE customer_bookings SET title=?1,starts=?2,ends=?3,version=version+1 WHERE id=?4",
        params![input.title, input.starts, input.ends, id],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &id, "rescheduled")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}

#[derive(Deserialize, Serialize)]
pub struct Cancel {
    expected_version: i64,
    op: String,
}
pub async fn cancel(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(input): Json<Cancel>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&input.op) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid operation"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    manage(&tx, &who)?;
    let row: Option<(String, i64)> = tx
        .query_row(
            "SELECT state,version FROM customer_bookings WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (state, version) = row.ok_or(err(StatusCode::NOT_FOUND, "booking not found"))?;
    let payload = format!("cancel:{}:{}", id, serde_json::to_string(&input).unwrap());
    if replay(&tx, &input.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    if version != input.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale booking version"));
    }
    if state != "scheduled" {
        return Err(err(StatusCode::CONFLICT, "booking already cancelled"));
    }
    tx.execute(
        "UPDATE customer_bookings SET state='cancelled',version=version+1 WHERE id=?1",
        [&id],
    )
    .map_err(db_error)?;
    audit(&tx, &input.op, &payload, &who, &id, "cancelled")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}
#[derive(Serialize)]
pub struct Event {
    actor: String,
    action: String,
    created: i64,
}
pub async fn history(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Vec<Event>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    super::customers::authorized(&db, &who)?;
    let exists: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM customer_bookings WHERE id=?1)",
            [&id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !exists {
        return Err(err(StatusCode::NOT_FOUND, "booking not found"));
    }
    let mut s = db
        .prepare("SELECT actor,action,created FROM booking_audit WHERE booking=?1 ORDER BY seq")
        .map_err(db_error)?;
    let rows = s
        .query_map([id], |r| {
            Ok(Event {
                actor: r.get(0)?,
                action: r.get(1)?,
                created: r.get(2)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
