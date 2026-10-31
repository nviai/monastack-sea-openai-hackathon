//! Prototype role policy. Roles must be supplied by a trusted authority.
pub fn can_access_customers(roles: &[String]) -> bool {
    roles
        .iter()
        .any(|r| matches!(r.as_str(), "sales" | "cs" | "org-admin"))
}
pub fn can_manage_sales(roles: &[String]) -> bool {
    roles
        .iter()
        .any(|r| matches!(r.as_str(), "sales" | "org-admin"))
}

pub fn valid_contract_proposal(title: &str, terms: &str) -> bool {
    !title.trim().is_empty()
        && title.len() <= 200
        && !terms.trim().is_empty()
        && terms.len() <= 4000
}

pub fn can_decide_contract(roles: &[String], actor: &str, creator: &str) -> bool {
    actor != creator && roles.iter().any(|role| role == "org-admin")
}

pub fn contract_next_state(state: &str, action: &str) -> Option<&'static str> {
    match (state, action) {
        ("proposed", "approve") => Some("approved_internal"),
        ("proposed", "reject") => Some("rejected"),
        ("proposed", "withdraw") => Some("withdrawn"),
        _ => None,
    }
}
pub fn can_manage_support(roles: &[String]) -> bool {
    roles
        .iter()
        .any(|r| matches!(r.as_str(), "cs" | "org-admin"))
}
pub fn support_transition(from: &str, to: &str) -> bool {
    matches!(
        (from, to),
        ("open", "in_progress") | ("in_progress", "resolved") | ("resolved", "in_progress")
    )
}
pub fn sales_transition(from: &str, to: &str) -> bool {
    matches!(
        (from, to),
        ("lead", "qualified")
            | ("qualified", "proposal")
            | ("proposal", "won")
            | ("lead" | "qualified" | "proposal", "lost")
    )
}

/// UTC epoch seconds, bounded to 2000–2100 and meetings no longer than seven days.
pub fn valid_meeting(title: &str, starts: i64, ends: i64) -> bool {
    !title.trim().is_empty()
        && title.len() <= 200
        && (946_684_800..=4_102_444_800).contains(&starts)
        && ends > starts
        && ends <= 4_102_444_800
        && ends - starts <= 7 * 86_400
}
pub fn valid_whiteboard_note(text: &str, x: i64, y: i64) -> bool {
    !text.trim().is_empty()
        && text.len() <= 500
        && (0..=1000).contains(&x)
        && (0..=1000).contains(&y)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn customer_data_defaults_to_deny() {
        assert!(!can_access_customers(&[]));
        assert!(!can_access_customers(&["dev".into()]));
        assert!(can_access_customers(&["sales".into()]));
        assert!(can_access_customers(&["cs".into()]));
        assert!(can_access_customers(&["org-admin".into()]));
        assert!(!can_manage_sales(&["cs".into()]));
        assert!(can_manage_sales(&["sales".into()]));
        assert!(!can_decide_contract(&["sales".into()], "a", "b"));
        assert!(!can_decide_contract(&["org-admin".into()], "a", "a"));
        assert!(can_decide_contract(&["org-admin".into()], "a", "b"));
        assert!(valid_contract_proposal("Title", "Terms"));
        assert!(!valid_contract_proposal("Title", " "));
        assert_eq!(
            contract_next_state("proposed", "approve"),
            Some("approved_internal")
        );
        assert_eq!(contract_next_state("approved_internal", "approve"), None);
        assert!(sales_transition("lead", "qualified"));
        assert!(sales_transition("proposal", "lost"));
        assert!(!sales_transition("lead", "won"));
        assert!(!sales_transition("won", "lost"));
        assert!(can_manage_support(&["cs".into()]));
        assert!(!can_manage_support(&["sales".into()]));
        assert!(support_transition("resolved", "in_progress"));
        assert!(!support_transition("open", "resolved"));
    }
}

pub fn can_access_finance(roles: &[String]) -> bool {
    roles
        .iter()
        .any(|r| matches!(r.as_str(), "accountant" | "org-admin"))
}
pub fn can_decide_expense(roles: &[String], actor: &str, creator: &str) -> bool {
    actor != creator && roles.iter().any(|r| r == "org-admin")
}
pub fn can_decide_payment(
    roles: &[String],
    actor: &str,
    requester: &str,
    expense_creator: &str,
) -> bool {
    actor != requester && actor != expense_creator && roles.iter().any(|r| r == "org-admin")
}

