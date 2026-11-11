# Element X notification lifecycle adaptation

Source: Element X iOS, revision `0f3b33c5ae3f9864197b20384e63286e4bfeb913`
(Apache-2.0). Only this historical revision was consulted.

- [NotificationServiceExtension.swift](https://github.com/element-hq/element-x-ios/blob/0f3b33c5ae3f9864197b20384e63286e4bfeb913/NSE/Sources/NotificationServiceExtension.swift), Copyright 2022 New Vector Ltd.
- [NSEUserSession.swift](https://github.com/element-hq/element-x-ios/blob/0f3b33c5ae3f9864197b20384e63286e4bfeb913/NSE/Sources/Other/NSEUserSession.swift), Copyright 2023 New Vector Ltd.

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
The adaptation uses Atum's fixed single-account read-only custody record,
per-request SDK lifetime, overlapping-fetch refusal, a cancellation/deadline
completion gate, current generated Swift SDK APIs, exported Atum copy, safe
person names and badge-only suppression. It omits media downloads, intents,
calls, payload logging and token persistence. It does not copy Element X UI or
its user-facing strings. The source pattern is used in
`Notifications/NotificationService.swift` and `Notifications/MatrixNotificationFetcher.swift`.
