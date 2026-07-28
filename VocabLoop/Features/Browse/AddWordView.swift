import SwiftUI

/// Add a word of your own.
///
/// Deliberately short. A form that demands phonetics, synonyms and three examples before it
/// will accept a word is a form nobody completes — headword and meaning are the only required
/// fields, and everything else can be filled in later from the detail screen.
struct AddWordView: View {
    let language: LearningLanguage

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.dismiss) private var dismiss

    @State private var headword = ""
    @State private var definition = ""
    @State private var translation = ""
    @State private var example = ""
    @State private var phonetic = ""
    @State private var partOfSpeech: PartOfSpeech = .noun
    @State private var addToStudy = true
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Word or phrase", text: $headword)
                    .autocorrectionDisabled()
                    // The learner's own language is not the target language, so autocapitalising
                    // a Thai or French headword against an English keyboard is wrong.
                    .textInputAutocapitalization(.never)
                Picker("Part of speech", selection: $partOfSpeech) {
                    ForEach(PartOfSpeech.allCases.filter { $0 != .other }) { pos in
                        Text(pos.displayName).tag(pos)
                    }
                }
            } header: {
                Text("\(language.flagEmoji) \(language.displayName)")
            }

            Section("Meaning") {
                TextField("Definition", text: $definition, axis: .vertical)
                    .lineLimit(2...5)
                TextField("Translation (optional)", text: $translation)
            }

            Section("Optional") {
                TextField("Example sentence", text: $example, axis: .vertical)
                    .lineLimit(1...4)
                TextField(
                    language.phoneticNotation == .ipa ? "Pronunciation (IPA)" : "Pronunciation",
                    text: $phonetic
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            }

            Section {
                Toggle("Start studying it now", isOn: $addToStudy)
            } footer: {
                Text(addToStudy
                    ? "It will appear in your next review session."
                    : "It will be saved to the dictionary only. You can add it to your studies later.")
            }

            Section {
                PrimaryButton("Save word", isEnabled: canSave) { save() }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("New word")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .alert("Could not save", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var canSave: Bool {
        !headword.trimmingCharacters(in: .whitespaces).isEmpty
            && !definition.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        do {
            let entry = try dependencies.search.createUserEntry(
                headword: headword,
                definition: definition,
                partOfSpeech: partOfSpeech,
                language: language,
                translation: translation.isEmpty ? nil : translation,
                example: example.isEmpty ? nil : example,
                phonetic: phonetic.isEmpty ? nil : phonetic
            )
            if addToStudy, let preferences = dependencies.preferences {
                try dependencies.review.enroll(entry: entry, preferences: preferences)
            }
            Haptics.tap()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack { AddWordView(language: .english) }
}
