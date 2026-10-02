import AgentSshMacOS
import Foundation
import Testing
@testable import AgentSshApp

@MainActor
struct HostWorkspaceTests {
    private func profile(_ id: String, _ name: String) -> ConnectionProfile {
        ConnectionProfile(id: id, name: name, host: "example.com", username: "root")
    }

    private func item(_ profileId: String, _ tier: AttentionTier, _ sourceId: String = "cpu") -> AttentionItem {
        AttentionItem(
            profileId: profileId,
            sourceKind: .metric,
            sourceId: sourceId,
            hostName: profileId,
            tier: tier,
            title: "t",
            detail: "d"
        )
    }

    @Test("Needs Attention lists the most urgent host first, then by name")
    func ordersByWorstTierThenName() {
        let hosts = [profile("a", "alpha"), profile("b", "bravo"), profile("c", "charlie"), profile("d", "delta")]
        let items = [
            item("c", .fixThisWeek),
            item("b", .fixThisWeek),
            item("d", .fixThisWeek),
            item("d", .actNow, "disk:/"),
        ]

        let ordered = HostAttentionOrder.hosts(hosts, items: items).map(\.name)

        #expect(ordered == ["delta", "bravo", "charlie"])
    }

    @Test("FYI items and deleted hosts stay out of Needs Attention")
    func skipsFyiAndUnknownProfiles() {
        let hosts = [profile("a", "alpha")]
        let items = [item("a", .fyi), item("gone", .actNow)]

        #expect(HostAttentionOrder.hosts(hosts, items: items).isEmpty)
    }

    @Test("SSH hosts open on Diagnosis; SFTP hosts only have Files")
    func sectionsFollowConnectionKind() {
        #expect(HostSection.available(for: .ssh) == [.diagnosis, .terminal, .files])
        #expect(HostSection.initial(for: .ssh) == .diagnosis)
        #expect(HostSection.available(for: .sftp) == [.files])
        #expect(HostSection.initial(for: .sftp) == .files)
    }
}
