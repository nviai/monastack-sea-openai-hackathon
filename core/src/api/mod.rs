//! Flutter-facing API. `flutter_rust_bridge_codegen generate` (run from `app/`)
//! reads this module and writes `src/frb_generated.rs` and the Dart bindings.
//! Functions here are thin adapters over the domain modules; they own no policy.
pub mod office;
pub mod outbox;

/// Incremented when a bridge signature or its meaning changes incompatibly.
pub const BRIDGE_VERSION: u32 = 2;

#[flutter_rust_bridge::frb(sync)]
pub fn bridge_version() -> u32 {
    BRIDGE_VERSION
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Category of a bridge failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoreErrorKind {
    /// The seed document is malformed or targets another workspace.
    InvalidSeed,
    /// The map document is malformed or fails geometry validation.
    InvalidMap,
    /// The destination is a wall, outside the map, or in a room the actor may not enter.
    Inaccessible,
    /// Local outbox failure; `detail` is a stable code such as `queue_full` or `not_pending`.
    Outbox,
}

/// Typed failure returned to Dart as an exception.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreError {
    pub kind: CoreErrorKind,
    pub detail: String,
}

impl CoreError {
    pub(crate) fn new(kind: CoreErrorKind, detail: impl Into<String>) -> Self {
        CoreError {
            kind,
            detail: detail.into(),
        }
    }
}
