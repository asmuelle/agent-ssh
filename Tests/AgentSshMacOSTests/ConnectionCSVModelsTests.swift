import XCTest
@testable import AgentSshMacOS

final class ConnectionCSVModelsTests: XCTestCase {
    func testCSVPlanUpdatesByStableIdAndPreservesCredentials() throws {
        let existing = ConnectionProfile(
            id: "prod",
            name: "Prod",
            host: "prod.example.com",
            username: "deploy",
            authMethod: .publicKey,
            sshKeyReference: .plainPath("/Users/me/.ssh/id_prod"),
            tags: ["old"]
        )
        let csv = """
        id,name,host,port,username,authMethod,kind,folder,tags,favorite,color,notes
        prod,Production,prod.example.com,22,deploy,publicKey,ssh,Work,api;blue,true,#00f,"has, comma"
        ,Staging,staging.example.com,2222,ubuntu,password,ssh,Work,stage,false,,
        """

        let plan = try ConnectionCSVImportPlanner.plan(existing: [existing], csv: csv)
        let applied = ConnectionCSVImportPlanner.apply(plan, to: [existing])
        let updated = try XCTUnwrap(applied.first { $0.id == "prod" })
        let inserted = try XCTUnwrap(applied.first { $0.host == "staging.example.com" })

        XCTAssertEqual(plan.updateCount, 1)
        XCTAssertEqual(plan.addCount, 1)
        XCTAssertEqual(updated.name, "Production")
        XCTAssertEqual(updated.folderPath, "Work")
        XCTAssertEqual(updated.notes, "has, comma")
        XCTAssertEqual(updated.sshKeyReference, existing.sshKeyReference)
        XCTAssertTrue(inserted.id.hasPrefix("csv-"))
    }

    func testCSVExportRoundTripsQuotedFields() throws {
        let profile = ConnectionProfile(
            id: "quoted",
            name: "Prod, Blue",
            host: "prod.example.com",
            username: "deploy",
            notes: "line 1\nline 2"
        )

        let csv = ConnectionCSVCodec.encode(profiles: [profile])
        let rows = try ConnectionCSVCodec.decode(csv)

        XCTAssertEqual(rows.first?.name, "Prod, Blue")
        XCTAssertEqual(rows.first?.notes, "line 1\nline 2")
    }
}
