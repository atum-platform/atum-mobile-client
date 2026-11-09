// SPDX-License-Identifier: Apache-2.0
// Insert inside `crypto_store_wrapper.rs`'s `#[cfg(test)] mod test`.
// This deliberately fails until a committed save cancelled before publication
// leaves the wrapper cache reconciled with its real backing store.
#[async_test]
async fn test_committed_save_cancellation_diverges_cached_sessions() {
    use super::super::traits::{CryptoStore, atum_publication_store::RefusingChangesStore};
    use crate::{Account, DeviceData, store::types::PendingChanges};
    use ruma::device_id;
    use std::time::Duration;
    use vodozemac::olm::SessionConfig;

    let account =
        Account::with_device_id(user_id!("@synthetic:atum.invalid"), device_id!("CANCEL"));
    let mut peer = Account::with_device_id(user_id!("@peer:atum.invalid"), device_id!("PEER"));
    peer.generate_one_time_keys(2);
    let keys: Vec<_> = peer.one_time_keys().values().copied().collect();
    let make_session = |key| {
        account
            .create_outbound_session_helper(
                SessionConfig::version_1(),
                peer.identity_keys().curve25519,
                key,
                false,
                account.device_keys(),
            )
            .unwrap()
    };
    let first = make_session(keys[0]);
    let second = make_session(keys[1]);
    assert_ne!(first.session_id(), second.session_id(), "fixture requires distinct real Olm sessions");

    let sender = peer.identity_keys().curve25519.to_base64();
    let own = DeviceData::from_account(&account);
    let user_id = account.user_id().to_owned();
    let device_id = account.device_id().to_owned();
    let backend = RefusingChangesStore::new();
    let wrapper = Arc::new(CryptoStoreWrapper::new(
        &user_id,
        &device_id,
        backend.clone(),
    ));
    wrapper.save_pending_changes(PendingChanges { account: Some(account) }).await.unwrap();
    wrapper
        .save_changes(Changes {
            sessions: vec![first.clone()],
            devices: DeviceChanges { new: vec![own], ..Default::default() },
            ..Default::default()
        })
        .await
        .unwrap();
    let seeded = wrapper.get_sessions(&sender).await.unwrap().unwrap();
    assert_eq!(seeded.lock().await.len(), 1, "first committed session must seed the wrapper cache");

    let (committed, _release) = backend.gate_next_commit();
    let second_for_writer = second.clone();
    let writer = tokio::spawn({
        let wrapper = wrapper.clone();
        async move {
            wrapper
                .save_changes(Changes { sessions: vec![second_for_writer], ..Default::default() })
                .await
        }
    });
    committed.notified().await;

    let mut committed_ids: Vec<_> = backend
        .get_sessions(&sender)
        .await
        .unwrap()
        .unwrap()
        .into_iter()
        .map(|session| session.session_id().to_owned())
        .collect();
    committed_ids.sort_unstable();
    assert_eq!(committed_ids.len(), 2, "post-commit gate must expose both actual sessions");
    assert!(committed_ids.contains(&first.session_id().to_owned()));
    assert!(committed_ids.contains(&second.session_id().to_owned()));

    writer.abort();
    assert!(writer.await.unwrap_err().is_cancelled(), "writer must be cancelled after durable commit");

    tokio::time::timeout(Duration::from_millis(100), wrapper.save_changes(Changes::default()))
        .await
        .expect("cancelled writer permanently wedged later saves")
        .expect("following save failed after writer cancellation");

    let cached = wrapper.get_sessions(&sender).await.unwrap().unwrap();
    assert!(
        Arc::ptr_eq(&seeded, &cached),
        "cancellation must not replace the originally seeded cache entry"
    );
    let mut cached_ids: Vec<_> =
        cached.lock().await.iter().map(|session| session.session_id().to_owned()).collect();
    cached_ids.sort_unstable();
    assert_eq!(
        cached_ids, committed_ids,
        "committed-write cancellation cache divergence: wrapper cache must match the durable MemoryStore"
    );
}
