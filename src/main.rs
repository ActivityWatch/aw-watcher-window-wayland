// The generated code will import stuff from wayland_sys
extern crate wayland_sys;
extern crate wayland_client;
extern crate aw_client_rust;
extern crate chrono;
extern crate gethostname;
extern crate getopts;

#[macro_use] extern crate lazy_static;

#[macro_use] extern crate smallvec;

mod current_window;
mod idle;
mod singleinstance;

use std::sync::{Arc, Mutex};
use std::{env, thread};
use std::time::Duration;
use std::os::unix::io::AsRawFd;

use mio::{Poll, Token, PollOpt, Ready, Events};
use mio::unix::EventedFd;
use timerfd::{TimerFd, TimerState, SetTimeFlags};

use serde_json::{Map, Value};
use chrono::prelude::*;
use tokio::sync::oneshot;
use wayland_client::Connection;


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

    println!("### Connecting to wayland server");
    let conn = Connection::connect_to_env().unwrap();

    println!("### Setting up toplevel manager");
    let (window_state, mut window_queue) = current_window::init_toplevel_manager(&conn).unwrap();
    // let (window_tx,window_rx) = oneshot::channel();
    let shared_window_state = Arc::new(Mutex::new(window_state));

    println!("### Setting up idle timeout");
    let (afk_state, mut afk_queue) = idle::init_afk_state(&conn, 120000).unwrap();
    let shared_afk_state = Arc::new(Mutex::new(afk_state));
    // let (afk_tx, afk_rx) = oneshot::channel();

    {
        let shared_window_state = shared_window_state.clone();
        let shared_afk_state = shared_afk_state.clone();
        let t1 = thread::spawn(move || {
            let mut dispatch = ||  {
                let mut window_state = shared_window_state.lock().unwrap();
                let mut afk_state = shared_afk_state.lock().unwrap();
                window_queue.dispatch_pending(&mut window_state);
                afk_queue.dispatch_pending(&mut afk_state);
            };
    
            loop {
                println!("reading socket");
                match conn.prepare_read() {
                    Some(read_event_guard) => {
                        read_event_guard.read().unwrap();
                        dispatch();
                    },
                    None => {
                        dispatch();
                    }
                }
            }
        });
    }

    println!("### Taking client locks");
    let host = "localhost";
    let port = match testing {
        true => "5666",
        false => "5600"
    };
    let _window_lock = singleinstance::get_client_lock(&format!("aw-watcher-window-at-{}-on-{}", host, port)).unwrap();
    let _afk_lock = singleinstance::get_client_lock(&format!("aw-watcher-afk-at-{}-on-{}", host, port)).unwrap();

    println!("### Creating aw-client");
    let client = aw_client_rust::blocking::AwClient::new(host, port, "aw-watcher-wayland");
    let hostname = gethostname::gethostname().into_string().unwrap();
    let window_bucket = format!("aw-watcher-window_{}", hostname);
    let afk_bucket = format!("aw-watcher-afk_{}", hostname);
    client.create_bucket_simple(&window_bucket, "currentwindow")
        .expect("Failed to create window bucket");
    client.create_bucket_simple(&afk_bucket, "afkstatus")
        .expect("Failed to create afk bucket");

    println!("### Watcher is now running");
    loop {
        {
            let window_state = shared_window_state.lock().unwrap();
            if let Some(window) = window_state.get_focused_window() {
                let window_event = window_to_event(&window);
                    if client.heartbeat(&window_bucket, &window_event, HEARTBEAT_INTERVAL_MARGIN_S).is_err() {
                        println!("Failed to send heartbeat");
                        break;
                    }
            }
    
            let afk_state = shared_afk_state.lock().unwrap();
            let afk_event = afk_state.get_current_afk_event();
            if client.heartbeat(&afk_bucket, &afk_event, HEARTBEAT_INTERVAL_MARGIN_S).is_err() {
                println!("Failed to send heartbeat");
                break;
            }
        }
    }
}
