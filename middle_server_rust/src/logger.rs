use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime},
};

use chrono::{Local, Utc};

#[derive(Clone)]
pub struct FileLogger {
    inner: Arc<FileLoggerInner>,
}

struct FileLoggerInner {
    log_file_path: PathBuf,
    max_bytes: i64,
    retention: Duration,
    last_cleanup: Mutex<SystemTime>,
    write_lock: Mutex<()>,
}

impl FileLogger {
    pub fn new(
        log_file_path: PathBuf,
        max_bytes: i64,
        retention_days: i32,
    ) -> anyhow::Result<Self> {
        if let Some(parent) = log_file_path.parent() {
            fs::create_dir_all(parent)?;
        }
        Ok(Self {
            inner: Arc::new(FileLoggerInner {
                log_file_path,
                max_bytes: max_bytes.max(1),
                retention: Duration::from_secs((retention_days.max(1) as u64) * 24 * 60 * 60),
                last_cleanup: Mutex::new(SystemTime::UNIX_EPOCH),
                write_lock: Mutex::new(()),
            }),
        })
    }

    pub fn path(&self) -> &Path {
        &self.inner.log_file_path
    }

    pub fn info(&self, category: &str, message: impl AsRef<str>) {
        self.log("INF", category, message.as_ref());
    }

    pub fn warn(&self, category: &str, message: impl AsRef<str>) {
        self.log("WRN", category, message.as_ref());
    }

    pub fn log(&self, level: &str, category: &str, message: &str) {
        let line = format!(
            "[{}] {:<11} {}: {}\n",
            Local::now().format("%Y-%m-%d %H:%M:%S%.3f %:z"),
            level,
            category,
            sanitize(message)
        );
        print!("{}", line);

        let Ok(_guard) = self.inner.write_lock.lock() else {
            return;
        };
        let _ = self.rotate_if_needed_locked();
        if let Ok(mut file) = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.inner.log_file_path)
        {
            let _ = file.write_all(line.as_bytes());
        }
        let _ = self.cleanup_archives_locked();
    }

    fn rotate_if_needed_locked(&self) -> anyhow::Result<()> {
        let path = &self.inner.log_file_path;
        let Ok(metadata) = fs::metadata(path) else {
            return Ok(());
        };
        if metadata.len() < self.inner.max_bytes as u64 {
            return Ok(());
        }
        let dir = path.parent().unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(dir)?;
        let stem = path
            .file_stem()
            .and_then(|x| x.to_str())
            .unwrap_or("server");
        let ext = path.extension().and_then(|x| x.to_str()).unwrap_or("");
        let timestamp = Utc::now().format("%Y%m%d-%H%M%S%3f");
        let mut suffix = 0;
        loop {
            let name = if ext.is_empty() {
                if suffix == 0 {
                    format!("{stem}-{timestamp}")
                } else {
                    format!("{stem}-{timestamp}-{suffix:02}")
                }
            } else if suffix == 0 {
                format!("{stem}-{timestamp}.{ext}")
            } else {
                format!("{stem}-{timestamp}-{suffix:02}.{ext}")
            };
            let archive = dir.join(name);
            if !archive.exists() {
                fs::rename(path, archive)?;
                return Ok(());
            }
            suffix += 1;
        }
    }

    fn cleanup_archives_locked(&self) -> anyhow::Result<()> {
        let now = SystemTime::now();
        {
            let Ok(mut last_cleanup) = self.inner.last_cleanup.lock() else {
                return Ok(());
            };
            if now.duration_since(*last_cleanup).unwrap_or_default() < Duration::from_secs(60) {
                return Ok(());
            }
            *last_cleanup = now;
        }

        let path = &self.inner.log_file_path;
        let dir = path.parent().unwrap_or_else(|| Path::new("."));
        let stem = path
            .file_stem()
            .and_then(|x| x.to_str())
            .unwrap_or("server");
        let cutoff = now
            .checked_sub(self.inner.retention)
            .unwrap_or(SystemTime::UNIX_EPOCH);
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let archive_path = entry.path();
            let Some(file_name) = archive_path.file_name().and_then(|x| x.to_str()) else {
                continue;
            };
            if !file_name.starts_with(&format!("{stem}-")) {
                continue;
            }
            let modified = entry.metadata()?.modified().unwrap_or(now);
            if modified <= cutoff {
                let _ = fs::remove_file(archive_path);
            }
        }
        Ok(())
    }
}

fn sanitize(value: &str) -> String {
    value.replace(['\r', '\n'], " ")
}
