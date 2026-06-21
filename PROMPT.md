# Varnish Hardened -- Build Prompt

## Objectif

Construire une image Docker hardened `jbsky/varnish-hardened` (Tier Or) pour Varnish Cache, deployee en StatefulSet k3s avec shard director et HPA autoscaling (1-3 replicas).

## Contraintes architecturales

**FROM scratch IMPOSSIBLE** : Varnish compile le VCL en C puis en .so a chaque demarrage (`exec cc -fpic -shared -Wl,-x -o %o %s`). Un compilateur C est requis au runtime.

**Tier Or retenu** : Alpine 3.21 minimal + TCC (Tiny C Compiler, 1.5 MB) comme compilateur VCL. Pas de gcc (120 MB), pas de shell superflu au-dela de busybox Alpine.

## Specifications techniques

### Versions cibles

| Composant | Version | Source |
|-----------|---------|--------|
| Varnish | 7.7.3 (latest stable) | https://varnish-cache.org/_downloads/ |
| Alpine | 3.21 | docker.io/library/alpine |
| Go | 1.26 | golang:1.26-alpine |
| TCC | apk (latest) | Alpine repos |
| tini-static | apk | Alpine repos |

### VMODs requis

- `std` : built-in (inclus dans Varnish)
- `directors` : built-in (shard director pour le scaling)
- PAS de `varnish-modules` (non utilise dans le VCL actuel)
- PAS de `vmod-dynamic` (backends statiques via DNS k8s)

### Multi-stage build (3 stages)

```
Stage 1: builder (Alpine 3.21)
  - Compile Varnish 7.7.3 from source avec hardening flags
  - Configure avec: --prefix=/usr --with-jemalloc
  - VCC_CC="tcc -fpic -shared -o %o %s" (pour que le binaire sache utiliser tcc)
  - strip binaries (varnishd, varnishadm, varnishlog, varnishstat, varnishncsa)
  - Conserver /usr/include/varnish/ (headers pour VCL compilation runtime)
  - Conserver /usr/lib/varnish/vmods/ (vmods built-in compiles)

Stage 2: gobuilder (golang:1.26-alpine)
  - Compiler init.go en binaire statique (CGO_ENABLED=0)
  - Modes: --healthcheck, --setup-dirs, (default)=entrypoint

Stage 3: runtime (Alpine 3.21 minimal)
  - apk: tcc, musl-dev, pcre2, libedit, ncurses-libs, jemalloc, tini-static, ca-certificates
  - COPY binaires depuis builder
  - COPY headers varnish depuis builder
  - COPY vmods depuis builder  
  - COPY init depuis gobuilder
  - ln -sf /usr/bin/tcc /usr/bin/cc
  - User varnish UID 6081 GID 6081
  - Healthcheck via Go init
  - ENTRYPOINT ["/sbin/tini-static", "--", "/usr/local/bin/init"]
```

### Compiler hardening flags (obligatoires)

```
CFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIE -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security"
CXXFLAGS="${CFLAGS}"
LDFLAGS="-Wl,-z,relro,-z,now,-z,noexecstack -pie"
```

### Go init binary (init.go)

3 modes :

| Flag | Comportement |
|------|-------------|
| `--setup-dirs` | Cree /var/lib/varnish (workdir), /etc/varnish (config) avec uid 6081 |
| `--healthcheck` | HTTP GET http://127.0.0.1:8080/healthcheck, expect 200, timeout 3s |
| (default) | Pre-checks (varnishd existe, VCL existe) + exec varnishd avec les args passes |

L'entrypoint par defaut :
1. Verifie que `/etc/varnish/default.vcl` existe (ou le VCL passe en `-f`)
2. Cree `/var/lib/varnish/$(hostname)` si absent (workdir varnish)
3. Exec `varnishd -F -f /etc/varnish/default.vcl -a http=:8080,HTTP -a proxy=:8443,PROXY -p feature=+http2 -s malloc,${VARNISH_SIZE:-256M}` + args supplementaires

### Dockerfile final attendu

