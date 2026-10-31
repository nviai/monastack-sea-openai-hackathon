//! One-time updates for existing seeded workspaces, without resetting user data.
use rusqlite::{params, Transaction};

pub fn apply(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    let applied: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='seed-english-leadership-v1')",
        [],
        |r| r.get(0),
    )?;
    if applied {
        return Ok(());
    }
    // Match original seed names so a user-customized name is preserved.
    for (id, old, new) in [
        ("an", "Nguyễn Văn An", "Nguyen Van An"),
        ("thao", "Đỗ Phương Thảo", "Do Phuong Thao"),
        ("hung", "Vũ Mạnh Hùng", "Vu Manh Hung"),
        ("tuan", "Trần Anh Tuấn", "Tran Anh Tuan"),
        ("linh", "Phạm Khánh Linh", "Pham Khanh Linh"),
        ("mai", "Lê Thị Mai", "Le Thi Mai"),
        ("duc", "Hoàng Minh Đức", "Hoang Minh Duc"),
        ("van", "Ngô Thu Vân", "Ngo Thu Van"),
    ] {
        tx.execute(
            "UPDATE actors SET name=?3 WHERE id=?1 AND name=?2",
            params![id, old, new],
        )?;
    }
    for (id, role) in [
        ("le-pha", "ceo"),
        ("hua-hao", "cto"),
        ("le-triet", "org-admin"),
    ] {
        // Replace their old seeded job roles; preserve unrelated explicit grants.
        tx.execute(
            "DELETE FROM actor_roles WHERE actor=?1 AND role IN ('dev','pm','qa')",
            [id],
        )?;
        tx.execute("INSERT OR IGNORE INTO actor_roles(actor,role) SELECT id,?2 FROM actors WHERE id=?1 AND kind='human'",params![id,role])?;
    }
    tx.execute(
        "INSERT INTO metadata VALUES ('seed-english-leadership-v1','applied')",
        [],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn migrates_old_seed_once_and_preserves_custom_names_and_grants() {
        let mut db = rusqlite::Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT); CREATE TABLE actors(id TEXT PRIMARY KEY,kind TEXT,name TEXT); CREATE TABLE actor_roles(actor TEXT,role TEXT,PRIMARY KEY(actor,role));
        INSERT INTO actors VALUES ('an','human','Nguyễn Văn An'),('van','human','Custom Name'),('le-pha','human','Pha Le'),('hua-hao','human','Hao Hua'),('le-triet','human','Triet Le');
        INSERT INTO actor_roles VALUES ('le-pha','dev'),('hua-hao','dev'),('hua-hao','pm'),('le-triet','dev'),('le-triet','qa'),('le-triet','operations');").unwrap();
        {
            let tx = db.transaction().unwrap();
            apply(&tx).unwrap();
            tx.commit().unwrap();
        }
        let name: String = db
            .query_row("SELECT name FROM actors WHERE id='an'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(name, "Nguyen Van An");
        let custom: String = db
            .query_row("SELECT name FROM actors WHERE id='van'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(custom, "Custom Name");
        for (id, role) in [
            ("le-pha", "ceo"),
            ("hua-hao", "cto"),
            ("le-triet", "org-admin"),
            ("le-triet", "operations"),
        ] {
            let present: bool = db
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM actor_roles WHERE actor=?1 AND role=?2)",
                    params![id, role],
                    |r| r.get(0),
                )
                .unwrap();
            assert!(present);
        }
        let stale: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM actor_roles WHERE role IN ('dev','pm','qa')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(stale, 0);
        db.execute(
            "DELETE FROM actor_roles WHERE actor='le-triet' AND role='org-admin'",
            [],
        )
        .unwrap();
        {
            let tx = db.transaction().unwrap();
            apply(&tx).unwrap();
            tx.commit().unwrap();
        }
        let restored: bool=db.query_row("SELECT EXISTS(SELECT 1 FROM actor_roles WHERE actor='le-triet' AND role='org-admin')",[],|r|r.get(0)).unwrap();
        assert!(!restored);
    }
}
