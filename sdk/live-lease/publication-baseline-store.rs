// Explicit persistence-refusal fixture for cache publication invariants.
// Actual MemoryStore and actual Olm sessions; no network or server account.
// SPDX-License-Identifier: Apache-2.0
use super::*;
use crate::store::MemoryStore;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex as StdMutex, atomic::AtomicUsize};
use tokio::sync::Notify;

#[derive(Clone, Debug)]
pub(crate) struct RefusingChangesStore {
    inner: Arc<MemoryStore>,
    refuse: Arc<AtomicBool>,
    gate: Arc<StdMutex<Option<(Arc<Notify>, Arc<Notify>)>>>,
    started: Arc<AtomicUsize>,
}
impl RefusingChangesStore {
    pub(crate) fn new() -> Self {
        Self {
            inner: Arc::new(MemoryStore::new()),
            refuse: Arc::new(AtomicBool::new(false)),
            gate: Default::default(),
            started: Default::default(),
        }
    }
    pub(crate) fn refuse(&self, value: bool) {
        self.refuse.store(value, Ordering::SeqCst);
    }
    pub(crate) fn gate_next_commit(&self) -> (Arc<Notify>, Arc<Notify>) {
        let pair = (Arc::new(Notify::new()), Arc::new(Notify::new()));
        *self.gate.lock().unwrap() = Some(pair.clone());
        self.started.store(0, Ordering::SeqCst);
        pair
    }
    pub(crate) fn started_saves(&self) -> usize {
        self.started.load(Ordering::SeqCst)
    }
}

#[cfg_attr(target_family = "wasm", async_trait(?Send))]
#[cfg_attr(not(target_family = "wasm"), async_trait)]
impl CryptoStore for RefusingChangesStore {
    type Error = CryptoStoreError;

    fn lease_scope(&self) -> Option<CrossProcessLockScope> {
        self.inner.lease_scope()
    }

    fn bind_lease(&self, guard: &CrossProcessLockGuard) -> Result<Arc<DynCryptoStore>> {
        self.inner.bind_lease(guard)
    }

    async fn load_account(&self) -> Result<Option<Account>> {
        self.inner.load_account().await.map_err(Into::into)
    }

    async fn load_identity(&self) -> Result<Option<PrivateCrossSigningIdentity>> {
        self.inner.load_identity().await.map_err(Into::into)
    }

    async fn save_changes(&self, changes: Changes) -> Result<()> {
        self.started.fetch_add(1, Ordering::SeqCst);
        let gate = self.gate.lock().unwrap().take();
        if self.refuse.load(Ordering::SeqCst) {
            return Err(CryptoStoreError::LeaseBindingUnsupported);
        }
        self.inner.save_changes(changes).await.map_err(CryptoStoreError::from)?;
        if let Some((committed, release)) = gate {
            committed.notify_one();
            release.notified().await;
        }
        Ok(())
    }

    async fn save_pending_changes(&self, changes: PendingChanges) -> Result<()> {
        self.inner.save_pending_changes(changes).await.map_err(Into::into)
    }

    async fn save_inbound_group_sessions(
        &self,
        sessions: Vec<InboundGroupSession>,
        backed_up_to_version: Option<&str>,
    ) -> Result<()> {
        self.inner
            .save_inbound_group_sessions(sessions, backed_up_to_version)
            .await
            .map_err(Into::into)
    }

    async fn get_sessions(&self, sender_key: &str) -> Result<Option<Vec<Session>>> {
        self.inner.get_sessions(sender_key).await.map_err(Into::into)
    }

    async fn get_inbound_group_session(
        &self,
        room_id: &RoomId,
        session_id: &str,
    ) -> Result<Option<InboundGroupSession>> {
        self.inner.get_inbound_group_session(room_id, session_id).await.map_err(Into::into)
    }

    async fn get_inbound_group_sessions(&self) -> Result<Vec<InboundGroupSession>> {
        self.inner.get_inbound_group_sessions().await.map_err(Into::into)
    }

