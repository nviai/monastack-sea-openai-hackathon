//! Task authority with workspace-visible and explicitly private projects.
use super::{actor, db_error, err, hash, now, ApiError, Db};
use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    Json,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};

pub fn initialize(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY, name TEXT NOT NULL, created_by TEXT NOT NULL REFERENCES actors(id));
    CREATE TABLE IF NOT EXISTS project_rules(project TEXT PRIMARY KEY REFERENCES projects(id), visibility TEXT NOT NULL CHECK(visibility='private'));
    CREATE TABLE IF NOT EXISTS project_members(project TEXT NOT NULL REFERENCES projects(id), actor TEXT NOT NULL REFERENCES actors(id), PRIMARY KEY(project,actor));
    CREATE TABLE IF NOT EXISTS project_readers(project TEXT NOT NULL, actor TEXT NOT NULL, PRIMARY KEY(project,actor), FOREIGN KEY(project,actor) REFERENCES project_members(project,actor) ON DELETE CASCADE);
    CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY, project TEXT NOT NULL REFERENCES projects(id), title TEXT NOT NULL, assignee TEXT REFERENCES actors(id), state TEXT NOT NULL, version INTEGER NOT NULL, created_by TEXT NOT NULL REFERENCES actors(id));
    CREATE TABLE IF NOT EXISTS task_comments(id TEXT PRIMARY KEY, task TEXT NOT NULL REFERENCES tasks(id), author TEXT NOT NULL REFERENCES actors(id), body TEXT NOT NULL, created INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS task_audit(seq INTEGER PRIMARY KEY AUTOINCREMENT, op TEXT NOT NULL UNIQUE, request_hash BLOB NOT NULL, actor TEXT NOT NULL REFERENCES actors(id), object_type TEXT NOT NULL, object_id TEXT NOT NULL, action TEXT NOT NULL, created INTEGER NOT NULL);")
}
/// No rule means workspace-visible, preserving projects created before this feature.
pub fn can_access_project(db: &Connection, who: &str, project: &str) -> Result<bool, ApiError> {
    let row: Option<(String, bool)> = db.query_row(
        "SELECT created_by, EXISTS(SELECT 1 FROM project_rules WHERE project=projects.id) FROM projects WHERE id=?1",
        [project], |r| Ok((r.get(0)?,r.get(1)?)),
    ).optional().map_err(db_error)?;
    let Some((owner, private)) = row else {
        return Ok(false);
    };
    if !private || owner == who {
        return Ok(true);
    }
    db.query_row(
        "SELECT EXISTS(SELECT 1 FROM project_members WHERE project=?1 AND actor=?2)",
        params![project, who],
        |r| r.get(0),
    )
    .map_err(db_error)
}
pub fn can_access_task(db: &Connection, who: &str, task: &str) -> Result<bool, ApiError> {
    let project: Option<String> = db
        .query_row("SELECT project FROM tasks WHERE id=?1", [task], |r| {
            r.get(0)
        })
        .optional()
        .map_err(db_error)?;
    match project {
        Some(id) => can_access_project(db, who, &id),
        None => Ok(false),
    }
}
pub fn can_edit_project(db: &Connection, who: &str, project: &str) -> Result<bool, ApiError> {
    if !can_access_project(db, who, project)? {
        return Ok(false);
    }
    let reader: bool = db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM project_readers WHERE project=?1 AND actor=?2)",
            params![project, who],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    Ok(!reader)
}
pub fn can_edit_task(db: &Connection, who: &str, task: &str) -> Result<bool, ApiError> {
    let project: Option<String> = db
        .query_row("SELECT project FROM tasks WHERE id=?1", [task], |r| {
            r.get(0)
        })
        .optional()
        .map_err(db_error)?;
    match project {
        Some(project) => can_edit_project(db, who, &project),
        None => Ok(false),
    }
}
fn require_project_edit(db: &Connection, who: &str, project: &str) -> Result<(), ApiError> {
    require_project(db, who, project)?;
    if can_edit_project(db, who, project)? {
        Ok(())
    } else {
        Err(err(StatusCode::FORBIDDEN, "project is read-only"))
    }
}
fn require_task_edit(db: &Connection, who: &str, task: &str) -> Result<(), ApiError> {
    require_task(db, who, task)?;
    if can_edit_task(db, who, task)? {
        Ok(())
    } else {
        Err(err(StatusCode::FORBIDDEN, "project is read-only"))
    }
}
fn require_project(db: &Connection, who: &str, project: &str) -> Result<(), ApiError> {
    if can_access_project(db, who, project)? {
        Ok(())
    } else {
        Err(err(StatusCode::NOT_FOUND, "project not found"))
    }
}
fn require_task(db: &Connection, who: &str, task: &str) -> Result<(), ApiError> {
    if can_access_task(db, who, task)? {
        Ok(())
    } else {
        Err(err(StatusCode::NOT_FOUND, "task not found"))
    }
}
fn is_false(value: &bool) -> bool {
    !*value
}
fn valid_id(id: &str) -> bool {
    id.len() >= 16
        && id.len() <= 80
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
fn valid_text(text: &str, max: usize) -> bool {
    !text.trim().is_empty() && text.len() <= max
}
fn replay(tx: &Transaction<'_>, op: &str, payload: &str, who: &str) -> Result<bool, ApiError> {
    let prior: Option<(Vec<u8>, String)> = tx
        .query_row(
            "SELECT request_hash,actor FROM task_audit WHERE op=?1",
            [op],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_error)?;
    match prior {
        None => Ok(false),
        Some((digest, actor)) if digest == hash(payload) && actor == who => Ok(true),
        Some(_) => Err(err(StatusCode::CONFLICT, "operation id conflict")),
    }
}
fn audit(
    tx: &Transaction<'_>,
    op: &str,
    payload: &str,
    who: &str,
    kind: &str,
    id: &str,
    action: &str,
) -> Result<(), ApiError> {
    tx.execute("INSERT INTO task_audit(op,request_hash,actor,object_type,object_id,action,created) VALUES (?1,?2,?3,?4,?5,?6,?7)",params![op,hash(payload),who,kind,id,action,now()]).map_err(db_error)?;
    Ok(())
}
#[derive(Serialize)]
pub struct Project {
    id: String,
    name: String,
    private: bool,
    owner: String,
    can_edit: bool,
    description: String,
    url: String,
    demo: bool,
    task_count: i64,
    done_count: i64,
}
#[derive(Deserialize, Serialize)]
pub struct NewProject {
    id: String,
    name: String,
    op: String,
    #[serde(default, skip_serializing_if = "is_false")]
    private: bool,
}
pub async fn projects(
    State(state): State<Db>,
    headers: HeaderMap,
) -> Result<Json<Vec<Project>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    let mut stmt = db.prepare("SELECT p.id,p.name,p.created_by,EXISTS(SELECT 1 FROM project_rules WHERE project=p.id),COALESCE(d.description,''),COALESCE(d.url,''),COALESCE(d.demo,0),(SELECT COUNT(*) FROM tasks WHERE project=p.id),(SELECT COUNT(*) FROM tasks WHERE project=p.id AND state='done') FROM projects p LEFT JOIN project_details d ON d.project=p.id ORDER BY COALESCE(d.demo,0) DESC,p.name,p.id").map_err(db_error)?;
    let rows = stmt
        .query_map([], |r| {
            Ok(Project {
                id: r.get(0)?,
                name: r.get(1)?,
                owner: r.get(2)?,
                private: r.get(3)?,
                can_edit: false,
                description: r.get(4)?,
                url: r.get(5)?,
                demo: r.get(6)?,
                task_count: r.get(7)?,
                done_count: r.get(8)?,
            })
        })
        .map_err(db_error)?;
    let mut result = Vec::new();
    for row in rows {
        let mut p = row.map_err(db_error)?;
        if can_access_project(&db, &who, &p.id)? {
            p.can_edit = can_edit_project(&db, &who, &p.id)?;
            result.push(p);
        }
    }
    Ok(Json(result))
}
pub async fn create_project(
    State(state): State<Db>,
    headers: HeaderMap,
    Json(p): Json<NewProject>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&p.id) || !valid_id(&p.op) || !valid_text(&p.name, 120) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid project"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    let payload = serde_json::to_string(&p).unwrap();

    if replay(&tx, &p.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM projects WHERE id=?1)",
            [&p.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "project id exists"));
    }
    tx.execute(
        "INSERT INTO projects VALUES (?1,?2,?3)",
        params![p.id, p.name, who],
    )
    .map_err(db_error)?;
    if p.private {
        tx.execute("INSERT INTO project_rules VALUES (?1,'private')", [&p.id])
            .map_err(db_error)?;
        tx.execute(
            "INSERT INTO project_members VALUES (?1,?2)",
            params![p.id, who],
        )
        .map_err(db_error)?;
    }
    audit(&tx, &p.op, &payload, &who, "project", &p.id, "created")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
