import Foundation
import CryptoKit

/// Commitment comes before either reveal, preventing adaptive short-code matching.
struct TVPairingHandshake {
    private struct Hello: Codable { let role: String; let publicKey: Data; let nonce: Data }
    private let role: String
    private let privateKey: P256.KeyAgreement.PrivateKey
    let reveal: Data
    var commitment: Data { Data(SHA256.hash(data: reveal)) }
    private var peerCommitment: Data?

    init(sender: Bool) {
        role = sender ? "sender" : "receiver"
        privateKey = P256.KeyAgreement.PrivateKey()
        let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        reveal = try! JSONEncoder().encode(Hello(role: role, publicKey: privateKey.publicKey.x963Representation, nonce: nonce))
    }
    mutating func receiveCommitment(_ data: Data) -> Data? {
        guard peerCommitment == nil, data.count == 32 else { return nil }
        peerCommitment = data
        return reveal
    }
    func receiveReveal(_ data: Data) -> TVSecureChannel? {
        guard let peerCommitment, Data(SHA256.hash(data: data)) == peerCommitment,
              let hello = try? JSONDecoder().decode(Hello.self, from: data), hello.nonce.count == 32,
              hello.role == (role == "sender" ? "receiver" : "sender"),
              let publicKey = try? P256.KeyAgreement.PublicKey(x963Representation: hello.publicKey),
              let secret = try? privateKey.sharedSecretFromKeyAgreement(with: publicKey) else { return nil }
        let salt = role == "sender" ? commitment + peerCommitment : peerCommitment + commitment
        func key(_ purpose: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                sharedInfo: Data(("YaoShi TV v1 " + purpose).utf8), outputByteCount: 32)
        }
        let verification = key("verify sender receiver transcript")
        let digest = HMAC<SHA256>.authenticationCode(for: Data("verify both screens".utf8), using: verification)
        let number = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return TVSecureChannel(role: role,
            transmitKey: key(role == "sender" ? "sender to receiver" : "receiver to sender"),
            receiveKey: key(role == "sender" ? "receiver to sender" : "sender to receiver"),
            verificationCode: String(format: "%06u", number))
    }
}

struct TVSecureChannel {
    struct Message: Codable {
        let sequence: UInt64
        let senderRole: String
        let kind: String
        let snapshot: TVCurveSnapshot?
    }
    let role: String
    let transmitKey: SymmetricKey
    let receiveKey: SymmetricKey
    let verificationCode: String
    private var outgoingSequence: UInt64 = 0
    private var incomingSequence: UInt64 = 0

    init(role: String, transmitKey: SymmetricKey, receiveKey: SymmetricKey, verificationCode: String) {
        self.role = role; self.transmitKey = transmitKey; self.receiveKey = receiveKey
        self.verificationCode = verificationCode
    }
    mutating func seal(kind: String, snapshot: TVCurveSnapshot? = nil) -> Data? {
        guard outgoingSequence < UInt64.max else { return nil }
        outgoingSequence += 1
        let message = Message(sequence: outgoingSequence, senderRole: role, kind: kind, snapshot: snapshot)
        guard let data = try? JSONEncoder().encode(message) else { return nil }
        return try? AES.GCM.seal(data, using: transmitKey).combined
    }
    mutating func open(_ data: Data) -> Message? {
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let raw = try? AES.GCM.open(box, using: receiveKey),
              let message = try? JSONDecoder().decode(Message.self, from: raw),
              message.senderRole == (role == "sender" ? "receiver" : "sender"),
              message.sequence > incomingSequence else { return nil }
        incomingSequence = message.sequence
        return message
    }
}
