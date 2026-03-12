use std::{fs, path::PathBuf};

fn main() {
    println!("cargo::rustc-link-arg-tests=-Tlink.ld");
    println!("cargo::rustc-link-arg-tests=-no-pie");
    println!("cargo::rustc-link-arg-tests=-znostart-stop-gc");

    fs::copy("link.ld", out_dir().join("link.ld")).unwrap();

    println!("cargo:rustc-link-search={}", out_dir().display());
}

fn out_dir() -> PathBuf {
    PathBuf::from(std::env::var("OUT_DIR").unwrap())
}
