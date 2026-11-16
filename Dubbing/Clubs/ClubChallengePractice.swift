import SwiftUI

struct ClubChallengePractice: View {
    let account: AccountModel
    let scene: CuratedScene
    let scoring: DubScoringModel?
    @State private var stage: Stage = .characters
    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case characters, preparing, studio(DubSetup, [Int: RecordedTake]), result(DubSetup, [Int: RecordedTake]), failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .characters, .failed:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(scene.title).font(.title2.weight(.semibold))
                            Text("Choose your character").font(.headline)
                            ForEach(scene.characters) { character in
                                Button { Task { await prepare(character) } } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(character.displayName).font(.headline)
                                        Text(character.description).font(.body)
                                        Text("\(scene.lines(spokenBy: character.id).count) lines").font(.subheadline)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                                }.buttonStyle(.plain).accessibilityIdentifier("clubCharacter-\(character.id)")
                            }
                            if case .failed(let message) = stage { Text(message).foregroundStyle(Palette.streak) }
                            Text(scene.attribution.text).font(.footnote).foregroundStyle(Palette.textSecondary)
                        }.padding(20)
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                    .navigationTitle("Bridge challenge").navigationBarTitleDisplayMode(.inline)
                case .preparing: ProgressView("Preparing the scene…")
                case .studio(let setup, let takes):
                    DubSessionView(setup: setup, account: account, initialTakes: takes, requiredKeptLines: 1) { stage = .result(setup, $0) }
                case .result(let setup, let takes):
                    DubResultView(setup: setup, takes: takes, account: account, scoring: scoring, completionRoom: nil, onDone: { dismiss() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .screenBackground().foregroundStyle(Palette.textPrimary)
        }
        .tint(Palette.accentText).preferredColorScheme(.dark)
    }

    private func prepare(_ character: SceneCharacter) async {
        stage = .preparing
        do {
            let setup = try await CuratedSceneStudio.makeSetup(scene: scene, characterID: character.id, barCount: 64, workingDirectory: CuratedSceneStudio.newWorkingDirectory())
            stage = .studio(setup, [:])
        } catch { stage = .failed(error.localizedDescription) }
    }
}
