use wayland_client::{protocol::wl_registry, Dispatch, globals::GlobalListContents, QueueHandle, Connection};

pub struct RegistryState;

impl<State> Dispatch<wl_registry::WlRegistry, GlobalListContents, State> for RegistryState
where
State: Dispatch<wl_registry::WlRegistry, GlobalListContents>,
{
    fn event(
        _: &mut State,
        _: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<State>,
    ) {
        // TODO: handle dynamic global change
        // although I think we can simply do nothing here..
        println!("wayland globals has changed: {:?}", event);
    }
}

