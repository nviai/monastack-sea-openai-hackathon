use super::*;

impl Bridge {
    async fn change_memberships(
        &self,
        db: &Db,
        room: &str,
        desired: &BTreeSet<String>,
        remove_only: bool,
    ) -> Result<(), ApiError> {
        let _guard = self.resource_gate(format!("membership:{room}")).await;
        let value = self
            .call(
                Method::GET,
                &format!("/_synapse/admin/v1/rooms/{}/members", segment(room)),
                json!({}),
            )
            .await?;
        let actual: BTreeSet<String> = value["members"]
            .as_array()
            .ok_or_else(unavailable)?
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect();
        // Remove unauthorized members before admitting anyone.
        let mut failed = false;
        for user in actual
            .difference(desired)
            .filter(|u| *u != &self.admin_user)
        {
            let op = format!("kick:{room}:{user}");
            let result = async {
                Self::intent(db, &op)?;
                self.call(
                    Method::POST,
                    &format!("/_matrix/client/v3/rooms/{}/kick", segment(room)),
                    json!({"user_id":user,"reason":"Office access revoked"}),
                )
                .await?;
                Self::done(db, &op)
            }
            .await;
            failed |= result.is_err();
        }
        if remove_only {
            return if failed { Err(unavailable()) } else { Ok(()) };
        }
        for user in desired.difference(&actual) {
            let op = format!("join:{room}:{user}");
            let result = async {
                Self::intent(db, &op)?;
                self.call(
                    Method::POST,
                    &format!("/_synapse/admin/v1/join/{}", segment(room)),
                    json!({"user_id":user}),
                )
                .await?;
                Self::done(db, &op)
            }
            .await;
            failed |= result.is_err();
        }
        if failed {
            Err(unavailable())
        } else {
            Ok(())
        }
    }

    pub(super) async fn memberships(
        &self,
        db: &Db,
        room: &str,
        desired: &BTreeSet<String>,
    ) -> Result<(), ApiError> {
        self.change_memberships(db, room, desired, false).await
    }

    async fn user_lifecycle(&self, db: &Db, who: &str, user: &str) -> Result<(), ApiError> {
        let (enabled, fingerprint, old) = {
            let conn = db.lock().unwrap();
            let enabled = human(&conn, who).is_ok();
            let fingerprint: String = conn.query_row("SELECT COALESCE(group_concat(value,','),'') FROM (SELECT id AS value FROM sessions WHERE actor=?1 AND revoked=1 UNION ALL SELECT hex(hash) AS value FROM tokens WHERE actor=?1 ORDER BY value)",[who],|r|r.get(0)).map_err(db_error)?;
            let old: Option<String> = conn
                .query_row(
                    "SELECT fingerprint FROM matrix_session_revocations WHERE actor=?1",
                    [who],
                    |r| r.get(0),
                )
                .optional()
                .map_err(db_error)?;
            (enabled, fingerprint, old)
        };
        let fingerprint = format!("{enabled}:{fingerprint}");
        if old.is_none() && enabled {
            db.lock()
                .unwrap()
                .execute(
                    "INSERT INTO matrix_session_revocations VALUES (?1,?2)",
                    params![who, fingerprint],
                )
                .map_err(db_error)?;
        }
        if old.as_ref().is_some_and(|old| old != &fingerprint)
            || !enabled && old.as_deref() != Some(&fingerprint)
        {
            let op = format!("logout:{who}");
            Self::intent(db, &op)?;
            let path = format!("/_synapse/admin/v2/users/{}", segment(&user));
            let devices = self
                .call(Method::GET, &format!("{path}/devices"), json!({}))
                .await?;
            let devices: Vec<Value> = devices["devices"]
                .as_array()
                .ok_or_else(unavailable)?
                .iter()
                .map(|d| d["device_id"].clone())
                .collect();
            self.call(
                Method::POST,
                &format!("{path}/delete_devices"),
                json!({"devices":devices}),
            )
            .await?;
            if !enabled {
                db.lock()
                    .unwrap()
                    .execute("DELETE FROM matrix_user_config WHERE actor=?1", [who])
                    .map_err(db_error)?;
                self.call(Method::PUT, &path, json!({"locked":true}))
                    .await?;
            }
            db.lock().unwrap().execute("INSERT INTO matrix_session_revocations VALUES (?1,?2) ON CONFLICT(actor) DO UPDATE SET fingerprint=excluded.fingerprint",params![who,fingerprint]).map_err(db_error)?;
            Self::done(db, &op)?;
        }
        Ok(())
    }

