# Release process

## Versioning rules (SemVer)

ClawTier uses [Semantic Versioning](https://semver.org/) (`MAJOR.MINOR.PATCH`).

- **MAJOR**: Increment for breaking changes to bootstrap behavior, CLI flags/options, environment variable contracts, or script interfaces that require users to change existing automation.
- **MINOR**: Increment for backward-compatible functionality additions such as new flags, new optional setup stages, or additive behavior that does not break existing documented flows.
- **PATCH**: Increment for backward-compatible fixes, reliability improvements, docs-only clarifications, or internal maintenance that preserves existing behavior and interfaces.

## Tag format

- Tag format is strictly **`vX.Y.Z`** (for example, `v1.4.2`).
- Use **annotated tags only** (`git tag -a vX.Y.Z -m "Release vX.Y.Z"`).
- Lightweight tags are not part of this release model.

## Release branch and tagging process

- Releases are cut from the **`main`** branch only.
- The **repository owner/maintainer** is responsible for cutting release tags.
- Cut a release tag after the intended changes are merged into `main` and validation checks pass.
- Recommended flow:
  1. Ensure local `main` is up to date with remote.
  2. Run project checks relevant to the release.
  3. Create an annotated `vX.Y.Z` tag at the release commit on `main`.
  4. Push the tag and publish release notes in GitHub Releases.

## Backports and hotfixes

If a post-release issue requires a rapid fix:

- Create a hotfix branch from `main` (or from the specific release commit when needed for isolation).
- Apply the minimal safe change.
- Merge the hotfix to `main`.
- Cut the next **PATCH** release tag from `main`.

If older lines must be supported later:

- Create a dedicated maintenance branch for that line (for example, `release/1.2`).
- Cherry-pick narrowly scoped fixes.
- Tag maintenance releases with normal SemVer patch increments (`v1.2.4`, etc.).
- Keep release notes explicit about which branch/line received the backport.
