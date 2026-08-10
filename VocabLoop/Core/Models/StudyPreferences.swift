import Foundation
import SwiftData

/// Everything the user can tune, owned by their ``UserAccount``.
///
/// Stored per-account rather than in `UserDefaults` so that preferences travel with
/// the account when sync is enabled, and so switching accounts on a shared device
/// does not leak one person's settings into another's.
@Model
public final class StudyPreferences {
    // MARK: Language

    public var activeLanguageCode: String
    /// Languages whose seed packs have been imported.
    public var installedLanguageCodes: [String]
    /// The learner's own language(s), most preferred first. Drives which translation
    /// is picked out of a sense's `translations` dictionary.
    public var nativeLanguageCodes: [String]

    // MARK: Daily targets

    /// Reviews per day the progress ring fills toward.
    public var dailyGoal: Int
    /// New words the daily batch may offer.
    public var newWordsPerDay: Int
    /// Cap on one sitting, so a large backlog does not present as an unwinnable wall.
    public var maxReviewsPerSession: Int

    // MARK: Scheduling

    public var schedulerRaw: String
    public var desiredRetention: Double
    public var maximumIntervalDays: Double
    public var learningStepsMinutes: [Double]
    public var relearningStepsMinutes: [Double]
    public var fuzzEnabled: Bool
    /// Persisted FSRS weights. `nil` means "use the published defaults" and is what
    /// a future per-user optimiser would write to.
    public var fsrsWeights: [Double]?
    public var fsrsParametersVersion: String

    // MARK: Content selection

    public var cefrFloorRaw: String
    public var cefrCeilingRaw: String
    /// Which directions get a card when a word is enrolled.
    public var enabledDirectionsRaw: [String]

    // MARK: Notifications

    public var remindersEnabled: Bool
    public var reminderHour: Int
    public var reminderMinute: Int
    public var dailyWordNotificationEnabled: Bool

    // MARK: Presentation

    public var autoPlayAudio: Bool
    public var showPhonetics: Bool
    /// Show the interval each rating button would produce. On by default — seeing the
    /// consequence is what makes the scheduler feel trustworthy.
    public var showIntervalPreview: Bool
    public var hapticsEnabled: Bool

    // MARK: Day boundary

    /// The user's timezone at last write, so a day boundary computed on one device
    /// matches another. Recorded rather than read live because a streak must not break
    /// because someone got on a plane.
    public var timeZoneIdentifier: String
    /// Hour at which "today" rolls over, `0…23`. Defaults to 4am: someone studying at
    /// 1am is finishing yesterday, and telling them they broke their streak is how you
    /// lose a user.
    public var dayStartHour: Int

    public var updatedAt: Date

    public init(
        activeLanguage: LearningLanguage = .default,
        now: Date = Date()
    ) {
        self.activeLanguageCode = activeLanguage.rawValue
        self.installedLanguageCodes = [activeLanguage.rawValue]
        self.nativeLanguageCodes = StudyPreferences.systemNativeLanguageCodes()
        self.dailyGoal = 30
        self.newWordsPerDay = 8
        self.maxReviewsPerSession = 60
        self.schedulerRaw = SchedulerKind.fsrs5.rawValue
        self.desiredRetention = 0.90
        self.maximumIntervalDays = 365 * 5
        self.learningStepsMinutes = [1, 10]
        self.relearningStepsMinutes = [10]
        self.fuzzEnabled = true
        self.fsrsWeights = nil
        self.fsrsParametersVersion = FSRSParameters.fsrs5Default.version
        self.cefrFloorRaw = CEFRLevel.a1.rawValue
        self.cefrCeilingRaw = CEFRLevel.b2.rawValue
        self.enabledDirectionsRaw = [CardDirection.recognition.rawValue]
        self.remindersEnabled = false
        self.reminderHour = 20
        self.reminderMinute = 0
        self.dailyWordNotificationEnabled = false
        self.autoPlayAudio = false
        self.showPhonetics = true
        self.showIntervalPreview = true
        self.hapticsEnabled = true
        self.timeZoneIdentifier = TimeZone.current.identifier
        self.dayStartHour = 4
        self.updatedAt = now
    }

    // MARK: - Typed accessors

    public var activeLanguage: LearningLanguage {
        get { LearningLanguage(code: activeLanguageCode) ?? .default }
        set { activeLanguageCode = newValue.rawValue }
    }

    public var installedLanguages: [LearningLanguage] {
        installedLanguageCodes.compactMap { LearningLanguage(code: $0) }
    }

    public var scheduler: SchedulerKind {
        get { SchedulerKind(rawValue: schedulerRaw) ?? .fsrs5 }
        set { schedulerRaw = newValue.rawValue }
    }

    public var cefrFloor: CEFRLevel {
        get { CEFRLevel(rawValue: cefrFloorRaw) ?? .a1 }
        set { cefrFloorRaw = newValue.rawValue }
    }

    public var cefrCeiling: CEFRLevel {
        get { CEFRLevel(rawValue: cefrCeilingRaw) ?? .c1 }
        set { cefrCeilingRaw = newValue.rawValue }
    }

    /// Always contains at least `.recognition` — a word with no cards at all cannot be
    /// studied, and an empty directions list is easy to produce by unticking both boxes.
    public var enabledDirections: [CardDirection] {
        get {
            let parsed = enabledDirectionsRaw.compactMap(CardDirection.init(rawValue:))
            return parsed.isEmpty ? [.recognition] : parsed
        }
        set {
            let sanitised = newValue.isEmpty ? [CardDirection.recognition] : newValue
            enabledDirectionsRaw = sanitised.map(\.rawValue)
        }
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    /// Assembles the value type the schedulers take. Always sanitised, so a corrupt
    /// persisted value cannot produce absurd intervals.
    public var schedulerConfig: SchedulerConfig {
        var parameters = FSRSParameters.fsrs5Default
        if let fsrsWeights, fsrsWeights.count >= FSRSParameters.fsrs5WeightCount {
            parameters = FSRSParameters(weights: fsrsWeights, version: fsrsParametersVersion)
        }
        return SchedulerConfig(
            desiredRetention: desiredRetention,
            maximumInterval: maximumIntervalDays,
            learningStepsMinutes: learningStepsMinutes,
            relearningStepsMinutes: relearningStepsMinutes,
            fuzzEnabled: fuzzEnabled,
            fsrsParameters: parameters.validated
        ).sanitised
    }

    public func makeScheduler() -> any Scheduler {
        SchedulerFactory.make(scheduler, config: schedulerConfig)
    }

    public var reminderTimeComponents: DateComponents {
        DateComponents(hour: reminderHour, minute: reminderMinute)
    }

    public func touch(_ now: Date = Date()) { updatedAt = now }

    /// The learner's own languages, from system settings, so translations are useful
    /// out of the box without an onboarding question.
    static func systemNativeLanguageCodes() -> [String] {
        var codes = Locale.preferredLanguages.compactMap { tag -> String? in
            tag.split(separator: "-").first.map(String.init)?.lowercased()
        }
        // Guarantee a fallback that our seed packs always carry.
        if !codes.contains("en") { codes.append("en") }
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
    }
}