    // Read desired membership independently of successful provisioning. A failed
    // reactivation must never turn an authorized user into an accidental kick.
    fn desired(db: &Db, key: &str, dm: bool) -> Result<BTreeSet<String>, ApiError> {
        let conn = db.lock().unwrap();
        let members: Vec<String> = if dm {
            serde_json::from_str(key).map_err(|_| unavailable())?
        } else {
            Vec::new()
        };
        let users = rows(&conn, "SELECT actor,user_id FROM matrix_users")?;
        let mut desired = BTreeSet::new();
        for (actor, user) in users {
            if human(&conn, &actor).is_ok()
                && (if dm {
                    members.contains(&actor)
                } else {
                    permitted(&conn, &actor, key)?
                })
            {
                desired.insert(user);
            }
        }
        Ok(desired)
    }

    fn office_rooms(db: &Db) -> Result<Vec<(String, String, String, bool)>, ApiError> {
        let conn = db.lock().unwrap();
        let mut stmt = conn.prepare("SELECT r.id,COALESCE(d.name,r.id),COALESCE(d.topic,''),r.restricted FROM rooms r LEFT JOIN matrix_room_details d ON d.office_room=r.id ORDER BY r.id").map_err(db_error)?;
        let result = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
            .map_err(db_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(db_error)?;
        Ok(result)
    }

    async fn reconcile_locked(&self, db: &Db) -> Result<(), ApiError> {
        let pending = {
            let conn = db.lock().unwrap();
            let mut stmt = conn
                .prepare("SELECT op,created FROM matrix_intents WHERE done=0")
                .map_err(db_error)?;
            let result = stmt
                .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))
                .map_err(db_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(db_error)?;
            result
        };
        let mut failed = false;
        // Revoke in EVERY existing room before provisioning any user or grant.
        // Errors are isolated per room and per member, and remain retryable.
        for (table, column, dm) in [
            ("matrix_rooms", "office_room", false),
            ("matrix_dms", "member_key", true),
        ] {
            let existing = {
                rows(
                    &db.lock().unwrap(),
                    &format!("SELECT {column},room_id FROM {table} WHERE room_id IS NOT NULL"),
                )?
            };
            for (key, room) in existing {
                let result = async {
                    let desired = Self::desired(db, &key, dm)?;
                    self.change_memberships(db, &room, &desired, true).await
                }
                .await;
                failed |= result.is_err();
            }
        }
        let users = {
            rows(
                &db.lock().unwrap(),
                "SELECT actor,user_id FROM matrix_users",
            )?
        };
        for (who, user) in users {
            let result = async {
                self.user_lifecycle(db, &who, &user).await?;
                let enabled = { human(&db.lock().unwrap(), &who).is_ok() };
                if enabled {
                    self.user(db, &who).await?;
                }
                Ok::<_, ApiError>(())
            }
            .await;
            failed |= result.is_err();
        }
        for (id, name, topic, restricted) in Self::office_rooms(db)? {
            let result = async {
                let room = self.room(db, &id, false, &name, &topic, restricted).await?;
                let desired = Self::desired(db, &id, false)?;
                self.memberships(db, &room, &desired).await
            }
            .await;
            failed |= result.is_err();
        }
        let dms = {
            rows(
                &db.lock().unwrap(),
                "SELECT member_key,alias FROM matrix_dms",
            )?
        };
        for (key, _) in dms {
            let result = async {
                let room = self
                    .room(db, &key, true, "Direct message", "", true)
                    .await?;
                let desired = Self::desired(db, &key, true)?;
                self.memberships(db, &room, &desired).await
            }
            .await;
            failed |= result.is_err();
        }
        if failed {
            return Err(unavailable());
        }
        // A complete authoritative pass also retires obsolete intents from a
        // crash or a permission change that superseded the original operation.
        for (op, generation) in pending {
            db.lock()
                .unwrap()
                .execute(
                    "UPDATE matrix_intents SET done=1 WHERE op=?1 AND created=?2",
                    params![op, generation],
                )
                .map_err(db_error)?;
        }
        Ok(())
    }

