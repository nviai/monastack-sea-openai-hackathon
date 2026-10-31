//! One-time demo data; restarting never resets edited tickets.
use rusqlite::{params, Transaction};
pub fn seed(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    tx.execute_batch("CREATE TABLE IF NOT EXISTS project_details(project TEXT PRIMARY KEY REFERENCES projects(id),description TEXT NOT NULL,url TEXT NOT NULL,demo INTEGER NOT NULL DEFAULT 0);")?;
    let applied: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='demo-product-projects-v1')",
        [],
        |r| r.get(0),
    )?;
    if applied {
        return translate_legacy(tx);
    }
    let projects = [
        (
            "demo-meslingo-v1",
            "Meslingo",
            "AI-powered English learning",
            "https://meslingo.com",
            [
                "Design a beginner English learning path",
                "Add vocabulary review reminders",
                "Integrate AI pronunciation feedback",
                "Test the speaking practice flow",
                "Complete the learning goals screen",
                "Create workplace vocabulary flashcards",
            ],
        ),
        (
            "demo-vibekol-v1",
            "VibeKOL",
            "AI model image creation",
            "https://vibekol.com",
            [
                "Add product photography style presets",
                "Design multi-size image export",
                "Optimize the AI image generation queue",
                "Test character consistency",
                "Complete the prompt editor",
                "Build the sample image gallery",
            ],
        ),
        (
            "demo-omitx-v1",
            "OmitX",
            "Mac storage cleanup for vibe coders",
            "https://omitx.nviai.com",
            [
                "Add cache filters by developer tool",
                "Design scheduled cleanup reminders",
                "Build the storage recovery preview",
                "Test macOS folder permissions",
                "Design the disk usage dashboard",
                "Complete the developer cache inventory",
            ],
        ),
    ];
    for (id, name, description, url, titles) in projects {
        tx.execute(
            "INSERT INTO projects VALUES (?1,?2,'le-pha')",
            params![id, name],
        )?;
        tx.execute(
            "INSERT INTO project_details VALUES (?1,?2,?3,1)",
            params![id, description, url],
        )?;
        for (i, title) in titles.iter().enumerate() {
            let state = if i < 2 {
                "todo"
            } else if i < 4 {
                "in_progress"
            } else {
                "done"
            };
            let assignee = match i {
                0 | 4 => "pm-agent",
                3 => "qa-agent",
                _ => "dev-agent",
            };
            tx.execute(
                "INSERT INTO tasks VALUES (?1,?2,?3,?4,?5,1,'le-pha')",
                params![format!("{id}-task-{i}"), id, title, assignee, state],
            )?;
        }
    }
    tx.execute(
        "INSERT INTO metadata VALUES ('demo-product-projects-v1','applied')",
        [],
    )?;
    Ok(())
}
/// Translate only unchanged demo seed values, preserving edits and task status.
fn translate_legacy(tx: &Transaction<'_>) -> rusqlite::Result<()> {
    let applied: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='demo-projects-english-v1')",
        [],
        |r| r.get(0),
    )?;
    if applied {
        return Ok(());
    }
    tx.execute(
        "UPDATE project_details SET description=?1 WHERE project=?2 AND description=?3",
        params![
            "AI-powered English learning",
            "demo-meslingo-v1",
            "App học tiếng Anh cùng AI"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Design a beginner English learning path",
            "demo-meslingo-v1-task-0",
            "Thiết kế lộ trình tiếng Anh cho người mới"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Add vocabulary review reminders",
            "demo-meslingo-v1-task-1",
            "Thêm nhắc lịch ôn từ vựng"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Integrate AI pronunciation feedback",
            "demo-meslingo-v1-task-2",
            "Tích hợp phản hồi phát âm với AI"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Test the speaking practice flow",
            "demo-meslingo-v1-task-3",
            "Kiểm thử luồng hội thoại luyện nói"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Complete the learning goals screen",
            "demo-meslingo-v1-task-4",
            "Hoàn thiện màn hình chọn mục tiêu học"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Create workplace vocabulary flashcards",
            "demo-meslingo-v1-task-5",
            "Thiết kế bộ flashcard chủ đề công việc"
        ],
    )?;
    tx.execute(
        "UPDATE project_details SET description=?1 WHERE project=?2 AND description=?3",
        params![
            "AI model image creation",
            "demo-vibekol-v1",
            "App tạo ảnh mẫu bằng AI"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Add product photography style presets",
            "demo-vibekol-v1-task-0",
            "Thêm bộ phong cách chụp sản phẩm"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Design multi-size image export",
            "demo-vibekol-v1-task-1",
            "Thiết kế xuất ảnh theo nhiều kích thước"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Optimize the AI image generation queue",
            "demo-vibekol-v1-task-2",
            "Tối ưu hàng đợi tạo ảnh AI"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Test character consistency",
            "demo-vibekol-v1-task-3",
            "Kiểm thử độ nhất quán nhân vật"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Complete the prompt editor",
            "demo-vibekol-v1-task-4",
            "Hoàn thiện màn hình nhập prompt"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Build the sample image gallery",
            "demo-vibekol-v1-task-5",
            "Xây dựng thư viện ảnh mẫu"
        ],
    )?;
    tx.execute(
        "UPDATE project_details SET description=?1 WHERE project=?2 AND description=?3",
        params![
            "Mac storage cleanup for vibe coders",
            "demo-omitx-v1",
            "Dọn bộ nhớ Mac dành cho Vibe Coder"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Add cache filters by developer tool",
            "demo-omitx-v1-task-0",
            "Thêm bộ lọc cache theo công cụ lập trình"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Design scheduled cleanup reminders",
            "demo-omitx-v1-task-1",
            "Thiết kế lịch nhắc dọn dẹp"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Build the storage recovery preview",
            "demo-omitx-v1-task-2",
            "Xây dựng màn hình xem trước dung lượng giải phóng"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Test macOS folder permissions",
            "demo-omitx-v1-task-3",
            "Kiểm thử quyền truy cập thư mục macOS"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Design the disk usage dashboard",
            "demo-omitx-v1-task-4",
            "Thiết kế dashboard dung lượng ổ đĩa"
        ],
    )?;
    tx.execute(
        "UPDATE tasks SET title=?1,version=version+1 WHERE id=?2 AND title=?3",
        params![
            "Complete the developer cache inventory",
            "demo-omitx-v1-task-5",
            "Hoàn thiện danh sách cache phát triển"
        ],
    )?;
    tx.execute(
        "INSERT INTO metadata VALUES ('demo-projects-english-v1','applied')",
        [],
    )?;
    Ok(())
}
#[cfg(test)]
mod tests {
    #[test]
    fn legacy_translation_preserves_edits_and_status_and_runs_once() {
        let mut db = rusqlite::Connection::open_in_memory().unwrap();
        crate::initialize(
            &mut db,
            include_str!("../../../data/seed/nviai/seed.v1.json"),
        )
        .unwrap();
        db.execute("UPDATE tasks SET title='Thêm nhắc lịch ôn từ vựng',state='done' WHERE id='demo-meslingo-v1-task-1'",[]).unwrap();
        db.execute(
            "UPDATE tasks SET title='My custom title' WHERE id='demo-meslingo-v1-task-0'",
            [],
        )
        .unwrap();
        crate::initialize(
            &mut db,
            include_str!("../../../data/seed/nviai/seed.v1.json"),
        )
        .unwrap();
        let row: (String, String, i64) = db
            .query_row(
                "SELECT title,state,version FROM tasks WHERE id='demo-meslingo-v1-task-1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(
            row,
            ("Add vocabulary review reminders".into(), "done".into(), 2)
        );
        assert_eq!(
            db.query_row(
                "SELECT title FROM tasks WHERE id='demo-meslingo-v1-task-0'",
                [],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
            "My custom title"
        );
        crate::initialize(
            &mut db,
            include_str!("../../../data/seed/nviai/seed.v1.json"),
        )
        .unwrap();
        assert_eq!(
            db.query_row(
                "SELECT version FROM tasks WHERE id='demo-meslingo-v1-task-1'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            2
        );
    }
    #[test]
    fn demo_is_seeded_once_without_resetting_user_edits() {
        let mut db = rusqlite::Connection::open_in_memory().unwrap();
        crate::initialize(
            &mut db,
            include_str!("../../../data/seed/nviai/seed.v1.json"),
        )
        .unwrap();
        assert_eq!(
            db.query_row(
                "SELECT COUNT(*) FROM project_details WHERE demo=1",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            3
        );
        assert_eq!(
            db.query_row(
                "SELECT COUNT(*) FROM tasks WHERE project LIKE 'demo-%'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            18
        );
        db.execute(
            "UPDATE tasks SET title='User edit',state='done' WHERE id='demo-meslingo-v1-task-0'",
            [],
        )
        .unwrap();
        crate::initialize(
            &mut db,
            include_str!("../../../data/seed/nviai/seed.v1.json"),
        )
        .unwrap();
        assert_eq!(
            db.query_row(
                "SELECT title FROM tasks WHERE id='demo-meslingo-v1-task-0'",
                [],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
            "User edit"
        );
    }
}
