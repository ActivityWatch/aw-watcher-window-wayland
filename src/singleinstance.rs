use file_lock::FileLock;
use std::fs;
use std::io;

pub fn get_client_lock(clientname: &str) -> Result<FileLock, String> {
    // $XDG_USER_CACHE_DIR/activitywatch/client_locks/clientname
    let mut path = match appdirs::user_cache_dir(Some("activitywatch"), None) {
        Ok(path) => path,
        Err(_) => return Err("Failed to fetch user_cache_dir".to_string()),
    };
    path.push("client_locks");

    if let Err(err) = fs::create_dir_all(path.clone()) {
        match err.kind() {
            io::ErrorKind::AlreadyExists => (),
            _other_kind => return Err(format!("Failed to create client_locks dir: {}", err)),
        }
    }

    path.push(clientname);

    match FileLock::lock(path.to_str().unwrap(), false, true) {
        Ok(lockfile) => Ok(lockfile),
        Err(err) => Err(format!(
            "Failed to get lock for client '{}': {}",
            clientname, err
        )),
    }
}
