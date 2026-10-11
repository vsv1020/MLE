import Foundation
import Observation
import OSLog
import UIKit
// `@preconcurrency` for the same reason as in `NotificationService`: only `UNAuthorizationStatus`
// is used here, but the module's annotations otherwise produce warnings nothing here can fix.
@preconcurrency import UserNotifications

/// Sends one HTTP request and returns the response's status code. Injectable so the service's
/// logic is tested without a network.
public protocol PushTransport: Sendable {
    func send(_ request: URLRequest) async throws -> Int
}

/// The real transport: an ephemeral session with a short timeout, so a dead server costs the
/// app nothing but a log line.
public struct URLSessionPushTransport: PushTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = PushRegistrationService.requestTimeout) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> Int {
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// Opt-in remote push for 活动和新功能通知 — announcements of new word packs and features.
///
/// Daily study reminders are *not* this: they stay local (``NotificationService``) and keep
/// working with this switch off. Promotional pushes need explicit opt-in (App Review 4.5.4), so
/// nothing here runs until the user turns the switch on in Settings ▸ 通知, and the server only
/// ever holds the tokens of people who did.
///
/// What is sent, to `{website}/api/push/register`: the APNs device token, the APNs environment,
/// the active learning language, the app version and the UI locale — nothing that identifies
/// the person. Turning the switch off posts the token to `/api/push/unregister`.
///
/// Every request is best effort: a failure is logged and the next launch (or language change)
/// tries again. Re-registration is deduplicated against the last successful one, so calling
/// ``refresh()`` on every launch costs nothing when nothing changed.
@MainActor
@Observable
public final class PushRegistrationService {
    public static let enabledKey = "push.announcements.enabled"
    static let lastRegistrationKey = "push.announcements.lastRegistration"
    static let pendingUnregisterKey = "push.announcements.pendingUnregister"
    public nonisolated static let requestTimeout: TimeInterval = 15

    /// The UI locale the server is told about. The app's UI is Chinese only.
    static let locale = "zh-Hans"

    /// What the server last accepted. A registration equal to this is not sent again.
    struct Registration: Codable, Equatable {
        var token: String
        var language: String
        var appVersion: String
        var environment: String
    }

    /// The JSON body of `POST /api/push/register`.
    struct RegisterBody: Encodable, Equatable {
        var token: String
        var environment: String
        var language: String
        var appVersion: String
        var locale: String
    }

    /// The JSON body of `POST /api/push/unregister`.
    struct UnregisterBody: Encodable, Equatable {
        var token: String
    }

    /// The user's choice. Off by default — promotional pushes are opt-in only.
    public private(set) var isEnabled: Bool

    /// True when the switch is on but iOS Settings has notifications turned off for the app,
    /// so Settings can point the user there.
    public private(set) var notificationsDenied = false

    private let defaults: UserDefaults
    private let transport: PushTransport
    private let baseURL: URL?
    private let languageCode: @MainActor () -> String?
    private let appVersion: String
    private let environment: String
    private let authorizationStatus: @MainActor () async -> UNAuthorizationStatus
    private let requestAuthorization: @MainActor () async -> Bool
    private let registerWithAPNs: @MainActor () -> Void
    private let logger = Logger(subsystem: "com.vocabloop.app", category: "push")

    /// The token APNs handed over in this process, if it has yet.
    @ObservationIgnored private(set) var currentToken: String?
    /// A registration being sent right now, so a second identical one does not race it.
    @ObservationIgnored private var inFlight: Registration?

    /// - Parameters:
    ///   - baseURL: the website the app links to (``AppLinks/website``). `nil` turns the whole
    ///     service into a no-op apart from remembering the switch.
    ///   - languageCode: the active learning language, read at the moment of each registration.
    public init(
        defaults: UserDefaults = .standard,
        transport: PushTransport = URLSessionPushTransport(),
        baseURL: URL? = AppLinks.website,
        languageCode: @escaping @MainActor () -> String?,
        appVersion: String = PushRegistrationService.bundleShortVersion,
        environment: String = PushRegistrationService.apnsEnvironment,
        authorizationStatus: @escaping @MainActor () async -> UNAuthorizationStatus,
        requestAuthorization: @escaping @MainActor () async -> Bool,
        registerWithAPNs: @escaping @MainActor () -> Void = {
            UIApplication.shared.registerForRemoteNotifications()
        }
    ) {
        self.defaults = defaults
        self.transport = transport
        self.baseURL = baseURL
        self.languageCode = languageCode
        self.appVersion = appVersion
        self.environment = environment
        self.authorizationStatus = authorizationStatus
        self.requestAuthorization = requestAuthorization
        self.registerWithAPNs = registerWithAPNs
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// Debug builds are signed for the APNs sandbox; TestFlight and App Store builds use
    /// production.
    public nonisolated static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    public nonisolated static var bundleShortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Hex, lower case — the form APNs and the server expect.
    public nonisolated static func hexString(_ deviceToken: Data) -> String {
        deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Entry points

    /// The Settings switch. The choice is saved first, so it sticks even if the permission
    /// prompt is declined or the server is unreachable.
    public func setEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        if enabled {
            await activate(askingPermission: true)
        } else {
            notificationsDenied = false
            await deactivate()
        }
    }

    /// At launch: re-register when on (deduplicated, so normally nothing is sent), or retry an
    /// unregister that failed last time when off. Never asks for permission.
    public func refresh() async {
        if isEnabled {
            await activate(askingPermission: false)
        } else if let pending = pendingUnregisterToken {
            await unregister(token: pending)
        }
    }

    /// The learning language changed; the server segments announcements by it.
    public func languageDidChange() async {
        guard isEnabled, let token = currentToken ?? lastRegistration?.token else { return }
        await register(token: token)
    }

    /// Re-read the authorization status, e.g. when the user comes back from iOS Settings.
    public func refreshAuthorizationStatus() async {
        guard isEnabled else {
            notificationsDenied = false
            return
        }
        let status = await authorizationStatus()
        notificationsDenied = isEnabled && status == .denied
    }

    /// From `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    public func didReceiveDeviceToken(_ token: String) async {
        currentToken = token
        guard isEnabled else { return }
        await register(token: token)
    }

