//! Shared task lifecycle rules. Assigning an agent never starts its runtime.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Todo,
    InProgress,
    Done,
}
impl State {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "todo" => Some(Self::Todo),
            "in_progress" => Some(Self::InProgress),
            "done" => Some(Self::Done),
            _ => None,
        }
    }
    pub fn can_transition(self, next: Self) -> bool {
        matches!(
            (self, next),
            (Self::Todo, Self::InProgress)
                | (Self::InProgress, Self::Todo)
                | (Self::InProgress, Self::Done)
                | (Self::Done, Self::InProgress)
        )
    }
}
#[cfg(test)]
mod tests {
    use super::State;
    #[test]
    fn task_transitions_require_a_real_step() {
        assert!(State::Todo.can_transition(State::InProgress));
        assert!(State::InProgress.can_transition(State::Done));
        assert!(State::Done.can_transition(State::InProgress));
        assert!(!State::Todo.can_transition(State::Done));
        assert!(!State::Done.can_transition(State::Done));
        assert!(State::parse("bogus").is_none());
    }
}
