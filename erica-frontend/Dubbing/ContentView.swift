import PhotosUI
import SwiftUI

enum AppTab: Hashable {
    case discover
    case feed
    case create
    case inbox
    case shelf
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var tab: AppTab = .discover
    @State private var isCreatePresented = false
    /// Set by the Create sheet; acted on once the sheet has finished dismissing.
    @State private var queuedCreateAction: CreateAction?

    var body: some View {
        TabView(selection: tabSelection) {
            Tab("Discover", systemImage: "popcorn.fill", value: AppTab.discover) {
                DiscoverView()
            }
            Tab("Feed", systemImage: "play.rectangle.on.rectangle.fill", value: AppTab.feed) {
                FeedView()
            }
            // Create is an action, not a section: selecting it opens a sheet and the current tab stays put.
            Tab("Create", systemImage: "plus.circle.fill", value: AppTab.create) {
                Color.clear
            }
            Tab("Inbox", systemImage: "tray.fill", value: AppTab.inbox) {
                InboxView()
            }
            .badge(model.invites.count)
            Tab("Shelf", systemImage: "books.vertical.fill", value: AppTab.shelf) {
                ShelfView()
            }
        }
        .tint(Palette.accent)
        .sheet(isPresented: $isCreatePresented, onDismiss: runQueuedCreateAction) {
            CreateSheet { action in
                queuedCreateAction = action
                isCreatePresented = false
            }
        }
        .sheet(item: $model.previewScene, onDismiss: model.previewDidDismiss) { scene in
            ScenePreviewSheet(scene: scene)
        }
        .fullScreenCover(item: $model.activeDub) { request in
            DubFlowView(request: request)
        }
        .preferredColorScheme(.dark)
        // Outermost, so sheets and the full-screen cover receive the model too.
        .environment(model)
    }

    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { tab },
            set: { newTab in
                if newTab == .create {
                    isCreatePresented = true
                } else {
                    tab = newTab
                }
            }
        )
    }

    private func runQueuedCreateAction() {
        guard let action = queuedCreateAction else { return }
        queuedCreateAction = nil
        switch action {
        case .browse:
            tab = .discover
        case .preview(let scene):
            model.preview(scene)
        }
    }
}

enum CreateAction: Hashable {
    case browse
    case preview(SceneClip)
}

/// Start something new: a curated scene, or (once the upload service exists) a clip from the camera roll.
private struct CreateSheet: View {
    let onAction: (CreateAction) -> Void
    @Environment(AppModel.self) private var model
    @State private var pickedClip: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New dub")
                .dubFont(28, weight: .bold)
                .foregroundStyle(Palette.textPrimary)
                .padding(.bottom, 4)
            option(title: "Browse scenes", detail: "Films, originals, and daily challenges", systemImage: "popcorn.fill") {
                onAction(.browse)
            }
            option(title: "Surprise me", detail: "A random scene to dub right now", systemImage: "dice.fill") {
                if let scene = model.scenes.randomElement() {
                    onAction(.preview(scene))
                }
            }
            PhotosPicker(selection: $pickedClip, matching: .videos) {
                CreateOptionLabel(title: "Upload from your album", detail: "Dub a clip of your own", systemImage: "photo.on.rectangle.angled")
            }
            .buttonStyle(.plain)
            if pickedClip != nil {
                Label("Got your clip. Splitting voices out of your own videos needs the upload service, which isn't connected yet.", systemImage: "info.circle")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.background)
    }

    private func option(title: String, detail: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            CreateOptionLabel(title: title, detail: detail, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}

private struct CreateOptionLabel: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 44, height: 44)
                .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .dubFont(17, weight: .semibold)
                    .foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.placeholder)
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card))
        .contentShape(Rectangle())
    }
}

#Preview {
    ContentView()
}
