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
                TextField("单词或短语", text: $headword)
                    .autocorrectionDisabled()
                    // The learner's own language is not the target language, so autocapitalising
                    // a Thai or French headword against an English keyboard is wrong.
                    .textInputAutocapitalization(.never)
                Picker("词性", selection: $partOfSpeech) {
                    ForEach(PartOfSpeech.allCases.filter { $0 != .other }) { pos in
                        Text(pos.displayName).tag(pos)
                    }
                }
            } header: {
                Text("\(language.flagEmoji) \(language.displayName)")
            }

            Section("释义") {
                TextField("释义", text: $definition, axis: .vertical)
                    .lineLimit(2...5)
                TextField("翻译（选填）", text: $translation)
            }

            Section("选填") {
                TextField("例句", text: $example, axis: .vertical)
                    .lineLimit(1...4)
                TextField(
                    language.phoneticNotation == .ipa ? "发音（IPA 音标）" : "发音",
                    text: $phonetic
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            }

            Section {
                Toggle("现在就开始学习", isOn: $addToStudy)
            } footer: {
                Text(addToStudy
                    ? "它会出现在你下一次复习里。"
                    : "只保存到词典里。之后也可以再加入学习。")
            }

            Section {
                PrimaryButton("保存单词", isEnabled: canSave) { save() }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("添加单词")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
        .alert("没能保存", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
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
