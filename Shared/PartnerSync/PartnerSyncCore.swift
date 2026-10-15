import Foundation
import Combine
import CryptoKit
import Security

/// Cross-account relay for the private BeiYun and YaoShi apps.
/// Only AES-GCM ciphertext is sent to the relay; this file contains no app records.
enum PartnerApp: String, Codable, CaseIterable, Hashable {
    case beiYun = "beiyun"
    case yaoShi = "yaoshi"

    var urlScheme: String { self == .beiYun ? "beiyun-partner" : "yaoshi-21012r7-partner" }
    private var storageNamespace: String { self == .yaoShi ? "yaoshi.archive.v21012r7" : rawValue }
    var keychainService: String { "com.richardhuo.\(storageNamespace).partner-sharing.\(PartnerBuildConfiguration.role.rawValue)" }
    var keychainGroup: String { "P272ZF8FA9.com.richardhuo.\(storageNamespace).partner.\(PartnerBuildConfiguration.role.rawValue)" }

    static var current: PartnerApp {
        #if BEIYUN_APP || BEIYUN_PARTNER
        return .beiYun
        #else
        return .yaoShi
        #endif
    }
}

enum PartnerRole: String, Codable, Hashable { case owner, partner }

enum PartnerBuildConfiguration {
    #if YAOSHI_PARTNER || BEIYUN_PARTNER
    static let role: PartnerRole = .partner
    #else
    static let role: PartnerRole = .owner
    #endif
}

struct PartnerSpaceCredentials: Codable, Equatable {
    var app: PartnerApp
    var role: PartnerRole
    var baseURL: URL
    var spaceID: String
    var accessToken: String
    var encryptionKey: Data
    var joinedAt: Date
}

struct PartnerInvite: Equatable {
    var app: PartnerApp
    var spaceID: String
    var baseURL: URL
    var inviteToken: String
    var encryptionKey: Data

    var url: URL? {
        var components = URLComponents()
        components.scheme = app.urlScheme
        components.host = "join"
        components.queryItems = [
            URLQueryItem(name: "space", value: spaceID),
            URLQueryItem(name: "server", value: baseURL.absoluteString),
            URLQueryItem(name: "invite", value: inviteToken)
        ]
        components.fragment = "key=\(encryptionKey.base64URLEncoded)"
        return components.url
    }

    static func parse(_ url: URL) -> PartnerInvite? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let app = PartnerApp.allCases.first(where: { $0.urlScheme == components.scheme }),
              components.host == "join",
              let space = components.queryItems?.first(where: { $0.name == "space" })?.value,
              let serverText = components.queryItems?.first(where: { $0.name == "server" })?.value,
              let server = URL(string: serverText), server.scheme?.lowercased() == "https",
              let token = components.queryItems?.first(where: { $0.name == "invite" })?.value,
              let fragment = components.fragment, fragment.hasPrefix("key="),
              let key = Data(base64URLString: String(fragment.dropFirst(4))), key.count == 32 else {
            return nil
        }
        return PartnerInvite(app: app, spaceID: space, baseURL: server,
                             inviteToken: token, encryptionKey: key)
    }
}

struct EncryptedPartnerEvent: Codable, Identifiable, Equatable {
    var id: UUID
    var author: PartnerRole
    var revision: Int
    var createdAt: Date
    /// Server-side routing hint. Missing on older server responses.
    var notifyPartner: Bool? = nil
    /// AES-GCM combined representation. The relay cannot read the payload.
    var sealedData: Data
}

/// A durable, idempotent send queue. The app writes an event here before trying
/// the network, so a server outage never blocks the local record or loses a send.
struct PartnerQueuedEvent: Codable, Identifiable, Equatable {
    var id: UUID
    var payload: Data
    var createdAt: Date
    /// A non-sensitive routing hint. The payload itself remains end-to-end encrypted.
    var notifyPartner: Bool? = nil
}

/// Decrypted events remain queued until the owning app has applied them locally.
struct PartnerReceivedEvent: Codable, Identifiable, Equatable {
    var id: UUID
    var author: PartnerRole
    var revision: Int
    var createdAt: Date
    var payload: Data
    var notifyPartner: Bool? = nil
}

struct PartnerSyncJournal: Codable, Equatable {
    var schemaVersion = 1
    var lastRevision = 0
    var outbox: [PartnerQueuedEvent] = []
    var incoming: [PartnerReceivedEvent] = []
}

