import SwiftUI

/// The script is ready before this screen opens, so role selection has no loading step.
struct ScriptReviewView: View {
    let prepared: PreparedScript
    let onStart: (DubSetup) -> Void

    var body: some View {
        ScriptEditor(request: prepared.request, source: prepared.source, onStart: onStart)
            .screenBackground()
            .navigationTitle("Your scene")
            .navigationBarTitleDisplayMode(.inline)
            .overlay { StateCarriers(items: [StateCarrier(identifier: "transcribeProgress", value: "ready")]) }
    }
}

private struct ScriptEditor: View {
    let request: TranscriptionRequest
    let source: ScriptSource
    let onStart: (DubSetup) -> Void
    @State private var speakerCount: Int
    @State private var script: Script
    @State private var characterID: Int
    @State private var renamingSpeaker: Speaker?
    @State private var draftName = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(request: TranscriptionRequest, source: ScriptSource, onStart: @escaping (DubSetup) -> Void) {
        self.request = request
        self.source = source
        self.onStart = onStart
        let speakerCount = 2
        let script = switch source {
        case .voices(let analysis): ScriptBuilder.buildScript(analysis: analysis, speakerCount: speakerCount, names: [])
        case .cast(let script, _): script
        }
        _speakerCount = State(initialValue: speakerCount)
        _script = State(initialValue: script)
        _characterID = State(initialValue: script.speakers.first { !script.lines(spokenBy: $0.id).isEmpty }?.id ?? 0)
    }

    private var characterLines: [ScriptLine] { script.lines(spokenBy: characterID) }

