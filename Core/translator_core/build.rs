// translator_core/build.rs
//
// Cargo build script for translator_core.
//
// Compiles the C++ wrapper (ctranslate2_wrapper.cpp) and links against
// CTranslate2, SentencePiece, and macOS system frameworks.

fn main() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let manifest_path = std::path::Path::new(&manifest_dir);

    // Core/ directory is the parent of translator_core/
    let core_dir = manifest_path.parent().expect("Could not resolve Core/ directory");

    // Project root is the parent of Core/
    let root_dir = core_dir.parent().expect("Could not resolve project root directory");

    // ThirdParty build artifacts
    let thirdparty_build = root_dir.join("ThirdParty").join("build");

    // Native C++ sources
    let native_dir = core_dir.join("native");

    // ── Compile the C++ wrapper ──

    cc::Build::new()
        .cpp(true)
        .file(native_dir.join("ctranslate2_wrapper.cpp"))
        .include(&native_dir)
        .include(thirdparty_build.join("include"))
        .flag("-std=c++17")
        .flag("-O2")
        .warnings(false) // suppress warnings from third-party headers
        .compile("ctranslate2_wrapper");

    // ── Link third-party static libraries ──

    let lib_dir = thirdparty_build.join("lib");
    println!("cargo:rustc-link-search=native={}", lib_dir.display());

    // CTranslate2 core library
    println!("cargo:rustc-link-lib=static=ctranslate2");

    // SentencePiece libraries
    println!("cargo:rustc-link-lib=static=sentencepiece");
    println!("cargo:rustc-link-lib=static=sentencepiece_train");

    // ── Link macOS system frameworks ──

    // Accelerate framework for BLAS/LAPACK used by CTranslate2
    println!("cargo:rustc-link-lib=framework=Accelerate");

    // C++ standard library
    println!("cargo:rustc-link-lib=c++");

    // ── Rebuild triggers ──

    println!(
        "cargo:rerun-if-changed={}",
        native_dir.join("ctranslate2_wrapper.cpp").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        native_dir.join("ctranslate2_wrapper.h").display()
    );
}
