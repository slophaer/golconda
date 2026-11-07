//! golcondad: Golconda's console daemon. This first part shows the systems' configuration and
//! their changes against git as web pages and JSON; it changes nothing (console/README.md).

pub mod app;
pub mod auth;
pub mod events;
pub mod jobs;
pub mod pages;
pub mod write;

use std::sync::{Mutex, MutexGuard, PoisonError};

/// A lock that a panicked holder left behind is still good: the sessions' updates are one call
/// each, a panic inside a journal transaction rolls it back, and the audit lock guards no state.
pub fn locked<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

// FONTS: (file name, WOFF2 bytes), from build.rs
include!(concat!(env!("OUT_DIR"), "/fonts.rs"));
