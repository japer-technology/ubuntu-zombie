# Release process

How to cut a new release of Ubuntu Zombie. For maintainers only.

## Cadence

There is no fixed cadence. Cut a release when:

- A security-impacting bug has been fixed (within two weeks of the
  fix landing on `main`).
- A user-visible feature has stabilised on `main` and the changelog
  for it is written.
- The `[Unreleased]` section of `CHANGELOG.md` has grown to "enough
  to justify a tag".

We follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Steps

1. **Land everything on `main`** that should be in the release.
   `main` must be green: `make lint && make test` plus all CI
   workflows.

2. **Update `VERSION`** to the new version (no `v` prefix, no
   leading/trailing whitespace).

   ```bash
   echo "0.4.0" > VERSION
   ```

3. **Update `CHANGELOG.md`**: rename the `[Unreleased]` heading to
   `[<version>] - <YYYY-MM-DD>` and start a fresh empty
   `[Unreleased]` section above it.

4. **Update `debian/changelog`**: prepend a stanza for the new
   version.

   ```
   ubuntu-zombie (0.4.0) UNRELEASED; urgency=medium

     * See /CHANGELOG.md.

    -- Japer Technology <ops@japer.technology>  <RFC-2822 date>
   ```

5. **Open a "Release X.Y.Z" PR** with the three file changes above.
   Merge once green.

6. **Tag from `main`**:

   ```bash
   git fetch origin
   git checkout main
   git pull --ff-only
   git tag -s "v$(cat VERSION)" -m "Release v$(cat VERSION)"
   git push origin "v$(cat VERSION)"
   ```

   The tag *must* match `v<VERSION>` exactly; the release workflow
   refuses to publish otherwise.

7. **Watch the `Release` workflow** finish. It will:

   - Re-run lint + smoke.
   - Build the source tarball (`make package`).
   - Build the `.deb` (`make deb`).
   - Compute `SHA256SUMS`.
   - Generate an SPDX SBOM with Syft.
   - Keyless-sign every artifact with cosign.
   - Create the GitHub Release and upload everything.

8. **Verify the release page**:

   - Tarball, `.deb`, `SHA256SUMS`, SPDX, and `.sig`/`.pem`/`.cosign.bundle`
     for each artifact must all be attached.
   - Release notes should contain the relevant CHANGELOG section and
     the cosign verification snippet.

9. **Announce** in the
   [Discussions › Announcements](https://github.com/japer-technology/ubuntu-zombie/discussions/categories/announcements)
   category. Link the release page.

## Hotfix (patch) releases

For a single security-impacting fix:

1. Branch from the previous release tag: `git checkout -b release/0.3.x v0.3.0`.
2. Cherry-pick the fix.
3. Follow steps 2–9 above with the patch version (`0.3.1`).

## Rolling back a release

GitHub Releases are immutable in spirit. To roll back:

1. Mark the release as "Pre-release" in the GitHub UI so it does
   not appear under "Latest".
2. Cut a new patch that supersedes it.
3. Update the release notes of the bad release with a link to the
   replacement.

Never delete an existing release: external installers may have
pinned to the tarball URL by SHA.

## What goes in a "non-release" build

Pushing to `main` does **not** create a release. CI builds the source
bundle on every push for sanity, but it is never published. Operators
who track `main` use `git pull && sudo ./scripts/install.sh install`.
