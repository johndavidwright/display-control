# Publishing releases

[Back to DisplayControl](../README.md) · [Development](DEVELOPMENT.md)

Run the commands below from the repository root.

The Build and Test workflow runs mock-based tests and verifies packaging on
pushes to main and pull requests. Pushing a `v*` tag runs the release workflow:
tests, Apple Silicon packaging, EdDSA signing, and GitHub Release publication.

1. Update both version fields in `Resources/Info.plist` to the same new version.
2. Update `RELEASE_NOTES.md` and commit the changes to main.
3. Create and push the matching tag (for example, `v0.3.1`).
4. Confirm Publish Release succeeds before announcing the release.

The release contains an app ZIP, its SHA-256 checksum, the MIT `LICENSE`, and
the signed `appcast.xml` consumed by installed copies of DisplayControl. The stable feed
address is the latest GitHub Release's `appcast.xml` asset. Keep the repository
and release downloads public so app users do not need GitHub credentials.

For a local release build:

```bash
./scripts/package-release.sh
./scripts/generate-appcast.sh
```

Local signing uses the `com.jdw.DisplayControl` account created by Sparkle's
`generate_keys` tool in the login Keychain. CI uses the encrypted repository
secret `SPARKLE_PRIVATE_KEY`, passed to the signer through standard input. The
public counterpart is `SUPublicEDKey` in Info.plist. Keep the private key backed
up securely and out of Git: replacing it without a supported key migration
prevents installed copies from accepting future updates.

## Editing published release text

GitHub release descriptions can be edited after publication. The update feed
contains its own signed copy of the release notes from build time. Preserve
published app archives and signed feeds when making editorial changes; publish
a new version when the app itself needs to change.
