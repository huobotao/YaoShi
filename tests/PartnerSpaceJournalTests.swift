import Foundation
import CryptoKit

private final class JournalProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((JournalProtocol) -> Void)?
    static var held: JournalProtocol?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func reply(_ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    static func hold(_ value: JournalProtocol) { lock.lock(); held = value; lock.unlock() }
    static func take() -> JournalProtocol? {
        lock.lock(); defer { lock.unlock() }
        let value = held; held = nil; return value
    }
}

@main struct PartnerSpaceJournalTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("FAIL: " + message) }
        checks += 1
    }
    static func credentials(_ space: String) -> PartnerSpaceCredentials {
        PartnerSpaceCredentials(app: .yaoShi, role: .partner,
            baseURL: URL(string: "https://journal-test.invalid")!, spaceID: space,
            accessToken: "SYNTHETIC-TEST-TOKEN", encryptionKey: Data(repeating: 42, count: 32),
            joinedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
    static func queued() -> PartnerQueuedEvent {
        PartnerQueuedEvent(id: UUID(), payload: Data("synthetic-medication".utf8), createdAt: Date())
    }
    static func incoming() -> PartnerReceivedEvent {
        PartnerReceivedEvent(id: UUID(), author: .owner, revision: 1, createdAt: Date(), payload: Data())
    }
    private static func heldRequest() async throws -> JournalProtocol {
        for _ in 0..<5000 {
            if let value = JournalProtocol.take() { return value }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Timed out waiting for mock request")
    }
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yaoshi-journal-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        PartnerSyncJournalStore.testingDirectory = directory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JournalProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = PartnerSyncClient(session: session)
        let a = credentials("space-a"), b = credentials("space-b")

        // Legacy migration keeps pending medication events, while a later switch archives them.
        let original = queued()
        var legacy = PartnerSyncJournal(); legacy.lastRevision = 100; legacy.outbox = [original]
        let migration = PartnerSharingCoordinator(testingClient: client, credentials: [.yaoShi: a], journals: [.yaoShi: legacy])
        try migration.testingSetCredentials(a, prepare: true)
        check(migration.journals[.yaoShi]?.sharingIdentity == a.locationSharingIdentity, "legacy identity bound")
        check(migration.journals[.yaoShi]?.outbox == [original], "legacy outbox retained")
        check(migration.journals[.yaoShi]?.lastRevision == 100, "legacy cursor retained")
        try migration.testingSetCredentials(b, prepare: true)
        check(migration.journals[.yaoShi]?.lastRevision == 0, "new space starts at zero")
        check(migration.journals[.yaoShi]?.outbox.isEmpty == true, "old outbox never sent to new space")
        let archives = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("archive-") }
        check(archives.count == 1, "one local archive created")
        let archived = try JSONDecoder().decode(PartnerSyncJournal.self, from: Data(contentsOf: archives[0]))
        check(archived.outbox == [original] && archived.lastRevision == 100 && archived.sharingIdentity == a.locationSharingIdentity,
              "archive retains complete original queue and identity")
        JournalProtocol.handler = { JournalProtocol.hold($0) }
        let migrationTask = Task { await migration.sync(app: .yaoShi) }
        let migrationRequest = try await heldRequest()
        check(migrationRequest.request.url?.query == "after=0", "new space fetch actually requests zero")
        migrationRequest.reply("{\"events\":[]}")
        await migrationTask.value

        // Mutate queues while fetch and append are held at real URLSession suspension points.
        var journal = PartnerSyncJournal(); journal.sharingIdentity = a.locationSharingIdentity
        let first = queued(), ackFetch = incoming(), ackAppend = incoming()
        journal.outbox = [first]; journal.incoming = [ackFetch, ackAppend]
        let coordinator = PartnerSharingCoordinator(testingClient: client, credentials: [.yaoShi: a], journals: [.yaoShi: journal])
        let task = Task { await coordinator.sync(app: .yaoShi) }
        let fetch = try await heldRequest()
        let duringFetch = queued()
        let acceptedFetch = await coordinator.enqueue(app: .yaoShi, eventID: duringFetch.id, payload: duringFetch.payload)
        check(acceptedFetch, "enqueue during fetch accepted")
        coordinator.acknowledgeReceived(app: .yaoShi, eventID: ackFetch.id)
        let eventID = UUID()
        let sealed = try AES.GCM.seal(Data("synthetic-location-payload".utf8), using: SymmetricKey(data: a.encryptionKey)).combined!.base64EncodedString()
        fetch.reply("{\"events\":[{\"eventID\":\"\(eventID)\",\"author\":\"owner\",\"revision\":2,\"createdAt\":\"2027-01-15T08:00:00Z\",\"ciphertext\":\"\(sealed)\"}]}")
        let append = try await heldRequest()
        check(append.request.httpMethod == "POST", "fetch proceeds to append")
        check(coordinator.journals[.yaoShi]?.outbox.contains(where: { $0.id == duringFetch.id }) == true, "fetch does not overwrite concurrent enqueue")
        check(coordinator.journals[.yaoShi]?.incoming.contains(where: { $0.id == ackFetch.id }) == false, "fetch does not resurrect acknowledgement")
        check(coordinator.journals[.yaoShi]?.incoming.first(where: { $0.id == eventID })?.sourceSharingIdentity == a.locationSharingIdentity, "decrypted incoming event carries source identity")
        let duringAppend = queued()
        let acceptedAppend = await coordinator.enqueue(app: .yaoShi, eventID: duringAppend.id, payload: duringAppend.payload)
        check(acceptedAppend, "enqueue during append accepted")
        coordinator.acknowledgeReceived(app: .yaoShi, eventID: ackAppend.id)
        append.reply("{\"revision\":3}")
        let secondAppend = try await heldRequest()
        check(coordinator.journals[.yaoShi]?.outbox.contains(where: { $0.id == duringAppend.id }) == true, "append does not overwrite concurrent enqueue")
        check(coordinator.journals[.yaoShi]?.incoming.contains(where: { $0.id == ackAppend.id }) == false, "append does not resurrect acknowledgement")
        secondAppend.reply("{\"revision\":4}")
        let thirdAppend = try await heldRequest(); thirdAppend.reply("{\"revision\":5}")
        await task.value
        check(coordinator.journals[.yaoShi]?.outbox.isEmpty == true, "all three queued events drain")

        // A response from the previous credentials cannot write into the replacement journal.
        let stale = PartnerSharingCoordinator(testingClient: client, credentials: [.yaoShi: a], journals: [.yaoShi: journal])
        let staleTask = Task { await stale.sync(app: .yaoShi) }
        let staleFetch = try await heldRequest()
        try stale.testingSetCredentials(b, prepare: true)
        let replacement = stale.journals[.yaoShi]
        staleFetch.reply("{\"events\":[]}")
        await staleTask.value
        check(stale.journals[.yaoShi] == replacement, "stale fetch leaves new-space journal unchanged")
        let staleAppendCoordinator = PartnerSharingCoordinator(testingClient: client, credentials: [.yaoShi: a], journals: [.yaoShi: journal])
        let staleAppendTask = Task { await staleAppendCoordinator.sync(app: .yaoShi) }
        let fetchBeforeAppend = try await heldRequest(); fetchBeforeAppend.reply("{\"events\":[]}")
        let oldAppend = try await heldRequest()
        try staleAppendCoordinator.testingSetCredentials(b, prepare: true)
        let replacementAfterAppend = staleAppendCoordinator.journals[.yaoShi]
        oldAppend.reply("{\"revision\":500}")
        await staleAppendTask.value
        check(staleAppendCoordinator.journals[.yaoShi] == replacementAfterAppend, "stale append leaves new-space journal unchanged")
        print("PASS: \(checks) partner-space journal checks")
    }
}
