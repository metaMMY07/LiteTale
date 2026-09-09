fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        // NDK r27 defaults to 4 KB; keep the reader usable on 16 KB Android devices.
        println!("cargo:rustc-link-arg-cdylib=-Wl,-z,max-page-size=16384");
        println!("cargo:rustc-link-arg-cdylib=-Wl,-z,common-page-size=16384");
    }
}
