    #[async_test]
    async fn test_concurrent_clear_then_add_publishes_in_commit_order() {
        use super::super::traits::atum_publication_store::RefusingChangesStore;
        use crate::{Account, DeviceData, store::types::PendingChanges};
        use ruma::device_id;
        use vodozemac::olm::SessionConfig;

        let account =
            Account::with_device_id(user_id!("@synthetic:atum.invalid"), device_id!("ORDER"));
        let mut peer = Account::with_device_id(user_id!("@peer:atum.invalid"), device_id!("PEER"));
        peer.generate_one_time_keys(1);
        let key = *peer.one_time_keys().values().next().unwrap();
        let session = account
            .create_outbound_session_helper(
                SessionConfig::version_1(),
                peer.identity_keys().curve25519,
                key,
                false,
                account.device_keys(),
            )
            .unwrap();
        let sender = peer.identity_keys().curve25519.to_base64();
        let own = DeviceData::from_account(&account);
        let backend = RefusingChangesStore::new();
        let wrapper = Arc::new(CryptoStoreWrapper::new(
            account.user_id(),
            account.device_id(),
            backend.clone(),
        ));
        wrapper.save_pending_changes(PendingChanges { account: Some(account) }).await.unwrap();
        wrapper
            .save_changes(Changes {
                devices: DeviceChanges { new: vec![own.clone()], ..Default::default() },
                ..Default::default()
            })
            .await
            .unwrap();
        // The first real commit changes our device and will clear the cache.
        // Hold its return to model a delayed writer after successful persistence.
        let (committed, release) = backend.gate_next_commit();
        let first_wrapper = wrapper.clone();
        let first = tokio::spawn(async move {
            first_wrapper
                .save_changes(Changes {
                    devices: DeviceChanges { changed: vec![own], ..Default::default() },
                    ..Default::default()
                })
                .await
        });
        committed.notified().await;
        let mut second = Box::pin(
            wrapper.save_changes(Changes { sessions: vec![session.clone()], ..Default::default() }),
        );
        // The later save must stop before persistence while publication is gated.
        let second_poll = futures_util::poll!(&mut second);
        assert_eq!(
            backend.started_saves(),
            1,
            "second persistence must wait for first publication"
        );
        assert!(second_poll.is_pending());
        release.notify_one();
        first.await.unwrap().unwrap();
        second.await.unwrap();
        let cached =
            wrapper.sessions.get(&sender).await.expect("later committed session remains cached");
        let persisted = wrapper.store.get_sessions(&sender).await.unwrap().unwrap();
        assert_eq!(cached.lock().await.len(), persisted.len());
        assert_eq!(cached.lock().await[0].session_id(), session.session_id());
        assert_eq!(persisted[0].session_id(), session.session_id());
    }