pub fn payment_next_state(state: &str, action: &str) -> Option<&'static str> {
    match (state, action) {
        ("pending", "approve") => Some("approved_waiting"),
        ("pending", "reject") => Some("rejected"),
        ("pending", "withdraw") => Some("withdrawn"),
        ("approved_waiting", "revoke") => Some("revoked"),
        _ => None,
    }
}
pub fn valid_expense(description: &str, minor: i64, currency: &str) -> bool {
    !description.trim().is_empty()
        && description.len() <= 400
        && (1..=1_000_000_000_000).contains(&minor)
        && currency.len() == 3
        && currency.bytes().all(|b| b.is_ascii_uppercase())
}
/// Single-currency two-line journal; account codes are local identifiers.
pub fn valid_journal(
    description: &str,
    debit: &str,
    credit: &str,
    minor: i64,
    currency: &str,
) -> bool {
    let valid_account = |s: &str| {
        !s.is_empty()
            && s.len() <= 80
            && s.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
    };
    valid_expense(description, minor, currency)
        && valid_account(debit)
        && valid_account(credit)
        && debit != credit
}
#[cfg(test)]
mod finance_tests {
    use super::*;
    #[test]
    fn finance_and_approval_are_scoped() {
        assert!(!can_access_finance(&["sales".into()]));
        assert!(can_access_finance(&["accountant".into()]));
        assert!(!can_decide_expense(&["org-admin".into()], "an", "an"));
        assert!(!can_decide_expense(&["accountant".into()], "van", "an"));
        assert!(can_decide_expense(&["org-admin".into()], "an", "van"));
        assert!(!can_decide_payment(
            &["org-admin".into()],
            "an",
            "an",
            "van"
        ));
        assert!(!can_decide_payment(
            &["org-admin".into()],
            "an",
            "van",
            "an"
        ));
        assert!(can_decide_payment(
            &["org-admin".into()],
            "an",
            "van",
            "mai"
        ));
        assert!(valid_expense("Expense", 1, "VND"));
        assert!(!valid_expense("Expense", 0, "VND"));
        assert!(!valid_expense("Expense", 1, "vnd"));
        assert_eq!(
            payment_next_state("approved_waiting", "revoke"),
            Some("revoked")
        );
        assert_eq!(payment_next_state("pending", "revoke"), None);
        assert_eq!(payment_next_state("revoked", "approve"), None);
        assert!(valid_journal("Example", "cash", "expense", 100, "VND"));
        assert!(!valid_journal("Example", "cash", "cash", 100, "VND"));
        assert!(!valid_journal("Example", "cash", "expense", 0, "VND"));
    }
}

/// HR is explicit; administrator status alone does not confer access.
pub fn can_manage_hr(roles: &[String]) -> bool {
    roles.iter().any(|r| r == "hr")
}

/// State changes are separate from caller authorization, which the authority checks.
pub fn leave_next_state(state: &str, action: &str) -> Option<&'static str> {
    match (state, action) {
        ("proposed", "approve") => Some("approved"),
        ("proposed", "reject") => Some("rejected"),
        ("proposed", "withdraw") => Some("withdrawn"),
        ("approved", "request_cancel") => Some("cancellation_pending"),
        ("cancellation_pending", "cancel_approve") => Some("cancelled"),
        ("cancellation_pending", "cancel_reject" | "cancel_withdraw") => Some("approved"),
        _ => None,
    }
}

/// Incident responders are explicitly granted; administrator status is not a grant.
pub fn can_manage_incidents(roles: &[String]) -> bool {
    roles.iter().any(|r| r == "operations")
}

pub fn valid_incident(title: &str, description: &str, severity: &str) -> bool {
    !title.trim().is_empty()
        && title.len() <= 200
        && !description.trim().is_empty()
        && description.len() <= 4000
        && matches!(severity, "low" | "medium" | "high" | "critical")
}

pub fn valid_incident_comment(body: &str) -> bool {
    !body.trim().is_empty() && body.len() <= 2000
}

#[cfg(test)]
mod incident_tests {
    use super::*;
    #[test]
    fn incidents_default_deny_and_validate_fields() {
        assert!(!can_manage_incidents(&["org-admin".into()]));
        assert!(can_manage_incidents(&["operations".into()]));
        assert!(valid_incident("Incident", "Details", "high"));
        assert!(!valid_incident("", "Details", "high"));
        assert!(!valid_incident("Incident", "Details", "unknown"));
        assert!(valid_incident_comment("Update"));
        assert!(!valid_incident_comment("   "));
        assert!(!valid_incident_comment(&"a".repeat(2001)));
    }
}

