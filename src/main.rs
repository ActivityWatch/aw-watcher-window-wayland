// The generated code will import stuff from wayland_sys
extern crate wayland_sys;
extern crate wayland_client;
extern crate aw_client_rust;
extern crate chrono;

#[macro_use] extern crate lazy_static;

#[macro_use] extern crate smallvec;

use serde_json::{Map, Value};
use chrono::prelude::*;

mod wl_client;
mod current_window;
mod idle;
mod singleinstance;


use mio::{Poll, Token, PollOpt, Ready, Events};
use mio::unix::EventedFd;

use timerfd::{TimerFd, TimerState, SetTimeFlags};
use std::os::unix::io::AsRawFd;
use std::time::Duration;

fn get_wl_display() -> wayland_client::Display {
    match wayland_client::Display::connect_to_env() {
        Ok(display) => return display,
        Err(e) => println!("Couldn't connect to wayland display by env: {}", e)
    };
    match wayland_client::Display::connect_to_name("wayland-0") {
        Ok(display) => return display,
        Err(e) => println!("Couldn't connect to wayland display by name 'wayland-0': {}", e)
    }
    panic!("Failed to connect to wayland display");
}

fn window_to_event(window: &current_window::Window) -> aw_client_rust::Event {
    let mut data = Map::new();
    data.insert("app".to_string(), Value::String(window.appid.clone()));
    data.insert("title".to_string(), Value::String(window.title.clone()));
    aw_client_rust::Event {
        id: None,
        timestamp: Utc::now().to_rfc3339(),
        duration: 0.0,
        data: data,
    }
}

// Setup some tokens to allow us to identify which event is for which socket.
const STATE_CHANGE: Token = Token(0);
const TIMER: Token = Token(1);

static HEARTBEAT_INTERVAL_MS : u32 = 5000;
static HEARTBEAT_INTERVAL_MARGIN_S : f64 = (HEARTBEAT_INTERVAL_MS + 1000) as f64 / 1000.0;

fn main() {
    println!("### Setting up display");
    let display = get_wl_display();
    let mut event_queue = display.create_event_queue();
    let attached_display = (*display).clone().attach(event_queue.get_token());

    println!("### Fetching wayland globals");
    let globals = wayland_client::GlobalManager::new(&attached_display);
    event_queue.sync_roundtrip(|_, _| unreachable!())
        .expect("Failed to sync_roundtrip when fetching globals");

    println!("### Setting up toplevel manager");
    current_window::assign_toplevel_manager(&globals);

    println!("### Setting up idle timeout");
    idle::assign_idle_timeout(&globals, 180000, HEARTBEAT_INTERVAL_MS);

    println!("### Syncing roundtrip");
    event_queue
        .sync_roundtrip(|_, _| { /* we ignore unfiltered messages */ })
        .expect("event_queue sync_roundtrip failure");

    println!("### Preparing poll fds");
    let poll = Poll::new()
        .expect("Failed to create poll fds");
    let fd = event_queue.get_connection_fd();

    let mut timer = TimerFd::new()
        .expect("Failed to create timer fd");
    let timer_state = TimerState::Periodic {
        current: Duration::from_secs(1),
        interval: Duration::from_millis(HEARTBEAT_INTERVAL_MS as u64)
    };
    let timer_flags = SetTimeFlags::Default;
    timer.set_state(timer_state, timer_flags);

    poll.register(&EventedFd(&fd), STATE_CHANGE, Ready::readable(), PollOpt::empty())
        .expect("Failed to register state_change fd");
    poll.register(&EventedFd(&timer.as_raw_fd()), TIMER, Ready::readable(), PollOpt::empty())
        .expect("Failed to register timer fd");

    println!("### Taking client locks");
    let _window_lock = singleinstance::get_client_lock("aw-watcher-window-at-localhost-on-5600").unwrap();
    let _afk_lock = singleinstance::get_client_lock("aw-watcher-afk-at-localhost-on-5600").unwrap();

    println!("### Creating aw-client");
    let client = aw_client_rust::AwClient::new("localhost", "5600", "aw-watcher-wayland");
    let window_bucket = "aw-watcher-wayland-window";
    let afk_bucket = "aw-watcher-wayland-afk";
    client.create_bucket(window_bucket, "currentwindow")
        .expect("Failed to create window bucket");
    client.create_bucket(afk_bucket, "afkstatus")
        .expect("Failed to create afk bucket");

    println!("### Watcher is now running");
    let mut events = Events::with_capacity(1);
    let mut prev_window : Option<current_window::Window> = None;
    loop {
        poll.poll(&mut events, None).expect("Failed to poll fds");
        for event in &events {
            match event.token() {
                STATE_CHANGE => {
                    //println!("state change!");
                    event_queue
                        .dispatch(|_, _| { /* we ignore unfiltered messages */ } )
                        .expect("event_queue dispatch failure");

                    if let Some(ref prev_window) = prev_window {
                        let window_event = window_to_event(&prev_window);
                        client.heartbeat(window_bucket, &window_event, HEARTBEAT_INTERVAL_MARGIN_S)
                            .expect("Failed to send heartbeat");
                    }

                    match current_window::get_focused_window() {
                        Some(current_window) => {
                            let window_event = window_to_event(&current_window);
                            client.heartbeat(window_bucket, &window_event, HEARTBEAT_INTERVAL_MARGIN_S)
                                .expect("Failed to send heartbeat");
                            prev_window = Some(current_window);
                        },
                        None => {
                            prev_window = None;
                        },
                    }

                    let afk_event = idle::get_current_afk_event();
                    client.heartbeat(afk_bucket, &afk_event, HEARTBEAT_INTERVAL_MARGIN_S)
                        .expect("Failed to send heartbeat");
                },
                TIMER => {
                    //println!("timer!");
                    timer.read();

                    if let Some(ref prev_window) = prev_window {
                        let window_event = window_to_event(&prev_window);
                        client.heartbeat(window_bucket, &window_event, HEARTBEAT_INTERVAL_MARGIN_S)
                            .expect("Failed to send heartbeat");
                    }

                    let afk_event = idle::get_current_afk_event();
                    client.heartbeat(afk_bucket, &afk_event, HEARTBEAT_INTERVAL_MARGIN_S)
                        .expect("Failed to send heartbeat");

                },
                _ => panic!("Invalid token!")
            }
        }
    }
}
