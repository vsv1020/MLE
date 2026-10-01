import SwiftUI

/// The parent report (engagement plan §1.10), shown once the gate is passed.
///
/// Free: this week's recap with week-on-week arrows, total minutes, every word started with its
/// translation, the words worth another look, the streak and plain-language notes. Plus: the
/// 12-week history and a PDF export. Without Plus those two appear as one row that leads to
/// ``PlusView`` — a described extra, never a button that does nothing.
///
/// No account, and nothing leaves the device unless the parent shares the PDF themselves.
struct ParentReportView: View {
    @Environment(\.appDependencies) private var dependencies
    @State private var recap: WeeklyRecap?
    @State private var history: [WeeklyRecap] = []
    @State private var pdfURL: URL?
    @State private var didLoad = false

    static let historyWeeks = 12

    private var isPlus: Bool { dependencies.entitlements.isPlus }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                if let recap {
                    summaryCard(recap)
                    numbersCard(recap)
                    startedCard(recap)
                    if !recap.trickyWords.isEmpty {
                        trickyCard(recap)
                    }
                    notesCard(recap)
                    plusSection
                } else if didLoad {
                    EmptyStateView(
                        systemImage: "chart.bar.doc.horizontal",
                        title: "No report yet",
                        message: "Once a few words have been reviewed, this week's report appears here."
                    )
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(Spacing.md)
            .readableWidth()
        }
        .screenBackground()
        .navigationTitle("Parent report")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        // Plus can be bought from the row below and the user comes straight back here.
        .onChange(of: isPlus) { _, _ in load() }
    }

    // MARK: - Cards

    private func summaryCard(_ recap: WeeklyRecap) -> some View {
        CardContainer(style: .crayon, wobbleSeed: 0x9A2E_0001) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("Last seven days")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.brandSecondary)
                Text(RecapCopy.parentHeadline(wordsMastered: recap.wordsMastered))
                    .font(Typography.sectionHeader)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                RecapDayDots(dayKeys: recap.dayKeys, studiedDays: recap.studiedDays)
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(Palette.brandSecondary)
                    Text(recap.streak > 0 ? "\(recap.streak)-day streak" : "No streak running right now")
                        .foregroundStyle(Palette.textSecondary)
                    Text("· \(RecapCopy.daysStudied(recap.studiedDays)) studied")
                        .foregroundStyle(Palette.textSecondary)
                }
                .font(Typography.caption)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func numbersCard(_ recap: WeeklyRecap) -> some View {
        CardContainer(style: .crayon, wobbleSeed: 0x9A2E_0002) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader("This week", subtitle: "Compared with the seven days before")
                comparisonRow("Reviews", value: "\(recap.reviews)", delta: recap.previous?.reviews)
                comparisonRow("Minutes studied", value: "\(recap.minutes)", delta: recap.previous?.minutes)
                comparisonRow("Words well known", value: "\(recap.wordsMastered)", delta: recap.previous?.wordsMastered)
                comparisonRow("Words started", value: "\(recap.wordsStarted)", delta: nil)
                comparisonRow("Recalled correctly", value: RecapCopy.percent(recap.accuracy), delta: nil)
                comparisonRow("Mochi level", value: "\(recap.level)", delta: nil)
            }
        }
    }

    private func comparisonRow(_ label: String, value: String, delta: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(label)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            if let delta {
                let trend = RecapCopy.Trend(delta: delta)
                HStack(spacing: 2) {
                    Image(systemName: trend.symbolName)
                    Text(RecapCopy.delta(delta))
                }
                .font(Typography.caption)
                // Neutral ink for "down": a quieter week is information, not a warning.
                .foregroundStyle(trend == .up ? Palette.success : Palette.textSecondary)
            }
            Text(value)
                .font(Typography.bodyEmphasis)
                .monospacedDigit()
                .foregroundStyle(Palette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private func startedCard(_ recap: WeeklyRecap) -> some View {
        CardContainer(style: .crayon, wobbleSeed: 0x9A2E_0003) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(
                    "Words started this week",
                    subtitle: RecapCopy.count(recap.wordsStarted, "new word")
                )
                if recap.startedWords.isEmpty {
                    Text(recap.wordsStarted > 0
                         ? "The word list will appear here after the next review."
                         : "No new words this week. Today's words on the Today screen are the easiest way to add some.")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(recap.startedWords) { word in
                        wordRow(word)
                    }
                }
            }
        }
    }

    private func trickyCard(_ recap: WeeklyRecap) -> some View {
        CardContainer(style: .crayon, wobbleSeed: 0x9A2E_0004) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader("Worth another look", subtitle: "Forgotten twice or more this week")
                ForEach(recap.trickyWords) { word in
                    wordRow(word)
                }
            }
        }
    }

    private func wordRow(_ word: RecapWord) -> some View {
        HStack {
            Text(word.headword)
                .font(Typography.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Text(word.translation ?? "—")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func notesCard(_ recap: WeeklyRecap) -> some View {
        CardContainer(style: .crayon, wobbleSeed: 0x9A2E_0005) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader("Notes")
                ForEach(notes(for: recap), id: \.self) { note in
                    HStack(alignment: .top, spacing: Spacing.xs) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Palette.brandPrimary)
                            .accessibilityHidden(true)
                        Text(note)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func notes(for recap: WeeklyRecap) -> [String] {
        RecapCopy.parentNotes(
            accuracy: recap.accuracy,
            reviews: recap.reviews,
            daysStudied: recap.studiedDays.filter { $0 }.count,
            streak: recap.streak,
            trickyCount: recap.trickyWords.count
        )
    }

    // MARK: - Plus

    @ViewBuilder
    private var plusSection: some View {
        if isPlus {
            CardContainer(style: .crayon, wobbleSeed: 0x9A2E_0006) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionHeader("History", subtitle: "The last \(Self.historyWeeks) weeks")
                    ForEach(history, id: \.weekStartKey) { week in
                        historyRow(week)
                    }
                }
            }
            if let pdfURL {
                ShareLink(item: pdfURL) {
                    Label("Export PDF", systemImage: "doc.richtext")
                        .font(Typography.buttonLabel)
                        .frame(maxWidth: .infinity, minHeight: LayoutMetrics.minimumTapTarget)
                        .foregroundStyle(Palette.onBrand)
                        .background(Palette.brandPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                }
                .pressable()
            }
        } else {
            CardContainer(style: .crayon, wobbleSeed: 0x9A2E_0007) {
                NavigationLink {
                    PlusView()
                } label: {
                    HStack(spacing: Spacing.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("12-week history and PDF export")
                                .font(Typography.bodyEmphasis)
                                .foregroundStyle(Palette.textPrimary)
                            Text("See how the weeks add up, and save a report to share with a teacher.")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        PlusBadge()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Palette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func historyRow(_ week: WeeklyRecap) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(RecapCopy.weekLabel(weekStartKey: week.weekStartKey))
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Text("\(RecapCopy.count(week.reviews, "review")) · \(week.minutes) min · \(week.wordsMastered) known")
                .font(Typography.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Loading

    private func load() {
        defer { didLoad = true }
        guard let account = dependencies.account, let preferences = account.preferences else { return }
        let now = Date()
        recap = try? dependencies.recap.recap(for: account, preferences: preferences, endingAt: now)
        guard isPlus else {
            history = []
            pdfURL = nil
            return
        }
        history = (try? dependencies.recap.history(
            for: account, preferences: preferences, weeks: Self.historyWeeks, now: now
        )) ?? []
        if let recap {
            pdfURL = ParentReportPDF.write(recap: recap, history: history)
        }
    }
}

// MARK: - PDF

/// The report as a single US-Letter-wide PDF page, for the Plus export.
@MainActor
enum ParentReportPDF {
    static let pageWidth: CGFloat = 612

    static func write(recap: WeeklyRecap, history: [WeeklyRecap]) -> URL? {
        let content = ParentReportPrintView(recap: recap, history: history)
            .frame(width: pageWidth)
            .environment(\.colorScheme, .light)
            .dynamicTypeSize(.large)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: pageWidth, height: nil)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabLoop-parent-report-\(recap.weekStartKey).pdf")
        var succeeded = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            pdf.beginPDFPage(nil)
            draw(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
            succeeded = true
        }
        return succeeded ? url : nil
    }
}

/// A flat, scroll-free layout of the report for rendering to PDF. `ImageRenderer` cannot draw a
/// `ScrollView`'s contents, so the on-screen view is not reused.
private struct ParentReportPrintView: View {
    let recap: WeeklyRecap
    let history: [WeeklyRecap]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("VocabLoop · Parent report")
                .font(Typography.caption)
                .foregroundStyle(Palette.brandSecondary)
            Text(RecapCopy.parentHeadline(wordsMastered: recap.wordsMastered))
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.textPrimary)
            RecapDayDots(dayKeys: recap.dayKeys, studiedDays: recap.studiedDays)
                .frame(maxWidth: 360)

            Group {
                line("Reviews", "\(recap.reviews)", delta: recap.previous?.reviews)
                line("Minutes studied", "\(recap.minutes)", delta: recap.previous?.minutes)
                line("Words well known", "\(recap.wordsMastered)", delta: recap.previous?.wordsMastered)
                line("Words started", "\(recap.wordsStarted)", delta: nil)
                line("Recalled correctly", RecapCopy.percent(recap.accuracy), delta: nil)
                line("Streak", "\(recap.streak) days", delta: nil)
            }

            if !recap.startedWords.isEmpty {
                heading("Words started")
                Text(recap.startedWords.map { word in
                    word.translation.map { "\(word.headword) (\($0))" } ?? word.headword
                }.joined(separator: ", "))
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !recap.trickyWords.isEmpty {
                heading("Worth another look")
                Text(recap.trickyWords.map(\.headword).joined(separator: ", "))
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !history.isEmpty {
                heading("Last \(history.count) weeks")
                ForEach(history, id: \.weekStartKey) { week in
                    line(
                        RecapCopy.weekLabel(weekStartKey: week.weekStartKey),
                        "\(RecapCopy.count(week.reviews, "review")) · \(week.minutes) min · \(week.wordsMastered) known",
                        delta: nil
                    )
                }
            }
            heading("Notes")
            ForEach(RecapCopy.parentNotes(
                accuracy: recap.accuracy,
                reviews: recap.reviews,
                daysStudied: recap.studiedDays.filter { $0 }.count,
                streak: recap.streak,
                trickyCount: recap.trickyWords.count
            ), id: \.self) { note in
                Text("• \(note)")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(Typography.sectionHeader)
            .foregroundStyle(Palette.textPrimary)
            .padding(.top, Spacing.xs)
    }

    private func line(_ label: String, _ value: String, delta: Int?) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let delta {
                Text(RecapCopy.delta(delta))
                    .foregroundStyle(Palette.textSecondary)
            }
            Text(value)
                .monospacedDigit()
        }
        .font(Typography.body)
        .foregroundStyle(Palette.textPrimary)
    }
}

#Preview {
    NavigationStack { ParentReportView() }
}
