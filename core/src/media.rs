//! Fail-closed issuance state for a future media control plane.
//!
//! This type does not start a media server, revoke existing tokens, authenticate
//! callers, persist state, or serialize concurrent operations. An authority
//! must do those things and check current membership atomically with issuance.
//! Generations are sequence numbers, not secrets or authentication tokens.

use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Inactive,
    Stopping,
    Starting,
    Active,
    Blocked,
}

#[derive(Debug)]
pub struct MediaGate {
    generation: u64,
    phase: Phase,
    members: HashSet<String>,
}

impl Default for MediaGate {
    fn default() -> Self {
        Self {
            generation: 0,
            phase: Phase::Inactive,
            members: HashSet::new(),
        }
    }
}

impl MediaGate {
    pub fn phase(&self) -> Phase {
        self.phase
    }
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Stop issuing immediately. Every activation, including the first, must
    /// explicitly confirm the prior endpoint is absent before starting.
    pub fn begin_rotation(&mut self) -> Result<u64, &'static str> {
        self.members.clear();
        let Some(next) = self.generation.checked_add(1) else {
            self.phase = Phase::Blocked;
            return Err("generation exhausted");
        };
        self.generation = next;
        self.phase = Phase::Stopping;
        Ok(next)
    }

    pub fn confirm_stopped(&mut self, generation: u64) -> Result<(), &'static str> {
        if generation != self.generation || self.phase != Phase::Stopping {
            return Err("stale or invalid transition");
        }
        self.phase = Phase::Starting;
        Ok(())
    }

    /// The caller supplies membership from trusted, current authority state.
    pub fn activate(
        &mut self,
        generation: u64,
        members: HashSet<String>,
    ) -> Result<(), &'static str> {
        if generation != self.generation || self.phase != Phase::Starting {
            return Err("stale or invalid transition");
        }
        if members.iter().any(|id| {
            id.is_empty()
                || id.len() > 80
                || !id
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
        }) {
            self.phase = Phase::Blocked;
            self.members.clear();
            return Err("invalid member");
        }
        self.members = members;
        self.phase = Phase::Active;
        Ok(())
    }

    pub fn fail(&mut self, generation: u64) -> Result<(), &'static str> {
        if generation != self.generation {
            return Err("stale generation");
        }
        self.members.clear();
        self.phase = Phase::Blocked;
        Ok(())
    }

    /// `currently_authorized` must be freshly checked by the authority, not
    /// taken from a client. Even this does not invalidate a token already sent.
    pub fn may_issue(&self, generation: u64, actor: &str, currently_authorized: bool) -> bool {
        self.phase == Phase::Active
            && generation == self.generation
            && currently_authorized
            && self.members.contains(actor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn members(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|id| (*id).to_owned()).collect()
    }
    #[test]
    fn rotation_stops_issuance_until_the_old_instance_is_confirmed_stopped() {
        let mut gate = MediaGate::default();
        assert!(!gate.may_issue(0, "alice", true));
        let first = gate.begin_rotation().unwrap();
        assert!(gate.activate(first, members(&["alice", "bob"])).is_err());
        gate.confirm_stopped(first).unwrap();
        gate.activate(first, members(&["alice", "bob"])).unwrap();
        assert!(gate.may_issue(first, "alice", true));
        assert!(!gate.may_issue(first, "alice", false));
        let next = gate.begin_rotation().unwrap();
        assert!(!gate.may_issue(first, "alice", true));
        assert!(gate.confirm_stopped(first).is_err());
        assert!(gate.activate(next, members(&["alice"])).is_err());
        gate.confirm_stopped(next).unwrap();
        gate.activate(next, members(&["alice"])).unwrap();
        assert!(!gate.may_issue(next, "bob", true));
        assert!(gate.may_issue(next, "alice", true));
        assert!(gate.fail(first).is_err());
        assert!(gate.may_issue(next, "alice", true));
    }
    #[test]
    fn failed_or_malformed_rotation_stays_closed_and_old_ack_cannot_reopen_it() {
        let mut gate = MediaGate::default();
        let generation = gate.begin_rotation().unwrap();
        gate.fail(generation).unwrap();
        assert_eq!(gate.phase(), Phase::Blocked);
        assert!(gate.confirm_stopped(generation).is_err());
        assert!(!gate.may_issue(generation, "alice", true));
        let retry = gate.begin_rotation().unwrap();
        assert!(gate.confirm_stopped(generation).is_err());
        gate.confirm_stopped(retry).unwrap();
        assert!(gate.activate(retry, members(&["bad id"])).is_err());
        assert_eq!(gate.phase(), Phase::Blocked);
        assert!(!gate.may_issue(retry, "alice", true));
    }
    #[test]
    fn exhausted_generation_blocks_instead_of_wrapping() {
        let mut gate = MediaGate {
            generation: u64::MAX,
            phase: Phase::Active,
            members: members(&["alice"]),
        };
        assert!(gate.begin_rotation().is_err());
        assert_eq!(gate.phase(), Phase::Blocked);
        assert!(!gate.may_issue(u64::MAX, "alice", true));
    }
}