```dockerfile
# --- Metadata ---
ARG VARNISH_VERSION=7.7.3
ARG ALPINE_VERSION=3.21

# --- Stage 1: Builder ---
FROM alpine:${ALPINE_VERSION} AS builder
# ... compile from source ...

# --- Stage 2: Go init ---
FROM golang:1.26-alpine AS gobuilder
# ... build init binary ...

# --- Stage 3: Runtime ---
FROM alpine:${ALPINE_VERSION}

# Labels OCI
LABEL org.opencontainers.image.title="varnish-hardened" \
      org.opencontainers.image.description="Varnish Cache hardened (Tier Or)" \
      org.opencontainers.image.vendor="jbsky" \
      org.opencontainers.image.source="https://github.com/jbsky/varnish-hardened" \
      security.hardening.tier="or"

# Runtime deps + TCC compiler + tini
RUN apk add --no-cache tcc musl-dev pcre2 libedit ncurses-libs jemalloc tini-static ca-certificates \
    && adduser -D -u 6081 -H -s /sbin/nologin varnish \
    && ln -sf /usr/bin/tcc /usr/bin/cc \
    && mkdir -p /var/lib/varnish /etc/varnish \
    && chown varnish:varnish /var/lib/varnish

COPY --from=builder /out/usr/sbin/varnishd /usr/sbin/
COPY --from=builder /out/usr/bin/varnish* /usr/bin/
COPY --from=builder /out/usr/lib/varnish/ /usr/lib/varnish/
COPY --from=builder /out/usr/include/varnish/ /usr/include/varnish/
COPY --from=gobuilder /init /usr/local/bin/init

ENV VARNISH_SIZE=256M

USER 6081:6081
WORKDIR /etc/varnish

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
    CMD ["/usr/local/bin/init", "--healthcheck"]

ENTRYPOINT ["/sbin/tini-static", "--", "/usr/local/bin/init"]
EXPOSE 8080 8443
```

### Security context k8s

```yaml
securityContext:
  runAsUser: 6081
  runAsGroup: 6081
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
```

Volumes :
- `/etc/varnish/` : ConfigMap (VCL + sous-fichiers)
- `/var/lib/varnish/` : emptyDir (workdir, .so compiles)

## Deploiement k8s (StatefulSet + HPA)

### Architecture shard director

- **StatefulSet** `varnish` (namespace `varnish`) avec headless service `varnish-peers`
- **HPA** : 1-3 replicas, target CPU 70%
- **Init-container** : remplace `__MY_ORDINAL__` dans le VCL par l'index du pod (ex: `varnish-0` -> `0`)
- **Sidecar vcl-reload** (optionnel) : watch ConfigMap + `varnishadm vcl.load`
- **Sidecar exporter** : `prometheus_varnish_exporter` pour metriques

### VCL shard logic

Chaque pod :
1. Recoit une requete du WAF nginx
2. `directors.shard(SHA256)` determine le peer owner de l'URL
3. Si owner == moi -> fetch backend WordPress, cache localement
4. Si owner != moi -> forward au peer owner via `X-Varnish-Peer` header

Backends WordPress (DNS k8s) :
- `jbsky-fr-production-wordpress.jbsky-fr-production.svc.cluster.local:80`
- `integ-jbsky-fr-wordpress.integ-jbsky-fr.svc.cluster.local:80`

### Probes

- **Liveness** : TCP 8080
- **Readiness** : HTTP GET `/healthcheck` port 8080 (via VCL `if (req.url == "/healthcheck") { return(synth(200)); }`)
- **Backend probe** : `.url = "/healthcheck"` (PAS `/` -> 301 WordPress = backend sick)

## CI/CD

### GitHub Actions (source de verite)

3 workflows standards :
- `build-push.yml` : lint + build multi-platform (amd64) + cosign + Trivy + SLSA
- `version-watch.yml` : cron quotidien, detect upstream Varnish updates
- `security-audit.yml` : cron hebdo, Trivy + Grype + cosign verify

### GitLab CI (homelab)

Stages : `lint` -> `build` -> `scan`
- Image CI : `docker:27-dind` (runner tag `docker,apk`)
- Build proxy-aware (secret CA + http_proxy)
- Push `gitlab.home.arpa:5050/docker/varnish-hardened:latest`

## Fichiers a creer

```
varnish-hardened/
  Dockerfile
  init.go
  go.mod
  .github/
    workflows/
      build-push.yml
      version-watch.yml
      security-audit.yml
  .gitlab-ci.yml
  scripts/
    test.sh          # Tests: healthcheck, cache HIT/MISS, shard headers
  versions.json      # {"varnish": "7.7.3", "alpine": "3.21"}
  .hadolint.yaml
  .dockerignore
```

## Registries

- GitHub : `ghcr.io/jbsky/varnish-hardened`
- Docker Hub : `docker.io/jbsky/varnish-hardened`
- GitLab : `gitlab.home.arpa:5050/docker/varnish-hardened`

## Criteres de succes

1. Image < 35 MB
2. Non-root (UID 6081)
3. Read-only rootfs (sauf emptyDir /var/lib/varnish)
4. VCL compile au demarrage via TCC (pas gcc)
5. Healthcheck Go binary (pas curl/shell)
6. tini-static PID 1
7. Shard director fonctionnel (multi-pod cache distribution)
8. HPA scale 1->3 sans perte de cache (grace period)
9. Probe backend `/healthcheck` (pas `/`)
10. Metriques Prometheus via exporter sidecar
11. CI complete : lint + build + sign + scan
12. Zero CVE HIGH/CRITICAL (Trivy)
