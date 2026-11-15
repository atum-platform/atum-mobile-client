#if DEBUG
import AVFoundation
import AtumNativeAPI
import Intents
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Debug only: `-AtumScriptedShare <scenario>` presents the share extension's real
/// picker (`SharePickerView` on a real `ShareComposerModel`, `ShareQueue` and
/// `ShareItemLoader`) as a sheet, so UI tests and screenshots can drive it on the
/// simulator. The queue lives in this app's temporary folder, never the App Group;
/// the account, chats and shared items are synthetic. `-AtumScriptedShareScheme
/// light|dark` pins the appearance. Release builds compile none of this.
enum ScriptedShareScenario: String, CaseIterable {
    /// A Share Suggestion tap: the intent names "Design team", preselected in Recent.
    case suggested
    /// The Atum icon in the share sheet: nothing preselected.
    case plain
    /// The last item never finishes copying, so the sheet stays in its loading state.
    case loading
    /// Atum has published no chats (signed out on this phone, or a first run).
    case empty
    /// The signed-in identity changed between snapshot and share.
    case failed

    static let flag = "-AtumScriptedShare"
    static let schemeFlag = "-AtumScriptedShareScheme"

    static func parse(_ arguments: [String]) -> ScriptedShareScenario? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return ScriptedShareScenario(rawValue: arguments[index + 1])
    }

    static func scheme(_ arguments: [String]) -> ColorScheme? {
        guard let index = arguments.firstIndex(of: schemeFlag), index + 1 < arguments.count else { return nil }
        return switch arguments[index + 1] { case "dark": .dark; case "light": .light; default: nil }
    }
}

struct ScriptedShareHost: View {
    let scenario: ScriptedShareScenario
    private let design = try! LiveDesign()
    private let forcedScheme = ScriptedShareScenario.scheme(ProcessInfo.processInfo.arguments)
    @State private var model: ShareComposerModel?
    @State private var presented = true
    @State private var outcome = "open"
    @State private var diagnostic = "pending"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            design.color("ground", scheme: scheme).ignoresSafeArea()
            VStack {
                Text(verbatim: outcome).accessibilityIdentifier("share.host.outcome")
                Text(verbatim: diagnostic).accessibilityIdentifier("share.host.diagnostic")
            }
        }
        .sheet(isPresented: $presented) {
            Group {
                if let model {
                    SharePickerView(model: model, avatars: ScriptedShareFixtures.avatars,
                                    finish: { outcome = "finished"; presented = false },
                                    cancel: { model.cancel(); outcome = "cancelled"; presented = false })
                }
            }
            .atumDesign(design)
            .interactiveDismissDisabled()
            .preferredColorScheme(forcedScheme)
        }
        .preferredColorScheme(forcedScheme)
        .atumDesign(design)
        .task {
            guard model == nil else { return }
            let made = try? ScriptedShareFixtures.model(scenario)
            model = made?.model
            guard let made else { diagnostic = "fixture failed"; return }
            diagnostic = await ScriptedShareFixtures.diagnose(made.diagnosable, queue: made.queue)
            await made.model.load(providers: made.providers, intent: made.intent)
        }
    }
}

@MainActor
enum ScriptedShareFixtures {
    static let account = ShareAccount(userID: "@owner:scripted.atum",
                                      generation: UUID(uuidString: "5C0E0000-0000-4000-8000-000000000001")!)
    static let suggestedRoom = "!design:scripted.atum"

    /// Recency order, as the app publishes it. "Design team" is seventh, so the
    /// suggestion visibly moves into Recent.
    static let chats: [ShareChat] = [
        chat("lan", "Lan Anh", .person, avatar: true),
        chat("atum", "Atum", .atum),
        chat("moon", "Moon", .app, avatar: true),
        chat("minh", "Minh Trần", .person),
        chat("family", "Family", .group, avatar: true),
        chat("kiwi", "Kiwi", .assistant, mark: AgentMark(shape: .spark, color: .mint)),
        chat("design", "Design team", .group),
        chat("hamy", "Hà My", .person, avatar: true),
        chat("bao", "Quốc Bảo", .person),
        chat("climb", "Weekend climbers", .group),
        chat("trang", "Thu Trang", .person, avatar: true),
        chat("andy", "Andy", .app),
    ]

    private static func chat(_ id: String, _ name: String, _ face: ShareChat.Face, avatar: Bool = false,
                             mark: AgentMark? = nil) -> ShareChat {
        ShareChat(id: "!\(id):scripted.atum", name: name, isGroup: face == .group,
                  recipients: ["@\(id):scripted.atum"], avatarURI: avatar ? "mxc://scripted.atum/\(id)" : nil,
                  face: face, mark: mark)
    }

    static let avatars = ShareAvatarSource { uri in
        guard uri.hasPrefix("mxc://scripted.atum/") else { return nil }
        return portrait(seed: uri)
    }

