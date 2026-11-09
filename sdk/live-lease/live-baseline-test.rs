// Regression against the previous binding-only checkpoint. Synthetic data only.
// SPDX-License-Identifier: Apache-2.0
#![cfg(all(feature = "e2e-encryption", feature = "sqlite"))]
use matrix_sdk_base::{
    BaseClient, DmRoomDefinition, SessionMeta, ThreadingSupport,
    cross_process_lock::CrossProcessLockConfig,
    crypto::{DecryptionSettings, EncryptionSyncChanges, TrustRequirement},
    store::{RoomLoadSettings, StoreConfig},
};
use matrix_sdk_sqlite::SqliteCryptoStore;
use ruma::{device_id, user_id};
use std::time::Duration;
use tempfile::TempDir;

#[tokio::test(flavor = "multi_thread")]
async fn retained_baseclient_machine_refuses_after_handoff() {
    let dir = TempDir::new().unwrap();
    let store = SqliteCryptoStore::open(dir.path(), Some("synthetic-live-baseline"))
        .await
        .unwrap();
    let config = CrossProcessLockConfig::multi_process("A");
    let a = BaseClient::new(
        StoreConfig::new(config.clone()).crypto_store(store),
        ThreadingSupport::Disabled,
        DmRoomDefinition::default(),
    );
    let lock_a = a.create_crypto_store_lock(config);
    let guard_a = lock_a.try_lock_once().await.unwrap().unwrap().into_guard();
    let meta = SessionMeta {
        user_id: user_id!("@synthetic:atum.invalid").to_owned(),
        device_id: device_id!("BASELINE").to_owned(),
    };
    a.activate(meta.clone(), RoomLoadSettings::All, None)
        .await
        .unwrap();
    let old = a.olm_machine().await.as_ref().unwrap().clone();
    drop(guard_a);
    let reopened = SqliteCryptoStore::open(dir.path(), Some("synthetic-live-baseline"))
        .await
        .unwrap();
    let config = CrossProcessLockConfig::multi_process("B");
    let b = BaseClient::new(
        StoreConfig::new(config.clone()).crypto_store(reopened),
        ThreadingSupport::Disabled,
        DmRoomDefinition::default(),
    );
    let lock_b = b.create_crypto_store_lock(config);
    let _guard_b = tokio::time::timeout(Duration::from_secs(5), lock_b.spin_lock(Some(1000)))
        .await
        .unwrap()
        .unwrap()
        .unwrap()
        .into_guard();
    b.activate(meta, RoomLoadSettings::All, None).await.unwrap();
    let result = old
        .receive_sync_changes(
            EncryptionSyncChanges {
                to_device_events: vec![],
                changed_devices: &Default::default(),
                one_time_keys_counts: &Default::default(),
                unused_fallback_keys: None,
                next_batch_token: Some("stale-A".into()),
            },
            &DecryptionSettings {
                sender_device_trust_requirement: TrustRequirement::Untrusted,
            },
        )
        .await;
    assert!(
        result.is_err(),
        "retained BaseClient machine must refuse expired handoff writes"
    );
}