    pub async fn reconcile(&self, db: &Db) -> Result<(), ApiError> {
        let _guard = self.gate.lock().await;
        self.reconcile_locked(db).await
    }

    // Caller requests never run a global pass or wait behind its gate. These
    // idempotent operations touch only this caller's authorized room joins.
    pub(super) async fn caller_rooms(&self, db: &Db, who: &str) -> Result<(), ApiError> {
        let user = self.user(db, who).await?;
        for (id, name, topic, restricted) in Self::office_rooms(db)? {
            let allowed = { permitted(&db.lock().unwrap(), who, &id)? };
            if !allowed {
                continue;
            }
            let room = self.room(db, &id, false, &name, &topic, restricted).await?;
            let _guard = self.resource_gate(format!("membership:{room}")).await;
            let actual = self
                .call(
                    Method::GET,
                    &format!("/_synapse/admin/v1/rooms/{}/members", segment(&room)),
                    json!({}),
                )
                .await?;
            if actual["members"]
                .as_array()
                .ok_or_else(unavailable)?
                .iter()
                .any(|m| m.as_str() == Some(&user))
            {
                continue;
            }
            let op = format!("join:{room}:{user}");
            Self::intent(db, &op)?;
            self.call(
                Method::POST,
                &format!("/_synapse/admin/v1/join/{}", segment(&room)),
                json!({"user_id":user}),
            )
            .await?;
            Self::done(db, &op)?;
        }
        Ok(())
    }
}

fn retry_delay(previous: Duration) -> Duration {
    (previous * 2).clamp(Duration::from_secs(1), Duration::from_secs(30))
}

pub fn spawn_reconcile(db: Db, bridge: Arc<Bridge>) {
    tokio::spawn(async move {
        let mut last = None;
        let mut attempted = None;
        let mut delay = Duration::ZERO;
        let mut retry_at = tokio::time::Instant::now();
        loop {
            let epoch = { realtime_epoch(&db.lock().unwrap()).ok() };
            let pending = {
                db.lock()
                    .unwrap()
                    .query_row(
                        "SELECT EXISTS(SELECT 1 FROM matrix_intents WHERE done=0)",
                        [],
                        |r| r.get::<_, bool>(0),
                    )
                    .unwrap_or(true)
            };
            let changed = epoch != attempted;
            if (epoch != last || pending) && (changed || tokio::time::Instant::now() >= retry_at) {
                if changed {
                    delay = Duration::ZERO;
                }
                attempted = epoch;
                match bridge.reconcile(&db).await {
                    Ok(()) => {
                        last = epoch;
                        delay = Duration::ZERO;
                    }
                    Err(_) => {
                        delay = retry_delay(delay);
                        eprintln!(
                            "Matrix reconciliation pending; retry in {}s",
                            delay.as_secs()
                        );
                    }
                }
                retry_at = tokio::time::Instant::now() + delay;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn failures_back_off_and_cap_at_thirty_seconds() {
        let mut delay = Duration::ZERO;
        for expected in [1, 2, 4, 8, 16, 30, 30] {
            delay = retry_delay(delay);
            assert_eq!(delay.as_secs(), expected);
        }
    }
}