#[cfg(test)]
mod meeting_tests {
    use super::*;
    #[test]
    fn meeting_bounds_and_duration_are_checked() {
        assert!(valid_meeting("Meeting", 1_800_000_000, 1_800_003_600));
        assert!(!valid_meeting("", 1_800_000_000, 1_800_003_600));
        assert!(!valid_meeting("Meeting", 1_800_000_000, 1_800_000_000));
        assert!(!valid_meeting(
            "Meeting",
            1_800_000_000,
            1_800_000_000 + 7 * 86_400 + 1
        ));
        assert!(!valid_meeting("Meeting", i64::MIN, i64::MAX));
        assert!(valid_whiteboard_note("A note", 0, 1000));
        assert!(!valid_whiteboard_note("", 0, 0));
        assert!(!valid_whiteboard_note("A note", -1, 0));
    }
}
pub fn valid_leave(start: &str, end: &str, reason: &str) -> bool {
    let parse = |value: &str| {
        if value.len() != 10 {
            None
        } else {
            chrono::NaiveDate::parse_from_str(value, "%Y-%m-%d").ok()
        }
    };
    match (parse(start), parse(end)) {
        (Some(a), Some(b)) => {
            b >= a && (b - a).num_days() <= 365 && !reason.trim().is_empty() && reason.len() <= 1000
        }
        _ => false,
    }
}

/// Inclusive ISO date bounds for a calendar month, restricted to supported years.
pub fn leave_month_bounds(month: &str) -> Option<(String, String)> {
    use chrono::{Datelike, NaiveDate};
    if month.len() != 7
        || month.as_bytes()[4] != b'-'
        || !month
            .bytes()
            .enumerate()
            .all(|(i, c)| i == 4 || c.is_ascii_digit())
    {
        return None;
    }
    let year: i32 = month[0..4].parse().ok()?;
    let number: u32 = month[5..7].parse().ok()?;
    if !(2000..=2100).contains(&year) {
        return None;
    }
    let first = NaiveDate::from_ymd_opt(year, number, 1)?;
    let next = if first.month() == 12 {
        NaiveDate::from_ymd_opt(year + 1, 1, 1)?
    } else {
        NaiveDate::from_ymd_opt(year, number + 1, 1)?
    };
    Some((first.to_string(), next.pred_opt()?.to_string()))
}
#[cfg(test)]
mod hr_tests {
    use super::*;
    #[test]
    fn hr_is_explicit_and_dates_are_real() {
        assert!(!can_manage_hr(&["org-admin".into()]));
        assert!(can_manage_hr(&["hr".into()]));
        assert!(valid_leave("2026-02-01", "2026-02-02", "Leave"));
        assert!(!valid_leave("2026-02-30", "2026-03-01", "Leave"));
        assert!(!valid_leave("2026-03-01", "2026-02-01", "Leave"));
        assert_eq!(
            leave_next_state("approved", "request_cancel"),
            Some("cancellation_pending")
        );
        assert_eq!(
            leave_next_state("cancellation_pending", "cancel_approve"),
            Some("cancelled")
        );
        assert_eq!(
            leave_next_state("cancellation_pending", "cancel_reject"),
            Some("approved")
        );
        assert_eq!(
            leave_next_state("cancellation_pending", "cancel_withdraw"),
            Some("approved")
        );
        assert_eq!(leave_next_state("approved", "cancel_approve"), None);
        assert_eq!(leave_next_state("cancelled", "request_cancel"), None);
    }
    #[test]
    fn calendar_month_bounds_validate_and_include_leap_days() {
        assert_eq!(
            leave_month_bounds("2024-02"),
            Some(("2024-02-01".into(), "2024-02-29".into()))
        );
        assert_eq!(
            leave_month_bounds("2100-02"),
            Some(("2100-02-01".into(), "2100-02-28".into()))
        );
        assert!(leave_month_bounds("2026-13").is_none());
        assert!(leave_month_bounds("2026-2").is_none());
        assert!(leave_month_bounds("1999-12").is_none());
    }
}
/// Workspace room membership administration is explicit; this alone never
/// grants a principal access to the contents of a restricted room.
pub fn can_manage_room_members(roles: &[String]) -> bool {
    roles.iter().any(|role| role == "org-admin")
}

#[cfg(test)]
mod room_admin_tests {
    use super::can_manage_room_members;
    #[test]
    fn room_admin_requires_explicit_org_admin_role() {
        assert!(!can_manage_room_members(&[]));
        assert!(!can_manage_room_members(&["hr".into(), "finance".into()]));
        assert!(can_manage_room_members(&["org-admin".into()]));
    }
}
