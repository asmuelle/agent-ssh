#!/usr/bin/env bash

set -euo pipefail

mode="${1:-false}"
notarize="${mode}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
macos_dir="$(cd "${script_dir}/.." && pwd)"
plist="${macos_dir}/AgentSshApp/Info.plist"
app_name="agent-ssh"
app_path="${ASSH_MAC_DERIVED_DATA:-${macos_dir}/.derivedData/macos}/Build/Products/Release/${app_name}.app"

if [[ "${mode}" == "--check" ]]; then
    for command in just xcodegen xcodebuild hdiutil codesign shasum; do
        command -v "${command}" >/dev/null || {
            echo "Missing release prerequisite: ${command}" >&2
            exit 1
        }
    done
    bash -n "${BASH_SOURCE[0]}"
    plutil -lint "$plist" "${macos_dir}/AgentSshWidgets/Info.plist" >/dev/null
    echo "macOS release script preflight passed (static checks only)"
    echo "Expected app: ${app_path}"
    exit 0
fi

if [[ "${mode}" != "true" && "${mode}" != "false" ]]; then
    echo "Usage: scripts/mac_release.sh [true|false|--check]" >&2
    exit 1
fi

if [[ "${notarize}" != "true" && -n "${MAC_RELEASE_BASE_URL:-}" ]]; then
    echo "MAC_RELEASE_BASE_URL requires notarization. Non-notarized artifacts are local-only." >&2
    exit 1
fi

if [[ -z "${APPLE_DEVELOPMENT_TEAM:-}" ]]; then
    echo "APPLE_DEVELOPMENT_TEAM is required for a release build." >&2
    exit 1
fi

if [[ -z "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    echo "APPLE_SIGNING_IDENTITY is required for a public Developer ID release." >&2
    exit 1
fi

# A release with an empty SUPublicEDKey ships updates that Sparkle cannot
# signature-verify. Fail early instead of producing an unverifiable artifact.
sparkle_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null || true)"
if [[ -z "$sparkle_key" ]]; then
    echo "SUPublicEDKey is empty in ${plist}." >&2
    echo "Run 'just mac-sparkle-keygen' and add the printed public key to Info.plist before releasing." >&2
    exit 1
fi

build="${CURRENT_PROJECT_VERSION:-$(date -u +%Y%m%d%H%M%S)}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
latest_dmg="${macos_dir}/${app_name}.dmg"

cd "$macos_dir"

just mac-clean

CURRENT_PROJECT_VERSION="$build" just mac-build-signed

if [[ ! -d "$app_path" ]]; then
    echo "Expected app not found after build: ${app_path}" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
if ! codesign -dv --verbose=4 "$app_path" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
    echo "Built app is not signed with a Developer ID Application certificate: ${app_path}" >&2
    exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app_path}/Contents/Info.plist")"
if [[ -z "$version" || "$version" == *'$('* ]]; then
    echo "Built app has an invalid version: ${version}" >&2
    exit 1
fi

release_name="${app_name}-${version}-${build}-${stamp}"
release_dir="${macos_dir}/build/release/${release_name}"
release_dmg="${release_dir}/${app_name}-${version}.dmg"
rm -rf "$release_dir"
mkdir -p "$release_dir"

just mac-dmg

if [[ ! -f "$latest_dmg" ]]; then
    echo "Expected DMG not found: ${latest_dmg}" >&2
    exit 1
fi

mv "$latest_dmg" "$release_dmg"
shasum -a 256 "$release_dmg" > "${release_dmg}.sha256"

cat > "${release_dir}/release-notes.md" <<EOF
# ${app_name} ${version}

Build: ${build}
Generated: ${stamp}

## Release Checklist

- Verify the app launches on a clean macOS account.
- Verify SSH password and key authentication.
- Verify SFTP browsing, file editing, and transfers.
- Verify monitor diagnostics and service drill-downs.
- Verify update checks once Sparkle keys and appcast hosting are configured.

## Distribution

- DMG: $(basename "$release_dmg")
- SHA-256: $(cut -d ' ' -f 1 "${release_dmg}.sha256")
EOF

if [[ "$notarize" == "true" ]]; then
    just mac-notarize "$release_dmg"
    xcrun stapler validate "$release_dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$release_dmg"
else
    echo "Skipping notarization. This artifact is not ready for public distribution. Pass 'true' to notarize it."
fi

if [[ "$notarize" == "true" && -n "${MAC_RELEASE_BASE_URL:-}" ]]; then
    # generate_appcast signs each DMG with the EdDSA private key from the
    # keychain (created by `just mac-sparkle-keygen`), producing enclosure
    # entries with a sparkle:edSignature that the app can verify.
    generate_appcast="$("${script_dir}/find_sparkle_tool.sh" generate_appcast)"
    "$generate_appcast" --download-url-prefix "${MAC_RELEASE_BASE_URL%/}/" "$release_dir"
fi

echo "Release artifact written to:"
echo "  ${release_dmg}"
echo "  ${release_dmg}.sha256"
echo "  ${release_dir}/release-notes.md"
if [[ -f "${release_dir}/appcast.xml" ]]; then
    echo "  ${release_dir}/appcast.xml"
fi
