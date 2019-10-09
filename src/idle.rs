use super::wl_client as wl_client;
use std::sync::Mutex;
use serde_json::{Map, Value};

use chrono::prelude::*;
use chrono::{DateTime, Duration};

use aw_client_rust::Event as AwEvent;

use wayland_client::protocol::wl_seat::WlSeat;
use wl_client::idle::org_kde_kwin_idle::OrgKdeKwinIdle as Idle;
use wl_client::idle::org_kde_kwin_idle_timeout::Event as TimeoutEvent;

struct AfkState {
    is_afk: bool,
    state_start: DateTime<Utc>,
    timeout_ms: u32,
    heartbeat_interval_ms: u32,
}

lazy_static! {
    static ref AFK_STATE_LOCKED: Mutex<AfkState> = Mutex::new(AfkState {
        is_afk: false,
        state_start: Utc::now(),
        timeout_ms: 0, /* gets set in start on assign_idle_timeout */
        heartbeat_interval_ms: 0, /* gets set in start on assign_idle_timeout */
    });
}

fn init_afk_state(timeout_ms: u32, heartbeat_interval_ms: u32) {
    let mut afk_state = AFK_STATE_LOCKED.lock().expect("Unable to lock");
    afk_state.state_start = Utc::now();
    afk_state.timeout_ms = timeout_ms;
    afk_state.heartbeat_interval_ms = heartbeat_interval_ms;
}

fn set_afk_state(afk: bool) {
    let mut afk_state = AFK_STATE_LOCKED.lock().expect("Unable to lock");
    afk_state.is_afk = afk;
    afk_state.state_start = Utc::now();
}

pub fn get_current_afk_event() -> AwEvent {
    let afk_state = AFK_STATE_LOCKED.lock().expect("Unable to take lock");

    let now = Utc::now();

    let timestamp = match afk_state.is_afk {
        true => now,
        false => {
            let last_guaranteed_activity = now - Duration::milliseconds(afk_state.timeout_ms as i64);
            match last_guaranteed_activity > afk_state.state_start {
                true => last_guaranteed_activity,
                false => afk_state.state_start,
            }
        }
    };

    let mut data = Map::new();
    data.insert("afk".to_string(), Value::Bool(afk_state.is_afk));

    AwEvent {
        id: None,
        timestamp: timestamp.to_rfc3339(),
        duration: 0.0,
        data,
    }
}

pub fn assign_idle_timeout(globals: &wayland_client::GlobalManager, timeout_ms: u32, heartbeat_interval_ms: u32) -> () {
    init_afk_state(timeout_ms, heartbeat_interval_ms);
    let seat = globals.instantiate_exact::<WlSeat>(1).unwrap();
    let idle = globals.instantiate_exact::<Idle>(1).unwrap();
    let idle_timeout = idle.get_idle_timeout(&seat, timeout_ms);
    idle_timeout.assign_mono(|_idle_timeout, event| {
        match event {
            TimeoutEvent::Idle => {
                println!("idle");
                set_afk_state(true);
            },
            TimeoutEvent::Resumed => {
                println!("resumed");
                set_afk_state(false);
            },
            _ => panic!("Got unexpected timeout event"),
        }
    });
}
