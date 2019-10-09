

// Re-export only the actual code, and then only use this re-export
// The `generated` module below is just some boilerplate to properly isolate stuff
// and avoid exposing internal details.
//
// You can use all the types from my_protocol as if they went from `wayland_client::protocol`.

// The generated code tends to trigger a lot of warnings
// so we isolate it into a very permissive module
#![allow(dead_code,non_camel_case_types,unused_unsafe,unused_variables)]
#![allow(non_upper_case_globals,non_snake_case,unused_imports)]

pub mod toplevel_management {
    pub(crate) use smallvec;
    pub(crate) use wayland_sys as sys;
    pub(crate) use wayland_client::{AnonymousObject, Interface, Main, Proxy, ProxyMap};
    pub(crate) use wayland_client::protocol::{wl_surface, wl_region, wl_seat, wl_output};
    pub(crate) use wayland_commons::{MessageGroup};
    pub(crate) use wayland_commons::map::{Object, ObjectMetadata};
    pub(crate) use wayland_commons::wire::{Argument, ArgumentType, Message, MessageDesc};

    include!("protocols/wlr-foreign-toplevel-management.rs");
}

pub mod idle {
    pub(crate) use smallvec;
    pub(crate) use wayland_sys as sys;
    pub(crate) use wayland_client::{AnonymousObject, Interface, Main, Proxy, ProxyMap};
    pub(crate) use wayland_client::protocol::{wl_surface, wl_region, wl_seat, wl_output};
    pub(crate) use wayland_commons::{MessageGroup};
    pub(crate) use wayland_commons::map::{Object, ObjectMetadata};
    pub(crate) use wayland_commons::wire::{Argument, ArgumentType, Message, MessageDesc};

    include!("protocols/idle.rs");
}
