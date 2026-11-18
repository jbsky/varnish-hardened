# Varnish Hardened

[![Build](https://github.com/jbsky/varnish-hardened/actions/workflows/build-push.yml/badge.svg)](https://github.com/jbsky/varnish-hardened/actions/workflows/build-push.yml)
[![Docker Hub](https://img.shields.io/docker/v/jbsky/varnish-hardened?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/jbsky/varnish-hardened)
[![Hardening](https://img.shields.io/badge/hardening-platine-blueviolet)](https://github.com/jbsky/varnish-hardened#hardening)

Varnish Cache <!--v:varnish-hardened-->8.0.0<!--/v--> built from source, in a `FROM scratch`
image: no shell, no package manager, no OS. Only `varnishd`, the Tiny C
Compiler it needs for VCL, their libraries, `tini` and a static Go init --
about 18 MB. Meant for a K3s deployment scaled horizontally with the shard
director.

## What is built

- **Varnish Cache**: upstream release tarball, verified against its sha256
  pinned in [`versions.json`](versions.json).
- **TCC** (Tiny C Compiler): Varnish compiles VCL to C, then to a shared
  object, **at runtime** -- it needs a C compiler, and GCC or Clang are far too
  heavy for `FROM scratch`. TCC (~200 KB) is enough for the shared objects
  Varnish generates. Upstream publishes no release tarball, only the `mob`
  branch: it is built from a commit pinned in `versions.json`.
- **jemalloc**: built from source, sha256-verified.
- **PROXY protocol**: a second listener (port 8443) receives the real client
  IP from the load balancer.

## Hardening

Tier **platine** (OCI label `security.hardening.tier`): a `FROM scratch` image
with no shell and no package manager, a non-root user, a static Go init behind
`tini` as PID 1, and binaries built with hardening flags.

- Non-root user `6081:65534` (`varnish:nogroup`), no capability.
- Compiler flags: PIE, full RELRO, `-fstack-protector-strong`,
  `-fstack-clash-protection`, `_FORTIFY_SOURCE=2`, non-executable stack.
- Libraries copied from a dependency closure resolved at build time
  (`lddtree`), never `/lib` or `/usr/lib` wholesale.
- The init builds the `varnishd` command line from the environment (no shell
  script) and serves as the healthcheck.

## Tags

Every image is published under three tags: `latest` (last build of `main`),
the upstream version alone, and the upstream version followed by a **revision
counter**. The first two are **overwritten in place** on every rebuild (Alpine
update, CVE fix, configuration change), and the build they pointed to can no
longer be pulled by them. **In production, pin the tag that carries the
counter.**

<!-- BEGIN:tags (genere par la CI -- ne pas editer a la main) -->
| Image | Version amont | Tag immuable a epingler |
|-------|---------------|-------------------------|
| `jbsky/varnish-hardened` | `8.0.0` | `8.0.0.48` |
<!-- END:tags -->

This table, the versions quoted in the text and the tags in the examples are
rendered by `update-readme-tags.sh` ([hardened-ci](https://github.com/jbsky/hardened-ci))
after each publication: do not edit them by hand.

The counter counts the commits that touch the image inputs (the `revision`
list of [`.github/hardened-ci.json`](.github/hardened-ci.json)) since the last
upstream version change, and restarts at `0` with each new upstream version. A
commit that only touches `.github/` does not increment it.

`docker.io` and `ghcr.io` publish the same tags with the same digest, for
`linux/amd64`. Each registry keeps the last six immutable tags of an image, so
that superseded builds do not stay pullable: move your pin forward.

`version-watch` checks upstream daily, bumps `versions.json` (version and
sha256) and republishes.

## Usage

```bash
docker run -d --name varnish \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --tmpfs /var/lib/varnish:nodev,nosuid,exec,size=256m,mode=1777 \
  --tmpfs /tmp:nodev,nosuid,noexec,size=16m,mode=1777 \
  -v ./default.vcl:/etc/varnish/default.vcl:ro \
  -p 8080:8080 -p 8443:8443 \
  jbsky/varnish-hardened:8.0.0.48
```

- The image ships [`conf/default.vcl`](conf/default.vcl), a test VCL with no
  real backend; mount your own on `/etc/varnish/default.vcl`.
- **`/var/lib/varnish` must allow `exec`**: `varnishd` maps an executable
  shared-memory log in its working directory and refuses to start on a
  `noexec` mount. `mode=1777` is needed too, or the tmpfs belongs to root and
  uid `6081` cannot write to it.
- **Healthcheck**: the init sends `GET /__health` on port 8080, which your VCL
  must answer (the shipped one does), or another URL through
  `VARNISH_HEALTH_URL`. It also serves the Kubernetes liveness and readiness
  probes.

### Configuration

| Environment variable | Default | Description |
|---|---|---|
| `VARNISH_VCL` | `/etc/varnish/default.vcl` | VCL file |
| `VARNISH_SIZE` | `256M` | Cache size (`malloc`) |
| `VARNISH_HTTP_PORT` | `8080` | HTTP listener |
| `VARNISH_PROXY_PORT` | `8443` | PROXY protocol listener |
| `VARNISH_OPTS` | (empty) | Extra `varnishd` arguments |

## Horizontal scaling: shard director

The image is designed for horizontal scaling through Varnish's **shard
director**.

```
                     K3s Service (round-robin)
                    /          |          \
              varnish-0   varnish-1   varnish-2  ...  varnish-N
                    \          |          /
                     Shard director (SHA256)
                     each URL = one single owner
```

Each pod receives requests round-robin. The VCL computes the shard owner of
the requested URL:

- if the current pod IS the owner, it caches locally and serves;
- otherwise, it forwards to the owner peer (header `X-Varnish-Peer`).

The number of replicas is **not limited**. To scale:

1. scale the StatefulSet: `kubectl scale statefulset varnish --replicas=N`;
2. regenerate the VCL with N peer backends (through the init-container
   template);
3. apply the new ConfigMap.

The init-container generates the VCL by iterating over the StatefulSet
replicas; the `__MY_ORDINAL__` placeholder is replaced by the current pod's
index. Pods find each other through a headless Service:
`varnish-{i}.varnish-peers.varnish.svc.cluster.local`. These manifests live
with the deployment, not in this repository.

## Build and test

```bash
make build   # build args come from versions.json
make up      # start the compose stack
make test    # scripts/test.sh against the running container
make scan    # Trivy, HIGH and CRITICAL
```

`scripts/test.sh` checks the healthcheck endpoint, that `TRACE` is refused
(405) and that no `Via` header leaks.

Versions live only in [`versions.json`](versions.json): the Dockerfile has no
defaults, `make build` and CI pass them through `scripts/versions-build-args.py`,
and a bare `docker build` stops at the guard.

## Verification

Images are signed with [cosign](https://github.com/sigstore/cosign) (keyless,
GitHub OIDC) by the shared [hardened-ci](https://github.com/jbsky/hardened-ci)
pipeline. The certificate names that workflow and, in an extension, this
repository: the commands below require both.

```bash
# ghcr.io
cosign verify ghcr.io/jbsky/varnish-hardened:8.0.0.48 \
  --certificate-identity-regexp '^https://github.com/(jbsky/varnish-hardened|jbsky/hardened-ci)/' \
  --certificate-github-workflow-repository jbsky/varnish-hardened \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# Docker Hub (the signature is stored on ghcr.io)
COSIGN_REPOSITORY=ghcr.io/jbsky/varnish-hardened \
  cosign verify docker.io/jbsky/varnish-hardened:8.0.0.48 \
  --certificate-identity-regexp '^https://github.com/(jbsky/varnish-hardened|jbsky/hardened-ci)/' \
  --certificate-github-workflow-repository jbsky/varnish-hardened \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Each published digest also carries a CycloneDX SBOM (the `prep` stage the
image is assembled from, plus its Go binaries), attested with cosign, and a
GitHub SLSA build provenance attestation. The pipeline lints, builds, scans the
`prep` stage with Trivy, tests the exact digest it is about to publish (image
manifest, dependency closure, functional tests), then promotes and signs it.
Base image digests follow upstream daily (`base-watch`), a fixable Alpine
package CVE triggers a rebuild (`cve-watch`), and the published image is
audited weekly (`security-audit`: Trivy, Grype, cosign). Audit status and
documented exceptions: [`SECURITY.md`](SECURITY.md).

## License

The contents of this repository (Dockerfile, `init.go`, scripts and CI) are
licensed under **Apache-2.0**, see [`LICENSE`](LICENSE). Copyright 2026 jbsky.

The software shipped in the image keeps its own license: **Varnish Cache is
under BSD-2-Clause**, and the other components built from source keep their
upstream's. The two never mix: `init.go` is a separate program that executes
`varnishd` without being linked to its libraries.

Contributions: see [`CONTRIBUTING.md`](CONTRIBUTING.md); a `Signed-off-by` is
required.
