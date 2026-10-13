import Foundation

@main struct TVPairingTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: " + label) }; passed += 1
    }
    static func main() throws {
        var phone = TVPairingHandshake(sender: true)
        var tv = TVPairingHandshake(sender: false)
        check(phone.receiveReveal(tv.reveal) == nil, "reveal cannot establish a key before peer commitment")
        check(phone.receiveCommitment(Data([1, 2])) == nil, "invalid commitment length rejected")
        check(phone.receiveCommitment(tv.commitment) == phone.reveal, "commitment accepted before revealing local key")
        check(phone.receiveCommitment(tv.commitment) == nil, "second commitment cannot replace the first")
        _ = tv.receiveCommitment(phone.commitment)
        var phoneChannel = phone.receiveReveal(tv.reveal)!
        var tvChannel = tv.receiveReveal(phone.reveal)!
        check(phoneChannel.verificationCode == tvChannel.verificationCode, "independently derived verification codes match")
        check(phoneChannel.verificationCode.count == 6, "verification code retains six digits including leading zeros")
        let attacker = TVPairingHandshake(sender: false)
        check(phone.receiveReveal(attacker.reveal) == nil, "substituting a different public key after commitment fails")
        var tamperedReveal = tv.reveal; tamperedReveal[tamperedReveal.startIndex] ^= 1
        check(phone.receiveReveal(tamperedReveal) == nil, "tampered reveal rejected")
        var wrongRole = TVPairingHandshake(sender: true)
        _ = wrongRole.receiveCommitment(phone.commitment)
        check(wrongRole.receiveReveal(phone.reveal) == nil, "same-role handshakes rejected")
        let approve = phoneChannel.seal(kind: "approve")!
        check(phoneChannel.open(approve) == nil, "reflecting phone approval back to phone fails directional authentication")
        check(tvChannel.open(approve)?.kind == "approve", "opposite endpoint decrypts approval")
        check(tvChannel.open(approve) == nil, "replayed approval rejected")
        let answer = tvChannel.seal(kind: "approve")!
        check(phoneChannel.open(answer)?.kind == "approve", "reverse direction uses its own authenticated key")
        let message = phoneChannel.seal(kind: "received")!
        var tampered = message; tampered[tampered.startIndex + 5] ^= 1
        check(tvChannel.open(tampered) == nil, "tampered ciphertext rejected")
        check(tvChannel.open(message) != nil, "invalid ciphertext does not consume valid sequence")
        var otherPhone = TVPairingHandshake(sender: true), otherTV = TVPairingHandshake(sender: false)
        _ = otherPhone.receiveCommitment(otherTV.commitment); _ = otherTV.receiveCommitment(otherPhone.commitment)
        var otherChannel = otherTV.receiveReveal(otherPhone.reveal)!
        check(otherChannel.open(message) == nil, "another session cannot decrypt prior records")
        let now = Date()
        var dose = Dose(at: now.addingTimeInterval(-3600), mg: 40, food: .withFood)
        dose.note = "PRIVATE NOTE MUST NOT TRANSFER"
        dose.reasons = [.work]
        let future = Dose(at: now.addingTimeInterval(3600), mg: 50)
        let snapshot = TVCurveSnapshot(doses: [dose, future], curve: .standard, now: now)
        let data = try JSONEncoder().encode(snapshot)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let point = (json["doses"] as! [[String: Any]])[0]
        check(Set(point.keys) == ["at", "mg", "food"], "only permitted per-dose fields serialize")
        check(!String(decoding: data, as: UTF8.self).contains(dose.note), "private notes absent from wire payload")
        check(snapshot.doses.count == 1, "future actual records excluded from transfer")
        check(snapshot.isValid && snapshot.records[0].mg == dose.mg, "valid snapshot reconstructs chart inputs")
        let recordFrame = phoneChannel.seal(kind: "snapshot", snapshot: snapshot)!
        check(tvChannel.open(recordFrame)?.snapshot?.doses.count == 1, "minimal snapshot survives authenticated transport")
        var invalid = json; invalid["peakHours"] = -1
        let invalidData = try JSONSerialization.data(withJSONObject: invalid)
        let invalidSnapshot = try JSONDecoder().decode(TVCurveSnapshot.self, from: invalidData)
        check(!invalidSnapshot.isValid, "invalid curve parameters rejected")
        print("PASS: \(passed) secure TV pairing and minimal-payload checks")
    }
}
