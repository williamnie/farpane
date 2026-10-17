use std::{env, path::PathBuf, process::Command};

pub fn build() {
    let prefix = PathBuf::from(
        env::var_os("VCPKG_ROOT").expect("Linux GPU build requires the pinned vcpkg prefix"),
    )
    .join("installed/x64-linux");
    let output = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let object = output.join("farpane_gpu.o");
    let compiler = env::var("CXX").unwrap_or_else(|_| "g++".into());
    let result = Command::new(compiler)
        .args([
            "-std=c++17",
            "-O2",
            "-fPIC",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-I/usr/include/libdrm",
            "-Isrc/common/linux_gpu",
            "-c",
            "src/common/linux_gpu/gpu_media.cpp",
            "-o",
        ])
        .arg(&object)
        .arg(format!("-I{}", prefix.join("include").display()))
        .status()
        .expect("C++ compiler");
    assert!(
        result.success(),
        "Linux GPU native adapter compilation failed"
    );
    assert!(Command::new("ar")
        .arg("crs")
        .arg(output.join("libfarpane_gpu.a"))
        .arg(object)
        .status()
        .expect("archiver")
        .success());
    if env::var_os("CARGO_FEATURE_NATIVE_VIEWER").is_some() {
        let compat_object = output.join("farpane_vaapi_compat.o");
        assert!(Command::new(env::var("CC").unwrap_or_else(|_| "cc".into()))
            .args([
                "-std=c11",
                "-O2",
                "-fPIC",
                "-Wall",
                "-Wextra",
                "-Werror",
                "-c",
                "src/common/linux_gpu/vaapi_compat.c",
                "-o"
            ])
            .arg(&compat_object)
            .status()
            .expect("VAAPI compatibility compiler")
            .success());
        assert!(Command::new("ar")
            .arg("crs")
            .arg(output.join("libfarpane_gpu.a"))
            .arg(compat_object)
            .status()
            .expect("VAAPI compatibility archiver")
            .success());
        println!("cargo:rerun-if-changed=src/common/linux_gpu/vaapi_compat.c");
        let viewer_object = output.join("farpane_viewer.o");
        assert!(
            Command::new(env::var("CXX").unwrap_or_else(|_| "g++".into()))
                .args([
                    "-std=c++17",
                    "-O2",
                    "-fPIC",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-I/usr/include/libdrm",
                    "-Isrc/common/linux_gpu",
                    "-c",
                    "src/common/linux_gpu/viewer_decode.cpp",
                    "-o"
                ])
                .arg(&viewer_object)
                .arg(format!("-I{}", prefix.join("include").display()))
                .status()
                .expect("Viewer C++ compiler")
                .success(),
            "Viewer native decoder compilation failed"
        );
        assert!(Command::new("ar")
            .arg("crs")
            .arg(output.join("libfarpane_gpu.a"))
            .arg(viewer_object)
            .status()
            .expect("Viewer archiver")
            .success());
        println!("cargo:rerun-if-changed=src/common/linux_gpu/viewer_decode.cpp");
        println!("cargo:rerun-if-changed=src/common/linux_gpu/viewer_decode.h");
    }
    println!("cargo:rerun-if-changed=src/common/linux_gpu/gpu_media.cpp");
    println!("cargo:rerun-if-changed=src/common/linux_gpu/gpu_media.h");
    println!("cargo:rerun-if-changed=linux_gpu_build.rs");
    println!("cargo:rustc-link-search=native={}", output.display());
    println!(
        "cargo:rustc-link-search=native={}",
        prefix.join("lib").display()
    );
    for name in ["farpane_gpu", "avfilter", "avcodec", "avutil"] {
        println!("cargo:rustc-link-lib=static={name}");
    }
    for name in ["va", "va-drm", "drm", "stdc++", "m"] {
        println!("cargo:rustc-link-lib={name}");
    }
}
