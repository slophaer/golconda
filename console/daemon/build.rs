//! The fonts golcondad serves, compiled in: every *.woff2 in `GOLCONDA_FONTS` (the
//! ibm-plex-web package's share/fonts/ibm-plex; console/package.nix sets it). Without it the
//! list is empty and the pages use the system's fonts.

use std::fmt::Write;

fn main() {
    println!("cargo:rerun-if-env-changed=GOLCONDA_FONTS");
    let mut out = String::from("pub const FONTS: &[(&str, &[u8])] = &[\n");
    if let Some(dir) = std::env::var_os("GOLCONDA_FONTS") {
        let mut files: Vec<_> = std::fs::read_dir(&dir)
            .expect("GOLCONDA_FONTS is a directory")
            .map(|e| e.unwrap().path())
            .filter(|p| p.extension().is_some_and(|e| e == "woff2"))
            .collect();
        files.sort();
        for f in files {
            println!("cargo:rerun-if-changed={}", f.display());
            let name = f.file_name().unwrap().to_string_lossy().into_owned();
            writeln!(
                out,
                "    ({name:?}, include_bytes!({:?})),",
                f.display().to_string()
            )
            .unwrap();
        }
    }
    out.push_str("];\n");
    let dest = std::path::Path::new(&std::env::var("OUT_DIR").unwrap()).join("fonts.rs");
    std::fs::write(dest, out).unwrap();
}
