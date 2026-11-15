import SwiftUI

/// How the dub flow opens: on the scene list (from Create) or straight into a scene (from Discover).
enum DubFlowLaunch: Identifiable {
    case chooseScene
    case scene(LibraryClip)
    case social(SocialDubLaunch)

    var id: String {
        switch self {
        case .chooseScene: "choose"
        case .scene(let clip): clip.url.absoluteString
        case .social(let launch): launch.setup.clip.workingDirectory.absoluteString
        }
    }
}

/// The create-a-dub flow: pick a scene, frame a section, review the script, dub, and export.
struct DubFlowView: View {
    let clips: LoadState<[LibraryClip]>
    let account: AccountModel
    let scoring: DubScoringModel?
    let completionRoom: CoDubRoom?
    let onRetry: () -> Void
    let onClose: () -> Void
    @State private var path: [DubFlowStep]

    init(launch: DubFlowLaunch, clips: LoadState<[LibraryClip]>, account: AccountModel, scoring: DubScoringModel?, onRetry: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.clips = clips
        self.account = account
        self.scoring = scoring
        self.onRetry = onRetry
        self.onClose = onClose
        switch launch {
        case .chooseScene:
            completionRoom = nil
            _path = State(initialValue: [])
        case .scene(let clip):
            completionRoom = nil
            _path = State(initialValue: [.section(ImportedClip(clip: clip))])
        case .social(let launch):
            completionRoom = launch.completionRoom
            _path = State(initialValue: [.studio(launch.setup)])
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScenePickerView(clips: clips, onPick: { path.append(.section(ImportedClip(clip: $0))) }, onRetry: onRetry, onClose: onClose)
                .navigationDestination(for: DubFlowStep.self) { step in
                    switch step {
                    case .section(let clip):
                        SectionPickerView(clip: clip) { path.append(.script($0)) }
                    case .script(let request):
                        ScriptReviewView(request: request) { path.append(.studio($0)) }
                    case .studio(let setup):
                        DubSessionView(setup: setup, initialTakes: [:], requiredKeptLines: completionRoom == nil ? 1 : setup.script.lines(spokenBy: setup.characterID).count) { path.append(.result(setup, $0)) }
                    case .result(let setup, let takes):
                        DubResultView(setup: setup, takes: takes, account: account, scoring: scoring, completionRoom: completionRoom, onDone: onClose, onKeepRecording: { path.removeLast() })
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

/// The flow's first screen: every scene in the Media folder.
private struct ScenePickerView: View {
    let clips: LoadState<[LibraryClip]>
    let onPick: (LibraryClip) -> Void
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Pick your scene")
                        .dubFont(32, weight: .bold)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .dubFont(16, weight: .semibold)
                            .foregroundStyle(Palette.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Palette.surface, in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                .padding(.top, 8)
                Text("Choose a scene. Next you'll frame up to 30 seconds and pick a character.")
                    .dubFont(14, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                LoadStateContent(state: clips, failureIdentifier: "scenePickerLoadFailed", retry: onRetry) { clips in
                    if clips.isEmpty {
                        EmptyStateView(
                            systemImage: "film.stack",
                            title: "No scenes available yet",
                            message: "Your next role will appear here when library scenes are available."
                        )
                        Button("Reload library", action: onRetry)
                            .buttonStyle(SecondaryButtonStyle())
                            .accessibilityIdentifier("reloadSceneLibrary")
                    } else {
                        VStack(spacing: 16) {
                            ForEach(clips) { clip in
                                SceneCard(clip: clip) { onPick(clip) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension Palette {
    static func speakerColor(_ speakerID: Int) -> Color {
        let colors = [accent, Color(hex: 0xBBBBBB), Color(hex: 0x999999), Color(hex: 0x777777)]
        return colors[speakerID % colors.count]
    }
}
