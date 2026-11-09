// Atum SQLite lease-fence regression. Disposable synthetic stores only.
// SPDX-License-Identifier: Apache-2.0

use matrix_sdk_common::cross_process_lock::{
    CrossProcessLock, CrossProcessLockConfig, CrossProcessLockGuard,
};
use matrix_sdk_crypto::{
    Account,
    store::{CryptoStore, LockableCryptoStore, types::PendingChanges},
};
use ruma::{device_id, user_id};
use tempfile::TempDir;

use super::SqliteCryptoStore;

const LOCK_KEY: &str = "cross_process_lock";
type Lock = CrossProcessLock<LockableCryptoStore>;

fn lock(store: &SqliteCryptoStore, holder: &str) -> Lock {
    CrossProcessLock::new(
        LockableCryptoStore::new(store.clone()),
        LOCK_KEY.to_owned(),
        CrossProcessLockConfig::multi_process(holder),
    )
}

// Baseline adapter: the SDK currently has no immutable per-lease writer.
fn writer(store: &SqliteCryptoStore, _guard: &CrossProcessLockGuard) -> SqliteCryptoStore {
    store.clone()
}

#[tokio::test]
async fn stale_custom_write_preserves_successor_data_and_original_keys() {
    let temp = TempDir::new().unwrap();
    let a = SqliteCryptoStore::open(temp.path(), Some("synthetic-fence-test")).await.unwrap();
    let account = Account::with_device_id(user_id!("@synthetic:atum.invalid"), device_id!("FENCE"));
    let expected = account.identity_keys();
    a.save_pending_changes(PendingChanges { account: Some(account) }).await.unwrap();
    let b = SqliteCryptoStore::open(temp.path(), Some("synthetic-fence-test")).await.unwrap();

    let lock_a = lock(&a, "synthetic-A");
    let guard_a: CrossProcessLockGuard = lock_a.try_lock_once().await.unwrap().unwrap().into_guard();
    let stale = writer(&a, &guard_a);
    stale.set_custom_value("owner-state", b"A".to_vec()).await.unwrap();
    drop(guard_a);
    let lock_b = lock(&b, "synthetic-B");
    let guard_b: CrossProcessLockGuard = lock_b.spin_lock(None).await.unwrap().unwrap().into_guard();
    let current = writer(&b, &guard_b);
    current.set_custom_value("owner-state", b"B".to_vec()).await.unwrap();

    let result = stale.set_custom_value("owner-state", b"STALE".to_vec()).await;
    assert!(result.is_err(), "stale writer must be refused before mutating current-owner state");
    assert_eq!(b.get_custom_value("owner-state").await.unwrap(), Some(b"B".to_vec()));
    assert_eq!(b.load_account().await.unwrap().unwrap().identity_keys(), expected);
}
