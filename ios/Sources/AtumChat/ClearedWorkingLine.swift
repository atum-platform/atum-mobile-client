import Foundation

/// Persisted self-redaction signal shared with desktop and cloud Hermes.
public enum ClearedWorkingLine {
    public static func matches(json: String?, originalSender: String) -> Bool {
        guard !originalSender.isEmpty, let data = json?.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let unsigned = event["unsigned"] as? [String: Any],
              let redaction = unsigned["redacted_because"] as? [String: Any],
              redaction["sender"] as? String == originalSender,
              let content = redaction["content"] as? [String: Any],
              content["reason"] as? String == "Turn ended" else { return false }
        return true
    }
}
