// Actual SDK operation lifetimes on disposable encrypted SQLite stores.
// SPDX-License-Identifier: Apache-2.0
#![cfg(all(feature = "e2e-encryption", feature = "sqlite"))]

use std::{path::Path, sync::Arc, time::Duration};

use matrix_sdk::{
    Client, SessionMeta, SessionTokens,
    authentication::oauth::{OAuthSession, UserSession},
    config::RequestConfig,
    sliding_sync::{SlidingSyncList, Version},
};
use matrix_sdk_base::{
    BaseClient, DmRoomDefinition, ThreadingSupport,
    cross_process_lock::{CrossProcessLock, CrossProcessLockConfig},
    crypto::{
        OlmMachineBuilder,
        store::{CRYPTO_STORE_LOCK_KEY, CryptoStore, LockableCryptoStore},
    },
    store::{RoomLoadSettings, StoreConfig},
};
use matrix_sdk_sqlite::SqliteCryptoStore;
use oauth2::ClientId;
use ruma::{api::MatrixVersion, device_id, events::direct::DirectEvent, user_id};
use serde_json::json;
use tempfile::TempDir;
use tokio::sync::Notify;
use wiremock::{
    Mock, MockServer, Request, ResponseTemplate,
    matchers::{method, path_regex},
};

const PASSPHRASE: &str = "synthetic-protected-task-store";
const EXPIRE_WAIT: Duration = Duration::from_millis(1200);

fn session() -> OAuthSession {
    OAuthSession {
        client_id: ClientId::new("synthetic-protected-task-client".into()),
        user: UserSession {
            meta: SessionMeta {
                user_id: user_id!("@synthetic:atum.invalid").to_owned(),
                device_id: device_id!("PROTECTED").to_owned(),
            },
            tokens: SessionTokens {
                access_token: "synthetic-not-an-access-token".into(),
                refresh_token: None,
            },
        },
    }
}

async fn seed(path: &Path) -> (String, String) {
    let store = SqliteCryptoStore::open(path, Some(PASSPHRASE)).await.unwrap();
    let meta = session().user.meta;
    let machine = OlmMachineBuilder::new(&meta.user_id, &meta.device_id)
        .with_crypto_store(store.clone())
        .build()
        .await
        .unwrap();
    let keys = machine.identity_keys();
    let keys = (keys.curve25519.to_base64(), keys.ed25519.to_base64());
    drop(machine);
    store.close().await.unwrap();
    keys
}

async fn client(path: &Path, server: &MockServer, keys: &(String, String)) -> Client {
    let client = Client::builder()
        .homeserver_url(server.uri())
        .disable_well_known_lookup(true)
        .server_versions([MatrixVersion::V1_12])
        .request_config(RequestConfig::new().disable_retry())
        .sqlite_store(path, Some(PASSPHRASE))
        .cross_process_store_config(CrossProcessLockConfig::multi_process("operation-A"))
        .build()
        .await
        .unwrap();
    client
        .restore_session_existing(session(), RoomLoadSettings::All, keys.0.clone(), keys.1.clone())
        .await
        .unwrap();
    client
}

async fn contender(path: &Path) -> (SqliteCryptoStore, CrossProcessLock<LockableCryptoStore>) {
    let store = SqliteCryptoStore::open(path, Some(PASSPHRASE)).await.unwrap();
    let lock = CrossProcessLock::new(
        LockableCryptoStore::new(store.clone()),
        CRYPTO_STORE_LOCK_KEY.into(),
        CrossProcessLockConfig::multi_process("operation-B"),
    );
    (store, lock)
}

async fn released(lock: &CrossProcessLock<LockableCryptoStore>) {
    let guard = tokio::time::timeout(Duration::from_secs(5), lock.spin_lock(Some(500)))
        .await
        .expect("operation must release its guard")
        .unwrap()
        .unwrap()
        .into_guard();
    drop(guard);
}

