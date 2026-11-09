// SPDX-License-Identifier: Apache-2.0
// Insert inside `crypto_store_wrapper.rs`'s `#[cfg(test)] mod test`.
// New contract: permanently refuse failed wrapper cache, reload durable state in a new wrapper.
#[derive(Clone, Copy)]
enum CancelPoint {
    BeforeCommit,
    AfterCommit,
    CacheTail,
    MutexWaiter,
}

async fn cancelled_publication_refuses_old_cache(point: CancelPoint) {
    let before_commit = matches!(point, CancelPoint::BeforeCommit);
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
    assert_ne!(
        first.session_id(),
        second.session_id(),
        "fixture requires distinct real Olm sessions"
    );

    let sender = peer.identity_keys().curve25519.to_base64();
    let own = DeviceData::from_account(&account);
    let user_id = account.user_id().to_owned();
    let device_id = account.device_id().to_owned();
    let backend = RefusingChangesStore::new();
    let wrapper = Arc::new(CryptoStoreWrapper::new(&user_id, &device_id, backend.clone()));
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

    let held_cache =
        if matches!(point, CancelPoint::CacheTail) { Some(seeded.lock().await) } else { None };
    let (committed, release) =
        if before_commit { backend.gate_before_next_commit() } else { backend.gate_next_commit() };
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
    assert_eq!(
        committed_ids.len(),
        if before_commit { 1 } else { 2 },
        "gate must expose only actually committed sessions"
    );
    assert!(committed_ids.contains(&first.session_id().to_owned()));
    assert_eq!(committed_ids.contains(&second.session_id().to_owned()), !before_commit);

    if matches!(point, CancelPoint::MutexWaiter) {
        let mut waiter = Box::pin(wrapper.save_changes(Changes::default()));
        assert!(
            futures_util::poll!(&mut waiter).is_pending(),
            "waiter must block before publication ownership"
        );
        drop(waiter);
        assert!(wrapper.is_usable(), "cancelled mutex waiter must not retire an active owner");
        release.notify_one();
        writer.await.unwrap().unwrap();
        let cached = wrapper.get_sessions(&sender).await.unwrap().unwrap();
        assert_eq!(cached.lock().await.len(), 2);
        return;
    }
    if matches!(point, CancelPoint::CacheTail) {
        release.notify_one();
        tokio::time::timeout(Duration::from_secs(1), async {
            while backend.finished_saves() != 1 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("backend must finish before aborting the cache tail");
        assert!(
            !writer.is_finished(),
            "held real cache mutex must block publication after returned persistence"
        );
    }
    writer.abort();
    assert!(
        writer.await.unwrap_err().is_cancelled(),
        "actual publication writer must be cancelled at its selected boundary"
    );
    drop(held_cache);

    assert!(!wrapper.is_usable(), "cancelled publication must retire its owning wrapper");
    let result =
        tokio::time::timeout(Duration::from_millis(100), wrapper.save_changes(Changes::default()))
            .await
            .expect("retired wrapper must refuse without waiting");
    assert!(
        matches!(result, Err(CryptoStoreError::Invalidated)),
        "retired wrapper must refuse later persistence"
    );
    assert!(
        matches!(wrapper.get_sessions(&sender).await, Err(CryptoStoreError::Invalidated)),
        "retired wrapper must not serve its stale cache"
    );
    assert_eq!(seeded.lock().await.len(), 1, "old retained Arc is isolated, not mutated in place");
    let rebuilt = CryptoStoreWrapper::new(&user_id, &device_id, backend.clone());
    let fresh = rebuilt.get_sessions(&sender).await.unwrap().unwrap();
    assert!(!Arc::ptr_eq(&seeded, &fresh), "durable reconstruction must use a distinct cache Arc");
    let mut fresh_ids: Vec<_> =
        fresh.lock().await.iter().map(|s| s.session_id().to_owned()).collect();
    fresh_ids.sort_unstable();
    assert_eq!(
        fresh_ids, committed_ids,
        "new wrapper must observe exact durable sessions after abort"
    );
}

#[async_test]
async fn test_committed_publication_abort_refuses_old_cache_and_reloads_two_sessions() {
    cancelled_publication_refuses_old_cache(CancelPoint::AfterCommit).await;
}

#[async_test]
async fn test_uncommitted_publication_abort_refuses_old_cache_without_phantom_session() {
    cancelled_publication_refuses_old_cache(CancelPoint::BeforeCommit).await;
}

#[async_test]
async fn test_cache_tail_abort_after_returned_persistence_refuses_old_cache() {
    cancelled_publication_refuses_old_cache(CancelPoint::CacheTail).await;
}

#[async_test]
async fn test_cancelled_publication_mutex_waiter_keeps_active_owner_usable() {
    cancelled_publication_refuses_old_cache(CancelPoint::MutexWaiter).await;
}
