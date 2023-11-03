use std::collections::HashMap;
use wayland_client::{Connection, globals::{registry_queue_init, GlobalListContents}, Proxy, protocol::wl_registry::WlRegistry, event_created_child, EventQueue};
use wayland_backend::rs::client::ObjectId;

use wayland_protocols_wlr::foreign_toplevel::v1::client::{zwlr_foreign_toplevel_manager_v1::{
    ZwlrForeignToplevelManagerV1, EVT_TOPLEVEL_OPCODE, Event as ToplevelManagerEvent
}, zwlr_foreign_toplevel_handle_v1::{ZwlrForeignToplevelHandleV1, Event as TopLevelHandleEvent, State as TopLevelHandleState}};

#[derive(Clone)]
pub struct Window {
    pub title: String,
    pub appid: String,
}

pub struct WindowState {
    pub current_window: Option<ObjectId>,
    pub all_windows: HashMap::<ObjectId, Window>,
}

impl WindowState {
    pub fn get_focused_window(&self) -> Option<Window> {
        let current_window_id = match &self.current_window {
            Some(id) => id,
            None => {
                println!("No focused window");
                return None;
            }
        };
        match self.all_windows.get(&current_window_id) {
            Some(window_ref) => Some(window_ref.clone()),
            None => None
        }
    }
}

impl wayland_client::Dispatch<WlRegistry, GlobalListContents> for WindowState {
    fn event(
            state: &mut Self,
            proxy: &WlRegistry,
            event: <WlRegistry as Proxy>::Event,
            data: &GlobalListContents,
            conn: &Connection,
            qhandle: &wayland_client::QueueHandle<Self>,
        ) {
        todo!("remove this")
    }
}

impl wayland_client::Dispatch<ZwlrForeignToplevelHandleV1, ()> for WindowState {
    fn event(
            state: &mut Self,
            proxy: &ZwlrForeignToplevelHandleV1,
            event: <ZwlrForeignToplevelHandleV1 as Proxy>::Event,
            data: &(),
            conn: &Connection,
            qhandle: &wayland_client::QueueHandle<Self>,
        ) {
            let id = proxy.id();
            let window = state.all_windows.get_mut(&id)
                    .expect("Tried to change appid on a non-existing window");
        match event {
            TopLevelHandleEvent::AppId { app_id } => window.appid = app_id,
            TopLevelHandleEvent::Title { title } => window.title = title,
            TopLevelHandleEvent::State { state: event_state } => {
                if event_state.contains(&(TopLevelHandleState::Activated as u8)) {
                    state.current_window = Some(id);
                }
            },
            TopLevelHandleEvent::Done => (), // TODO: do something here?
            TopLevelHandleEvent::Closed => {
                let closed_window = state.all_windows.remove(&id).unwrap();
                println!("closed {}", closed_window.appid);
            },
            _ => println!("Unknown toplevel handle event")
        }
    }
}

impl wayland_client::Dispatch<ZwlrForeignToplevelManagerV1, ()> for WindowState {
    fn event(
            state: &mut Self,
            proxy: &ZwlrForeignToplevelManagerV1,
            event: <ZwlrForeignToplevelManagerV1 as Proxy>::Event,
            data: &(),
            conn: &Connection,
            qhandle: &wayland_client::QueueHandle<Self>,
        ) {
        match event {
            ToplevelManagerEvent::Toplevel { toplevel: handle } => {
                let id = handle.id();
                let window = Window {
                    appid: "unknown".into(),
                    title: "unknown".into(),
                };
                state.all_windows.insert(id, window);
            },
            // TODO: What do do at finish?
            ToplevelManagerEvent::Finished =>println!("Finished?"),
            _ => println!("Unknown toplevel handle event")
        }
    }

    event_created_child!(WindowState, ZwlrForeignToplevelManagerV1, [
        EVT_TOPLEVEL_OPCODE => (ZwlrForeignToplevelHandleV1, ()),
    ]);
}

pub fn init_toplevel_manager(conn: &Connection) -> anyhow::Result<(WindowState, EventQueue<WindowState>)> {
    let (globals, mut queue) = registry_queue_init(&conn)?;
    let toplevel_manager: ZwlrForeignToplevelManagerV1 = globals
        .bind(&queue.handle(), 1..=ZwlrForeignToplevelManagerV1::interface().version, ())?;

        let mut window_state = WindowState {
            current_window: None,
            all_windows: HashMap::new(),
        };

    queue.roundtrip(&mut window_state)?;
    
    Ok((window_state, queue))
}
