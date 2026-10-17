use std::{env, path::PathBuf, process::Command};
fn main() {
    let output = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));
    assert!(Command::new("glib-compile-resources")
        .arg("resources/farpane.gresource.xml")
        .arg("--sourcedir=resources")
        .arg("--target")
        .arg(output.join("farpane.gresource"))
        .status()
        .expect("GLib resource compiler")
        .success());
    println!("cargo:rerun-if-changed=resources");
    let object = output.join("gpu_renderer.o");
    assert!(Command::new("cc")
        .args([
            "-std=c11",
            "-O2",
            "-fPIC",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-c",
            "src/gpu_renderer.c",
            "-o"
        ])
        .arg(&object)
        .status()
        .expect("C compiler")
        .success());
    assert!(Command::new("ar")
        .arg("crs")
        .arg(output.join("libfarpane_gpu_renderer.a"))
        .arg(object)
        .status()
        .expect("archiver")
        .success());
    println!("cargo:rustc-link-search=native={}", output.display());
    println!("cargo:rustc-link-lib=static=farpane_gpu_renderer");
    println!("cargo:rustc-link-lib=EGL");
    println!("cargo:rustc-link-lib=GLESv2");
    println!("cargo:rustc-link-lib=gbm");
    println!("cargo:rerun-if-changed=src/gpu_renderer.c");
    println!("cargo:rerun-if-changed=src/gpu_renderer.h");
    let flags = Command::new("pkg-config")
        .args(["--cflags", "libsecret-1"])
        .output()
        .expect("libsecret development headers");
    assert!(
        flags.status.success(),
        "libsecret headers are required in the isolated builder"
    );
    let object = output.join("secret_service.o");
    assert!(Command::new("cc")
        .args([
            "-std=c11",
            "-O2",
            "-fPIC",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-c",
            "src/secret_service.c",
            "-o"
        ])
        .arg(&object)
        .args(String::from_utf8(flags.stdout).unwrap().split_whitespace())
        .status()
        .expect("credential bridge compiler")
        .success());
    assert!(Command::new("ar")
        .arg("crs")
        .arg(output.join("libfarpane_secret_service.a"))
        .arg(object)
        .status()
        .expect("archiver")
        .success());
    println!("cargo:rustc-link-lib=static=farpane_secret_service");
    println!("cargo:rustc-link-lib=dl");
    println!("cargo:rerun-if-changed=src/secret_service.c");
    println!("cargo:rerun-if-changed=src/secret_service.h");
}
