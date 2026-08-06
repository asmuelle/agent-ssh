import StoreKit
import XCTest

// `MobileEntitlementsStore.swift` is compiled directly into this logic-test
// target (see project.yml), so the ids under test are the exact same source of
// truth the app ships — no `@testable import` of the full iOS app required.

/// Guards against product-id and metadata drift in the checked-in StoreKit
/// configuration. Signed sandbox-device testing and App Store Connect
/// availability remain separate release gates documented in metadata.
@MainActor
final class EntitlementsProductConfigTests: XCTestCase {
    private struct Configuration: Decodable {
        struct Product: Decodable {
            let displayPrice: String
            let localizations: [Localization]
            let productID: String
            let type: String
        }

        struct Localization: Decodable {
            let description: String
            let displayName: String
            let locale: String
        }

        let products: [Product]
    }

    private func loadConfiguration() throws -> Configuration {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "Products", withExtension: "storekit"),
            "Products.storekit must be bundled into the logic-test target."
        )
        return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    }

    func testConfiguredProductIdsAreNotEmpty() {
        XCTAssertFalse(
            MobileEntitlementsStore.shared.configuredProductIds.isEmpty,
            "configuredProductIds is empty — the paywall has nothing to sell."
        )
    }

    func testEveryConfiguredProductIdHasCompleteStoreKitMetadata() throws {
        let expected = MobileEntitlementsStore.shared.configuredProductIds
        let products = try loadConfiguration().products
        let configured = Dictionary(uniqueKeysWithValues: products.map { ($0.productID, $0) })

        for id in expected {
            let product = try XCTUnwrap(configured[id], "Product id '\(id)' is missing from Products.storekit.")
            XCTAssertEqual(product.type, "NonConsumable")
            XCTAssertNotNil(Decimal(string: product.displayPrice))
            XCTAssertFalse(product.localizations.isEmpty)
            for localization in product.localizations {
                XCTAssertFalse(localization.displayName.trimmingCharacters(in: .whitespaces).isEmpty)
                XCTAssertFalse(localization.description.trimmingCharacters(in: .whitespaces).isEmpty)
                XCTAssertFalse(localization.locale.isEmpty)
            }
        }
        XCTAssertEqual(
            Set(configured.keys), Set(expected),
            "Products.storekit and MobileEntitlementsStore must define exactly the same product identifiers."
        )
    }


    /// The lifetime id must stay namespaced to this app's bundle. A shared id
    /// (the original `com.mc-ssh.*` bug) collides across apps because StoreKit
    /// product ids are unique per developer account.
    func testLifetimeProductIdIsNamespacedToThisApp() {
        XCTAssertTrue(
            MobileEntitlementsStore.proLifetimeProductId.hasPrefix("com.agent-ssh.mobile"),
            "Lifetime product id must be namespaced to com.agent-ssh.mobile to avoid cross-app collision."
        )
    }
}
