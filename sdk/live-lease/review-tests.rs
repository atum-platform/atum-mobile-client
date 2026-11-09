// Retained-review evidence only; synthetic encrypted stores, no server account.
// SPDX-License-Identifier: Apache-2.0
#![cfg(all(feature = "e2e-encryption", feature = "sqlite"))]

use matrix_sdk_base::{
    BaseClient, DmRoomDefinition, SessionMeta, ThreadingSupport,
    cross_process_lock::{CrossProcessLock, CrossProcessLockConfig, LEASE_DURATION_MS},
    crypto::{DecryptionSettings, EncryptionSyncChanges, TrustRequirement,
        store::{CryptoStore, LockableCryptoStore}},
    store::{RoomLoadSettings, StoreConfig},
};
use matrix_sdk_sqlite::SqliteCryptoStore;
use ruma::{device_id, user_id};
use std::time::Duration;
use tempfile::TempDir;

fn base(store: &SqliteCryptoStore, holder: &str) -> (BaseClient, CrossProcessLock<LockableCryptoStore>) {
    let config = CrossProcessLockConfig::multi_process(holder);
    let client = BaseClient::new(StoreConfig::new(config.clone()).crypto_store(store.clone()),
        ThreadingSupport::Disabled, DmRoomDefinition::default());
    let lock = client.create_crypto_store_lock(config).unwrap();
    (client, lock)
}

fn meta() -> SessionMeta {
    SessionMeta { user_id: user_id!("@review:atum.invalid").to_owned(),
        device_id: device_id!("REVIEW").to_owned() }
}

#[tokio::test(flavor = "multi_thread")]
async fn oauth_guard_cannot_bind_crypto_while_another_crypto_holder_owns_store() {
    let dir = TempDir::new().unwrap();
    let a_store = SqliteCryptoStore::open(dir.path(), Some("synthetic-review")).await.unwrap();
    let (a, a_lock) = base(&a_store, "A");
    let initial = a_lock.try_lock_once().await.unwrap().unwrap().into_guard();
    a.activate(meta(), RoomLoadSettings::All, None).await.unwrap();
    let original = a.olm_machine().await.as_ref().unwrap().clone();
    let keys = original.identity_keys();
    drop(initial);
    let b_store = SqliteCryptoStore::open(dir.path(), Some("synthetic-review")).await.unwrap();
    let (b, b_lock) = base(&b_store, "B");
    let b_guard = tokio::time::timeout(Duration::from_secs(5), b_lock.spin_lock(Some(1000)))
        .await.unwrap().unwrap().unwrap().into_guard();
    b.activate(meta(), RoomLoadSettings::All, None).await.unwrap();
    let oauth_lock = a.create_oauth_refresh_lock("A-oauth".into());
    let oauth_guard = oauth_lock.try_lock_once().await.unwrap().unwrap().into_guard();
    assert_eq!(oauth_guard.lease_identity().unwrap().0, "oidc_session_refresh_lock");
    assert!(a.bind_olm_to_lease(&oauth_guard).await.is_err(), "OAuth namespace cannot mint a crypto writer");
    assert_eq!(a.olm_machine().await.as_ref().unwrap().identity_keys(), keys);
    assert!(original.store().set_custom_value("review-stale", vec![1]).await.is_err());
    assert!(b_store.get_custom_value("review-stale").await.unwrap().is_none());
    b.olm_machine().await.as_ref().unwrap().store().set_custom_value("review-live", vec![2]).await.unwrap();
    assert_eq!(a_store.get_custom_value("review-live").await.unwrap(), Some(vec![2]));
    drop(oauth_guard);
    drop(b_guard);
}

#[tokio::test(flavor = "multi_thread")]
async fn nested_regeneration_does_not_release_outer_crypto_guard() {
    let dir = TempDir::new().unwrap();
    let store = SqliteCryptoStore::open(dir.path(), Some("synthetic-review")).await.unwrap();
    let (a, a_lock) = base(&store, "A");
    let outer = a_lock.try_lock_once().await.unwrap().unwrap().into_guard();
    a.activate(meta(), RoomLoadSettings::All, None).await.unwrap();
    let keys = a.olm_machine().await.as_ref().unwrap().identity_keys();
    a.regenerate_olm(None).await.unwrap();
    // Pass two real lease durations: renewal must still see the outer holder.
    tokio::time::sleep(Duration::from_millis(u64::from(LEASE_DURATION_MS) * 2)).await;
    let other = SqliteCryptoStore::open(dir.path(), Some("synthetic-review")).await.unwrap();
    let (_, b_lock) = base(&other, "B");
    assert!(b_lock.try_lock_once().await.unwrap().is_err(), "outer holder must still renew after nested guard drop");
    let current = a.olm_machine().await.as_ref().unwrap().clone();
    assert_eq!(current.identity_keys(), keys);
    current.receive_sync_changes(EncryptionSyncChanges { to_device_events: vec![],
        changed_devices: &Default::default(), one_time_keys_counts: &Default::default(),
        unused_fallback_keys: None, next_batch_token: Some("outer-still-owned".into()) },
        &DecryptionSettings { sender_device_trust_requirement: TrustRequirement::Untrusted }).await.unwrap();
    assert_eq!(store.next_batch_token().await.unwrap().as_deref(), Some("outer-still-owned"));
    drop(outer);
}
