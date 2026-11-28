import AtumChat
import SwiftUI

extension View {
    /// Shows another own device's verification request as one quiet banner
    /// above the content, never a modal: Compare emoji opens the emoji sheet,
    /// the close button declines. Nothing else in the app waits on it.
    /// `ready` is the live session's completed initial sync; the SDK can attach
    /// its verification delegate only after that.
    func deviceVerificationRequests(design: LiveDesign, actions: SecurityActions?, ready: Bool) -> some View {
        modifier(DeviceVerificationPresenter(design: design, actions: actions, ready: ready))
    }
}

private struct DeviceVerificationPresenter: ViewModifier {
    let design: LiveDesign
    let actions: SecurityActions?
    let ready: Bool

    @State private var sheet: SheetItem?
    @State private var toast: String?
    @State private var toastCount = 0
    @State private var declined = Set<UUID>()

    private struct SheetItem: Identifiable {
        let id: UUID
    }

    func body(content: Content) -> some View {
        let driver = ready ? actions?.verification() : nil
        return content
            .overlay(alignment: .bottom) {
                VStack(spacing: design.kit.space(.s2)) {
                    if let driver, sheet == nil, case let .incoming(invitation) = driver.state,
                       !declined.contains(invitation.id) {
                        IncomingVerificationBanner(
                            design: design, deviceName: invitation.deviceName,
                            compare: { sheet = SheetItem(id: invitation.id) },
                            decline: {
                                declined.insert(invitation.id)
                                Task { await driver.cancel(invitation.id) }
                            }
                        )
                        .motionTransition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let toast {
                        TrustToast(design: design, text: toast)
                            .motionTransition(.opacity)
                    }
                }
                .padding(.horizontal, design.kit.space(.s4))
                .padding(.bottom, design.kit.space(.s12))
                .motion(.quick, value: driver?.state)
            }
            .task(id: ListenKey(driver: driver.map { ObjectIdentifier($0) })) {
                await driver?.listen()
            }
            .sheet(item: $sheet) { item in
                if let driver {
                    NavigationStack {
                        DeviceVerificationView(
                            design: design, driver: driver, entry: .accept(item.id),
                            onConfirmed: { show(SecurityCopy(design: design).text(.confirmedToast)) },
                            close: { sheet = nil }
                        )
                    }
                    .atumDesign(design)
                }
            }
    }

    private struct ListenKey: Equatable {
        let driver: ObjectIdentifier?
    }

    private func show(_ text: String) {
        withMotion(.quick) { toast = text }
        toastCount += 1
        let event = toastCount
        AccessibilityNotification.Announcement(text).post()
        Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if toastCount == event { withMotion(.quick) { toast = nil } }
        }
    }
}

/// One line and two controls, the size of a toast.
private struct IncomingVerificationBanner: View {
    let design: LiveDesign
    let deviceName: String?
    let compare: () -> Void
    let decline: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var kit: AtumKit { design.kit }
    private var copy: SecurityCopy { SecurityCopy(design: design) }

    var body: some View {
        HStack(spacing: kit.space(.s3)) {
            Image(atum.symbol(.deviceMobile))
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityHidden(true)
            Text(deviceName.map { copy.text(.incomingBody, $0) } ?? copy.text(.incomingBodyUnnamed))
                .font(.subheadline)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copy.exported("src.matrix.security-copy.copies.emoji"), action: compare)
                .fixedSize()
                .buttonStyle(AtumCompactButtonStyle(atum: atum, scheme: scheme, size: .small))
                .accessibilityIdentifier("security.incoming.compare")
            Button(action: decline) {
                Image(atum.symbol(.close))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copy.exported(AtumCopyKey.notNow.rawValue))
            .accessibilityIdentifier("security.incoming.decline")
        }
        .padding(.horizontal, kit.space(.s4))
        .padding(.vertical, kit.space(.s3))
        .background(atum.color(.cell, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: kit.phoneRadius(.lg), style: .continuous))
        .atumKitElevation(.two, in: RoundedRectangle(cornerRadius: kit.phoneRadius(.lg), style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("security.incoming")
    }
}