    /// The speakers with a line in the section. A cast character who speaks only elsewhere in the clip has
    /// nothing to dub here.
    private var roles: [Speaker] { script.speakers.filter { !script.lines(spokenBy: $0.id).isEmpty } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose your role")
                    .dubFont(32, weight: .bold)
                    .foregroundStyle(Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("\(request.clip.title) · \(request.section.duration.preciseClockString)")
                    .dubFont(15, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                LazyVGrid(columns: adaptiveGridColumns(spacing: 14, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize), spacing: 14) {
                    ForEach(roles) { speaker in
                        characterCard(speaker)
                    }
                }
                DisclosureGroup {
                    speakersCard
                    VStack(spacing: 8) {
                        ForEach(script.lines) { line in
                            ScriptLineRow(line: line, speakers: script.speakers) { speakerID in
                                script = script.reassigning(lineID: line.id, to: speakerID)
                            }
                        }
                    }
                } label: {
                    Label("Review dialogue and voices", systemImage: "text.alignleft")
                        .dubFont(17, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                        .frame(minHeight: 44)
                }
                .tint(Palette.textSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .containerIdentifier("scriptScreen")
        }
        .scrollIndicators(.hidden)
        // Pinned so the primary action stays on screen beside a long script.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Dub as \(script.speaker(withID: characterID)?.name ?? "this character")") {
                onStart(DubSetup(clip: request.clip, section: request.section, script: script, characterID: characterID, locale: request.language.identifier))
            }
            .buttonStyle(PrimaryButtonStyle(cornerRadius: 16))
            .disabled(characterLines.isEmpty)
            .opacity(characterLines.isEmpty ? 0.5 : 1)
            .accessibilityIdentifier("startDubbing")
            .padding(16)
            .background(Palette.background)
        }
        .onChange(of: speakerCount) { _, count in
            guard case .voices(let analysis) = source else { return }
            script = ScriptBuilder.buildScript(analysis: analysis, speakerCount: count, names: script.speakers.map(\.name))
        }
        // Regrouping or reassigning lines can leave the chosen role with nothing to dub and no card to show.
        .onChange(of: script) {
            if characterLines.isEmpty, let first = roles.first {
                characterID = first.id
            }
        }
        .alert("Rename speaker", isPresented: Binding(get: { renamingSpeaker != nil }, set: { if !$0 { renamingSpeaker = nil } })) {
            TextField("Character name", text: $draftName)
            Button("Save") {
                let name = draftName.trimmingCharacters(in: .whitespaces)
                if let speaker = renamingSpeaker, !name.isEmpty {
                    script = script.renaming(speakerID: speaker.id, to: name)
                }
                renamingSpeaker = nil
            }
            Button("Cancel", role: .cancel) { renamingSpeaker = nil }
        }
    }

    private var speakersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A cast already knows how many characters speak, so only voice grouping has a count to change.
            if case .voices = source {
                AdaptiveStack(rowAlignment: .center, spacing: 8) {
                    Text("Voices in this scene")
                        .dubFont(16, weight: .medium)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    Stepper("\(speakerCount)", value: $speakerCount, in: 1...4)
                        .dubFont(16, weight: .semibold)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize()
                        .accessibilityLabel("Voices in this scene")
                        .accessibilityValue("\(speakerCount)")
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(script.speakers) { speaker in
                        Button {
                            draftName = speaker.name
                            renamingSpeaker = speaker
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Palette.speakerColor(speaker.id))
                                    .frame(width: 10, height: 10)
                                Text(speaker.name)
                                    .dubFont(14, weight: .medium)
                                Image(systemName: "pencil")
                                    .dubFont(12, weight: .regular)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(Palette.background, in: Capsule())
                        }
                        .accessibilityLabel("Rename \(speaker.name)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            Text(speakerNote)
                .dubFont(12, weight: .regular)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private var speakerNote: String {
        switch source {
        case .voices:
            "Voices are grouped by how they sound, so similar voices or loud music can mix them up. Tap a line's name to fix it."
        case .cast:
            "Speakers were worked out from the whole scene's voices and picture, and can still be wrong. Tap a line's name to fix it."
        }
    }

    /// The cast's chosen frame of this character, from anywhere in the clip; otherwise the middle of their first line.
    private func stillMoment(for speaker: Speaker, lines: [ScriptLine]) -> StillMoment {
        if case .cast(_, let cast) = source, cast.characters.indices.contains(speaker.id),
           let seconds = cast.characters[speaker.id].portraitSeconds {
            return StillMoment(seconds: seconds, faceCenterX: cast.characters[speaker.id].faceCenterX)
        }
        return StillMoment(seconds: request.section.start + (lines.first.map { $0.start + $0.duration / 2 } ?? 0), faceCenterX: nil)
    }

    private func characterCard(_ speaker: Speaker) -> some View {
        let lines = script.lines(spokenBy: speaker.id)
        let seconds = lines.reduce(0) { $0 + $1.duration }
        let isSelected = speaker.id == characterID
        return Button {
            characterID = speaker.id
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                SpeakerStillView(url: request.clip.url, moment: stillMoment(for: speaker, lines: lines))
                    .aspectRatio(SpeakerStill.aspectRatio, contentMode: .fit)
                    .overlay {
                        LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    }
                    .overlay(alignment: .bottomLeading) {
                        Text(speaker.name.uppercased())
                            .displayFont(34)
                            .foregroundStyle(Palette.textPrimary)
                            .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                            .padding(10)
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Palette.onAccent, Palette.accent)
                                .padding(8)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.card)
                            .strokeBorder(isSelected ? Palette.accent : .clear, lineWidth: 2.5)
                    }
                Text("\(lines.count) lines · \(Int(seconds.rounded()))s of dialogue")
                    .dubFont(13, weight: .regular)
                    .foregroundStyle(Palette.textSecondary)
                if let first = lines.first {
                    Text("“\(first.text)”")
                        .dubFont(14, weight: .regular)
                        .italic()
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("\(speaker.name), ^[\(lines.count) line](inflect: true), \(Int(seconds.rounded())) seconds"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("characterCard-\(speaker.id)")
    }
}

/// The frame a role card shows, and where the character's face is in it when the cast knows.
private struct StillMoment: Hashable {
    let seconds: Double
    /// A fraction of the frame width; nil picks the largest face.
    let faceCenterX: Double?
}

/// A role card's image: the moment's frame cropped around the character's face.
private struct SpeakerStillView: View {
    let url: URL
    let moment: StillMoment
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Palette.surface
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityLabel("Preview unavailable")
                }
            }
            .clipped()
            .task(id: moment) {
                do {
                    failed = false
                    image = try await SpeakerStill.portrait(videoURL: url, seconds: moment.seconds, faceCenterX: moment.faceCenterX)
                } catch is CancellationError {
                    return
                } catch {
                    failed = true
                }
            }
    }
}

private struct ScriptLineRow: View {
    let line: ScriptLine
    let speakers: [Speaker]
    let onAssign: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(speakers) { speaker in
                        Button(speaker.name) { onAssign(speaker.id) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(speakers.first { $0.id == line.speakerID }?.name ?? "Speaker")
                            .dubFont(12, weight: .semibold)
                        Image(systemName: "chevron.down")
                            .dubFont(10, weight: .semibold)
                    }
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(Palette.speakerColor(line.speakerID), in: Capsule())
                }
                .accessibilityLabel("Speaker for this line")
                Spacer()
                Text("\(line.start.preciseClockString) – \(line.end.preciseClockString)")
                    .dubFont(12, weight: .regular)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
            Text(line.text)
                .dubFont(16, weight: .regular)
                .foregroundStyle(Palette.textPrimary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
        .containerIdentifier("scriptLine-\(line.id)")
        .accessibilityValue("\(line.speakerID)")
    }
}
