//! Minimal durable job lifecycle. Approval does not start an agent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JobState {
    Proposed,
    ApprovedWaiting,
    HostClaimed,
    HostReported,
    Cancelled,
    WaitingInput,
    Completed,
    Rejected,
}
impl JobState {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "proposed" => Some(Self::Proposed),
            "approved_waiting" => Some(Self::ApprovedWaiting),
            "host_claimed" => Some(Self::HostClaimed),
            "host_reported" => Some(Self::HostReported),
            "waiting_input" => Some(Self::WaitingInput),
            "completed" => Some(Self::Completed),
            "rejected" => Some(Self::Rejected),
            "cancelled" => Some(Self::Cancelled),
            _ => None,
        }
    }
    pub fn allows(self, next: Self) -> bool {
        matches!(
            (self, next),
            (Self::Proposed, Self::ApprovedWaiting)
                | (Self::Proposed, Self::Cancelled)
                | (Self::ApprovedWaiting, Self::Cancelled)
                | (Self::HostClaimed, Self::Cancelled)
                | (Self::WaitingInput, Self::Cancelled)
        )
    }
}
#[cfg(test)]
mod tests {
    use super::JobState as S;
    #[test]
    fn approval_is_required_and_terminal_cancellation() {
        assert!(S::Proposed.allows(S::ApprovedWaiting));
        assert!(S::ApprovedWaiting.allows(S::Cancelled));
        assert!(S::HostClaimed.allows(S::Cancelled));
        assert!(!S::HostReported.allows(S::Cancelled));
        assert!(!S::Cancelled.allows(S::ApprovedWaiting));
        assert!(!S::ApprovedWaiting.allows(S::ApprovedWaiting));
    }
}
