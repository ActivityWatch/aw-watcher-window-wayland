extern crate wayland_scanner;

use std::path::Path;

use wayland_scanner::{Side, generate_code};

fn main() {
    // Location of the xml file, relative to the `Cargo.toml`

    // Target directory for the generate files
    let out_dir = Path::new("./src/protocols");

    // (xmlsrc, outsrc)
    let protocols = vec!(
        ("protocols/wlr-foreign-toplevel-management-unstable-v1.xml",
         "wlr-foreign-toplevel-management.rs"),
        ("protocols/idle.xml",
         "idle.rs"),
    );

    for protocol in protocols {
        let (xmlsrc, outsrc) = protocol;
        generate_code(
            xmlsrc, out_dir.join(outsrc),
            Side::Client, // Replace by `Side::Server` for server-side code
        );
    }
}
