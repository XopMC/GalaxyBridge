use std::{env, fs, path::PathBuf};

fn main() {
    println!("cargo:rerun-if-env-changed=GB_PRODUCER_SHA256");
    let hex = env::var("GB_PRODUCER_SHA256")
        .expect("Use scripts/build-quic-backend.sh with GB_PRODUCER_JAR set to the freshly source-built enhanced scrcpy server");
    assert!(hex.len() == 64 && hex.bytes().all(|b| b.is_ascii_hexdigit()), "GB_PRODUCER_SHA256 must be a 32-byte hexadecimal digest");
    let bytes: Vec<String> = (0..32).map(|i| format!("0x{}", &hex[i * 2..i * 2 + 2])).collect();
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("producer_pin.rs");
    fs::write(out, format!("pub const PRODUCER_SHA: [u8; 32] = [{}];\n", bytes.join(", "))).unwrap();
}