    async fn get_inbound_group_sessions_by_room_id(
        &self,
        room_id: &RoomId,
    ) -> Result<Vec<InboundGroupSession>> {
        self.inner.get_inbound_group_sessions_by_room_id(room_id).await.map_err(Into::into)
    }

    async fn get_inbound_group_sessions_for_device_batch(
        &self,
        curve_key: Curve25519PublicKey,
        sender_data_type: SenderDataType,
        after_session_id: Option<String>,
        limit: usize,
    ) -> Result<Vec<InboundGroupSession>> {
        self.inner
            .get_inbound_group_sessions_for_device_batch(
                curve_key,
                sender_data_type,
                after_session_id,
                limit,
            )
            .await
            .map_err(Into::into)
    }

    async fn inbound_group_session_counts(
        &self,
        backup_version: Option<&str>,
    ) -> Result<RoomKeyCounts> {
        self.inner.inbound_group_session_counts(backup_version).await.map_err(Into::into)
    }
    async fn inbound_group_sessions_for_backup(
        &self,
        backup_version: &str,
        limit: usize,
    ) -> Result<Vec<InboundGroupSession>> {
        self.inner
            .inbound_group_sessions_for_backup(backup_version, limit)
            .await
            .map_err(Into::into)
    }

    async fn mark_inbound_group_sessions_as_backed_up(
        &self,
        backup_version: &str,
        room_and_session_ids: &[(&RoomId, &str)],
    ) -> Result<()> {
        self.inner
            .mark_inbound_group_sessions_as_backed_up(backup_version, room_and_session_ids)
            .await
            .map_err(Into::into)
    }

    async fn reset_backup_state(&self) -> Result<()> {
        self.inner.reset_backup_state().await.map_err(Into::into)
    }

    async fn load_backup_keys(&self) -> Result<BackupKeys> {
        self.inner.load_backup_keys().await.map_err(Into::into)
    }

    async fn load_dehydrated_device_pickle_key(&self) -> Result<Option<DehydratedDeviceKey>> {
        self.inner.load_dehydrated_device_pickle_key().await.map_err(Into::into)
    }

    async fn delete_dehydrated_device_pickle_key(&self) -> Result<(), Self::Error> {
        self.inner.delete_dehydrated_device_pickle_key().await.map_err(Into::into)
    }

    async fn get_outbound_group_session(
        &self,
        room_id: &RoomId,
    ) -> Result<Option<OutboundGroupSession>> {
        self.inner.get_outbound_group_session(room_id).await.map_err(Into::into)
    }

    async fn load_tracked_users(&self) -> Result<Vec<TrackedUser>> {
        self.inner.load_tracked_users().await.map_err(Into::into)
    }

    async fn save_tracked_users(&self, users: &[(&UserId, bool)]) -> Result<()> {
        self.inner.save_tracked_users(users).await.map_err(Into::into)
    }

    async fn get_device(
        &self,
        user_id: &UserId,
        device_id: &DeviceId,
    ) -> Result<Option<DeviceData>> {
        self.inner.get_device(user_id, device_id).await.map_err(Into::into)
    }

    async fn get_user_devices(
        &self,
        user_id: &UserId,
    ) -> Result<HashMap<OwnedDeviceId, DeviceData>> {
        self.inner.get_user_devices(user_id).await.map_err(Into::into)
    }

    async fn get_own_device(&self) -> Result<DeviceData> {
        self.inner.get_own_device().await.map_err(Into::into)
    }

    async fn get_user_identity(&self, user_id: &UserId) -> Result<Option<UserIdentityData>> {
        self.inner.get_user_identity(user_id).await.map_err(Into::into)
    }

    async fn is_message_known(&self, message_hash: &OlmMessageHash) -> Result<bool> {
        self.inner.is_message_known(message_hash).await.map_err(Into::into)
    }

    async fn get_outgoing_secret_requests(
        &self,
        request_id: &TransactionId,
    ) -> Result<Option<GossipRequest>> {
        self.inner.get_outgoing_secret_requests(request_id).await.map_err(Into::into)
    }

    async fn get_secret_request_by_info(
        &self,
        secret_info: &SecretInfo,
    ) -> Result<Option<GossipRequest>> {
        self.inner.get_secret_request_by_info(secret_info).await.map_err(Into::into)
    }

