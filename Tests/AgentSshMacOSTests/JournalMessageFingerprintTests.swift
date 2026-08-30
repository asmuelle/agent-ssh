import Testing
@testable import AgentSshMacOS

struct JournalMessageFingerprintTests {
    @Test("Hikari repeats with different connection ids share a template")
    func hikariConnectionIdsShareTemplate() {
        let a = JournalMessageFingerprinting.fingerprint(
            "2026-08-11T06:40:39.774+01:00  WARN 187989 --- [ari:housekeeper] com.zaxxer.hikari.pool.PoolBase : Hikari - Failed to validate connection org.postgresql.jdbc.PgConnection@8295ff9 (This connection has been closed.). Possibly consider using a shorter maxLifetime value."
        )
        let b = JournalMessageFingerprinting.fingerprint(
            "2026-08-11T06:40:48.781+01:00  WARN 187989 --- [ari:housekeeper] com.zaxxer.hikari.pool.PoolBase : Hikari - Failed to validate connection org.postgresql.jdbc.PgConnection@1c9ad066 (This connection has been closed.). Possibly consider using a shorter maxLifetime value."
        )
        #expect(a.template == b.template)
        #expect(a.captures != b.captures)
        #expect(a.captures.contains("8295ff9"))
        #expect(b.captures.contains("1c9ad066"))
    }

    @Test("Different statements keep different templates")
    func differentStatementsDiffer() {
        let a = JournalMessageFingerprinting.fingerprint("Failed to validate connection PgConnection@8295ff9")
        let b = JournalMessageFingerprinting.fingerprint("Accepted connection PgConnection@8295ff9")
        #expect(a.template != b.template)
    }

    @Test("Embedded ISO timestamp is masked")
    func isoTimestampMasked() {
        let result = JournalMessageFingerprinting.fingerprint("job finished at 2026-08-11T06:40:39.774+01:00 cleanly")
        #expect(result.template == "job finished at \(JournalMessageFingerprinting.placeholder) cleanly")
        #expect(result.captures == ["2026-08-11T06:40:39.774+01:00"])
    }

    @Test("UUIDs, hex literals, and IPv4:port are masked")
    func volatileTokensMasked() {
        let result = JournalMessageFingerprinting.fingerprint(
            "req 550e8400-e29b-41d4-a716-446655440000 from 192.168.1.10:5432 at 0xdeadbeef"
        )
        #expect(result.captures == ["550e8400-e29b-41d4-a716-446655440000", "192.168.1.10:5432", "0xdeadbeef"])
    }

    @Test("Durations and multi-digit counters are masked, structural single digits are not")
    func numberMasking() {
        let masked = JournalMessageFingerprinting.fingerprint("retried 12 times in 350ms via HTTP/2")
        #expect(masked.captures == ["12", "350ms"])
        #expect(masked.template.contains("HTTP/2"))
    }

    @Test("Message without volatile tokens is its own template")
    func stableMessageUnchanged() {
        let message = "reloading configuration"
        let result = JournalMessageFingerprinting.fingerprint(message)
        #expect(result.template == message)
        #expect(result.captures.isEmpty)
    }

    @Test("Ordinary words are never mistaken for hex runs")
    func wordsNotHex() {
        let result = JournalMessageFingerprinting.fingerprint("deactivated successfully")
        #expect(result.captures.isEmpty)
    }