enum PartnerSyncJournalStore {
    static func load(app: PartnerApp) throws -> PartnerSyncJournal {
        let file = url(app: app)
        guard FileManager.default.fileExists(atPath: file.path) else { return PartnerSyncJournal() }
        return try JSONDecoder().decode(PartnerSyncJournal.self, from: Data(contentsOf: file))
    }

    static func save(_ journal: PartnerSyncJournal, app: PartnerApp) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        try data.write(to: url(app: app), options: [.atomic, .completeFileProtection])
    }

    private static func url(app: PartnerApp) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("partner-\(app.rawValue)-sync-journal.json")
    }
}

enum PartnerSyncError: LocalizedError {
    case invalidServerURL
    case invalidInvite
    case missingCredentials
    case keychain(OSStatus)
    case server(Int, String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "共享服务地址无效"
        case .invalidInvite: return "共享邀请链接无效或已过期"
        case .missingCredentials: return "尚未加入共享空间"
        case .keychain(let status): return "共享凭据无法安全保存（\(status)）"
        case .server(let status, let message): return "共享服务错误（\(status)）：\(message)"
        case .malformedResponse: return "共享服务返回的数据无法读取"
        }
    }
}

/// Credentials are stored in the app's own synchronizable Keychain group.
/// Only tokens and a random encryption key are stored here, never health records.
enum PartnerCredentialVault {
    static func save(_ value: PartnerSpaceCredentials) throws {
        let account = "space-\(value.app.rawValue)"
        let query = baseQuery(app: value.app, account: account)
        let encoded = try JSONEncoder().encode(value)
        let attrs: [String: Any] = [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = encoded
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw PartnerSyncError.keychain(added) }
        } else if status != errSecSuccess {
            throw PartnerSyncError.keychain(status)
        }
    }

    static func load(app: PartnerApp) throws -> PartnerSpaceCredentials? {
        var query = baseQuery(app: app, account: "space-\(app.rawValue)")
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw PartnerSyncError.keychain(status)
        }
        return try JSONDecoder().decode(PartnerSpaceCredentials.self, from: data)
    }

    static func remove(app: PartnerApp) throws {
        let status = SecItemDelete(baseQuery(app: app, account: "space-\(app.rawValue)") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PartnerSyncError.keychain(status)
        }
    }

    private static func baseQuery(app: PartnerApp, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: app.keychainService,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: app.keychainGroup,
         kSecAttrSynchronizable as String: true]
    }
}

struct PartnerSyncClient {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func createOwnerSpace(app: PartnerApp, baseURL: URL) async throws -> PartnerSpaceCredentials {
        guard ["https"].contains(baseURL.scheme?.lowercased() ?? "") else {
            throw PartnerSyncError.invalidServerURL
        }
        let spaceID = try Self.randomToken(bytes: 24)
        let ownerToken = try Self.randomToken(bytes: 32)
        let key = try Self.randomBytes(count: 32)
        let body = CreateSpaceRequest(app: app, spaceID: spaceID, ownerToken: ownerToken)
        let _: EmptyResponse = try await send(path: "/v1/spaces", method: "POST", body: body,
                                              baseURL: baseURL, token: nil)
        return PartnerSpaceCredentials(app: app, role: .owner, baseURL: baseURL,
                                       spaceID: spaceID, accessToken: ownerToken,
                                       encryptionKey: key, joinedAt: Date())
    }

    func makeInvite(credentials: PartnerSpaceCredentials, lifetimeHours: Int = 168) async throws -> PartnerInvite {
        guard credentials.role == .owner else { throw PartnerSyncError.missingCredentials }
        let body = CreateInviteRequest(lifetimeHours: min(max(lifetimeHours, 1), 720))
        let response: InviteResponse = try await send(
            path: "/v1/spaces/\(credentials.spaceID)/invite", method: "POST", body: body,
            baseURL: credentials.baseURL, token: credentials.accessToken)
        return PartnerInvite(app: credentials.app, spaceID: credentials.spaceID,
                             baseURL: credentials.baseURL,
                             inviteToken: response.inviteToken, encryptionKey: credentials.encryptionKey)
    }

    func accept(_ invite: PartnerInvite) async throws -> PartnerSpaceCredentials {
        let baseURL = invite.baseURL
        guard baseURL.scheme?.lowercased() == "https" else { throw PartnerSyncError.invalidServerURL }
        let body = AcceptInviteRequest(inviteToken: invite.inviteToken)
        let response: AcceptInviteResponse = try await send(
            path: "/v1/spaces/\(invite.spaceID)/accept", method: "POST", body: body,
            baseURL: baseURL, token: nil)
        return PartnerSpaceCredentials(app: invite.app, role: .partner, baseURL: baseURL,
                                       spaceID: invite.spaceID, accessToken: response.partnerToken,
                                       encryptionKey: invite.encryptionKey, joinedAt: Date())
    }