async fn upload_mock(server: &MockServer, entered: Arc<Notify>, delay: Duration) {
    Mock::given(method("POST"))
        .and(path_regex(r"^/_matrix/client/(v3|r0)/keys/upload$"))
        .respond_with(move |_: &Request| {
            entered.notify_one();
            ResponseTemplate::new(200)
                .set_body_json(json!({"one_time_key_counts": {"signed_curve25519": 50}}))
                .set_delay(delay)
        })
        .expect(1)
        .mount(server)
        .await;
}

async fn sync_mock(server: &MockServer, delay: Duration, direct_event: bool) {
    let mut body = json!({"pos": "committed-pos", "lists": {},
        "extensions": {"e2ee": {"device_one_time_keys_count": {"signed_curve25519": 50}},
        "to_device": {"next_batch": "committed-to-device", "events": []}}});
    if direct_event {
        body["extensions"]["account_data"] =
            json!({"global": [{"type": "m.direct", "content": {}}]});
    }
    Mock::given(method("POST"))
        .and(path_regex(r"^/_matrix/client/unstable/org.matrix.simplified_msc3575/sync$"))
        .respond_with(ResponseTemplate::new(200).set_body_json(body).set_delay(delay))
        .expect(1)
        .mount(server)
        .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn outgoing_upload_owns_lease_after_outer_guard_drop_and_commits_ack() {
    let dir = TempDir::new().unwrap();
    let server = MockServer::start().await;
    let keys = seed(dir.path()).await;
    let client = client(dir.path(), &server, &keys).await;
    let outer = client.encryption().spin_lock_store(None).await.unwrap().unwrap();
    let (store_b, lock_b) = contender(dir.path()).await;
    let upload_entered = Arc::new(Notify::new());
    upload_mock(&server, upload_entered.clone(), Duration::from_secs(3)).await;
    sync_mock(&server, Duration::from_secs(4), false).await;
    let sync = client
        .sliding_sync("outgoing")
        .unwrap()
        .version(Version::Native)
        .with_all_extensions()
        .build()
        .await
        .unwrap();
    let task = tokio::spawn(async move { sync.sync_once().await });
    tokio::time::timeout(Duration::from_secs(5), upload_entered.notified()).await.unwrap();
    drop(outer);
    tokio::time::sleep(EXPIRE_WAIT).await;
    assert!(
        lock_b.try_lock_once().await.unwrap().is_err(),
        "outgoing HTTP operation must retain the lease after caller guard drop"
    );
    tokio::time::timeout(Duration::from_secs(8), task).await.unwrap().unwrap().unwrap();
    let account = store_b.load_account().await.unwrap().unwrap();
    assert!(account.shared(), "actual keys/upload acknowledgement must persist");
    assert_eq!(account.uploaded_key_count(), 50);
    assert_eq!(
        (
            account.identity_keys().curve25519.to_base64(),
            account.identity_keys().ed25519.to_base64()
        ),
        keys
    );
    released(&lock_b).await;
    client.pause().await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn outgoing_upload_cancellation_releases_guard_without_sync_ack() {
    let dir = TempDir::new().unwrap();
    let server = MockServer::start().await;
    let keys = seed(dir.path()).await;
    let client = client(dir.path(), &server, &keys).await;
    let outer = client.encryption().spin_lock_store(None).await.unwrap().unwrap();
    let (store_b, lock_b) = contender(dir.path()).await;
    let upload_entered = Arc::new(Notify::new());
    upload_mock(&server, upload_entered.clone(), Duration::from_secs(10)).await;
    sync_mock(&server, Duration::from_secs(10), false).await;
    let sync = client
        .sliding_sync("abort-upload")
        .unwrap()
        .version(Version::Native)
        .with_all_extensions()
        .build()
        .await
        .unwrap();
    let task = tokio::spawn(async move { sync.sync_once().await });
    tokio::time::timeout(Duration::from_secs(5), upload_entered.notified()).await.unwrap();
    drop(outer);
    tokio::time::sleep(EXPIRE_WAIT).await;
    assert!(
        lock_b.try_lock_once().await.unwrap().is_err(),
        "cancellable upload must retain the lease until its task is aborted"
    );
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    released(&lock_b).await;
    assert!(store_b.next_batch_token().await.unwrap().is_none());
    assert!(!store_b.load_account().await.unwrap().unwrap().shared());
    client.pause().await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn detached_response_retains_lease_and_position_after_caller_cancellation() {
    detached_response_cancellation(true).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn room_only_detached_response_retains_crypto_position_lease_after_cancellation() {
    detached_response_cancellation(false).await;
}

async fn detached_response_cancellation(e2ee: bool) {
    let dir = TempDir::new().unwrap();
    let server = MockServer::start().await;
    let keys = seed(dir.path()).await;
    let client = client(dir.path(), &server, &keys).await;
    let outer = client.encryption().spin_lock_store(None).await.unwrap().unwrap();
    let (store_b, lock_b) = contender(dir.path()).await;
    if e2ee {
        upload_mock(&server, Arc::new(Notify::new()), Duration::ZERO).await;
    }
    sync_mock(&server, Duration::ZERO, true).await;
    let handler_entered = Arc::new(Notify::new());
    let handler_release = Arc::new(Notify::new());
    let entered = handler_entered.clone();
    let release = handler_release.clone();
    client.add_event_handler(move |_: DirectEvent| {
        let entered = entered.clone();
        let release = release.clone();
        async move {
            entered.notify_one();
            release.notified().await;
        }
    });
    let sync = client
        .sliding_sync("detached")
        .unwrap()
        .version(Version::Native)
        .add_list(SlidingSyncList::builder("rooms"))
        .with_all_extensions();
    let sync =
        if e2ee { sync } else { sync.without_e2ee_extension().without_to_device_extension() };
    let sync = sync.build().await.unwrap();
    let task = tokio::spawn(async move { sync.sync_once().await });
    tokio::time::timeout(Duration::from_secs(5), handler_entered.notified()).await.unwrap();
    // Crypto has persisted before handlers run, but position storage is still pending.
    assert_eq!(
        store_b.next_batch_token().await.unwrap().as_deref(),
        e2ee.then_some("committed-to-device")
    );
    let position_key = "sliding_sync_store::detached::@synthetic:atum.invalid::instance";
    assert!(store_b.get_custom_value(position_key).await.unwrap().is_none());
    task.abort();
    assert!(task.await.unwrap_err().is_cancelled());
    drop(outer);
    tokio::time::sleep(EXPIRE_WAIT).await;
    assert!(
        lock_b.try_lock_once().await.unwrap().is_err(),
        "detached response must retain the lease after caller cancellation"
    );
    handler_release.notify_one();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(blob) = store_b.get_custom_value(position_key).await.unwrap() {
                assert_eq!(
                    serde_json::from_slice::<serde_json::Value>(&blob).unwrap()["pos"],
                    "committed-pos"
                );
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("detached response must finish position persistence");
    released(&lock_b).await;
    let account = store_b.load_account().await.unwrap().unwrap();
    assert_eq!(
        (
            account.identity_keys().curve25519.to_base64(),
            account.identity_keys().ed25519.to_base64()
        ),
        keys
    );
    client.pause().await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn same_epoch_binding_does_not_wait_for_existing_machine_reader() {
    let dir = TempDir::new().unwrap();
    seed(dir.path()).await;
    let store = SqliteCryptoStore::open(dir.path(), Some(PASSPHRASE)).await.unwrap();
    let config = CrossProcessLockConfig::multi_process("reader-A");
    let base = BaseClient::new(
        StoreConfig::new(config.clone()).crypto_store(store),
        ThreadingSupport::Disabled,
        DmRoomDefinition::default(),
    );
    let lock = base.create_crypto_store_lock(config).unwrap();
    let guard = lock.try_lock_once().await.unwrap().unwrap().into_guard();
    base.activate(session().user.meta, RoomLoadSettings::All, None).await.unwrap();
    let reader = base.olm_machine().await;
    let old_keys = reader.as_ref().unwrap().identity_keys();
    assert!(
        !tokio::time::timeout(Duration::from_secs(1), base.bind_olm_to_lease(&guard))
            .await
            .expect("same-epoch binding must not require machine WRITE while a reader is retained")
            .unwrap()
    );
    assert_eq!(reader.as_ref().unwrap().identity_keys(), old_keys);
    drop(reader);
    drop(guard);
}
