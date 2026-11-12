# Element X notification lifecycle adaptation

Source: Element X iOS, revision `0f3b33c5ae3f9864197b20384e63286e4bfeb913`
(Apache-2.0). Only this historical revision was consulted.

- [NotificationServiceExtension.swift](https://github.com/element-hq/element-x-ios/blob/0f3b33c5ae3f9864197b20384e63286e4bfeb913/NSE/Sources/NotificationServiceExtension.swift), Copyright 2022 New Vector Ltd.
- [NSEUserSession.swift](https://github.com/element-hq/element-x-ios/blob/0f3b33c5ae3f9864197b20384e63286e4bfeb913/NSE/Sources/Other/NSEUserSession.swift), Copyright 2023 New Vector Ltd.
- [UNNotificationContent.swift](https://github.com/element-hq/element-x-ios/blob/0f3b33c5ae3f9864197b20384e63286e4bfeb913/ElementX/Sources/Other/Extensions/UNNotificationContent.swift) (`addSenderIcon`) and
  [NotificationContentBuilder.swift](https://github.com/element-hq/element-x-ios/blob/0f3b33c5ae3f9864197b20384e63286e4bfeb913/NSE/Sources/NotificationContentBuilder.swift) (`icon(for:)`), Copyright 2023 New Vector Ltd.
  Consulted at release tag `1.7.5` (`7b03c23baa7ee3fdc1a5ed1e29995d6f653c277e`,
  2024-09-04), the last Element X iOS release before the AGPL switch
  (`664e87fe87`, 2024-09-06). Both files, and the app/NSE entitlements and
  `NSUserActivityTypes` declaration, are byte-identical at `0f3b33c5ae`.

Licensed under the Apache License, Version 2.0 (the License); you may not use
these adaptations except in compliance with the License. You may obtain a copy
at <https://www.apache.org/licenses/LICENSE-2.0>. Unless required by applicable
law or agreed to in writing, software distributed under the License is
distributed on an AS IS BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
either express or implied. See the License for the specific language governing
permissions and limitations under the License.

The full Apache-2.0 license is bundled as `MatrixRustSDK-LICENSE.txt` in both
app and notification extension. The historical source files' copyright and
license attribution is retained above and in the adapted Swift file headers.

Modifications: Copyright 2026 Anka Ventures Vietnam Company Limited.
The adaptation uses Atum's fixed single-account custody record, a read-only
SDK session delegate, per-request SDK lifetime, overlapping-fetch refusal, a cancellation/deadline
completion gate, current generated Swift SDK APIs, exported Atum copy, safe
person names and badge-only suppression. It omits message media downloads,
calls, payload logging and SDK token persistence. Atum's own journaled OIDC
coordinator now renews the shared Matrix grant under an App Group file lock
before SDK construction; that renewal code is not copied from Element X. It does not copy Element X UI or
its user-facing strings. The source pattern is used in
`Notifications/NotificationService.swift` and `Notifications/MatrixNotificationFetcher.swift`.

Communication notifications (2026-11-11) adapt the `addSenderIcon` pattern in
`Notifications/CommunicationNotification.swift`: one `INPerson` sender with an
`INPersonHandle` of the Matrix user ID; in a group, `speakableGroupName`, the
sender and an `isMe` recipient, and the image set on `\.speakableGroupName`
instead of the sender; an incoming `INInteraction` donated before
`content.updating(from:)`; a placeholder image when no avatar loads; and the
DM-versus-group split of `icon(for:)` (sender avatar for a DM, room avatar for
a group). Atum's changes: the room kind and image order come from a
`CommunicationNotificationPolicy` plan that also covers assistant/app chats
(the app's drawn header face) and Team Space channels/conversations (Team Space
name, company-logo fallback); avatars are fetched with the SDK's
`getMediaThumbnail` under a two-second deadline, normalised to 192 px and kept
in a capped App Group cache; the placeholder is Atum's own Kit monogram drawn
with Core Graphics (not Element X's `PlaceholderAvatarImage`); donation has a
deadline and any failure keeps the plain rich content; there is no upside-down
flip workaround (iOS 26 only) and no logging of names, IDs or URLs. No Element X
UI, strings, images or the placeholder view are copied.
