//! golcondad: Golconda's console daemon. This first part shows the systems' configuration and
//! their changes against git as web pages and JSON; it changes nothing (console/README.md).

pub mod app;
pub mod pages;

// FONTS: (file name, WOFF2 bytes), from build.rs
include!(concat!(env!("OUT_DIR"), "/fonts.rs"));
