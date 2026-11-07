//! Golconda's configuration as data, for the console (`golconda`, later `golcondad`).
//!
//! A system is a TOML document evaluated by Golconda's `mkSystem` through `iets`
//! ([`eval`]); the console reads its config, schema and module docs ([`system`]), looks
//! options up in the schema ([`schema`]) and finds them in the document ([`document`]).

pub mod advisories;
pub mod audit;
pub mod candidate;
pub mod check;
pub mod commit;
pub mod diff;
pub mod document;
pub mod eval;
pub mod git;
pub mod jobs;
pub mod machine;
pub mod packages;
pub mod release;
pub mod schema;
pub mod system;
pub mod upstream;
pub mod validate;
pub mod vars;
