//extern crate nix;
extern crate file_lock;
extern crate appdirs;

use file_lock::FileLock;

pub fn get_client_lock(clientname: &str) -> Result<FileLock, String> {
    // $XDG_USER_CACHE_DIR/activitywatch/client_locks/clientname
    let mut path = match appdirs::user_cache_dir(Some("activitywatch"), None) {
        Ok(path) => path,
        Err(_) => return Err("Failed to fetch user_cache_dir".to_string()),
    };
    path.push("client_locks");
    path.push(clientname);

    match FileLock::lock(&path.to_str().unwrap(), false, true) {
        Ok(lockfile) => Ok(lockfile),
        Err(e) => Err(format!("Failed to get lock for client '{}': {}", clientname, e)),
    }
}
