use std::collections::HashMap;
use wayland_client::Main;
use std::sync::Mutex;

use super::wl_client as wl_client;

use wl_client::toplevel_management::zwlr_foreign_toplevel_manager_v1::ZwlrForeignToplevelManagerV1 as ToplevelManager;
use wl_client::toplevel_management::zwlr_foreign_toplevel_handle_v1::ZwlrForeignToplevelHandleV1 as ToplevelHandle;

#[derive(Clone)]
pub struct Window {
    pub title: String,
    pub appid: String,
}

pub struct WindowState {
    pub current_window: Option<u32>,
    pub all_windows: HashMap::<u32, Window>,
}

lazy_static! {
    static ref WINDOW_STATE_LOCKED: Mutex<WindowState> = Mutex::new(WindowState {
        current_window: None,
        all_windows: HashMap::new(),
    });
}

pub fn get_focused_window() -> Option<Window> {
    let window_state = WINDOW_STATE_LOCKED.lock()
        .expect("Unable to take lock");
    let current_window_id = match window_state.current_window {
        Some(id) => id,
        None => {
            println!("No focused window");
            return None;
        }
    };
    match window_state.all_windows.get(&current_window_id) {
        Some(window_ref) => Some(window_ref.clone()),
        None => None
    }
}

/// New focused window id after toplevel `id` reports `state`.
///
/// `state` is a wl_array of u32 values; `activated` (2) means the window has focus.
/// A window that loses activation must stop being reported as focused, even when no
/// other toplevel becomes activated (empty workspace, last window minimized).
fn update_focus(current: Option<u32>, id: u32, state: &[u8]) -> Option<u32> {
    if state.contains(&2) { // 2 == activated; values are 0-3, so a byte check is exact
        Some(id)
    } else if current == Some(id) {
        None
    } else {
        current
    }
}

fn assign_toplevel_handle(toplevel_handle: &wayland_client::Main<ToplevelHandle>) -> () {
    use wl_client::toplevel_management::zwlr_foreign_toplevel_handle_v1::Event as HandleEvent;

    toplevel_handle
        .assign_mono(|toplevel_handle : Main<ToplevelHandle>, event| {
            let mut window_state = WINDOW_STATE_LOCKED.lock()
                .expect("Unable to take lock!");
            let id = toplevel_handle.as_ref().id();
            match event {
                HandleEvent::AppId{ app_id } => {
                    //println!("appid: {}", app_id);
                    let window = window_state.all_windows.get_mut(&id)
                        .expect("Tried to change appid on a non-existing window");
                    window.appid = app_id.clone();
                },
                HandleEvent::Title{ title } => {
                    //println!("title: {}", title);
                    let window = window_state.all_windows.get_mut(&id)
                        .expect("Tried to change title on a non-existing window");
                    window.title = title.clone();
                },
                HandleEvent::State{ state } => {
                    window_state.current_window =
                        update_focus(window_state.current_window, id, &state);
                }
                HandleEvent::Done => (),//println!("done"),
                HandleEvent::Closed => {
                    let closed_window = window_state.all_windows.remove(&id)
                        .expect("Tried to remove window which does not exist");
                    println!("closed {}", closed_window.appid)
                },
                _ => println!("Unknown toplevel handle event")
            };
        });
}

pub fn assign_toplevel_manager(globals: &wayland_client::GlobalManager) -> () {
    use wl_client::toplevel_management::zwlr_foreign_toplevel_manager_v1::Event as ToplevelEvent;

    globals
        .instantiate_exact::<ToplevelManager>(1)
        .expect("Wayland session does not expose a ToplevelManager object, \
                 this window manager is most likely not supported")
        .assign_mono(move |_toplevel_manager : Main<ToplevelManager>, event| {
            match event {
                ToplevelEvent::Toplevel{ toplevel: handle } => {
                    //println!("new handle");
                    let mut windows_state = WINDOW_STATE_LOCKED.lock()
                        .expect("Unable to take lock!");
                    let id = handle.as_ref().id();
                    let window = Window {
                        appid: "unknown".into(),
                        title: "unknown".into(),
                    };
                    windows_state.all_windows.insert(id, window);
                    assign_toplevel_handle(&handle);
                }
                // TODO: What do do at finish?
                ToplevelEvent::Finished => println!("Finished?"),
                _ => panic!("Got an unexpected event!")
            }
        });
}

#[cfg(test)]
mod tests {
    use super::update_focus;

    fn activated() -> Vec<u8> { 2u32.to_ne_bytes().to_vec() }

    #[test]
    fn activation_sets_focus() {
        assert_eq!(update_focus(None, 1, &activated()), Some(1));
        assert_eq!(update_focus(Some(2), 1, &activated()), Some(1));
    }

    #[test]
    fn losing_activation_clears_focus() {
        assert_eq!(update_focus(Some(1), 1, &[]), None);
        // maximized (0) without activated
        assert_eq!(update_focus(Some(1), 1, &0u32.to_ne_bytes()), None);
    }

    #[test]
    fn other_window_state_change_keeps_focus() {
        assert_eq!(update_focus(Some(1), 2, &[]), Some(1));
    }
}
