import Foundation

public final class ActuatorConfigurationStore: @unchecked Sendable {
    private let backing: SharedJSONFileStore<ActuatorFleetConfiguration>
    private let lock = NSLock()

    public init(directoryURL: URL? = nil) {
        backing = SharedJSONFileStore(
            fileName: SharedAppStorageConfiguration.actuatorConfigurationFileName,
            directoryURL: directoryURL
        )
    }

    public func load() throws -> ActuatorFleetConfiguration {
        try lock.withLock { try backing.load(default: .empty) }
    }

    public func save(_ configuration: ActuatorFleetConfiguration) throws {
        try lock.withLock { try backing.save(configuration) }
    }
}
