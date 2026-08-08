# Release process and trust

Imaginary Friend has an independent UTC date-time `VERSION`, changelog, tag,
artifact, SBOM, provenance, signatures, and test evidence. A root Ubuntu
Zombie release does not change the Friend version.

| Item | Convention |
| ---- | ---------- |
| Version | `yyyy.mm.dd.hh.nn.ss` UTC |
| Tag | `imaginary-friend-v<VERSION>` |
| Artifact | `imaginary-friend-<VERSION>.tar.gz` |
| SBOM | SPDX JSON |
| Checksums | SHA-256 manifest |
| Provenance | GitHub artifact attestation bundle |
| Signatures | Keyless cosign bundle, signature, and certificate for each asset |
| Test evidence | Product/version/commit JSON generated after lint, tests, and packaging |

The artifact contains only `products/imaginary-friend/`, the applicable
`family/schemas/`, and the repository license. The pinned workflow in
`.github/workflows/imaginary-friend-release.yml` validates and packages the
product, generates its SBOM and checksums, attests and signs assets, and
publishes the product tag.

Before installation, verify that the tag matches `VERSION`, every downloaded
asset matches the checksum manifest, the attestation subject matches the
artifact digest, and the signing certificate identity belongs to the expected
repository workflow. Keep those results with the release receipt.

Publishing an independent artifact does not admit it to Ubuntu Zombie's
production family catalogue. `family/catalog.json` remains empty until the
catalogue digest, manager, standalone VM, co-installation, red-team, and
release-verification gates pass. A source checkout can be used only for
reviewed disposable-VM development and is marked as an unreleased source
install.
