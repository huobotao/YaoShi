import Foundation
import CryptoKit

private final class LocationMockProtocol: URLProtocol {
    static var respond: ((URLRequest, Data) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count <= 0 { break }
                    body.append(contentsOf: bytes.prefix(count))
                }
            }
            let (status, data) = try Self.respond(request, body)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct LocationSharingTransportTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("FAIL: " + message) }; checks += 1
    }
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocationMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = PartnerSyncClient(session: session)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = Data(repeating: 42, count: 32)
        let credentials = PartnerSpaceCredentials(app: .yaoShi, role: .partner,
            baseURL: URL(string: "https://location-test.invalid")!, spaceID: "test-space",
            accessToken: "TEST-ONLY-TOKEN", encryptionKey: key, joinedAt: now)
        let batch = LocationBatch(deviceID: UUID(), createdAt: now, samples: [
            LocationSample(sampledAt: now, latitude: -33.8123456, longitude: 151.2345678,
                           horizontalAccuracy: 9, networkTransport: "wifi")])
        let payload = try JSONEncoder().encode(batch)
        var attempts = 0
        var recordedIDs: [String] = []
        var sealed = ""
        LocationMockProtocol.respond = { request, body in
            check(request.url?.scheme == "https", "HTTPS endpoint")
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer TEST-ONLY-TOKEN", "authentication header")
            check(request.httpMethod == "POST", "append uses POST")
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            check(Set(json.keys) == ["eventID", "ciphertext", "notifyPartner", "createdAt"], "wire envelope contains only routing metadata and ciphertext")
            check(json["notifyPartner"] as? Bool == false, "location append requests no notification")
            let text = String(decoding: body, as: UTF8.self)
            check(!text.contains("-33.8123456") && !text.contains("151.2345678") && !text.contains("latitude") && !text.contains("networkTransport"), "plaintext location absent from request")
            sealed = json["ciphertext"] as! String
            let box = try AES.GCM.SealedBox(combined: Data(base64Encoded: sealed)!)
            let decrypted = try AES.GCM.open(box, using: SymmetricKey(data: key))
            check(tryDecode(decrypted) == batch, "AES-GCM decrypt restores exact batch")
            recordedIDs.append(json["eventID"] as! String)
            attempts += 1
            return attempts == 1 ? (503, Data("{\"error\":\"temporary failure\"}".utf8)) : (200, Data("{\"revision\":7}".utf8))
        }
        do {
            _ = try await client.append(payload, eventID: batch.id, createdAt: now, notifyPartner: false, credentials: credentials)
            fatalError("FAIL: server error must surface")
        } catch PartnerSyncError.server(let status, _) { check(status == 503, "server error preserved for retry") }
        let revision = try await client.append(payload, eventID: batch.id, createdAt: now, notifyPartner: false, credentials: credentials)
        check(revision == 7, "retry succeeds")
        check(recordedIDs.count == 2 && recordedIDs[0] == recordedIDs[1] && recordedIDs[0] == batch.id.uuidString, "retry retains idempotency UUID")
        LocationMockProtocol.respond = { request, _ in
            check(request.httpMethod == "GET", "receiver fetch uses GET")
            check(request.url?.query == "after=6", "receiver requests next revision")
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer TEST-ONLY-TOKEN", "fetch authentication")
            let response: [String: Any] = ["events": [["eventID": batch.id.uuidString, "author": "partner", "revision": 7,
                "createdAt": "2027-01-15T08:00:00Z", "notifyPartner": false, "ciphertext": sealed]]]
            return (200, try JSONSerialization.data(withJSONObject: response))
        }
        let events = try await client.fetch(after: 6, credentials: credentials)
        check(events.count == 1 && events[0].notifyPartner == false, "fetch preserves silent envelope")
        let opened = try client.open(events[0], credentials: credentials)
        check(tryDecode(opened) == batch, "fetch decrypt decode restores exact original batch")
        var wrong = credentials; wrong.encryptionKey = Data(repeating: 7, count: 32)
        do { _ = try client.open(events[0], credentials: wrong); fatalError("FAIL: wrong key accepted") }
        catch { check(true, "wrong recipient key cannot read location") }
        print("PASS: \(checks) location transport checks")
    }
    static func tryDecode(_ data: Data) -> LocationBatch? { try? JSONDecoder().decode(LocationBatch.self, from: data) }
}