    /// From `application(_:didFailToRegisterForRemoteNotificationsWithError:)`. Log only: the
    /// next launch asks APNs again.
    public func didFailToRegister(_ error: Error) {
        logger.error("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Steps

    private func activate(askingPermission: Bool) async {
        // Whatever was waiting to be removed is about to be registered again.
        pendingUnregisterToken = nil
        var status = await authorizationStatus()
        if status == .notDetermined, askingPermission {
            _ = await requestAuthorization()
            status = await authorizationStatus()
        }
        // The user may have turned the switch off while the prompt was up.
        guard isEnabled else { return }
        notificationsDenied = status == .denied
        // Every launch, as Apple recommends: the token can change. The delegate callback then
        // calls `didReceiveDeviceToken`, which registers only if something differs.
        registerWithAPNs()
        if let token = currentToken {
            await register(token: token)
        }
    }

    private func deactivate() async {
        let token = lastRegistration?.token ?? currentToken ?? inFlight?.token
        lastRegistration = nil
        guard let token else { return }
        // Kept until the server confirms, so a failed request is retried at the next launch.
        pendingUnregisterToken = token
        await unregister(token: token)
    }

    private func register(token: String) async {
        guard isEnabled, let url = endpoint("register"), let language = languageCode() else { return }
        let registration = Registration(
            token: token, language: language, appVersion: appVersion, environment: environment
        )
        guard registration != lastRegistration, registration != inFlight else { return }

        inFlight = registration
        let previous = lastRegistration
        let accepted = await post(
            url,
            body: RegisterBody(
                token: token, environment: environment, language: language,
                appVersion: appVersion, locale: Self.locale
            )
        )
        if inFlight == registration { inFlight = nil }
        guard accepted else { return }

        if !isEnabled {
            // Switched off while this was in flight: take it back off the server.
            pendingUnregisterToken = token
            await unregister(token: token)
            return
        }
        lastRegistration = registration
        logger.info("Registered for announcements (\(language, privacy: .public))")
        // APNs issued a new token: the old one would only collect undeliverable pushes.
        if let previous, previous.token != token {
            await post(endpoint("unregister"), body: UnregisterBody(token: previous.token))
        }
    }

    private func unregister(token: String) async {
        guard let url = endpoint("unregister") else {
            // No server: nothing can have been registered.
            pendingUnregisterToken = nil
            return
        }
        if await post(url, body: UnregisterBody(token: token)), pendingUnregisterToken == token {
            pendingUnregisterToken = nil
            logger.info("Unregistered from announcements")
        }
    }

    private func endpoint(_ name: String) -> URL? {
        baseURL?.appending(path: "api/push/\(name)")
    }

    /// `true` for a 2xx. Never throws: every failure is a log line.
    @discardableResult
    private func post(_ url: URL?, body: some Encodable) async -> Bool {
        guard let url else { return false }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            request.httpBody = try encoder.encode(body)
            let status = try await transport.send(request)
            guard (200..<300).contains(status) else {
                logger.error("\(url.lastPathComponent, privacy: .public) returned \(status)")
                return false
            }
            return true
        } catch {
            logger.error("\(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Stored state

    var lastRegistration: Registration? {
        get {
            defaults.data(forKey: Self.lastRegistrationKey)
                .flatMap { try? JSONDecoder().decode(Registration.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.lastRegistrationKey)
            } else {
                defaults.removeObject(forKey: Self.lastRegistrationKey)
            }
        }
    }

    var pendingUnregisterToken: String? {
        get { defaults.string(forKey: Self.pendingUnregisterKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.pendingUnregisterKey)
            } else {
                defaults.removeObject(forKey: Self.pendingUnregisterKey)
            }
        }
    }
}
