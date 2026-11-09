// Atum binding baseline. Disposable synthetic stores only.
// SPDX-License-Identifier: Apache-2.0

use matrix_sdk_common::cross_process_lock::{CrossProcessLock, CrossProcessLockConfig};
use matrix_sdk_crypto::store::{CryptoStore, LockableCryptoStore, CRYPTO_STORE_LOCK_KEY};
use tempfile::TempDir;
use super::SqliteCryptoStore;
fn lock(store: &SqliteCryptoStore, holder: &str) -> CrossProcessLock<LockableCryptoStore> {
    CrossProcessLock::new(LockableCryptoStore::new(store.clone()), CRYPTO_STORE_LOCK_KEY.into(),
        CrossProcessLockConfig::multi_process(holder))
}

#[tokio::test]
async fn foreign_guard_with_identical_lease_tuple_is_refused() {
    let a_dir = TempDir::new().unwrap();
    let b_dir = TempDir::new().unwrap();
    let a = SqliteCryptoStore::open(a_dir.path(), Some("synthetic-binding-test")).await.unwrap();
    let b = SqliteCryptoStore::open(b_dir.path(), Some("synthetic-binding-test")).await.unwrap();
    let control_a = lock(&a, "same-holder");
    let control_b = lock(&b, "same-holder");
    let guard_a = control_a.try_lock_once().await.unwrap().unwrap().into_guard();
    let guard_b = control_b.try_lock_once().await.unwrap().unwrap().into_guard();
    assert_eq!(guard_a.lease_identity(), guard_b.lease_identity());
    let result = b.with_lease(&guard_a);
    assert!(result.is_err(), "guard from another opened store must not bind despite an identical lease tuple");
    b.with_lease(&guard_b).unwrap().set_custom_value("owner", b"B".to_vec()).await.unwrap();
    assert!(a.get_custom_value("owner").await.unwrap().is_none());
}
