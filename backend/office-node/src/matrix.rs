//! Matrix authority bridge: short committed intents, then external I/O.
use super::{actor, db_error, err, now, permitted, realtime_epoch, ApiError, Db};
use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    Extension, Json,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use hmac::{Hmac, Mac};
use reqwest::Method;
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::Sha256;
use std::{collections::BTreeSet, sync::Arc, time::Duration};

mod authorize;
mod client;
mod handlers;
mod identity;
mod mappings;
mod reconcile;

pub use authorize::authorize;
pub use client::{Bridge, Config};
pub use handlers::{config, dms, legacy, rooms, session, users};
use identity::*;
pub use mappings::initialize;
use mappings::*;
pub use reconcile::spawn_reconcile;

fn unavailable() -> ApiError {
    err(
        StatusCode::SERVICE_UNAVAILABLE,
        "Matrix unavailable; retry shortly",
    )
}
fn configured(config: &Config) -> Result<Arc<Bridge>, ApiError> {
    config.clone().ok_or_else(unavailable)
}

#[cfg(test)]
mod reconcile_tests;
