    #[async_test]
    async fn test_refused_save_neither_adds_nor_clears_session_cache() {
        use crate::{Account, DeviceData, store::types::PendingChanges};
        use super::super::traits::atum_publication_store::RefusingChangesStore;
        use ruma::device_id;
        use vodozemac::olm::SessionConfig;

        let account = Account::with_device_id(user_id!("@synthetic:atum.invalid"), device_id!("CACHE"));
        let mut peer = Account::with_device_id(user_id!("@peer:atum.invalid"), device_id!("PEER"));
        peer.generate_one_time_keys(2);
        let keys: Vec<_> = peer.one_time_keys().values().copied().collect();
        let make_session = |key| account.create_outbound_session_helper(
            SessionConfig::version_1(), peer.identity_keys().curve25519, key,
            false, account.device_keys()).unwrap();
        let first = make_session(keys[0]);
        let next = make_session(keys[1]);
        let sender = peer.identity_keys().curve25519.to_base64();
        let own = DeviceData::from_account(&account);
        let backend = RefusingChangesStore::new();
        let wrapper = CryptoStoreWrapper::new(account.user_id(), account.device_id(), backend.clone());
        wrapper.save_pending_changes(PendingChanges { account: Some(account) }).await.unwrap();
        wrapper.save_changes(Changes { sessions: vec![first.clone()],
                devices: DeviceChanges { new: vec![own.clone()], ..Default::default() }, ..Default::default() }).await.unwrap();
        let cached = wrapper.sessions.get(&sender).await.unwrap();
        assert_eq!(cached.lock().await.len(), 1);
        backend.refuse(true);

        assert!(wrapper.save_changes(Changes { sessions: vec![next.clone()], ..Default::default() }).await.is_err());
        assert_eq!(cached.lock().await.len(), 1, "refused session must not publish into the cache");
        assert_eq!(wrapper.store.get_sessions(&sender).await.unwrap().unwrap().len(), 1);

        assert!(wrapper.save_changes(Changes {
            devices: DeviceChanges { changed: vec![own.clone()], ..Default::default() },
            ..Default::default()
        }).await.is_err());
        assert!(Arc::ptr_eq(&cached, &wrapper.sessions.get(&sender).await.unwrap()),
            "refused device update must not clear the original cache");

        backend.refuse(false);
        wrapper.save_changes(Changes { sessions: vec![next], ..Default::default() }).await.unwrap();
        assert_eq!(cached.lock().await.len(), 2);
        assert_eq!(wrapper.store.get_sessions(&sender).await.unwrap().unwrap().len(), 2);
        wrapper.save_changes(Changes {
            devices: DeviceChanges { changed: vec![own], ..Default::default() },
            ..Default::default()
        }).await.unwrap();
        assert!(wrapper.sessions.get(&sender).await.is_none());
    }
