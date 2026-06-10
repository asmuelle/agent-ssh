#!/usr/bin/env bash

set -euo pipefail

notarize="${1:-false}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
macos_dir="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${macos_dir}/.." && pwd)"
plist="${macos_dir}/AgentSshApp/Info.plist"
app_name="agent-ssh"
app_path="${macos_dir}/build/Build/Products/Release/${app_name}.app"

# A release with an empty SUPublicEDKey ships updates that Sparkle cannot
# signature-verify. Fail early instead of producing an unverifiable artifact.
sparkle_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null || true)"
if [[ -z "$sparkle_key" ]]; then
    echo "SUPublicEDKey is empty in ${plist}." >&2
    echo "Run 'just mac-sparkle-keygen' and add the printed public key to Info.plist before releasing." >&2
    exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
release_name="${app_name}-${version}-${build}-${stamp}"
release_dir="${macos_dir}/build/release/${release_name}"
release_dmg="${release_dir}/${app_name}-${version}.dmg"
latest_dmg="${macos_dir}/${app_name}.dmg"

cd "$repo_root"

just mac-clean
rm -rf "$release_dir"
mkdir -p "$release_dir"

if [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]]; then
    just mac-build-signed
else
    echo "APPLE_SIGNING_IDENTITY is not set; building an ad-hoc signed release artifact."
    just mac-build
fi

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
else
    echo "Skipping notarization. Pass 'true' after Apple Developer credentials are available."
fi

if [[ -n "${MAC_RELEASE_BASE_URL:-}" ]]; then
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