    @Test("JSON logs differing only in field values share a template")
    func jsonFieldValuesShareTemplate() {
        let a = JournalMessageFingerprinting.fingerprint(
            #"{"timestamp":"2026-07-31 20:22:13.915 +01:00","level":"error","msg":"plugin process exited","caller":"plugin/hclog_adapter.go:79","plugin_id":"com.kwiqly.charts","wrapped_extras":"pluginplugins/com.kwiqly.charts/server/dist/plugin-linux-amd64id3573errorsignal: terminated"}"#
        )
        let b = JournalMessageFingerprinting.fingerprint(
            #"{"timestamp":"2026-07-31 20:22:13.916 +01:00","level":"error","msg":"plugin process exited","caller":"plugin/hclog_adapter.go:79","plugin_id":"playbooks","wrapped_extras":"pluginplugins/playbooks/server/dist/plugin-linux-amd64id3639errorsignal: terminated"}"#
        )
        #expect(a.template == b.template)
        #expect(a.captures.contains("plugin_id=com.kwiqly.charts"))
        #expect(b.captures.contains("plugin_id=playbooks"))
        // The timestamp field is per-line noise with its own column —
        // it must not appear as a capture.
        #expect(!a.captures.contains { $0.hasPrefix("timestamp=") })
    }

    @Test("JSON logs with different msg values stay separate")
    func jsonDifferentMsgDiffer() {
        let a = JournalMessageFingerprinting.fingerprint(
            #"{"level":"error","msg":"plugin process exited","plugin_id":"playbooks"}"#
        )
        let b = JournalMessageFingerprinting.fingerprint(
            #"{"level":"error","msg":"RPC call OnDeactivate to plugin failed.","plugin_id":"playbooks"}"#
        )
        #expect(a.template != b.template)
    }

    @Test("JSON logs with different key sets stay separate")
    func jsonDifferentKeysDiffer() {
        let a = JournalMessageFingerprinting.fingerprint(#"{"level":"error","msg":"boom","plugin_id":"x"}"#)
        let b = JournalMessageFingerprinting.fingerprint(#"{"level":"error","msg":"boom","request_id":"x"}"#)
        #expect(a.template != b.template)
    }

    @Test("Varied JSON captures isolate the fields that changed")
    func jsonVariedCaptures() {
        let group = [
            JournalMessageFingerprinting.fingerprint(
                #"{"level":"error","msg":"plugin process exited","caller":"plugin/hclog_adapter.go:79","plugin_id":"playbooks"}"#
            ),
            JournalMessageFingerprinting.fingerprint(
                #"{"level":"error","msg":"plugin process exited","caller":"plugin/hclog_adapter.go:79","plugin_id":"mattermost-ai"}"#
            ),
        ]
        let varied = JournalMessageFingerprinting.variedCaptureIndices(of: group)
        let values = varied.map { group[0].captures[$0] }
        #expect(values == ["plugin_id=playbooks"])
    }

    @Test("Varied capture indices skip constant slots")
    func variedCaptureIndices() {
        let group = [
            JournalMessageFingerprinting.fingerprint("conn PgConnection@8295ff9 on 192.168.1.10:5432 closed"),
            JournalMessageFingerprinting.fingerprint("conn PgConnection@1c9ad066 on 192.168.1.10:5432 closed"),
        ]
        #expect(JournalMessageFingerprinting.variedCaptureIndices(of: group) == [0])
    }
}

/// journald tags each line with the emitting PID. Forked-per-connection
/// daemons therefore log every line under a different one, which would
/// defeat repeat-collapsing entirely if the PID were part of the identity.
struct JournalProcessGroupKeyTests {
    @Test("A PID suffix is stripped so a forked daemon groups across workers")
    func stripsPid() {
        #expect(journalProcessGroupKey("sshd[1234]") == "sshd")
        #expect(journalProcessGroupKey("nginx[99]") == "nginx")
    }

    @Test("A process without a PID is unchanged")
    func keepsBareName() {
        #expect(journalProcessGroupKey("systemd") == "systemd")
        #expect(journalProcessGroupKey("kernel") == "kernel")
        #expect(journalProcessGroupKey("") == "")
    }

    @Test("Only a wholly numeric bracket is a PID")
    func leavesNonNumericBracketsAlone() {
        #expect(journalProcessGroupKey("app[worker]") == "app[worker]")
        #expect(journalProcessGroupKey("app[12a]") == "app[12a]")
        #expect(journalProcessGroupKey("app[]") == "app[]")
        #expect(journalProcessGroupKey("[1234]") == "[1234]")
    }
}
