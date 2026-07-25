# Distribution Strategy

Midnight SSH deliberately uses separate Apple distribution channels rather than pretending one macOS binary can satisfy incompatible requirements.

## iPhone and iPad — App Store

The mobile app is the initial App Store product. Release builds include only capabilities that are enabled and provisioned. Current minimum: iOS/iPadOS 17.

Before submission:

- run `just ios-test` and `just ios-ci-build`;
- archive with the production App ID and provisioning profile;
- inspect the archive for the mobile app, the intentionally embedded widget, privacy manifests, signatures, bundle versions, and App Group entitlements;
- validate the lifetime StoreKit product in App Store Connect and on a signed sandbox-device build;
- supply the metadata and review notes in `APP_STORE_METADATA.md`.

File Provider, Share, Shortcuts, cloud sync, and other feature-flagged integrations are not advertised or embedded until their implementation, provisioning, privacy behavior, and archive packaging are independently complete.

## Mac — Developer ID and Sparkle

The current Mac product is a Developer ID application distributed through GitHub Releases and updated with Sparkle. This channel is intentional because the app's external MCP helper, direct file workflows, updater, and non-sandboxed operational workspace are not a valid Mac App Store architecture.

Release with:

```sh
APPLE_SIGNING_IDENTITY="Developer ID Application: …" \
APPLE_ID="developer@example.com" \
APPLE_TEAM_ID="…" \
APPLE_APP_SPECIFIC_PASSWORD="…" \
scripts/mac_release.sh true
```

The release script builds the app, verifies the resolved bundle version, creates and hashes the DMG, notarizes and staples it, and can generate a signed Sparkle appcast when `MAC_RELEASE_BASE_URL` is set. Passing `false` creates a local-only, non-notarized artifact and refuses to generate appcast metadata.

## No current Mac App Store claim

The repository does not claim that the current Mac binary is Mac App Store compatible. A future Mac App Store edition requires a separate sandboxed target/configuration that excludes Sparkle and the external MCP helper, uses security-scoped file access, and is validated as a separate archive. Do not enable App Sandbox in the existing Developer ID target as a cosmetic submission change; doing so would silently break product behavior.

## External release prerequisites

These cannot be completed by repository code:

- Apple certificates, App IDs, capabilities, provisioning profiles, and notarization credentials;
- App Store Connect product availability, pricing, localization, agreements, tax, and banking;
- a dedicated App Review demo server and credentials;
- provider-side credential rotation;
- export-compliance filings or legal determinations;
- final archive upload and App Review submission.