    async fn get_unsent_secret_requests(&self) -> Result<Vec<GossipRequest>> {
        self.inner.get_unsent_secret_requests().await.map_err(Into::into)
    }

    async fn delete_outgoing_secret_requests(&self, request_id: &TransactionId) -> Result<()> {
        self.inner.delete_outgoing_secret_requests(request_id).await.map_err(Into::into)
    }

    async fn get_secrets_from_inbox(
        &self,
        secret_name: &SecretName,
    ) -> Result<Vec<Zeroizing<String>>> {
        self.inner.get_secrets_from_inbox(secret_name).await.map_err(Into::into)
    }

    async fn delete_secrets_from_inbox(&self, secret_name: &SecretName) -> Result<()> {
        self.inner.delete_secrets_from_inbox(secret_name).await.map_err(Into::into)
    }

    async fn get_withheld_info(
        &self,
        room_id: &RoomId,
        session_id: &str,
    ) -> Result<Option<RoomKeyWithheldEntry>, Self::Error> {
        self.inner.get_withheld_info(room_id, session_id).await.map_err(Into::into)
    }

    async fn get_withheld_sessions_by_room_id(
        &self,
        room_id: &RoomId,
    ) -> Result<Vec<RoomKeyWithheldEntry>, Self::Error> {
        self.inner.get_withheld_sessions_by_room_id(room_id).await.map_err(Into::into)
    }

    async fn get_room_settings(&self, room_id: &RoomId) -> Result<Option<RoomSettings>> {
        self.inner.get_room_settings(room_id).await.map_err(Into::into)
    }

    async fn get_received_room_key_bundle_data(
        &self,
        room_id: &RoomId,
        user_id: &UserId,
    ) -> Result<Option<StoredRoomKeyBundleData>> {
        self.inner.get_received_room_key_bundle_data(room_id, user_id).await.map_err(Into::into)
    }

    async fn has_downloaded_all_room_keys(&self, room_id: &RoomId) -> Result<bool, Self::Error> {
        self.inner.has_downloaded_all_room_keys(room_id).await.map_err(Into::into)
    }

    async fn get_pending_key_bundle_details_for_room(
        &self,
        room_id: &RoomId,
    ) -> Result<Option<RoomPendingKeyBundleDetails>, Self::Error> {
        self.inner.get_pending_key_bundle_details_for_room(room_id).await.map_err(Into::into)
    }

    async fn get_all_rooms_pending_key_bundles(
        &self,
    ) -> Result<Vec<RoomPendingKeyBundleDetails>, Self::Error> {
        self.inner.get_all_rooms_pending_key_bundles().await.map_err(Into::into)
    }

    async fn get_custom_value(&self, key: &str) -> Result<Option<Vec<u8>>, Self::Error> {
        self.inner.get_custom_value(key).await.map_err(Into::into)
    }

    async fn set_custom_value(&self, key: &str, value: Vec<u8>) -> Result<(), Self::Error> {
        self.inner.set_custom_value(key, value).await.map_err(Into::into)
    }

    async fn remove_custom_value(&self, key: &str) -> Result<(), Self::Error> {
        self.inner.remove_custom_value(key).await.map_err(Into::into)
    }

    async fn try_take_leased_lock(
        &self,
        lease_duration_ms: u32,
        key: &str,
        holder: &str,
    ) -> Result<Option<CrossProcessLockGeneration>, Self::Error> {
        self.inner.try_take_leased_lock(lease_duration_ms, key, holder).await.map_err(Into::into)
    }

    async fn next_batch_token(&self) -> Result<Option<String>, Self::Error> {
        self.inner.next_batch_token().await.map_err(Into::into)
    }

    async fn close(&self) -> Result<(), Self::Error> {
        self.inner.close().await.map_err(Into::into)
    }

    async fn reopen(&self) -> Result<(), Self::Error> {
        self.inner.reopen().await.map_err(Into::into)
    }

    async fn get_size(&self) -> Result<Option<usize>, Self::Error> {
        self.inner.get_size().await.map_err(Into::into)
    }
}
