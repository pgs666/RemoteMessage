use std::{
    env,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

pub fn executable_path() -> PathBuf {
    env::current_exe().unwrap_or_else(|_| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
}

pub fn runtime_directory() -> PathBuf {
    let path = executable_path();
    if path.is_dir() {
        path
    } else {
        path.parent()
            .map(PathBuf::from)
            .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
    }
}

pub fn now_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(i64::MAX as u128) as i64
}
