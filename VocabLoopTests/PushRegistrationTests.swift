import XCTest
@preconcurrency import UserNotifications
@testable import VocabLoop

/// Records every request and answers with a fixed status. An actor, so the service can call it
/// across its isolation boundary like the real `URLSession` transport.
private actor RecordingTransport: PushTransport {
    private(set) var requests: [URLRequest] = []
    private var status: Int

    init(status: Int = 204) { self.status = status }

    func setStatus(_ status: Int) { self.status = status }

    func send(_ request: URLRequest) async throws -> Int {
        requests.append(request)
        return status
    }

    /// Path's last component ("register" / "unregister") and decoded JSON body, in order.
    func calls() -> [(endpoint: String, body: [String: String])] {
        requests.map { request in
            let body = request.httpBody
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
            return (request.url?.lastPathComponent ?? "", body)
        }
    }
}

/// ``PushRegistrationService`` — opt-in remote push for 活动和新功能通知.
@MainActor
final class PushRegistrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var transport: RecordingTransport!
    private var language = "en"
    private var status: UNAuthorizationStatus = .authorized
    private var permissionRequests = 0
    private var apnsRegistrations = 0

    override func setUp() {
        super.setUp()
        suiteName = "PushRegistrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        transport = RecordingTransport()
        language = "en"
        status = .authorized
        permissionRequests = 0
        apnsRegistrations = 0
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        transport = nil
        super.tearDown()
    }

    private func makeService(baseURL: URL? = URL(string: "https://example.com/")) -> PushRegistrationService {
        PushRegistrationService(
            defaults: defaults,
            transport: transport,
            baseURL: baseURL,
            languageCode: { [unowned self] in self.language },
            appVersion: "1.0.12",
            environment: "production",
            authorizationStatus: { [unowned self] in self.status },
            requestAuthorization: { [unowned self] in
                self.permissionRequests += 1
                self.status = .authorized
                return true
            },
            registerWithAPNs: { [unowned self] in self.apnsRegistrations += 1 }
        )
    }

    // MARK: - Opt-in

    func testOffByDefaultAndSilent() async {
        let service = makeService()
        XCTAssertFalse(service.isEnabled, "promotional pushes are opt-in only (App Review 4.5.4)")

        await service.refresh()
        await service.didReceiveDeviceToken("abcd")
        await service.languageDidChange()

        let calls = await transport.calls()
        XCTAssertTrue(calls.isEmpty, "nothing is sent until the user turns the switch on")
        XCTAssertEqual(apnsRegistrations, 0)
    }

    func testTurningOnAsksPermissionOnlyWhenUndetermined() async {
        status = .notDetermined
        let service = makeService()

        await service.setEnabled(true)

        XCTAssertEqual(permissionRequests, 1)
        XCTAssertEqual(apnsRegistrations, 1)
        XCTAssertTrue(defaults.bool(forKey: PushRegistrationService.enabledKey))

        await service.setEnabled(false)
        await service.setEnabled(true)
        XCTAssertEqual(permissionRequests, 1, "already decided: no second prompt")
    }

    func testRegisterBodyShape() async throws {
        let service = makeService()
        await service.setEnabled(true)
        await service.didReceiveDeviceToken("a1b2c3")

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/push/register")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 15)

        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        )
        XCTAssertEqual(body, [
            "token": "a1b2c3",
            "environment": "production",
            "language": "en",
            "appVersion": "1.0.12",
            "locale": "zh-Hans",
        ])
    }

    func testHexEncodingOfDeviceToken() {
        let token = Data([0x00, 0x0f, 0xab, 0xff])
        XCTAssertEqual(PushRegistrationService.hexString(token), "000fabff")
    }

    // MARK: - Dedup

    func testUnchangedRegistrationIsNotSentAgain() async {
        let service = makeService()
        await service.setEnabled(true)
        await service.didReceiveDeviceToken("aa")
        await service.didReceiveDeviceToken("aa")

        // A new launch with the same token, language and version.
        let relaunched = makeService()
        await relaunched.refresh()
        await relaunched.didReceiveDeviceToken("aa")

        let calls = await transport.calls()
        XCTAssertEqual(calls.map(\.endpoint), ["register"])
        XCTAssertEqual(apnsRegistrations, 2, "APNs is still asked every launch — the token can change")
    }

    func testLanguageChangeReRegisters() async {
        let service = makeService()
        await service.setEnabled(true)
        await service.didReceiveDeviceToken("aa")

        language = "fr"
        await service.languageDidChange()
        await service.languageDidChange()

        let calls = await transport.calls()
        XCTAssertEqual(calls.map(\.endpoint), ["register", "register"])
        XCTAssertEqual(calls.last?.body["language"], "fr")
    }

    func testFailedRegistrationIsRetried() async {
        await transport.setStatus(500)
        let service = makeService()
        await service.setEnabled(true)
        await service.didReceiveDeviceToken("aa")

        await transport.setStatus(204)
        await service.didReceiveDeviceToken("aa")

        let calls = await transport.calls()
        XCTAssertEqual(calls.map(\.endpoint), ["register", "register"])
        XCTAssertEqual(service.lastRegistration?.token, "aa")
    }

    func testNewTokenUnregistersTheOldOne() async {
        let service = makeService()
        await service.setEnabled(true)
        await service.didReceiveDeviceToken("old")
        await service.didReceiveDeviceToken("new")

        let calls = await transport.calls()
        XCTAssertEqual(calls.map(\.endpoint), ["register", "register", "unregister"])
        XCTAssertEqual(calls[1].body["token"], "new")
        XCTAssertEqual(calls[2].body, ["token": "old"])
    }

    // MARK: - Opt-out

    func testDisablingUnregistersTheLastToken() async {
        let service = makeService()
        await service.setEnabled(true)
        await service.didReceiveDeviceToken("aa")

        await service.setEnabled(false)

        let calls = await transport.calls()
        XCTAssertEqual(calls.map(\.endpoint), ["register", "unregister"])
        XCTAssertEqual(calls.last?.body, ["token": "aa"])
        XCTAssertNil(service.lastRegistration)
        XCTAssertNil(service.pendingUnregisterToken)
        XCTAssertFalse(defaults.bool(forKey: PushRegistrationService.enabledKey))

        // On again: the same token is registered again rather than deduplicated away.
        await service.setEnabled(true)
        let again = await transport.calls()
        XCTAssertEqual(again.map(\.endpoint), ["register", "unregister", "register"])
    }

    func testFailedUnregisterIsRetriedAtNextLaunch() async {
        let service = makeService()
        await service.setEnabled(true)
        await service.didReceiveDeviceToken("aa")

        await transport.setStatus(503)
        await service.setEnabled(false)
        XCTAssertEqual(service.pendingUnregisterToken, "aa")

        await transport.setStatus(204)
        let relaunched = makeService()
        await relaunched.refresh()

        let calls = await transport.calls()
        XCTAssertEqual(calls.map(\.endpoint), ["register", "unregister", "unregister"])
        XCTAssertNil(relaunched.pendingUnregisterToken)
        XCTAssertEqual(apnsRegistrations, 1, "off: APNs is not asked for a token at launch")
    }

    // MARK: - Configuration

    func testNoWebsiteMeansNoRequests() async {
        let service = makeService(baseURL: nil)
        await service.setEnabled(true)
        await service.didReceiveDeviceToken("aa")
        await service.setEnabled(false)

        let calls = await transport.calls()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(service.pendingUnregisterToken)
    }

    func testDeniedNotificationsAreReported() async {
        status = .denied
        let service = makeService()
        await service.setEnabled(true)
        XCTAssertTrue(service.notificationsDenied, "Settings shows the hint to open iOS Settings")

        status = .authorized
        await service.refreshAuthorizationStatus()
        XCTAssertFalse(service.notificationsDenied)
    }
}
