use anyhow::Ok;
use serde_json::{Map, Value};

use chrono::prelude::*;
use chrono::{DateTime, Duration};

use aw_client_rust::Event as AwEvent;

use wayland_client::globals::GlobalListContents;
use wayland_client::protocol::wl_registry::WlRegistry;
use wayland_client::protocol::wl_seat::WlSeat;
use wayland_client::{Proxy, delegate_dispatch};

use wayland_client::{delegate_noop, globals::registry_queue_init, Connection, EventQueue};
use wayland_protocols_plasma::idle::client::org_kde_kwin_idle_timeout::Event as OrgKdeKwinIdleTimeoutEvent;
use wayland_protocols_plasma::idle::client::{
    org_kde_kwin_idle::OrgKdeKwinIdle, org_kde_kwin_idle_timeout::OrgKdeKwinIdleTimeout,
};

pub struct AfkState {
    is_afk: bool,
    state_start: DateTime<Utc>,
    timeout_ms: u32,
}

impl AfkState {
    pub fn get_current_afk_event(&self) -> AwEvent {
        let now = Utc::now();

        let timestamp = match self.is_afk {
            true => now,
            false => {
                let last_guaranteed_activity = now - Duration::milliseconds(self.timeout_ms as i64);
                match last_guaranteed_activity > self.state_start {
                    true => last_guaranteed_activity,
                    false => self.state_start,
                }
            }
        };

        let mut data = Map::new();
        let json_afk_state = match self.is_afk {
            true => Value::String("afk".to_string()),
            false => Value::String("not-afk".to_string()),
        };
        data.insert("status".to_string(), json_afk_state);

        AwEvent {
            id: None,
            timestamp,
            duration: Duration::milliseconds(0),
            data,
        }
    }
}

impl wayland_client::Dispatch<OrgKdeKwinIdleTimeout, ()> for AfkState {
    fn event(
        state: &mut Self,
        _proxy: &OrgKdeKwinIdleTimeout,
        event: <OrgKdeKwinIdleTimeout as wayland_client::Proxy>::Event,
        _data: &(),
        _conn: &Connection,
        _qhandle: &wayland_client::QueueHandle<Self>,
    ) {
        match event {
            OrgKdeKwinIdleTimeoutEvent::Idle => {
                println!("Became AFK");
                state.is_afk = true;
                state.state_start = Utc::now();
            }
            OrgKdeKwinIdleTimeoutEvent::Resumed => {
                println!("No longer AFK");
                state.is_afk = false;
                state.state_start = Utc::now();
            }
            _ => (),
        }
    }
}

delegate_dispatch!(AfkState: [WlRegistry: GlobalListContents] => crate::utils::RegistryState);

pub fn init_afk_state(
    conn: &Connection,
    timeout_ms: u32,
) -> anyhow::Result<(AfkState, EventQueue<AfkState>)> {
    let (globals, mut queue) = registry_queue_init(conn)?;
    let seat: WlSeat = globals.bind(&queue.handle(), 1..=WlSeat::interface().version, ())?;
    let idle: OrgKdeKwinIdle =
        globals.bind(&queue.handle(), 1..=OrgKdeKwinIdle::interface().version, ())?;

    let _kwin_idle_timeout = idle.get_idle_timeout(&seat, timeout_ms, &queue.handle(), ());

    delegate_noop!(AfkState: ignore WlSeat);
    delegate_noop!(AfkState: OrgKdeKwinIdle);

    let mut afk_state = AfkState {
        is_afk: false,
        state_start: Utc::now(),
        timeout_ms,
    };

    queue.roundtrip(&mut afk_state)?;

    Ok((afk_state, queue))
}
