// The generated code will import stuff from wayland_sys
extern crate wayland_sys;
extern crate wayland_client;
extern crate aw_client_rust;
extern crate chrono;
extern crate gethostname;
extern crate getopts;

#[macro_use] extern crate lazy_static;

#[macro_use] extern crate smallvec;

mod wl_client;
mod current_window;
mod idle;
mod singleinstance;

use std::env;
use std::time::Duration;
use std::os::unix::io::AsRawFd;

use mio::{Poll, Token, PollOpt, Ready, Events};
use mio::unix::EventedFd;
use timerfd::{TimerFd, TimerState, SetTimeFlags};

use serde_json::{Map, Value};
use chrono::prelude::*;

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
        timestamp: Utc::now(),
        duration: chrono::Duration::milliseconds(0),
        data: data,
    }
}

// Setup some tokens to allow us to identify which event is for which socket.
const STATE_CHANGE: Token = Token(0);
const TIMER: Token = Token(1);

// Startup: how long to wait for aw-server before giving up (aw-qt may start us first).
const SERVER_WAIT_MAX: Duration = Duration::from_secs(60);
const SERVER_WAIT_STEP: Duration = Duration::from_secs(2);
// Upper bound on heartbeats buffered while the server is unreachable.
const QUEUE_MAX: usize = 1000;

/// Retry `f` until it succeeds or `SERVER_WAIT_MAX` has passed, logging each wait.
fn wait_for_server<T, E: std::fmt::Display>(what: &str, mut f: impl FnMut() -> Result<T, E>) -> T {
    let start = std::time::Instant::now();
    loop {
        match f() {
            Ok(v) => return v,
            Err(e) => {
                if start.elapsed() >= SERVER_WAIT_MAX {
                    panic!("Failed to {} after {}s: {}", what, SERVER_WAIT_MAX.as_secs(), e);
                }
                println!("Could not {} ({}), retrying in {}s", what, e, SERVER_WAIT_STEP.as_secs());
                std::thread::sleep(SERVER_WAIT_STEP);
            }
        }
    }
}

/// Sends heartbeats, buffering them in a bounded queue while the server is
/// unreachable and flushing them (oldest first) once it is back.
struct HeartbeatSender {
    client: aw_client_rust::blocking::AwClient,
    queue: std::collections::VecDeque<(String, aw_client_rust::Event)>,
}

impl HeartbeatSender {
    fn new(client: aw_client_rust::blocking::AwClient) -> Self {
        HeartbeatSender { client, queue: std::collections::VecDeque::new() }
    }

    fn send(&mut self, bucket: &str, event: &aw_client_rust::Event) {
        self.queue.push_back((bucket.to_string(), event.clone()));
        while self.queue.len() > QUEUE_MAX {
            self.queue.pop_front();
        }
        while let Some((bucket, event)) = self.queue.front() {
            if self.client.heartbeat(bucket, event, HEARTBEAT_INTERVAL_MARGIN_S).is_err() {
                println!("Failed to send heartbeat, {} queued", self.queue.len());
                return;
            }
            self.queue.pop_front();
        }
    }
}

static HEARTBEAT_INTERVAL_MS : u32 = 5000;
static HEARTBEAT_INTERVAL_MARGIN_S : f64 = (HEARTBEAT_INTERVAL_MS + 1000) as f64 / 1000.0;

fn main() {
    let args: Vec<String> = env::args().collect();
    let program = args[0].clone();
    let mut opts = getopts::Options::new();
    opts.optflag("", "testing", "run in testing mode");
    opts.optflag("h", "help", "print this help menu");
    let matches = match opts.parse(&args[1..]) {
        Ok(m) => m,
        Err(f) => panic!("{}", f.to_string()),
    };
    if matches.opt_present("h") {
        let brief = format!("Usage: {} [options]", program);
        print!("{}", opts.usage(&brief));
        return;
    }
    // Always testing mode with "cargo run", enable testing on release build with --testing
    let mut testing = cfg!(debug_assertions);
    if matches.opt_present("testing") {
        testing = true;
    }

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
    let mut is_idle_active = match idle::assign_ext_idle_notify(&globals, 120000) {
        Ok(_) => true,
        Err(err_str) => {
            eprintln!("{}", err_str);
            false
        }
    };
    if !is_idle_active {
        is_idle_active = match idle::assign_kde_idle_timeout(&globals, 120000) {
            Ok(_) => true,
            Err(err_str) => {
                eprintln!("{}", err_str);
                false
            }
        };
    }
    if !is_idle_active {
        eprintln!("Wayland session does not expose any protocols to handle idle status, this \
                   window manager is most likely not supported")
    }

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
    let host = "localhost";
    let port = match testing {
        true => 5666,
        false => 5600
    };
    let _window_lock = singleinstance::get_client_lock(&format!("aw-watcher-window-at-{}-on-{}", host, port)).unwrap();
    let _afk_lock = singleinstance::get_client_lock(&format!("aw-watcher-afk-at-{}-on-{}", host, port)).unwrap();

    println!("### Creating aw-client");
    let client = aw_client_rust::blocking::AwClient::new(host, port, "aw-watcher-wayland")
        .expect("Failed to create a client");
    let hostname = gethostname::gethostname().into_string().unwrap();
    let window_bucket = format!("aw-watcher-window_{}", hostname);
    let afk_bucket = format!("aw-watcher-afk_{}", hostname);
    wait_for_server("create window bucket", || client.create_bucket_simple(&window_bucket, "currentwindow"));
    wait_for_server("create afk bucket", || client.create_bucket_simple(&afk_bucket, "afkstatus"));
    let mut sender = HeartbeatSender::new(client);

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
                        sender.send(&window_bucket, &window_event);
                    }

                    match current_window::get_focused_window() {
                        Some(current_window) => {
                            let window_event = window_to_event(&current_window);
                            sender.send(&window_bucket, &window_event);
                            prev_window = Some(current_window);
                        },
                        None => {
                            prev_window = None;
                        },
                    }

                    if is_idle_active {
                        let afk_event = idle::get_current_afk_event();
                        sender.send(&afk_bucket, &afk_event);
                    }
                },
                TIMER => {
                    //println!("timer!");
                    timer.read();

                    if let Some(ref prev_window) = prev_window {
                        let window_event = window_to_event(&prev_window);
                        sender.send(&window_bucket, &window_event);
                    }

                    if is_idle_active {
                        let afk_event = idle::get_current_afk_event();
                        sender.send(&afk_bucket, &afk_event);
                    }
                },
                _ => panic!("Invalid token!")
            }
        }
    }
}
