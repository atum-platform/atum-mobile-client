// SPDX-License-Identifier: Apache-2.0
// Actual gated SQLite interaction; disposable encrypted store, no server account.
use std::time::Duration;

use matrix_sdk_common::cross_process_lock::{CrossProcessLock, CrossProcessLockConfig};
use matrix_sdk_crypto::store::{CRYPTO_STORE_LOCK_KEY, CryptoStore, LockableCryptoStore};
use tempfile::TempDir;

use super::{SqliteCryptoStore, SqliteKeyValueStoreConnExt};

#[tokio::test]
async fn sqlite_worker_commits_after_async_writer_is_aborted() {
    let temp = TempDir::new().unwrap();
    let raw = SqliteCryptoStore::open(temp.path(), Some("synthetic-cancellation-test")).await.unwrap();
    let reader = SqliteCryptoStore::open(temp.path(), Some("synthetic-cancellation-test")).await.unwrap();
    let control = CrossProcessLock::new(
        LockableCryptoStore::new(raw.clone()),
        CRYPTO_STORE_LOCK_KEY.to_owned(),
        CrossProcessLockConfig::multi_process("synthetic-cancelled-writer"),
    );
    let guard = control.try_lock_once().await.unwrap().unwrap().into_guard();
    let writer = raw.with_lease(&guard).unwrap();
    let expected = b"committed-after-caller-abort".to_vec();
    let encrypted = raw.store_cipher.as_ref().unwrap().encrypt_value_data(expected.clone()).unwrap();
    let serialized = rmp_serde::to_vec_named(&encrypted).unwrap();
    let (started_send, started_receive) = tokio::sync::oneshot::channel();
    let (release_send, release_receive) = std::sync::mpsc::channel();
    let task = tokio::spawn(async move {
        // The actual operation owns the guard. Abort drops it while SQLite's
        // blocking transaction callback is still executing independently.
        let _operation_guard = guard;
        writer.with_crypto_write(move |txn| {
            txn.set_kv("synthetic-cancellation-value", &serialized)?;
            started_send.send(()).unwrap();
            release_receive.recv_timeout(Duration::from_secs(5)).expect("bounded worker gate");
            Ok(())
        }).await
    });
    tokio::time::timeout(Duration::from_secs(2), started_receive)
        .await.expect("SQLite worker did not enter transaction").unwrap();
    assert!(reader.get_custom_value("synthetic-cancellation-value").await.unwrap().is_none(),
        "uncommitted SQLite transaction must stay invisible");
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled(), "actual writer future must be cancelled");
    release_send.send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if reader.get_custom_value("synthetic-cancellation-value").await.unwrap() == Some(expected.clone()) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }).await.expect("cancelled async writer's started SQLite worker did not commit");
    assert_eq!(reader.get_custom_value("synthetic-cancellation-value").await.unwrap(), Some(expected));
}