#[derive(Serialize)]
pub struct Task {
    id: String,
    project: String,
    title: String,
    assignee: Option<String>,
    state: String,
    version: i64,
}
#[derive(Deserialize, Serialize)]
pub struct NewTask {
    id: String,
    title: String,
    assignee: Option<String>,
    op: String,
}
pub async fn list_tasks(
    State(state): State<Db>,
    Path(project): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Vec<Task>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    require_project(&db, &who, &project)?;
    let mut stmt=db.prepare("SELECT id,project,title,assignee,state,version FROM tasks WHERE project=?1 ORDER BY rowid").map_err(db_error)?;
    let rows = stmt
        .query_map([project], |r| {
            Ok(Task {
                id: r.get(0)?,
                project: r.get(1)?,
                title: r.get(2)?,
                assignee: r.get(3)?,
                state: r.get(4)?,
                version: r.get(5)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
pub async fn create_task(
    State(state): State<Db>,
    Path(project): Path<String>,
    headers: HeaderMap,
    Json(t): Json<NewTask>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&t.id) || !valid_id(&t.op) || !valid_text(&t.title, 240) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid task"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    require_project_edit(&tx, &who, &project)?;
    let payload = format!("{}:{}", project, serde_json::to_string(&t).unwrap());

    if replay(&tx, &t.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let project_exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM projects WHERE id=?1)",
            [&project],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !project_exists {
        return Err(err(StatusCode::NOT_FOUND, "project not found"));
    }
    if let Some(assignee) = &t.assignee {
        let found: bool = tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1)",
                [assignee],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        if !found {
            return Err(err(StatusCode::BAD_REQUEST, "unknown assignee"));
        }
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM tasks WHERE id=?1)",
            [&t.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if exists {
        return Err(err(StatusCode::CONFLICT, "task id exists"));
    }
    tx.execute(
        "INSERT INTO tasks VALUES (?1,?2,?3,?4,'todo',1,?5)",
        params![t.id, project, t.title, t.assignee, who],
    )
    .map_err(db_error)?;
    audit(&tx, &t.op, &payload, &who, "task", &t.id, "created")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}
#[derive(Deserialize, Serialize)]
pub struct Transition {
    to: String,
    expected_version: i64,
    op: String,
}
pub async fn transition(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(t): Json<Transition>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&t.op) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid operation"));
    }
    let Some(next) = monastack_core::tasks::State::parse(&t.to) else {
        return Err(err(StatusCode::BAD_REQUEST, "invalid state"));
    };
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    require_task_edit(&tx, &who, &id)?;
    let payload = format!("{}:{}", id, serde_json::to_string(&t).unwrap());

    if replay(&tx, &t.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let current: Option<(String, i64)> = tx
        .query_row("SELECT state,version FROM tasks WHERE id=?1", [&id], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .optional()
        .map_err(db_error)?;
    let (state, version) = current.ok_or(err(StatusCode::NOT_FOUND, "task not found"))?;
    if version != t.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale task version"));
    }
    let current = monastack_core::tasks::State::parse(&state).ok_or(err(
        StatusCode::INTERNAL_SERVER_ERROR,
        "invalid stored state",
    ))?;
    if !current.can_transition(next) {
        return Err(err(StatusCode::CONFLICT, "invalid transition"));
    }
    tx.execute(
        "UPDATE tasks SET state=?1,version=version+1 WHERE id=?2",
        params![t.to, id],
    )
    .map_err(db_error)?;
    audit(
        &tx,
        &t.op,
        &payload,
        &who,
        "task",
        &id,
        &format!("transition:{}:{}", state, t.to),
    )?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}
#[derive(Deserialize, Serialize)]
pub struct NewComment {
    id: String,
    body: String,
    op: String,
}
#[derive(Serialize)]
pub struct Comment {
    id: String,
    author: String,
    body: String,
    created: i64,
}
pub async fn comments(
    State(state): State<Db>,
    Path(task): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Vec<Comment>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    require_task(&db, &who, &task)?;
    let mut stmt = db
        .prepare("SELECT id,author,body,created FROM task_comments WHERE task=?1 ORDER BY rowid")
        .map_err(db_error)?;
    let rows = stmt
        .query_map([task], |r| {
            Ok(Comment {
                id: r.get(0)?,
                author: r.get(1)?,
                body: r.get(2)?,
                created: r.get(3)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
pub async fn add_comment(
    State(state): State<Db>,
    Path(task): Path<String>,
    headers: HeaderMap,
    Json(c): Json<NewComment>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&c.id) || !valid_id(&c.op) || !valid_text(&c.body, 4000) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid comment"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    require_task_edit(&tx, &who, &task)?;
    let payload = format!("{}:{}", task, serde_json::to_string(&c).unwrap());

    if replay(&tx, &c.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM tasks WHERE id=?1)",
            [&task],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !exists {
        return Err(err(StatusCode::NOT_FOUND, "task not found"));
    }
    let duplicate: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM task_comments WHERE id=?1)",
            [&c.id],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if duplicate {
        return Err(err(StatusCode::CONFLICT, "comment id exists"));
    }
    tx.execute(
        "INSERT INTO task_comments VALUES (?1,?2,?3,?4,?5)",
        params![c.id, task, who, c.body, now()],
    )
    .map_err(db_error)?;
    tx.execute("INSERT INTO task_notifications(recipient,task,body,created) SELECT id,?1,?2,?3 FROM actors WHERE kind='human' AND id<>?4 AND (id=(SELECT created_by FROM tasks WHERE id=?1) OR id=(SELECT assignee FROM tasks WHERE id=?1))", params![task,c.body,now(),who]).map_err(db_error)?;
    audit(&tx, &c.op, &payload, &who, "task", &task, "comment_added")?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::CREATED)
}

#[derive(Serialize)]
pub struct AuditEvent {
    actor: String,
    action: String,
    created: i64,
}
pub async fn history(
    State(state): State<Db>,
    Path(task): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Vec<AuditEvent>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    require_task(&db, &who, &task)?;
    let mut stmt=db.prepare("SELECT actor,action,created FROM task_audit WHERE object_type='task' AND object_id=?1 ORDER BY seq").map_err(db_error)?;
    let rows = stmt
        .query_map([task], |r| {
            Ok(AuditEvent {
                actor: r.get(0)?,
                action: r.get(1)?,
                created: r.get(2)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}

#[derive(Deserialize, Serialize)]
pub struct Assignment {
    assignee: Option<String>,
    expected_version: i64,
    op: String,
}
pub async fn assign(
    State(state): State<Db>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(a): Json<Assignment>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&a.op) {
        return Err(err(StatusCode::BAD_REQUEST, "invalid operation"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    require_task_edit(&tx, &who, &id)?;
    let payload = format!("assign:{}:{}", id, serde_json::to_string(&a).unwrap());

    if replay(&tx, &a.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let current: Option<(Option<String>, i64)> = tx
        .query_row(
            "SELECT assignee,version FROM tasks WHERE id=?1",
            [&id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(db_error)?;
    let (previous, version) = current.ok_or(err(StatusCode::NOT_FOUND, "task not found"))?;
    if version != a.expected_version {
        return Err(err(StatusCode::CONFLICT, "stale task version"));
    }
    if previous == a.assignee {
        return Err(err(StatusCode::CONFLICT, "assignment unchanged"));
    }
    if let Some(target) = &a.assignee {
        let found: bool = tx
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1)",
                [target],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        if !found {
            return Err(err(StatusCode::BAD_REQUEST, "unknown assignee"));
        }
    }
    tx.execute(
        "UPDATE tasks SET assignee=?1,version=version+1 WHERE id=?2",
        params![a.assignee, id],
    )
    .map_err(db_error)?;
    audit(
        &tx,
        &a.op,
        &payload,
        &who,
        "task",
        &id,
        &format!(
            "assignment:{}:{}",
            previous.as_deref().unwrap_or("none"),
            a.assignee.as_deref().unwrap_or("none")
        ),
    )?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}

#[derive(Serialize)]
pub struct ProjectMembers {
    private: bool,
    owner: String,
    can_manage: bool,
    members: Vec<String>,
    readers: Vec<String>,
}
pub async fn members(
    State(state): State<Db>,
    Path(project): Path<String>,
    headers: HeaderMap,
) -> Result<Json<ProjectMembers>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    require_project(&db, &who, &project)?;
    let (owner,private):(String,bool)=db.query_row("SELECT created_by,EXISTS(SELECT 1 FROM project_rules WHERE project=projects.id) FROM projects WHERE id=?1",[&project],|r|Ok((r.get(0)?,r.get(1)?))).map_err(db_error)?;
    let mut stmt = db
        .prepare("SELECT actor FROM project_members WHERE project=?1 ORDER BY actor")
        .map_err(db_error)?;
    let rows = stmt.query_map([&project], |r| r.get(0)).map_err(db_error)?;
    let members = rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?;
    let mut reader_stmt = db
        .prepare("SELECT actor FROM project_readers WHERE project=?1 ORDER BY actor")
        .map_err(db_error)?;
    let readers = reader_stmt
        .query_map([&project], |r| r.get(0))
        .map_err(db_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_error)?;
    Ok(Json(ProjectMembers {
        private,
        can_manage: owner == who,
        owner,
        members,
        readers,
    }))
}
#[derive(Deserialize, Serialize)]
pub struct MembershipChange {
    actor: String,
    action: String,
    op: String,
}
pub async fn change_member(
    State(state): State<Db>,
    Path(project): Path<String>,
    headers: HeaderMap,
    Json(change): Json<MembershipChange>,
) -> Result<StatusCode, ApiError> {
    if !valid_id(&change.op)
        || !matches!(
            change.action.as_str(),
            "grant" | "grant_reader" | "revoke" | "set_reader" | "set_writer"
        )
    {
        return Err(err(StatusCode::BAD_REQUEST, "invalid membership change"));
    }
    let mut db = state.lock().unwrap();
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(db_error)?;
    let who = actor(&tx, &headers)?;
    require_project(&tx, &who, &project)?;
    let (owner,private):(String,bool)=tx.query_row("SELECT created_by,EXISTS(SELECT 1 FROM project_rules WHERE project=projects.id) FROM projects WHERE id=?1",[&project],|r|Ok((r.get(0)?,r.get(1)?))).map_err(db_error)?;
    if owner != who {
        return Err(err(
            StatusCode::FORBIDDEN,
            "only project owner can manage members",
        ));
    }
    if !private {
        return Err(err(
            StatusCode::CONFLICT,
            "workspace projects have no membership list",
        ));
    }
    if change.actor == owner {
        return Err(err(StatusCode::CONFLICT, "owner membership cannot change"));
    }
    let payload = format!(
        "membership:{}:{}",
        project,
        serde_json::to_string(&change).unwrap()
    );

    if replay(&tx, &change.op, &payload, &who)? {
        return Ok(StatusCode::OK);
    }
    let human: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM actors WHERE id=?1 AND kind='human')",
            [&change.actor],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if !human {
        return Err(err(StatusCode::BAD_REQUEST, "unknown human"));
    }
    let exists: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM project_members WHERE project=?1 AND actor=?2)",
            params![project, change.actor],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    if (matches!(change.action.as_str(), "grant" | "grant_reader") && exists)
        || (!matches!(change.action.as_str(), "grant" | "grant_reader") && !exists)
    {
        return Err(err(StatusCode::CONFLICT, "membership unchanged"));
    }
    if matches!(change.action.as_str(), "grant" | "grant_reader") {
        tx.execute(
            "INSERT INTO project_members VALUES (?1,?2)",
            params![project, change.actor],
        )
        .map_err(db_error)?;
    } else if change.action == "revoke" {
        tx.execute(
            "DELETE FROM project_members WHERE project=?1 AND actor=?2",
            params![project, change.actor],
        )
        .map_err(db_error)?;
    }
    if matches!(change.action.as_str(), "grant_reader" | "set_reader") {
        let changed = tx
            .execute(
                "INSERT OR IGNORE INTO project_readers(project,actor) VALUES (?1,?2)",
                params![project, change.actor],
            )
            .map_err(db_error)?;
        if changed == 0 {
            return Err(err(StatusCode::CONFLICT, "membership unchanged"));
        }
    } else if change.action == "set_writer" {
        let changed = tx
            .execute(
                "DELETE FROM project_readers WHERE project=?1 AND actor=?2",
                params![project, change.actor],
            )
            .map_err(db_error)?;
        if changed == 0 {
            return Err(err(StatusCode::CONFLICT, "membership unchanged"));
        }
    }
    audit(
        &tx,
        &change.op,
        &payload,
        &who,
        "project",
        &project,
        &format!("{}:{}", change.action, change.actor),
    )?;
    tx.commit().map_err(db_error)?;
    Ok(StatusCode::OK)
}

pub async fn project_history(
    State(state): State<Db>,
    Path(project): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Vec<AuditEvent>>, ApiError> {
    let db = state.lock().unwrap();
    let who = actor(&db, &headers)?;
    require_project(&db, &who, &project)?;
    let mut stmt=db.prepare("SELECT actor,action,created FROM task_audit WHERE object_type='project' AND object_id=?1 ORDER BY seq").map_err(db_error)?;
    let rows = stmt
        .query_map([project], |r| {
            Ok(AuditEvent {
                actor: r.get(0)?,
                action: r.get(1)?,
                created: r.get(2)?,
            })
        })
        .map_err(db_error)?;
    Ok(Json(rows.collect::<Result<Vec<_>, _>>().map_err(db_error)?))
}
