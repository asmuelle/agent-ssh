# Export Compliance Notes

Midnight SSH implements SSH/SFTP and related secure network protocols using published, industry-standard cryptography supplied by its Rust dependencies and Apple platforms. The app does not implement proprietary or unpublished cryptographic algorithms.

`ITSAppUsesNonExemptEncryption` is set to `false` in the macOS and mobile application Info.plists on the engineering assessment that this use is exempt encryption rather than non-exempt encryption.

Before the first production submission, the developer must:

1. Reconfirm the classification against the current US Export Administration Regulations and Apple's App Store Connect guidance.
2. Answer App Store Connect's encryption questions consistently with the submitted binary.
3. Determine whether an annual self-classification report or other filing is required for distribution in the selected countries.
4. Retain the classification rationale and any filing confirmation with the release records.
5. Re-evaluate the answer if cryptographic behavior, VPN functionality, proprietary algorithms, or country availability changes.

This repository note documents the engineering facts and release checklist; it is not legal advice and cannot replace the developer's provider-side filing or legal determination.