    func append(_ plaintext: Data, eventID: UUID, createdAt: Date = Date(),
                credentials: PartnerSpaceCredentials) async throws -> Int {
        try await append(plaintext, eventID: eventID, createdAt: createdAt,
                         notifyPartner: false, credentials: credentials)
    }

    func append(_ plaintext: Data, eventID: UUID, createdAt: Date,
                notifyPartner: Bool,
                credentials: PartnerSpaceCredentials) async throws -> Int {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: credentials.encryptionKey))
        guard let combined = box.combined else { throw PartnerSyncError.malformedResponse }
        let body = AppendEventRequest(eventID: eventID, ciphertext: combined.base64EncodedString(),
                                      notifyPartner: notifyPartner, createdAt: createdAt)
        let response: RevisionResponse = try await send(
            path: "/v1/spaces/\(credentials.spaceID)/events", method: "POST", body: body,
            baseURL: credentials.baseURL, token: credentials.accessToken)
        return response.revision
    }

    func registerPushToken(_ deviceToken: String, environment: String,
                           credentials: PartnerSpaceCredentials) async throws {
        guard credentials.app == .yaoShi, credentials.role == .partner,
              ["development", "production"].contains(environment) else {
            throw PartnerSyncError.invalidInvite
        }
        let body = RegisterPushTokenRequest(deviceToken: deviceToken, environment: environment)
        let _: EmptyResponse = try await send(
            path: "/v1/spaces/\(credentials.spaceID)/push-token", method: "POST", body: body,
            baseURL: credentials.baseURL, token: credentials.accessToken)
    }

    func fetch(after revision: Int = 0, credentials: PartnerSpaceCredentials) async throws -> [EncryptedPartnerEvent] {
        guard var components = URLComponents(url: endpoint(credentials.baseURL,
            path: "/v1/spaces/\(credentials.spaceID)/events"), resolvingAgainstBaseURL: false) else {
            throw PartnerSyncError.invalidServerURL
        }
        components.queryItems = [URLQueryItem(name: "after", value: String(max(0, revision)))]
        guard let url = components.url else { throw PartnerSyncError.invalidServerURL }
        let response: EventsResponse = try await send(url: url, method: "GET", body: Optional<EmptyRequest>.none,
                                                       token: credentials.accessToken)
        return try response.events.map { event in
            guard let sealed = Data(base64Encoded: event.ciphertext) else { throw PartnerSyncError.malformedResponse }
            return EncryptedPartnerEvent(id: event.eventID, author: event.author,
                                         revision: event.revision, createdAt: event.createdAt,
                                         notifyPartner: event.notifyPartner,
                                         sealedData: sealed)
        }
    }

    func open(_ event: EncryptedPartnerEvent, credentials: PartnerSpaceCredentials) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: event.sealedData)
        return try AES.GCM.open(box, using: SymmetricKey(data: credentials.encryptionKey))
    }

    func revokePartner(credentials: PartnerSpaceCredentials) async throws {
        guard credentials.role == .owner else { throw PartnerSyncError.missingCredentials }
        let _: EmptyResponse = try await send(
            path: "/v1/spaces/\(credentials.spaceID)/partner", method: "DELETE",
            body: Optional<EmptyRequest>.none, baseURL: credentials.baseURL,
            token: credentials.accessToken)
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String, method: String, body: Body?, baseURL: URL, token: String?
    ) async throws -> Response {
        try await send(url: endpoint(baseURL, path: path), method: method, body: body, token: token)
    }

    private func send<Body: Encodable, Response: Decodable>(
        url: URL, method: String, body: Body?, token: String?
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PartnerSyncError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error) ?? "请求未完成"
            throw PartnerSyncError.server(http.statusCode, message)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(Response.self, from: data) else {
            throw PartnerSyncError.malformedResponse
        }
        return value
    }

    private func endpoint(_ baseURL: URL, path: String) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw PartnerSyncError.keychain(status) }
        return Data(bytes)
    }

    private static func randomToken(bytes: Int) throws -> String { try randomBytes(count: bytes).base64URLEncoded }
}

@MainActor
final class PartnerSharingCoordinator: ObservableObject {
    static let shared = PartnerSharingCoordinator()

    @Published private(set) var credentials: [PartnerApp: PartnerSpaceCredentials] = [:]
    @Published private(set) var inviteLinks: [PartnerApp: URL] = [:]
    @Published private(set) var status: [PartnerApp: String] = [:]
    @Published private(set) var workingApps: Set<PartnerApp> = []
    @Published private(set) var journals: [PartnerApp: PartnerSyncJournal] = [:]

