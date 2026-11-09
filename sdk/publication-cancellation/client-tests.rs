// Actual BaseClient replacement with held same-epoch guard and original keys.
// SPDX-License-Identifier: Apache-2.0
#![cfg(all(feature = "e2e-encryption", feature = "sqlite"))]
use matrix_sdk_base::{
    BaseClient, DmRoomDefinition, SessionMeta, ThreadingSupport,
    cross_process_lock::CrossProcessLockConfig,
    crypto::{
        DecryptionSettings, EncryptionSyncChanges, TrustRequirement,
        store::{CryptoStore, types::Changes},
    },
    store::{RoomLoadSettings, StoreConfig},
};
use matrix_sdk_sqlite::SqliteCryptoStore;
use ruma::{device_id, user_id};
use tempfile::TempDir;

async fn sync(
    machine: &matrix_sdk_base::crypto::OlmMachine,
    token: &str,
) -> Result<(), matrix_sdk_base::crypto::OlmError> {
    machine
        .receive_sync_changes(
            EncryptionSyncChanges {
                to_device_events: vec![],
                changed_devices: &Default::default(),
                one_time_keys_counts: &Default::default(),
                unused_fallback_keys: None,
                next_batch_token: Some(token.to_owned()),
            },
            &DecryptionSettings { sender_device_trust_requirement: TrustRequirement::Untrusted },
        )
        .await
        .map(|_| ())
}

#[tokio::test(flavor = "multi_thread")]
async fn invalidated_same_epoch_machine_is_replaced_and_old_clone_refuses_writes() {
    let temp = TempDir::new().unwrap();
    let raw = SqliteCryptoStore::open(temp.path(), Some("synthetic-rebuild-test")).await.unwrap();
    let config = CrossProcessLockConfig::multi_process("synthetic-rebuild-owner");
    let base = BaseClient::new(
        StoreConfig::new(config.clone()).crypto_store(raw.clone()),
        ThreadingSupport::Disabled,
        DmRoomDefinition::default(),
    );
    let control = base.create_crypto_store_lock(config).unwrap();
    let guard = control.try_lock_once().await.unwrap().unwrap().into_guard();
    base.activate(
        SessionMeta {
            user_id: user_id!("@synthetic:atum.invalid").to_owned(),
            device_id: device_id!("REBUILD").to_owned(),
        },
        RoomLoadSettings::All,
        None,
    )
    .await
    .unwrap();
    let old = base.olm_machine().await.as_ref().unwrap().clone();
    let original = old.identity_keys();
    old.store()
        .save_changes(Changes {
            next_batch_token: Some("durable-before-failure".into()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert!(
        !base.bind_olm_to_lease(&guard).await.unwrap(),
        "clean same epoch must preserve machine"
    );
    old.store().invalidate();
    assert!(!old.store().is_usable());
    assert!(
        base.bind_olm_to_lease(&guard).await.unwrap(),
        "failed same epoch must reconstruct rather than reuse"
    );
    let fresh = base.olm_machine().await.as_ref().unwrap().clone();
    assert!(fresh.store().is_usable());
    assert_eq!(
        fresh.identity_keys(),
        original,
        "reconstruction must preserve original crypto identity"
    );
    assert_eq!(
        fresh.store().next_batch_token().await.unwrap().as_deref(),
        Some("durable-before-failure")
    );
    assert!(
        old.store().set_custom_value("stale-clone", vec![1]).await.is_err(),
        "Deref store on a surviving old clone must refuse writes"
    );
    assert!(
        sync(&old, "stale-ack").await.is_err(),
        "old machine must refuse crypto acknowledgement after replacement"
    );
    sync(&fresh, "fresh-ack").await.unwrap();
    assert_eq!(raw.next_batch_token().await.unwrap().as_deref(), Some("fresh-ack"));
    assert!(raw.get_custom_value("stale-clone").await.unwrap().is_none());
    assert_eq!(raw.load_account().await.unwrap().unwrap().identity_keys(), original);
}
