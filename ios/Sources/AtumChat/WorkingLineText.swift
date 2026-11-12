import Foundation

/// What a live working line says, split as desktop's `MatrixAgentWorking`
/// splits it (`src/matrix/typing-indicator.tsx`): the first non-empty line is
/// the current step, shown beside the atom; every later line is a step of the
/// quiet checklist under it. The publisher writes the checklist as
/// "✓ done" and "• to do" rows (`shared/matrix-progress-kernel.ts`).
public struct WorkingLineText: Equatable, Sendable {
    public struct Step: Equatable, Hashable, Sendable {
        public var text: String
        public var done: Bool

        public init(text: String, done: Bool) {
            self.text = text
            self.done = done
        }
    }

    /// "Đang chạy tác vụ…", "Đang tra cứu trên web…", a wait line. Nil when
    /// the body is blank: the atom then shows alone.
    public var current: String?
    public var steps: [Step]

    public init(current: String?, steps: [Step]) {
        self.current = current
        self.steps = steps
    }

    public init(body: String) {
        let lines = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        current = lines.first
        steps = lines.dropFirst().map { line in
            // Desktop's regex consumes one marker scalar, even when it is
            // followed by a variation selector (one Swift Character).
            let first = line.unicodeScalars.first
            let done = first == "✓" || first == "✔"
            let text = line.replacingOccurrences(of: "^[✓✔•◦]\\s*", with: "",
                                                 options: .regularExpression)
            return Step(text: text, done: done)
        }
    }
}
