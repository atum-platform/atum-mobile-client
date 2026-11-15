#if DEBUG
import AtumDrive
import AtumNativeAPI
import Foundation
import UIKit

/// Debug only (D12): `-AtumScripted home.roster -AtumScriptedDrive` puts the
/// real `DriveScreen` and `DriveFeatureModel` on Home's Drive tab over a
/// scripted reader, so UI tests and screenshots exercise the live arrangement,
/// search, gallery and share paths with no account and no network. The
/// pictures and PDFs are drawn at launch, so their bytes are real; other files
/// up to 1 MB download as blank bytes, and larger ones refuse. Release builds
/// compile none of this (`Scripted*.swift`).
///
/// The host forgets the view, sort and Group By choices at launch unless
/// `-AtumScriptedDriveKeep` is passed, which a test uses to check they are
/// remembered across launches.
@MainActor
enum ScriptedDrive {
    static let flag = "-AtumScriptedDrive"
    static let keepFlag = "-AtumScriptedDriveKeep"

    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains(flag) }

    static let model: DriveFeatureModel = {
        let arguments = ProcessInfo.processInfo.arguments
        if !arguments.contains(keepFlag) {
            for key in [DriveLayout.storageKey, DriveGroupBy.storageKey, DriveSort.storageKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let reader = ScriptedDriveReader(now: Date())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atum-scripted-drive", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let cache = try? DriveCache(root: root.appendingPathComponent("v1/scripted", isDirectory: true))
        let model = DriveFeatureModel()
        let access: DriveFeatureModel.Access = {
            LiveDriveAccess(cache: cache, state: .active(reader))
        }
        model.configure(accountID: "@scripted:atum.test", resume: access, connect: access)
        return model
    }()
}

@MainActor
final class ScriptedDriveReader: DriveReading {
    static let driveID = "scripted$drive"

    private let root: [DriveItem]
    private let folders: [String: [DriveItem]]
    private let bytes: [String: Data]

    init(now: Date) {
        var bytes = [String: Data]()
        func day(_ count: Double) -> Date { now.addingTimeInterval(-count * 86_400) }
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: now)
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 10)) ?? now
        }
        func file(_ name: String, parent: String = DrivePage.rootParentID,
                  size: Int64? = nil, modified: Date, data: Data? = nil) -> DriveItem {
            let slug = Self.slug(parent + "/" + name)
            if let data { bytes["scripted$drive!" + slug] = data }
            return try! DriveItem(
                id: "scripted$drive!" + slug, name: name, kind: .file,
                etag: "scripted-" + slug, size: size ?? Int64(data?.count ?? 0),
                webDavURL: URL(string: "https://drive.atum.test/dav/spaces/scripted$drive/" + slug)!,
                modifiedAt: modified, parentDriveID: Self.driveID, parentID: parent)
        }
        func folder(_ name: String, modified: Date) -> DriveItem {
            try! DriveItem(id: "scripted$drive!folder-" + Self.slug(name), name: name, kind: .folder,
                           etag: "scripted-folder", size: 0, webDavURL: nil, modifiedAt: modified,
                           parentDriveID: Self.driveID, parentID: DrivePage.rootParentID)
        }

        let photos = folder("Photos", modified: now.addingTimeInterval(-2 * 3_600))
        let contracts = folder("Contracts", modified: day(12))
        let projects = folder("Projects 2026", modified: date(year, 3, 18))
        root = [
            photos, contracts, projects,
            file("Q3 board report.pdf", modified: now.addingTimeInterval(-3_600),
                 data: Self.pdf(title: "Q3 board report", pages: 3)),
            file("Beach — Nha Trang.jpg", modified: day(1),
                 data: Self.picture("Nha Trang", hue: 0.55, jpeg: true)),
            file("Budget 2026.xlsx", size: 48_200, modified: day(3)),
            file("Pitch deck v12.pptx", size: 18_400_000, modified: day(9)),
            file("Quarterly board meeting notes and final budget review.docx", size: 230_000,
                 modified: day(20)),
            file("Report 2.pdf", modified: day(25), data: Self.pdf(title: "Report 2", pages: 1)),
            file("Report 10.pdf", modified: day(26), data: Self.pdf(title: "Report 10", pages: 1)),
            file("Team offsite.mov", size: 1_400_000_000, modified: date(year, 2, 14)),
            file("notes.md", size: 2_100, modified: date(year - 1, 8, 2)),
            file("Archive 2024.zip", size: 340_000_000, modified: date(year - 2, 12, 30)),
            file("README", size: 0, modified: date(year - 2, 1, 5)),
        ]
        let inPhotos = photos.id
        folders = [
            inPhotos: [
                file("Sunrise.jpg", parent: inPhotos, modified: day(2),
                     data: Self.picture("Sunrise", hue: 0.08, jpeg: true)),
                file("Hội An lanterns.png", parent: inPhotos, modified: day(4),
                     data: Self.picture("Hội An", hue: 0.95, jpeg: false)),
                file("Rice terraces.jpg", parent: inPhotos, modified: day(6),
                     data: Self.picture("Sa Pa", hue: 0.3, jpeg: true)),
                file("Ticket.pdf", parent: inPhotos, modified: day(8),
                     data: Self.pdf(title: "Boarding pass", pages: 1)),
                file("Night market.jpg", parent: inPhotos, modified: day(40),
                     data: Self.picture("Night market", hue: 0.7, jpeg: true)),
            ],
            contracts.id: [
                file("Lease 2026.pdf", parent: contracts.id, modified: day(12),
                     data: Self.pdf(title: "Lease", pages: 2)),
            ],
            projects.id: [],
        ]
        self.bytes = bytes
    }

    func rootPage() async throws -> DrivePage {
        try DrivePage(driveID: Self.driveID, parentID: DrivePage.rootParentID, items: root)
    }

    func children(driveID: String, parentID: String) async throws -> DrivePage {
        try? await Task.sleep(for: .milliseconds(150))
        return try DrivePage(driveID: Self.driveID, parentID: parentID, items: folders[parentID] ?? [])
    }

    func download(_ item: DriveItem, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let data: Data
        if let drawn = bytes[item.id] {
            data = drawn
        } else if item.size <= 1_000_000 {
            data = Data(count: Int(item.size))
        } else {
            throw DriveFailure.serviceUnavailable(retryAfter: nil)
        }
        let total = Int64(data.count)
        for step in 1...4 {
            try await Task.sleep(for: .milliseconds(80))
            progress(total * Int64(step) / 4, total)
        }
        try data.write(to: destination)
    }

    private static func slug(_ value: String) -> String {
        String(value.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    }

    /// A soft gradient with a caption, standing in for a photo.
    private static func picture(_ caption: String, hue: CGFloat, jpeg: Bool) -> Data {
        let size = CGSize(width: 1_200, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [UIColor(hue: hue, saturation: 0.45, brightness: 0.95, alpha: 1).cgColor,
                          UIColor(hue: hue + 0.08, saturation: 0.6, brightness: 0.55, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors as CFArray, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero,
                                                 end: CGPoint(x: size.width, y: size.height), options: [])
            let text = NSAttributedString(string: caption, attributes: [
                .font: UIFont.systemFont(ofSize: 84, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9),
            ])
            text.draw(at: CGPoint(x: 80, y: size.height - 200))
        }
        return (jpeg ? image.jpegData(compressionQuality: 0.8) : image.pngData()) ?? Data()
    }

    /// A short document with a title and ruled lines on each page.
    private static func pdf(title: String, pages: Int) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 1...pages {
                context.beginPage()
                NSAttributedString(string: title, attributes: [
                    .font: UIFont.systemFont(ofSize: 30, weight: .bold),
                ]).draw(at: CGPoint(x: 56, y: 64))
                NSAttributedString(string: "\(page) / \(pages)", attributes: [
                    .font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.gray,
                ]).draw(at: CGPoint(x: 56, y: 108))
                UIColor(white: 0.85, alpha: 1).setFill()
                for line in 0..<22 {
                    UIBezierPath(rect: CGRect(x: 56, y: 160 + line * 28, width: line % 5 == 4 ? 300 : 483,
                                              height: 8)).fill()
                }
            }
        }
    }
}
#endif