    private let client = PartnerSyncClient()
    private var journalLoadErrors: Set<PartnerApp> = []

    private init() {
        reloadCredentials()
        for app in [PartnerApp.current] {
            do { journals[app] = try PartnerSyncJournalStore.load(app: app) }
            catch {
                journalLoadErrors.insert(app)
                status[app] = "本机待同步队列无法读取：\(error.localizedDescription)"
            }
        }
    }

    func reloadCredentials() {
        for app in [PartnerApp.current] {
            do { credentials[app] = try PartnerCredentialVault.load(app: app) }
            catch { status[app] = error.localizedDescription }
        }
    }

    func createInvite(app: PartnerApp, serverText: String) async {
        guard PartnerBuildConfiguration.role == .owner else {
            status[app] = "伴侣只读版不能创建共享空间或授予权限"
            return
        }
        guard !workingApps.contains(app) else { return }
        guard let server = URL(string: serverText.trimmingCharacters(in: .whitespacesAndNewlines)),
              server.scheme?.lowercased() == "https", server.host != nil else {
            status[app] = "请输入有效的 HTTPS 共享服务地址"
            return
        }
        workingApps.insert(app)
        defer { workingApps.remove(app) }
        do {
            let owner: PartnerSpaceCredentials
            if let current = credentials[app], current.role == .owner {
                owner = current
            } else {
                owner = try await client.createOwnerSpace(app: app, baseURL: server)
                try PartnerCredentialVault.save(owner)
                credentials[app] = owner
            }
            let invite = try await client.makeInvite(credentials: owner)
            guard let url = invite.url else { throw PartnerSyncError.invalidInvite }
            inviteLinks[app] = url
            status[app] = "邀请已生成，7 天内有效；尚未上传或共享任何记录。"
        } catch {
            status[app] = error.localizedDescription
        }
    }

    func acceptInvite(_ url: URL) async {
        guard PartnerBuildConfiguration.role == .partner else { return }
        guard let invite = PartnerInvite.parse(url), invite.app == .current else {
            status[.current] = "邀请链接不属于此 App"
            return
        }
        guard !workingApps.contains(invite.app) else { return }
        workingApps.insert(invite.app)
        defer { workingApps.remove(invite.app) }
        do {
            let joined = try await client.accept(invite)
            try PartnerCredentialVault.save(joined)
            credentials[invite.app] = joined
            inviteLinks[invite.app] = nil
            status[invite.app] = "已接受邀请；记录共享尚未启用。"
        } catch {
            status[invite.app] = error.localizedDescription
        }
    }

    func revokePartner(app: PartnerApp) async {
        guard let current = credentials[app], current.role == .owner,
              !workingApps.contains(app) else { return }
        workingApps.insert(app)
        defer { workingApps.remove(app) }
        do {
            try await client.revokePartner(credentials: current)
            inviteLinks[app] = nil
            status[app] = "配偶访问已撤销；已下载或截图的内容无法远程收回。"
        } catch {
            status[app] = error.localizedDescription
        }
    }

    func registerPushToken(app: PartnerApp, deviceToken: String, environment: String) async {
        guard app == .yaoShi, PartnerBuildConfiguration.role == .partner,
              let current = credentials[app], current.role == .partner else { return }
        do {
            try await client.registerPushToken(deviceToken, environment: environment, credentials: current)
            UserDefaults.standard.set(true, forKey: "yaoshi.partner.pushRegistered")
            status[app] = "伴侣手机已登记推送通知"
        } catch {
            UserDefaults.standard.set(false, forKey: "yaoshi.partner.pushRegistered")
            status[app] = "推送设备登记失败；共享记录仍可在打开 App 后同步（\(error.localizedDescription)）"
        }
    }

