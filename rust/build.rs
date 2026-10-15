use std::io::Result;

fn main() -> Result<()> {
    let mut prost_build = prost_build::Config::new();
    // Enable a protoc experimental feature.
    prost_build.protoc_arg("--experimental_allow_proto3_optional");
    prost_build.compile_protos(&["src/mac_hw_info.proto"], &["src/"])?;

    build_evs()?;
    // listing paths below stops cargo rerunning this for every file change, so list them all
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src/mac_hw_info.proto");
    Ok(())
}

/// The 3GPP EVS reference decoder (TS 26.443), for FaceTime peers that send EVS audio
fn build_evs() -> Result<()> {
    let root = std::path::Path::new("third_party/evs");
    let mut build = cc::Build::new();
    build
        .include(root.join("lib_com"))
        .include(root.join("lib_dec"))
        // headers only: the shared headers pull in encoder structs
        .include(root.join("lib_enc"))
        .file("src/evs_shim.c")
        // its asserts and exit()s would take the whole app down; evs_shim.c catches the exits
        .define("NDEBUG", None)
        .define("exit", "evs_shim_exit")
        // tables that fdk-aac also defines globally
        .define("exp2_tab_long", "evs_exp2_tab_long")
        .define("exp2w_tab_long", "evs_exp2w_tab_long")
        .define("exp2x_tab_long", "evs_exp2x_tab_long")
        .define("t_qua_gain7b", "evs_t_qua_gain7b")
        .opt_level(2)
        .warnings(false)
        .flag_if_supported("-w");
    for dir in ["lib_com", "lib_dec"] {
        for entry in std::fs::read_dir(root.join(dir))? {
            let path = entry?.path();
            // decoder.c is the command line tool's main()
            if path.extension().is_some_and(|e| e == "c") && path.file_name().is_some_and(|n| n != "decoder.c") {
                build.file(&path);
            }
        }
    }
    build.compile("evs");
    println!("cargo:rerun-if-changed=src/evs_shim.c");
    println!("cargo:rerun-if-changed=third_party/evs");
    Ok(())
}
