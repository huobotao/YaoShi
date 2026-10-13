import Foundation
import Combine
import CryptoKit
import MultipeerConnectivity

/// Ephemeral ECDH secret; both people-facing endpoints verify the same six-digit SAS.
/// MCSession encryption is mandatory; application messages are additionally AES-GCM sealed.
/// Never persists keys/records, never sends records before both explicit approvals.
@MainActor final class TVLink: NSObject, ObservableObject {
    enum Role { case sender, receiver }
    struct Peer: Identifiable {
        let peer: MCPeerID
        var id: String { peer.displayName }
        var name: String { peer.displayName }
    }
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var status = "尚未连接"
    @Published private(set) var verificationCode: String?
    @Published private(set) var invitationName: String?
    @Published private(set) var isConnected = false
    @Published private(set) var ready = false
    @Published private(set) var localApproved = false
    var onSnapshot: ((TVCurveSnapshot) -> Void)?

    private let role: Role
    private var session: MCSession?
    private var browser: MCNearbyServiceBrowser?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var invitation: ((Bool, MCSession?) -> Void)?
    private var handshake: TVPairingHandshake?
    private var channel: TVSecureChannel?
    private var pendingPeer: MCPeerID?
    private var remoteApproved = false
    private var active = false
    private struct Envelope: Codable { let kind: String; let data: Data }
    init(role: Role) { self.role = role; super.init() }

    func start() {
        disconnect()
        active = true
        handshake = TVPairingHandshake(sender: role == .sender)
        let suffix = UUID().uuidString.prefix(5)
        let ownPeer = MCPeerID(displayName: (role == .receiver ? "药时电视 " : "药时手机 ") + suffix)
        let session = MCSession(peer: ownPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session
        if role == .receiver {
            let advertiser = MCNearbyServiceAdvertiser(peer: ownPeer, discoveryInfo: ["role": "tv", "v": "1"], serviceType: "yaoshi-tv-v1")
            advertiser.delegate = self
            self.advertiser = advertiser
            advertiser.startAdvertisingPeer()
            status = "等待手机连接；请在手机药时的电视配对页选择本电视"
        } else {
            let browser = MCNearbyServiceBrowser(peer: ownPeer, serviceType: "yaoshi-tv-v1")
            browser.delegate = self
            self.browser = browser
            browser.startBrowsingForPeers()
            status = "正在寻找附近的药时电视"
        }
    }
    func connect(_ peer: Peer) {
        guard let session, !isConnected else { return }
        browser?.invitePeer(peer.peer, to: session, withContext: Data("yaoshi-tv-v1".utf8), timeout: 30)
        status = "等待电视接受连接"
    }
    func acceptInvitation() {
        guard let invitation, let session else { return }
        self.invitation = nil; invitationName = nil
        advertiser?.stopAdvertisingPeer()
        invitation(true, session)
        status = "正在建立加密连接"
    }
    func rejectInvitation() {
        invitation?(false, nil); invitation = nil; invitationName = nil; pendingPeer = nil
    }
    func approveCode() {
        guard channel != nil, isConnected else { return }
        localApproved = true
        send(kind: "approve")
        updateReady()
    }
    func sendSnapshot(_ snapshot: TVCurveSnapshot) {
        guard role == .sender, ready, snapshot.isValid else { return }
        send(kind: "snapshot", snapshot: snapshot)
    }
    func disconnect() {
        active = false
        invitation?(false, nil); invitation = nil
        advertiser?.stopAdvertisingPeer(); browser?.stopBrowsingForPeers()
        session?.delegate = nil; session?.disconnect()
        session = nil; browser = nil; advertiser = nil
        channel = nil; handshake = nil; pendingPeer = nil; peers = []; verificationCode = nil; invitationName = nil
        isConnected = false; ready = false; localApproved = false; remoteApproved = false
        status = "已断开；连接密钥已清除"
    }
    private func updateReady() {
        ready = localApproved && remoteApproved && isConnected
        status = ready ? "已核对两端验证码，可以发送曲线" : (localApproved ? "等待另一端确认验证码" : "请核对两端六位验证码完全相同，再分别确认")
    }
    private func send(kind: String, snapshot: TVCurveSnapshot? = nil) {
        guard let sealed = channel?.seal(kind: kind, snapshot: snapshot) else { return }
        sendEnvelope(Envelope(kind: "sealed", data: sealed))
    }
    private func sendEnvelope(_ envelope: Envelope) {
        guard let session, session.connectedPeers.count == 1,
              let data = try? JSONEncoder().encode(envelope), data.count <= 4_000_000 else { return }
        do { try session.send(data, toPeers: session.connectedPeers, with: .reliable) }
        catch { status = "传输失败，请重新连接" }
    }
    private func receive(_ data: Data, from peer: MCPeerID) {
        guard active, let session, session.connectedPeers == [peer], data.count <= 4_000_000,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        if envelope.kind == "commit" {
            guard let reveal = handshake?.receiveCommitment(envelope.data) else { return }
            sendEnvelope(Envelope(kind: "reveal", data: reveal))
            return
        }
        if envelope.kind == "reveal" {
            guard channel == nil, let established = handshake?.receiveReveal(envelope.data) else { return }
            channel = established
            verificationCode = established.verificationCode
            // The application keys are all that remain necessary after key agreement.
            handshake = nil
            updateReady()
            return
        }
        guard envelope.kind == "sealed", let message = channel?.open(envelope.data) else { return }
        if message.kind == "approve" { remoteApproved = true; updateReady() }
        if message.kind == "snapshot", role == .receiver, ready,
           let snapshot = message.snapshot, snapshot.isValid {
            onSnapshot?(snapshot)
            status = "已收到曲线；数据仅保留在本次电视会话"
            send(kind: "received")
        }
        if message.kind == "received", role == .sender, ready { status = "电视已确认收到曲线" }
    }
}

extension TVLink: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            guard self.session === session, active else { return }
            if state == .connected {
                guard session.connectedPeers.count == 1 else { disconnect(); return }
                isConnected = true
                browser?.stopBrowsingForPeers(); advertiser?.stopAdvertisingPeer()
                status = "正在生成两端验证码"
                if let handshake { sendEnvelope(Envelope(kind: "commit", data: handshake.commitment)) }
            } else if state == .notConnected { disconnect() }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in guard self.session === session else { return }; receive(data, from: peerID) }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension TVLink: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                               withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in
            guard active, role == .receiver, self.advertiser === advertiser, !isConnected,
                  invitation == nil, pendingPeer == nil, context == Data("yaoshi-tv-v1".utf8) else { invitationHandler(false, nil); return }
            pendingPeer = peerID; invitation = invitationHandler; invitationName = peerID.displayName
            status = "手机请求连接，请在电视上接受"
        }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in status = "无法被附近手机发现，请检查本地网络权限" }
    }
}

extension TVLink: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard active, self.browser === browser, info?["role"] == "tv", info?["v"] == "1" else { return }
            if !peers.contains(where: { $0.peer == peerID }) { peers.append(Peer(peer: peerID)) }
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in peers.removeAll { $0.peer == peerID } }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in status = "无法搜索电视，请检查本地网络权限" }
    }
}
