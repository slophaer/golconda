//! Golconda's configuration as data, for the console (`golconda`, later `golcondad`).
//!
//! A system is a TOML document evaluated by Golconda's `mkSystem` through `iets`
//! ([`eval`]); the console reads its config, schema and module docs ([`system`]), looks
//! options up in the schema ([`schema`]) and finds them in the document ([`document`]).

pub mod document;
pub mod eval;
pub mod schema;
pub mod system;
