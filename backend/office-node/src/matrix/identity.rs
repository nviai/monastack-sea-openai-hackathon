use super::*;

impl Bridge {
    pub(super) async fn user(&self, db: &Db, who: &str) -> Result<String, ApiError> {
        let _guard = self.resource_gate(format!("user:{who}")).await;
        let (user, name) = {
            let mut conn = db.lock().unwrap();
            let tx = conn.transaction().map_err(db_error)?;
            human(&tx, who)?;
            let name: String = tx
                .query_row("SELECT name FROM actors WHERE id=?1", [who], |r| r.get(0))
                .map_err(db_error)?;
            let user = mapped_user(&tx, who, &self.server_name).map_err(db_error)?;
            tx.commit().map_err(db_error)?;
            (user, name)
        };
        let applied: Option<String> = db
            .lock()
            .unwrap()
            .query_row(
                "SELECT name FROM matrix_user_config WHERE actor=?1",
                [who],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_error)?;
        if applied.as_deref() == Some(&name) {
            return Ok(user);
        }
        let op = format!("user:{who}");
        Self::intent(db, &op)?;
        self.call(
            Method::PUT,
            &format!("/_synapse/admin/v2/users/{}", segment(&user)),
            json!({"displayname": name,"admin":false,"deactivated":false,
                "password":uuid::Uuid::new_v4().to_string(),"logout_devices":false}),
        )
        .await?;
        db.lock().unwrap().execute("INSERT INTO matrix_user_config VALUES (?1,?2) ON CONFLICT(actor) DO UPDATE SET name=excluded.name",params![who,name]).map_err(db_error)?;
        Self::done(db, &op)?;
        Ok(user)
    }
}
pub(super) fn human(conn: &Connection, who: &str) -> Result<(), ApiError> {
    let valid: bool=conn.query_row("SELECT EXISTS(SELECT 1 FROM actors a LEFT JOIN accounts c ON c.actor=a.id WHERE a.id=?1 AND a.kind='human' AND COALESCE(c.disabled,0)=0)",[who],|r|r.get(0)).map_err(db_error)?;
    if valid {
        Ok(())
    } else {
        Err(err(StatusCode::FORBIDDEN, "human account required"))
    }
}
pub(super) fn caller(db: &Db, headers: &HeaderMap) -> Result<String, ApiError> {
    let conn = db.lock().unwrap();
    let who = actor(&conn, headers)?;
    human(&conn, &who)?;
    Ok(who)
}
pub(super) fn mapped_user(conn: &Connection, who: &str, server: &str) -> rusqlite::Result<String> {
    conn.execute(
        "INSERT OR IGNORE INTO matrix_users(actor,user_id,created) VALUES (?1,?2,?3)",
        params![
            who,
            format!("@u{}:{server}", uuid::Uuid::new_v4().simple()),
            now()
        ],
    )?;
    conn.query_row(
        "SELECT user_id FROM matrix_users WHERE actor=?1",
        [who],
        |r| r.get(0),
    )
}
pub fn jwt(secret: &str, localpart: &str, issued: i64) -> String {
    let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
    let claims=URL_SAFE_NO_PAD.encode(serde_json::to_vec(&json!({"sub":localpart,"iss":"monastack-node","aud":"monastack-matrix","iat":issued,"exp":issued+60})).unwrap());
    let body = format!("{header}.{claims}");
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
    mac.update(body.as_bytes());
    format!(
        "{body}.{}",
        URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mapping_is_random_durable_and_independent_of_name() {
        let db = crate::tests::setup();
        let conn = db.lock().unwrap();
        let a = mapped_user(&conn, "an", "test.local").unwrap();
        conn.execute("UPDATE actors SET name='Renamed' WHERE id='an'", [])
            .unwrap();
        assert_eq!(mapped_user(&conn, "an", "test.local").unwrap(), a);
        assert_ne!(mapped_user(&conn, "van", "test.local").unwrap(), a);
        assert!(!a.contains("an:"));
    }
    #[test]
    fn dm_key_is_a_canonical_member_set() {
        assert_eq!(
            member_key("an", vec!["van".into(), "mai".into()])
                .unwrap()
                .0,
            member_key("mai", vec!["an".into(), "van".into(), "van".into()])
                .unwrap()
                .0
        );
        assert!(member_key("an", vec![]).is_err());
        assert!(member_key("an", vec!["an".into()]).is_err());
    }
    #[test]
    fn jwt_hs256_claims_expiry_and_tampering() {
        let token = jwt("test-secret", "urandom", 1000);
        let parts: Vec<_> = token.split('.').collect();
        let claims: Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(
            claims,
            json!({"sub":"urandom","iss":"monastack-node","aud":"monastack-matrix","iat":1000,"exp":1060})
        );
        let data = format!("{}.{}", parts[0], parts[1]);
        let signature = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
        let mut mac = Hmac::<Sha256>::new_from_slice(b"test-secret").unwrap();
        mac.update(data.as_bytes());
        assert!(mac.verify_slice(&signature).is_ok());
        let mut mac = Hmac::<Sha256>::new_from_slice(b"test-secret").unwrap();
        mac.update(format!("{data}x").as_bytes());
        assert!(mac.verify_slice(&signature).is_err());
    }
}
