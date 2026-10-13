import Foundation
import Combine

@MainActor final class TVStore: ObservableObject {
    @Published private(set) var doses: [Dose] = []
    @Published private(set) var curve = PlasmaCurveConfiguration.standard
    @Published private(set) var status = "按“开始配对”，再在手机药时的设置中连接电视"
    @Published private(set) var verificationCode: String?
    @Published private(set) var invitationName: String?
    @Published private(set) var isConnected = false
    @Published private(set) var readyToReceive = false
    @Published private(set) var localApproved = false
    @Published private(set) var lastReceivedAt: Date?
    private let link = TVLink(role: .receiver)
    private var observers = Set<AnyCancellable>()

    init() {
        link.$status.assign(to: &$status)
        link.$verificationCode.assign(to: &$verificationCode)
        link.$invitationName.assign(to: &$invitationName)
        link.$isConnected.sink { [weak self] connected in
            guard let self else { return }
            isConnected = connected

        }.store(in: &observers)
        link.$ready.assign(to: &$readyToReceive)
        link.$localApproved.assign(to: &$localApproved)
        link.onSnapshot = { [weak self] snapshot in
            self?.doses = snapshot.records
            self?.curve = snapshot.curve
            self?.lastReceivedAt = Date()
        }
    }
    func startPairing() { link.start() }
    func acceptInvitation() { link.acceptInvitation() }
    func rejectInvitation() { link.rejectInvitation() }
    func approveCode() { link.approveCode() }
    func disconnect() { link.disconnect(); doses = []; lastReceivedAt = nil }
}
