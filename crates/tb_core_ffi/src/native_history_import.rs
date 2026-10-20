//! Explicit, read-locked import into an unused namespace. Publication is one
//! no-replace directory rename; partial copies are never visible to the engine.
#[cfg(target_os = "macos")]
mod mac {
    use std::os::unix::{
        ffi::OsStrExt,
        fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    };
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::{
        ffi::CString,
        fs::{self, DirBuilder, File, OpenOptions},
        io::{Read, Write},
        path::Path,
    };
    static NEXT: AtomicU64 = AtomicU64::new(0);
    const FILES: [(&str, u64); 3] = [
        ("quota-account-scope-installation-key-v1.bin", 32),
        ("quota-account-scope-v1.json", 4 * 1024 * 1024),
        ("quota-pace-history-v3.json", 64 * 1024 * 1024),
    ];
    const LOCKS: [&str; 2] = ["quota-account-scope-v1.lock", "quota-pace-v3.lock"];
    unsafe extern "C" {
        fn geteuid() -> u32;
        fn renamex_np(
            from: *const std::ffi::c_char,
            to: *const std::ffi::c_char,
            flags: u32,
        ) -> i32;
    }
    fn directory(path: &Path) -> Result<(), String> {
        let m = fs::symlink_metadata(path).map_err(|_| "history_import_missing")?;
        if !m.is_dir() || m.uid() != unsafe { geteuid() } {
            return Err("history_import_unsafe_path".into());
        }
        Ok(())
    }
    fn open(path: &Path) -> Result<File, String> {
        let f = OpenOptions::new()
            .read(true)
            .custom_flags(0x100)
            .open(path)
            .map_err(|_| "history_import_missing")?;
        let m = f.metadata().map_err(|_| "history_import_read_failed")?;
        if !m.is_file()
            || m.uid() != unsafe { geteuid() }
            || m.nlink() != 1
            || m.mode() & 0o077 != 0
        {
            return Err("history_import_unsafe_path".into());
        }
        Ok(f)
    }
    fn publish(from: &Path, to: &Path) -> Result<(), String> {
        let from =
            CString::new(from.as_os_str().as_bytes()).map_err(|_| "history_import_unsafe_path")?;
        let to =
            CString::new(to.as_os_str().as_bytes()).map_err(|_| "history_import_unsafe_path")?;
        // RENAME_EXCL from the macOS SDK: a competing initialization wins safely.
        if unsafe { renamex_np(from.as_ptr(), to.as_ptr(), 0x4) } != 0 {
            return Err("history_import_publish_failed".into());
        }
        Ok(())
    }
    pub(super) fn run_at(
        source: &Path,
        parent: &Path,
        commit: bool,
    ) -> Result<serde_json::Value, String> {
        directory(source)?;
        let destination = parent.join("native-history");
        if fs::symlink_metadata(&destination).is_ok() {
            return Err("history_import_destination_exists".into());
        }
        let mut locks = Vec::new();
        for name in LOCKS {
            let lock = open(&source.join(name))?;
            fs2::FileExt::try_lock_shared(&lock).map_err(|_| "history_import_busy")?;
            locks.push(lock);
        }
        let mut data = Vec::new();
        for (name, cap) in FILES {
            let f = open(&source.join(name))?;
            let mut bytes = Vec::new();
            f.take(cap + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| "history_import_read_failed")?;
            if bytes.len() as u64 > cap {
                return Err("history_import_too_large".into());
            }
            data.push(bytes);
        }
        if !crate::agent_account_scope::validate_history_import_metadata(&data[0], &data[1]) {
            return Err("history_import_invalid_metadata".into());
        }
        let series = crate::agent_quota_history::validate_history_import(&data[2])
            .ok_or("history_import_invalid_history")?;
        if commit {
            if !parent.exists() {
                DirBuilder::new()
                    .mode(0o700)
                    .recursive(true)
                    .create(parent)
                    .map_err(|_| "history_import_write_failed")?;
            }
            directory(parent)?;
            let stage = parent.join(format!(
                ".history-import-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            DirBuilder::new()
                .mode(0o700)
                .create(&stage)
                .map_err(|_| "history_import_write_failed")?;
            let result = (|| {
                for ((name, _), bytes) in FILES.iter().zip(&data) {
                    let mut out = OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .mode(0o600)
                        .open(stage.join(name))
                        .map_err(|_| "history_import_write_failed")?;
                    out.write_all(bytes)
                        .and_then(|_| out.sync_all())
                        .map_err(|_| "history_import_write_failed")?;
                }
                File::open(&stage)
                    .and_then(|f| f.sync_all())
                    .map_err(|_| "history_import_write_failed")?;
                publish(&stage, &destination)?;
                Ok::<(), String>(())
            })();
            if result.is_err() {
                let _ = fs::remove_dir_all(&stage);
            }
            result?;
        }
        Ok(serde_json::json!({"seriesCount":series,"imported":commit}))
    }
    pub(super) fn run(commit: bool) -> Result<serde_json::Value, String> {
        let root = dirs::data_dir().ok_or("history_import_unavailable")?;
        run_at(
            &root.join("com.nyanako.tokenbar"),
            &root.join("org.flyresearch.agentusage"),
            commit,
        )
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        fn fixture() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
            let temp = tempfile::tempdir().unwrap();
            let source = temp.path().join("source");
            let dest = temp.path().join("dest");
            DirBuilder::new().mode(0o700).create(&source).unwrap();
            let key = [7u8; 32];
            let metadata = crate::agent_account_scope::history_import_fixture_metadata(&key);
            for (name, bytes) in [
                (FILES[0].0, key.to_vec()),
                (FILES[1].0, metadata),
                (FILES[2].0, b"{\"schemaVersion\":4,\"series\":[]}".to_vec()),
                (LOCKS[0], vec![]),
                (LOCKS[1], vec![]),
            ] {
                let mut f = OpenOptions::new()
                    .create_new(true)
                    .write(true)
                    .mode(0o600)
                    .open(source.join(name))
                    .unwrap();
                f.write_all(&bytes).unwrap();
            }
            (temp, source, dest)
        }
        #[test]
        fn import_preserves_pair_and_source_and_refuses_overwrite() {
            let (_temp, source, dest) = fixture();
            let before: Vec<_> = FILES
                .iter()
                .map(|(n, _)| fs::read(source.join(n)).unwrap())
                .collect();
            assert_eq!(run_at(&source, &dest, false).unwrap()["imported"], false);
            assert!(!dest.exists());
            assert_eq!(run_at(&source, &dest, true).unwrap()["imported"], true);
            for ((name, _), bytes) in FILES.iter().zip(before) {
                assert_eq!(fs::read(source.join(name)).unwrap(), bytes);
                assert_eq!(
                    fs::read(dest.join("native-history").join(name)).unwrap(),
                    bytes
                );
            }
            assert_eq!(
                run_at(&source, &dest, true).unwrap_err(),
                "history_import_destination_exists"
            );
        }
        #[test]
        fn busy_or_corrupt_source_cannot_publish() {
            let (_temp, source, dest) = fixture();
            let lock = open(&source.join(LOCKS[0])).unwrap();
            fs2::FileExt::lock_exclusive(&lock).unwrap();
            assert_eq!(
                run_at(&source, &dest, true).unwrap_err(),
                "history_import_busy"
            );
            drop(lock);
            fs::write(source.join(FILES[0].0), [8u8; 32]).unwrap();
            assert_eq!(
                run_at(&source, &dest, true).unwrap_err(),
                "history_import_invalid_metadata"
            );
            assert!(!dest.exists());
        }
        #[test]
        fn symlink_and_invalid_history_cannot_publish() {
            let (_temp, source, dest) = fixture();
            let key = source.join(FILES[0].0);
            let other = source.join("saved-key");
            fs::rename(&key, &other).unwrap();
            std::os::unix::fs::symlink(&other, &key).unwrap();
            assert!(run_at(&source, &dest, true).is_err());
            assert!(!dest.exists());
            fs::remove_file(&key).unwrap();
            fs::rename(&other, &key).unwrap();
            fs::write(source.join(FILES[2].0), b"{}").unwrap();
            assert_eq!(
                run_at(&source, &dest, true).unwrap_err(),
                "history_import_invalid_history"
            );
            assert!(!dest.exists());
        }
        #[test]
        fn atomic_publish_never_replaces_a_competing_directory() {
            let temp = tempfile::tempdir().unwrap();
            let a = temp.path().join("a");
            let b = temp.path().join("b");
            fs::create_dir(&a).unwrap();
            fs::create_dir(&b).unwrap();
            // An EMPTY competing directory is essential: ordinary rename would replace it.
            assert!(publish(&a, &b).is_err());
            assert!(a.exists() && b.exists());
        }
    }
}
pub(crate) fn run(commit: bool) -> Result<serde_json::Value, String> {
    #[cfg(target_os = "macos")]
    {
        mac::run(commit)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = commit;
        Err("history_import_unsupported_platform".into())
    }
}
