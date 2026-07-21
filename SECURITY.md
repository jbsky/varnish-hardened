# Security Audit Status

The weekly `security-audit.yml` workflow (Trivy + Grype, `--fail-on high --only-fixed`)
scans the published `:latest` image every Tuesday. This file tracks known,
investigated exceptions so the CI state doesn't need to be re-diagnosed from scratch
each time it comes up.

## Old vulnerable image tags left publicly pullable (found 2026-07-21, fixed)

Same root cause as `nginx-hardened`: `build-push.yml` pushes a new immutable version
tag (e.g. `7.7.3`) on every run, in addition to `:latest`, on both Docker Hub and
GHCR, and never retired the previous one. Confirmed via a direct `grype` scan against
the old published tag `7.7.3`: it still ships `go1.24.13` with ~19 unfixed Go stdlib
CVEs, several High severity (`GO-2026-4986`, `GO-2026-4918`, `GO-2026-4601`,
`GO-2026-4870`, `GO-2026-4947`, `GO-2026-4971`, `GO-2026-5038`, and others), all
already fixed in the current `8.0.0` build.

Fixed by `registry-cleanup.yml` (`scripts/prune-registry-tags.sh` for Docker Hub,
`scripts/prune-ghcr-tags.sh` for GHCR), called as a job from `build-push.yml` after
every push, and directly `workflow_dispatch`-able. Keeps the last 3 semver tags +
`:latest`. Only ever deletes a package version by its own named tag -- untagged
manifest-list children, attestations, and cosign signatures are left alone.

**Important caveat** (hit on `nginx-hardened`'s first run, applies here too): "keep the
last 3 semver tags" is generic hygiene, not CVE-aware. After any prune run,
cross-check the surviving semver tags with a direct `grype <image>:<tag> --fail-on
high --only-fixed` scan -- if one inside the keep-window is still flagged, delete it
explicitly.