    struct Made {
        let model: ShareComposerModel
        let providers: [NSItemProvider]
        let intent: INIntent?
        let queue: ShareQueue
        /// Every provider except a deliberately stalled one.
        let diagnosable: [NSItemProvider]
    }

    static func model(_ scenario: ScriptedShareScenario) throws -> Made {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("scripted-share", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        let inputs = base.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let queue = ShareQueue(root: base.appendingPathComponent("queue", isDirectory: true))
        try queue.publish(ShareDirectory(account: account, chats: scenario == .empty ? [] : chats))
        let current = scenario == .failed
            ? ShareAccount(userID: account.userID, generation: UUID()) : account
        let model = ShareComposerModel(queue: queue, account: { current })
        var intent: INIntent?
        if scenario == .suggested, let chat = chats.first(where: { $0.id == suggestedRoom }) {
            intent = ShareSuggestions.interaction(chat: chat).intent
        }
        let items = try providers(inputs, stalls: scenario == .loading)
        let diagnosable = try providers(inputs, stalls: false)
        return Made(model: model, providers: items, intent: intent, queue: queue, diagnosable: diagnosable)
    }

    /// A photo, a short video, a PDF, a link and a text, like a mixed Files/Photos share.
    private static func providers(_ folder: URL, stalls: Bool) throws -> [NSItemProvider] {
        let photo = folder.appendingPathComponent("Hoi An.png")
        try portrait(seed: "photo", side: 1_200).write(to: photo)
        let pdf = folder.appendingPathComponent("Quarterly plan.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).writePDF(to: pdf) { context in
            context.beginPage()
            ("Quarterly plan" as NSString).draw(at: CGPoint(x: 72, y: 72),
                                                withAttributes: [.font: UIFont.systemFont(ofSize: 28)])
        }
        // Registered file representations with a suggested name, as Photos and Files
        // hand them to a share extension.
        var providers = [file(photo, .png)]
        let video = folder.appendingPathComponent("Lantern walk.mov")
        if (try? writeVideo(to: video)) != nil { providers.append(file(video, .quickTimeMovie)) }
        providers.append(file(pdf, .pdf))
        providers.append(NSItemProvider(item: URL(string: "https://atum.chat/notes/launch-checklist")! as NSURL,
                                        typeIdentifier: UTType.url.identifier))
        if stalls {
            // Never completes: the strip stays on "Preparing…" with partial progress.
            let stalled = NSItemProvider()
            stalled.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { _ in
                Progress(totalUnitCount: 1)
            }
            providers.append(stalled)
        } else {
            providers.append(NSItemProvider(item: "Lantern walk on Saturday at 7. Bring a jacket, it gets windy by the river." as NSString,
                                            typeIdentifier: UTType.plainText.identifier))
        }
        return providers
    }

    private static func file(_ url: URL, _ type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = url.lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { done in
            done(url, false, nil); return nil
        }
        return provider
    }

    /// Loads each provider alone into a scratch job and names any the loader rejects
    /// (the model reports only a generic failure). Shown by the host for UI tests.
    static func diagnose(_ providers: [NSItemProvider], queue: ShareQueue) async -> String {
        var failures = [String]()
        for (index, provider) in providers.enumerated() {
            guard let job = try? queue.begin() else { failures.append("\(index):begin"); continue }
            do { _ = try await ShareItemLoader(queue: queue).load(provider, jobID: job) }
            catch { failures.append("\(index):\(provider.registeredTypeIdentifiers.joined(separator: ",")):\(error)") }
            try? queue.remove(job)
        }
        return failures.isEmpty ? "ok" : failures.joined(separator: " | ")
    }

    /// Fixture art only (a soft two-colour gradient with a disc), seeded by name.
    nonisolated static func portrait(seed: String, side: CGFloat = 192) -> Data {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let hue = CGFloat(hash % 360) / 360
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { context in
            let colors = [UIColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).cgColor,
                          UIColor(hue: hue + 0.08, saturation: 0.6, brightness: 0.55, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
            UIColor(white: 1, alpha: 0.55).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: side * 0.3, y: side * 0.18, width: side * 0.4, height: side * 0.4))
            context.cgContext.fillEllipse(in: CGRect(x: side * 0.12, y: side * 0.62, width: side * 0.76, height: side * 0.6))
        }
    }

    /// One second of a gradient at 320x240, H.264, so the strip has a real video thumbnail.
    private static func writeVideo(to url: URL) throws {
        let size = CGSize(width: 320, height: 240)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let art = UIImage(data: portrait(seed: "video", side: 320))?.cgImage
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { break }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width),
                                       height: Int(size.height), bitsPerComponent: 8,
                                       bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                       space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
               let art {
                context.draw(art, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
#endif