    /// Persist locally first. A network failure intentionally leaves the event
    /// in the outbox with the same ID, so a later retry is safe after timeouts.
    @discardableResult
    func enqueue(app: PartnerApp, eventID: UUID, payload: Data,
                 notifyPartner: Bool = false) async -> Bool {
        guard !journalLoadErrors.contains(app) else { return false }
        var journal = journals[app] ?? (try? PartnerSyncJournalStore.load(app: app)) ?? PartnerSyncJournal()
        guard !journal.outbox.contains(where: { $0.id == eventID }) else {
            if credentials[app] != nil { await sync(app: app) }
            return true
        }
        journal.outbox.append(PartnerQueuedEvent(id: eventID, payload: payload, createdAt: Date(),
                                                 notifyPartner: notifyPartner ? true : nil))
        do {
            try PartnerSyncJournalStore.save(journal, app: app)
            journals[app] = journal
            journalLoadErrors.remove(app)
            if credentials[app] != nil {
                status[app] = "已保存到本机，等待共享服务同步"
                await sync(app: app)
            } else {
                status[app] = "已保存在本机共享队列；建立共享空间后发送"
            }
            return true
        } catch {
            status[app] = "本机共享队列写入失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Retry pending sends and durably queue newly received events. Calling this
    /// on launch/foreground restores progress after either device or server was offline.
    func sync(app: PartnerApp) async {
        guard !workingApps.contains(app), !journalLoadErrors.contains(app),
              let credentials = credentials[app] else { return }
        workingApps.insert(app)
        defer { workingApps.remove(app) }

        var journal = journals[app] ?? (try? PartnerSyncJournalStore.load(app: app)) ?? PartnerSyncJournal()
        do {
            let fetched = try await client.fetch(after: journal.lastRevision, credentials: credentials)
            var nextRevision = journal.lastRevision
            for event in fetched.sorted(by: { $0.revision < $1.revision }) {
                let payload = try client.open(event, credentials: credentials)
                if !journal.incoming.contains(where: { $0.id == event.id }) {
                    journal.incoming.append(PartnerReceivedEvent(id: event.id, author: event.author,
                                                                 revision: event.revision,
                                                                 createdAt: event.createdAt, payload: payload,
                                                                 notifyPartner: event.notifyPartner))
                }
                nextRevision = max(nextRevision, event.revision)
            }
            journal.lastRevision = nextRevision
            try PartnerSyncJournalStore.save(journal, app: app)
            journals[app] = journal
            journalLoadErrors.remove(app)

            while let pending = journal.outbox.first {
                _ = try await client.append(pending.payload, eventID: pending.id, createdAt: pending.createdAt,
                                            notifyPartner: pending.notifyPartner == true,
                                            credentials: credentials)
                journal.outbox.removeAll { $0.id == pending.id }
                try PartnerSyncJournalStore.save(journal, app: app)
                journals[app] = journal
            }
            let inbound = journal.incoming.count
            status[app] = inbound > 0
                ? "收到 \(inbound) 条共享更新，等待写入本机记录"
                : (journal.outbox.isEmpty ? "共享空间已同步" : "本机还有 \(journal.outbox.count) 条待发送")
        } catch {
            // Never clear the outbox or incoming journal on a transport error.
            status[app] = "记录已保存在本机；共享服务暂不可用，恢复后会重试（\(error.localizedDescription)）"
        }
    }

    func syncAll() async {
        await sync(app: .current)
    }

    /// Remove only after the app-specific store has durably applied the event.
    func acknowledgeReceived(app: PartnerApp, eventID: UUID) {
        guard !journalLoadErrors.contains(app) else { return }
        var journal = journals[app] ?? (try? PartnerSyncJournalStore.load(app: app)) ?? PartnerSyncJournal()
        journal.incoming.removeAll { $0.id == eventID }
        do {
            try PartnerSyncJournalStore.save(journal, app: app)
            journals[app] = journal
        } catch {
            status[app] = "共享内容已读取，但本机确认状态未保存；下次仍会重试"
        }
    }
}

private struct CreateSpaceRequest: Encodable { var app: PartnerApp; var spaceID: String; var ownerToken: String }
private struct CreateInviteRequest: Encodable { var lifetimeHours: Int }
private struct InviteResponse: Decodable { var inviteToken: String }
private struct AcceptInviteRequest: Encodable { var inviteToken: String }
private struct AcceptInviteResponse: Decodable { var partnerToken: String }
private struct AppendEventRequest: Encodable {
    var eventID: UUID
    var ciphertext: String
    var notifyPartner: Bool
    var createdAt: Date
}
private struct RegisterPushTokenRequest: Encodable { var deviceToken: String; var environment: String }
private struct RevisionResponse: Decodable { var revision: Int }
private struct EventsResponse: Decodable { var events: [EventResponse] }
private struct EventResponse: Decodable {
    var eventID: UUID
    var author: PartnerRole
    var revision: Int
    var createdAt: Date
    var ciphertext: String
    var notifyPartner: Bool?
}
private struct ErrorResponse: Decodable { var error: String }
private struct EmptyRequest: Encodable {}
private struct EmptyResponse: Decodable { init() {} }

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URLString: String) {
        var value = base64URLString.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 { value += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: value)
    }
}
