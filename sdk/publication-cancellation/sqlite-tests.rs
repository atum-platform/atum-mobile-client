// SQLite publication-cancellation regressions. Disposable synthetic stores only.
// SPDX-License-Identifier: Apache-2.0

use std::{sync::mpsc, time::Duration};

use matrix_sdk_common::cross_process_lock::{CrossProcessLock, CrossProcessLockConfig};
use matrix_sdk_crypto::store::{
    CRYPTO_STORE_LOCK_KEY, CryptoStore, CryptoStoreError, IntoCryptoStore, LockableCryptoStore,
};
use tempfile::TempDir;

use super::{SqliteCryptoStore, SqliteKeyValueStoreConnExt};

fn lock(store: &SqliteCryptoStore, holder: &str) -> CrossProcessLock<LockableCryptoStore> {
    CrossProcessLock::new(
        LockableCryptoStore::new(store.clone()),
        CRYPTO_STORE_LOCK_KEY.to_owned(),
        CrossProcessLockConfig::multi_process(holder),
    )
}

#[tokio::test]
async fn aborted_bound_transaction_rolls_back_and_fresh_raw_binding_stays_usable() {
    let temp = TempDir::new().unwrap();
    let raw =
        SqliteCryptoStore::open(temp.path(), Some("synthetic-cancellation-test")).await.unwrap();
    let reader =
        SqliteCryptoStore::open(temp.path(), Some("synthetic-cancellation-test")).await.unwrap();
    raw.set_custom_value("original", b"durable-original".to_vec()).await.unwrap();

    let control = lock(&raw, "synthetic-cancelled-writer");
    let guard = control.try_lock_once().await.unwrap().unwrap().into_guard();
    let bound = raw.with_lease(&guard).unwrap();
    let old_clone = bound.clone();
    let erased = old_clone.clone().into_crypto_store();
    let (started_send, started_receive) = tokio::sync::oneshot::channel();
    let (release_send, release_receive) = mpsc::channel();
    let writer = tokio::spawn(async move {
        bound
            .with_crypto_write(move |txn| {
                txn.set_kv("cancelled-transaction", b"must-roll-back")?;
                started_send.send(()).unwrap();
                release_receive.recv_timeout(Duration::from_secs(5)).expect("bounded worker gate");
                Ok(())
            })
            .await
    });

    started_receive.await.unwrap();
    writer.abort();
    assert!(writer.await.unwrap_err().is_cancelled(), "caller future must be cancelled");
    release_send.send(()).unwrap();
    raw.await_pending_writes().await.unwrap();

    assert_eq!(reader.get_custom_value("cancelled-transaction").await.unwrap(), None);
    assert!(!old_clone.is_usable(), "all old bound clones share cancellation invalidation");
    assert!(old_clone.get_custom_value("original").await.is_err());
    assert!(
        matches!(erased.get_custom_value("original").await, Err(CryptoStoreError::Invalidated)),
        "erased Deref backend exposes the permanent invalidation"
    );

    let fresh = raw.with_lease(&guard).unwrap();
    assert!(fresh.is_usable(), "a raw control handle creates an independent bound token");
    assert_eq!(
        fresh.get_custom_value("original").await.unwrap(),
        Some(b"durable-original".to_vec())
    );
    fresh.set_custom_value("fresh-writer", b"fresh".to_vec()).await.unwrap();
    assert_eq!(reader.get_custom_value("fresh-writer").await.unwrap(), Some(b"fresh".to_vec()));
}

#[tokio::test]
async fn writer_drain_waits_for_the_actual_blocked_sqlite_worker() {
    let temp = TempDir::new().unwrap();
    let raw =
        SqliteCryptoStore::open(temp.path(), Some("synthetic-cancellation-test")).await.unwrap();
    let control = lock(&raw, "synthetic-drain-writer");
    let guard = control.try_lock_once().await.unwrap().unwrap().into_guard();
    let bound = raw.with_lease(&guard).unwrap();
    let (started_send, started_receive) = tokio::sync::oneshot::channel();
    let (release_send, release_receive) = mpsc::channel();
    let writer = tokio::spawn(async move {
        bound
            .with_crypto_write(move |txn| {
                txn.set_kv("drain-pending", b"worker")?;
                started_send.send(()).unwrap();
                release_receive.recv_timeout(Duration::from_secs(5)).expect("bounded worker gate");
                Ok(())
            })
            .await
    });
    started_receive.await.unwrap();

    let mut drain = tokio::spawn({
        let raw = raw.clone();
        async move { raw.await_pending_writes().await }
    });
    assert!(
        tokio::time::timeout(Duration::from_millis(100), &mut drain).await.is_err(),
        "drain must queue behind the started writer interaction"
    );
    release_send.send(()).unwrap();
    writer.await.unwrap().unwrap();
    drain.await.unwrap().unwrap();
}

#[tokio::test]
async fn explicit_invalidation_refuses_bound_clones_without_erasing_committed_data() {
    let temp = TempDir::new().unwrap();
    let raw =
        SqliteCryptoStore::open(temp.path(), Some("synthetic-cancellation-test")).await.unwrap();
    let reader =
        SqliteCryptoStore::open(temp.path(), Some("synthetic-cancellation-test")).await.unwrap();
    let control = lock(&raw, "synthetic-invalidate-writer");
    let guard = control.try_lock_once().await.unwrap().unwrap().into_guard();
    let bound = raw.with_lease(&guard).unwrap();
    let old_clone = bound.clone();
    let erased = old_clone.clone().into_crypto_store();

    bound.set_custom_value("committed-before-invalidate", b"durable".to_vec()).await.unwrap();
    bound.invalidate();

    assert!(!bound.is_usable());
    assert!(!old_clone.is_usable());
    assert!(bound.get_custom_value("committed-before-invalidate").await.is_err());
    assert!(old_clone.set_custom_value("later-write", b"refused".to_vec()).await.is_err());
    assert!(erased.get_custom_value("committed-before-invalidate").await.is_err());
    assert_eq!(
        reader.get_custom_value("committed-before-invalidate").await.unwrap(),
        Some(b"durable".to_vec())
    );
    assert!(reader.get_custom_value("later-write").await.unwrap().is_none());
}

#[tokio::test]
async fn unbound_handles_keep_upstream_behavior_after_invalidate() {
    let temp = TempDir::new().unwrap();
    let raw =
        SqliteCryptoStore::open(temp.path(), Some("synthetic-cancellation-test")).await.unwrap();

    raw.invalidate();
    assert!(raw.is_usable());
    raw.set_custom_value("unbound", b"still-usable".to_vec()).await.unwrap();
    assert_eq!(raw.get_custom_value("unbound").await.unwrap(), Some(b"still-usable".to_vec()));
}
