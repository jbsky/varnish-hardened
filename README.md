# Varnish Hardened

[![Build](https://github.com/jbsky/varnish-hardened/actions/workflows/build-push.yml/badge.svg)](https://github.com/jbsky/varnish-hardened/actions/workflows/build-push.yml)
[![Docker Hub](https://img.shields.io/docker/v/jbsky/varnish-hardened?sort=semver&label=Docker%20Hub)](https://hub.docker.com/r/jbsky/varnish-hardened)
[![Hardening](https://img.shields.io/badge/hardening-platine-blueviolet)](https://github.com/jbsky/varnish-hardened#security--verification)

Image Docker Varnish Cache 7.7.3 hardenee (FROM scratch, Go init, tini PID 1), optimisee pour deploiement K3s avec shard director horizontal scaling.

## Features

| Feature | Detail |
|---------|--------|
| FROM scratch | Zero shell, zero package manager, zero attack surface |
| Non-root | UID 6081 (varnish:nogroup) |
| Compiler hardening | RELRO, PIE, SSP, FORTIFY_SOURCE, NX |
| Go static init | Healthcheck HTTP + setup-dirs (no shell) |
| tini PID 1 | Signal forwarding + zombie reaping |
| TCC embarque | Tiny C Compiler pour compilation VCL at runtime |
| PROXY protocol | Support natif (port 8443) pour real client IP |
| Shard director | Scale horizontal natif via `directors.shard()` |

## Image

| Registry | Tag | Taille |
|----------|-----|--------|
| `docker.io/jbsky/varnish-hardened` | `7.7.3` | ~18 MB |
| `ghcr.io/jbsky/varnish-hardened` | `7.7.3` | ~18 MB |

## Usage rapide

```bash
cp .env.example .env    # (optionnel)
make build              # Build l'image
make up                 # Demarre Varnish
make test               # Smoke tests (healthcheck + cache hit)
make scan               # Trivy vulnerability scan
make down               # Arrete
```

## Configuration

| Variable d'env | Default | Description |
|---------------|---------|-------------|
| `VARNISH_VCL` | `/etc/varnish/default.vcl` | Chemin du fichier VCL |
| `VARNISH_SIZE` | `256M` | Taille du cache (malloc) |
| `VARNISH_HTTP_PORT` | `8080` | Port HTTP |
| `VARNISH_PROXY_PORT` | `8443` | Port PROXY protocol |
| `VARNISH_OPTS` | (vide) | Arguments supplementaires pour varnishd |

## Scale horizontal : shard director

L'image est concue pour le scale horizontal via le **shard director** de Varnish.

### Principe

```
                     Service K3s (round-robin)
                    /          |          \
              varnish-0   varnish-1   varnish-2  ...  varnish-N
                    \          |          /
                     Shard director (SHA256)
                     Chaque URL = 1 seul owner
```

Chaque pod recoit les requetes en round-robin. Le VCL calcule le shard owner pour l'URL demandee :
- Si le pod courant EST le owner : il cache localement et sert
- Sinon : il forward au peer owner (header `X-Varnish-Peer`)

### Scaling dynamique

Le nombre de replicas n'est **pas limite** -- il suffit de :
1. Scaler le StatefulSet : `kubectl scale statefulset varnish --replicas=N`
2. Regenerer le VCL avec N backends peer (via l'init-container template)
3. Appliquer le nouveau ConfigMap

L'init-container genere le VCL dynamiquement en iterant sur les replicas du StatefulSet. Le placeholder `__MY_ORDINAL__` est remplace par l'index du pod courant.

### Headless Service

Les pods se decouvrent via un headless Service :
```
varnish-{i}.varnish-peers.varnish.svc.cluster.local
```

## Architecture du repo

```
varnish-hardened/
├── Dockerfile              # Multi-stage 4 stages (builder → gobuilder → prep → scratch)
├── docker-compose.yml      # Stack hardenee pour dev local
├── Makefile                # Raccourcis (build, up, test, scan)
├── versions.json           # Versions trackees (Varnish, Alpine)
├── go.mod + init.go        # Go static init (healthcheck HTTP + entrypoint)
├── .hadolint.yaml          # Config linter Dockerfile
├── conf/
│   └── default.vcl         # VCL par defaut (backend none)
├── scripts/
│   └── test.sh             # Smoke tests (cache hit/miss, healthcheck)
├── .github/
│   └── workflows/
│       ├── build-push.yml      # Build + cosign sign + Trivy + SLSA
│       ├── version-watch.yml   # Daily upstream version detection
│       └── security-audit.yml  # Weekly Trivy + Grype
└── .gitlab-ci.yml          # Mirror CI GitLab homelab
```

## Build multi-stage

```
Stage 1: builder      → Compile Varnish 7.7.3 + TCC from source (hardening flags)
Stage 2: gobuilder    → CGO_ENABLED=0 Go static init binary
Stage 3: prep         → Runtime libs + tini + user 6081 + setcap (aucun)
Stage 4: FROM scratch → Assemblage final (~18 MB)
```

### Pourquoi TCC ?

Varnish compile le VCL (Varnish Configuration Language) en C puis en shared object **at runtime**. Il a besoin d'un compilateur C. GCC/Clang sont trop lourds pour FROM scratch.

TCC (Tiny C Compiler) est un compilateur C minimaliste (~200 KB) suffisant pour les shared objects generes par Varnish. Il est compile from source (branche mob) et embarque dans l'image.

## Healthcheck

Le Go init effectue un HTTP GET sur `/__health` (port 8080) :
- Verifie que Varnish repond et que le VCL est charge
- Utilise par les probes K8s (liveness + readiness)
- Timeout 3s, interval 10s, 3 retries

## Security & Verification

```bash
# Verifier la signature cosign (OIDC keyless)
cosign verify ghcr.io/jbsky/varnish-hardened:7.7.3 \
  --certificate-identity-regexp '^https://github.com/jbsky/varnish-hardened/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## CI/CD

3 workflows GitHub Actions :
- **build-push** : hadolint + build multi-platform + cosign + Trivy + SLSA attestation
- **version-watch** : cron quotidien, detecte nouvelle version Varnish Cache upstream
- **security-audit** : hebdomadaire Trivy + Grype, auto-issue si vulnerabilite

## Licence

MPL-2.0 (Varnish Cache) / MIT (init.go, scripts)
