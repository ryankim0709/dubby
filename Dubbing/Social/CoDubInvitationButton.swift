import MessageUI
import SwiftUI

private struct CoDubMessageDraft: Identifiable {
    let id: String
    let body: String

    init(code: String, roleName: String, title: String) throws {
        let link = try CoDubLink.url(code: code)
        id = code
        body = "Dub this scene with me! Play \(roleName) in \(title) and record the other half of our dub. Open this invitation in Dubby to join the scene and record your role:\n\n\(link.absoluteString)"
    }
}

private enum CoDubMessageError: LocalizedError {
    case unavailable
    case failed

    var errorDescription: String? {
        switch self {
        case .unavailable: "Messages isn't available on this device. Set up Messages on your iPhone, then try sharing again."
        case .failed: "Messages couldn't send the invitation. Tap Share to try again; your saved invitation will be reused."
        }
    }
}

struct CoDubInvitationButton: View {
    let source: SocialDubSource
    let account: AccountModel
    let guestCharacterId: Int
    let recipientId: String?
    let title: String
    @Binding var isWorking: Bool
    /// Shown as a tile in a row of actions, with any problem in an alert instead of below the button.
    var isTile = false
    @State private var clientId = UUID().uuidString
    @State private var assetId: String?
    @State private var invitation: CoDubMessageDraft?
    @State private var presentedMessage: CoDubMessageDraft?
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isTile {
                Button(action: share) {
                    Label(isWorking ? "Preparing…" : title, systemImage: "message")
                }
                .buttonStyle(TileButtonStyle())
                .disabled(isWorking)
                .accessibilityIdentifier("sendCoDubInvite")
            } else {
                Button(action: share) {
                    Label(isWorking ? "Preparing invitation…" : title, systemImage: "message")
                }
                .buttonStyle(PrimaryButtonStyle(cornerRadius: Radius.control))
                .disabled(isWorking)
                .accessibilityIdentifier("sendCoDubInvite")
                if let issue {
                    Text(issue).dubFont(14, weight: .regular).foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("coDubMessageError")
                }
            }
        }
        .alert("Couldn't invite", isPresented: Binding(get: { isTile && issue != nil }, set: { if !$0 { issue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(issue ?? "")
        }
        .sheet(item: $presentedMessage) { draft in
            CoDubMessageComposer(messageBody: draft.body) { result in
                presentedMessage = nil
                if result == .failed { issue = CoDubMessageError.failed.localizedDescription }
            }
            .ignoresSafeArea()
        }
    }

    private func share() {
        issue = nil
        guard MFMessageComposeViewController.canSendText() else {
            issue = CoDubMessageError.unavailable.localizedDescription
            return
        }
        if let invitation {
            presentedMessage = invitation
            return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let script = try source.invitationScript(guestCharacterId: guestCharacterId)
                let client = try SocialBackendClient.configured(account: account)
                let uploaded: String
                if let assetId { uploaded = assetId }
                else { uploaded = try await client.upload(video: source.video); assetId = uploaded }
                let receipt = try await client.invite(assetId: uploaded, script: script, recipientId: recipientId, clientId: clientId)
                let draft = try CoDubMessageDraft(code: receipt.code, roleName: script.roleName(guestCharacterId), title: script.title)
                invitation = draft
                presentedMessage = draft
            } catch {
                issue = error.localizedDescription
            }
        }
    }
}

private struct CoDubMessageComposer: UIViewControllerRepresentable {
    let messageBody: String
    let onFinish: (MessageComposeResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.body = messageBody
        controller.messageComposeDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (MessageComposeResult) -> Void

        init(onFinish: @escaping (MessageComposeResult) -> Void) { self.onFinish = onFinish }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish(result)
        }
    }
}
