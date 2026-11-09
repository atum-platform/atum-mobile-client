import Foundation

/// A plain-value crash event. The app maps Sentry's `Event` into this shape,
/// scrubs it here, and maps the result back. Keeping the rules independent of
/// the vendor types makes every sanitization decision unit-testable.
public struct ScrubbableCrashEvent: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public var fileName: String?
        public var package: String?
        public var contextLine: String?

        public init(fileName: String? = nil, package: String? = nil, contextLine: String? = nil) {
            self.fileName = fileName
            self.package = package
            self.contextLine = contextLine
        }
    }

    public struct Mechanism: Equatable, Sendable {
        public var type: String?
        /// Only whether vendor data is present; its free-form contents never
        /// leave the phone, so the scrubber does not need to carry them.
        public var hasData: Bool

        public init(type: String? = nil, hasData: Bool = false) {
            self.type = type
            self.hasData = hasData
        }
    }

    public struct Exception: Equatable, Sendable {
        public var type: String?
        public var value: String?
        public var mechanism: Mechanism?
        public var frames: [Frame]?

        public init(type: String? = nil, value: String? = nil,
                    mechanism: Mechanism? = nil, frames: [Frame]? = nil) {
            self.type = type
            self.value = value
            self.mechanism = mechanism
            self.frames = frames
        }
    }

    public struct Thread: Equatable, Sendable {
        public var name: String?
        public var frames: [Frame]?

        public init(name: String? = nil, frames: [Frame]? = nil) {
            self.name = name
            self.frames = frames
        }
    }

    public struct DebugImage: Equatable, Sendable {
        public var codeFile: String?

        public init(codeFile: String? = nil) {
            self.codeFile = codeFile
        }
    }

    public var message: String?
    public var hasUser: Bool
    public var hasRequest: Bool
    public var breadcrumbCount: Int
    public var extraKeyCount: Int
    public var transaction: String?
    public var tags: [String: String]
    public var exceptions: [Exception]
    public var threads: [Thread]
    public var debugImages: [DebugImage]

    public init(message: String? = nil, hasUser: Bool = false, hasRequest: Bool = false,
                breadcrumbCount: Int = 0, extraKeyCount: Int = 0, transaction: String? = nil,
                tags: [String: String] = [:], exceptions: [Exception] = [],
                threads: [Thread] = [], debugImages: [DebugImage] = []) {
        self.message = message
        self.hasUser = hasUser
        self.hasRequest = hasRequest
        self.breadcrumbCount = breadcrumbCount
        self.extraKeyCount = extraKeyCount
        self.transaction = transaction
        self.tags = tags
        self.exceptions = exceptions
        self.threads = threads
        self.debugImages = debugImages
    }
}

/// Removes everything that could carry content or identity from a crash event.
/// This is a denylist of fields, so the input shape is deliberately closed: no
/// vendor field can bypass it without adding a new field here first.
public enum CrashEventScrubber {
    public static func scrub(_ event: ScrubbableCrashEvent) -> ScrubbableCrashEvent {
        var clean = event
        clean.message = nil
        clean.hasUser = false
        clean.hasRequest = false
        clean.breadcrumbCount = 0
        clean.extraKeyCount = 0
        clean.transaction = nil
        clean.tags.removeAll()
        clean.exceptions = event.exceptions.map { exception in
            var cleanException = exception
            cleanException.value = exception.type
            if let mechanism = exception.mechanism {
                cleanException.mechanism = ScrubbableCrashEvent.Mechanism(type: mechanism.type, hasData: false)
            }
            cleanException.frames = exception.frames?.map(sanitize)
            return cleanException
        }
        clean.threads = event.threads.map { thread in
            var cleanThread = thread
            cleanThread.name = nil
            cleanThread.frames = thread.frames?.map(sanitize)
            return cleanThread
        }
        clean.debugImages = event.debugImages.map { image in
            var cleanImage = image
            if let codeFile = image.codeFile {
                cleanImage.codeFile = TelemetrySanitizer.fileName(codeFile)
            }
            return cleanImage
        }
        return clean
    }

    private static func sanitize(_ frame: ScrubbableCrashEvent.Frame) -> ScrubbableCrashEvent.Frame {
        var clean = frame
        if let fileName = frame.fileName {
            clean.fileName = TelemetrySanitizer.fileName(fileName)
        }
        clean.package = nil
        clean.contextLine = nil
        return clean
    }
}
