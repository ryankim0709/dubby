import SwiftUI

/// How the dub flow opens: on the scene list (from Create) or straight into a scene (from Discover).
enum DubFlowLaunch: Identifiable {
    case chooseScene
    case scene(LibraryClip)

    var id: String {
        switch self {
        case .chooseScene: "choose"
        case .scene(let clip): clip.url.absoluteString
        }
    }
}

/// The create-a-dub flow: pick a scene, frame a section, review the script, dub, and export.
struct DubFlowView: View {
    let clips: LoadState<[LibraryClip]>
    let scoring: DubScoringModel?
    let onClose: () -> Void
    @State private var path: [DubFlowStep]

    init(launch: DubFlowLaunch, clips: LoadState<[LibraryClip]>, scoring: DubScoringModel?, onClose: @escaping () -> Void) {
        self.clips = clips
        self.scoring = scoring
        self.onClose = onClose
        switch launch {
        case .chooseScene:
            _path = State(initialValue: [])
        case .scene(let clip):
            _path = State(initialValue: [.section(ImportedClip(clip: clip))])
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScenePickerView(clips: clips, onPick: { path.append(.section(ImportedClip(clip: $0))) }, onClose: onClose)
                .navigationDestination(for: DubFlowStep.self) { step in
                    switch step {
                    case .section(let clip):
                        SectionPickerView(clip: clip) { path.append(.script($0)) }
                    case .script(let request):
                        ScriptReviewView(request: request) { path.append(.studio($0)) }
                    case .studio(let setup):
                        DubSessionView(setup: setup) { path.append(.result(setup, $0)) }
                    case .result(let setup, let takes):
                        DubResultView(setup: setup, takes: takes, scoring: scoring, onDone: onClose)
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
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("New dub")
                        .dubFont(24, weight: .semibold)
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
                LoadStateContent(state: clips) { clips in
                    if clips.isEmpty {
                        EmptyStateView(
                            systemImage: "film.stack",
                            title: "No scenes yet",
                            message: "Add MP4 or MOV clips to the Media folder in the project, then build and run again."
                        )
                    } else {
                        VStack(spacing: 16) {
                            ForEach(clips) { clip in
                                SceneCard(clip: clip) { onPick(clip) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
        .background(Palette.background)
        .toolbar(.hidden, for: .navigationBar)
    }
}

extension Palette {
    /// Distinct colors so each speaker's lines are easy to tell apart.
    static func speakerColor(_ speakerID: Int) -> Color {
        let colors = [accent, streak, Color(hex: 0x5EC8D8), Color(hex: 0xF27BA8)]
        return colors[speakerID % colors.count]
    }
}
