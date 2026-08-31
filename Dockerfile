# =====================================================================
#  Varnish Hardened — Tier Platine (FROM scratch)
#  4-stage: builder → gobuilder → prep → scratch
# =====================================================================
# No default on purpose. versions.json is the single source of truth for the
# Varnish version; a default here drifts away from it silently -- it sat at
# 7.7.3 while versions.json and the published images had moved to 8.0.0, so
# `make build` produced a 7.7.3 image while CI shipped 8.0.0 under the same
# name. CI and the Makefile both pass it explicitly, and a bare `docker build`
# now fails with a message instead of building the wrong version.
ARG VARNISH_VERSION
# Upstream publishes neither a signature nor a checksum file next to the
# tarball (.asc, .sig and .sha256sum are all 404), so the integrity check is a
# sha256 pinned in versions.json -- the same fallback used for c-icap. It is
# recomputed by version-watch in the same commit as a version bump, never on
# its own: a hash that lags its version fails the build closed, which is the
# intended behaviour but only if the two always move together.
ARG VARNISH_SHA256
# ALPINE_VERSION kept for check-versions.sh/versions.json reference only --
# the FROM lines below pin tag+digest together as a literal so a version
# bump requires deliberately re-resolving the digest, not a silent drift
# if this ARG changes without the pin being updated to match.
ARG ALPINE_VERSION=3.24
# TCC ships no release tarball -- upstream publishes the `mob` branch only,
# so this build used to compile whatever mob HEAD happened to be that day:
# not reproducible, and a silent path for upstream changes into a compiler
# that ends up inside the published image. Pinned to an exact commit; bump
# it deliberately (`git ls-remote https://repo.or.cz/tinycc.git mob`).
ARG TCC_COMMIT=2ba12e83b3599ca8f5d50c179fe5138fe956f0c9

# jemalloc est compile depuis les sources, pas installe via apk : voir la note
# devant sa compilation dans le stage builder.
ARG JEMALLOC_VERSION=5.3.1
ARG JEMALLOC_SHA256=3826bc80232f22ed5c4662f3034f799ca316e819103bdc7bb99018a421706f92

# --- Stage 1: Build Varnish + TCC from source --------------------------
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

ARG VARNISH_VERSION
ARG VARNISH_SHA256
ARG TCC_COMMIT
ENV CFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIE -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
    CXXFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIE -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
    LDFLAGS="-Wl,-z,relro,-z,now,-z,noexecstack -pie"

# Fail before the (long) TCC build rather than after it
RUN test -n "${VARNISH_VERSION}" -a -n "${VARNISH_SHA256}" \
    || { echo "VARNISH_VERSION and VARNISH_SHA256 build-args are required: jq -r '.varnish, .varnish_sha256' versions.json" >&2; exit 1; }

# Proxy-aware: HTTP repos for SSL Bump compatibility
RUN sed -i 's|https://|http://|g' /etc/apk/repositories

# Proxy-aware CA injection
RUN --mount=type=secret,id=ca-certs,required=false \
    if [ -f /run/secrets/ca-certs ]; then \
        cat /run/secrets/ca-certs >> /etc/ssl/certs/ca-certificates.crt; \
    fi

# Build dependencies
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache \
        build-base autoconf automake libtool pkgconfig \
        python3 py3-docutils py3-sphinx \
        pcre2-dev libedit-dev ncurses-dev linux-headers \
        libunwind-dev curl

# --- jemalloc, compile depuis les sources ---
#
# Le paquet Alpine est construit avec le support C++ (surcharges de new/delete),
# ce qui fait de libjemalloc le SEUL consommateur de libstdc++ de cette image :
# 2,8 Mo de C++ embarques pour un allocateur ecrit en C. `--disable-cxx` les
# supprime, et libgcc_s part avec puisque plus rien ne l'appelle.
#
# jemalloc s'installe NON STRIPPE (il compile en -g3 par defaut) : 6,1 Mo au
# lieu de 818 Ko. Une bibliotheque compilee depuis les sources n'herite
# d'aucun strip, contrairement a un paquet Alpine -- le faire explicitement.
#
# jemalloc ne publie ni signature ni hash amont : le sha256 est epingle ici,
# comme varnish_sha256 juste au-dessus. Le canal a ete valide en comparant le
# sha512 de la 5.3.0 telechargee sur GitHub a celui qu'Alpine verifie de son
# cote -- identique octet pour octet.
#
# CFLAGS/LDFLAGS sont redefinis pour cette compilation seule : le stage porte
# `-fPIE` et `-pie` pour les executables de Varnish, mais jemalloc produit une
# bibliotheque PARTAGEE. `-pie` sur un lien `-shared` fait tirer Scrt1.o au
# linker, qui reclame alors un `main` inexistant. -fPIC suffit et est correct
# des deux cotes.
ARG JEMALLOC_VERSION
ARG JEMALLOC_SHA256
WORKDIR /tmp/jemalloc
RUN export CFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIC -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
 && export LDFLAGS="-Wl,-z,relro,-z,now,-z,noexecstack" \
 && curl -fsSL "https://github.com/jemalloc/jemalloc/releases/download/${JEMALLOC_VERSION}/jemalloc-${JEMALLOC_VERSION}.tar.bz2" \
      -o /tmp/jemalloc.tar.bz2 \
 && printf '%s  /tmp/jemalloc.tar.bz2\n' "${JEMALLOC_SHA256}" > /tmp/jemalloc.sha256 \
 && sha256sum -c /tmp/jemalloc.sha256 \
 && tar -xjf /tmp/jemalloc.tar.bz2 -C /tmp/jemalloc --strip-components=1 \
 && ./configure --prefix=/usr --disable-cxx --disable-static --disable-doc \
 && make -j"$(nproc)" \
 && make install \
 && test ! -e /usr/lib/libjemalloc.a \
 && strip --strip-unneeded /usr/lib/libjemalloc.so.2 \
 && rm -rf /tmp/jemalloc /tmp/jemalloc.tar.bz2 /tmp/jemalloc.sha256

# Retour a la racine : le telechargement de Varnish plus bas s'extrait dans le
# repertoire courant, et le WORKDIR /varnish-${VARNISH_VERSION} qui suit compte
# dessus. Sans cette ligne, le tarball atterrit dans /tmp/jemalloc et configure
# devient introuvable.
WORKDIR /

# Build TCC from source (pinned mob commit — compiler + empty libtcc1.a stub)
# VCL shared libs don't need libtcc1 symbols, but TCC requires the file to exist.
# `fetch --depth=1 <sha>` keeps it a shallow fetch while pinning exactly: git
# verifies the object hashes, so the pin is the integrity check. repo.or.cz is
# a single point of failure (it was down for hours on 2026-08-18 and took
# unrelated PR builds with it), hence the bounded retries.
# hadolint ignore=DL3003
RUN unset CFLAGS CXXFLAGS LDFLAGS \
    && apk add --no-cache git \
    && mkdir -p /tcc-src \
    && git -C /tcc-src init -q \
    && git -C /tcc-src remote add origin https://repo.or.cz/tinycc.git \
    && for attempt in 1 2 3; do \
         timeout 120 git -C /tcc-src fetch --depth=1 origin "${TCC_COMMIT}" && break; \
         echo "tinycc fetch attempt ${attempt} failed"; \
         [ "$attempt" = 3 ] && exit 1; \
         sleep 15; \
       done \
    && git -C /tcc-src checkout -q FETCH_HEAD \
    && cd /tcc-src \
    && ./configure --prefix=/usr \
    && make tcc \
    && mkdir -p /tcc-out/usr/bin /tcc-out/usr/lib/tcc \
    && cp tcc /tcc-out/usr/bin/tcc \
    && strip /tcc-out/usr/bin/tcc \
    && ar rcs /tcc-out/usr/lib/tcc/libtcc1.a

# Download and extract Varnish source
RUN --mount=type=secret,id=ca-certs,required=false \
    if [ -f /run/secrets/ca-certs ]; then cat /run/secrets/ca-certs >> /etc/ssl/certs/ca-certificates.crt; fi \
    && curl -fsSL "https://varnish-cache.org/_downloads/varnish-${VARNISH_VERSION}.tgz" -O \
    && printf '%s  varnish-%s.tgz\n' "${VARNISH_SHA256}" "${VARNISH_VERSION}" > varnish.sha256 \
    && sha256sum -c varnish.sha256 \
    && rm varnish.sha256 \
    && tar xzf "varnish-${VARNISH_VERSION}.tgz"

# Compile Varnish with hardening flags
WORKDIR /varnish-${VARNISH_VERSION}
RUN ./configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var/lib \
        --with-jemalloc \
        --disable-dependency-tracking \
        VCC_CC="exec tcc -fpic -shared -o %o %s" \
    && make -j"$(nproc)" \
    && make install DESTDIR=/out

# Strip all ELF binaries
RUN find /out -type f -executable -exec sh -c \
        'file "$1" | grep -q ELF && strip --strip-unneeded "$1"' _ {} \;

# Collect Varnish headers needed for VCL compilation at runtime
RUN mkdir -p /out/usr/include/varnish \
    && cp -a /out/usr/include/varnish/* /out/usr/include/varnish/ 2>/dev/null || true \
    && cp -a include/*.h /out/usr/include/varnish/ 2>/dev/null || true

# --- Stage 2: Go init binary -------------------------------------------
FROM golang:1.27-alpine@sha256:4c9fe60190a2a3350ddc51de80d0224b8a6698d12bdfc999fee45ea9d6c46dbc AS gobuilder

WORKDIR /src
COPY go.mod init.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags='-s -w' -trimpath -o /init .

# --- Stage 3: Prep — assemble runtime filesystem -----------------------
FROM alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS prep

# Proxy-aware: HTTP repos
RUN sed -i 's|https://|http://|g' /etc/apk/repositories

# Runtime libraries only (no compilers, no package manager in final)
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache \
        pcre2 libedit ncurses-libs libunwind \
        libgcc \
        musl-dev \
        tini-static ca-certificates tzdata

# Create non-root user
RUN adduser -D -u 6081 -H -s /sbin/nologin -G nogroup varnish

# Copy Varnish compiled artifacts
# jemalloc est compile dans le builder (voir la note la-bas), pas installe par
# apk ici : sa bibliotheque partagee doit donc etre reprise explicitement.
COPY --from=builder /usr/lib/libjemalloc.so* /usr/lib/

COPY --from=builder /out/usr/sbin/varnishd /usr/sbin/
COPY --from=builder /out/usr/bin/varnishadm /usr/bin/
COPY --from=builder /out/usr/bin/varnishlog /usr/bin/
COPY --from=builder /out/usr/bin/varnishstat /usr/bin/
COPY --from=builder /out/usr/bin/varnishncsa /usr/bin/
COPY --from=builder /out/usr/bin/varnishhist /usr/bin/
COPY --from=builder /out/usr/bin/varnishtop /usr/bin/
COPY --from=builder /out/usr/lib/varnish/ /usr/lib/varnish/
COPY --from=builder /out/usr/lib/libvarnishapi* /usr/lib/
COPY --from=builder /out/usr/include/varnish/ /usr/include/varnish/

# TCC binary as cc/gcc (Varnish VCC_CC defaults to "exec gcc")
COPY --from=builder /tcc-out/usr/bin/tcc /usr/bin/tcc
COPY --from=builder /tcc-out/usr/lib/tcc/ /usr/lib/tcc/
RUN ln -sf /usr/bin/tcc /usr/bin/cc \
    && ln -sf /usr/bin/tcc /usr/bin/gcc

# Go init binary
COPY --from=gobuilder /init /usr/local/bin/init

# Setup runtime directories
RUN mkdir -p /var/lib/varnish /etc/varnish /tmp \
    && chown 6081:65534 /var/lib/varnish \
    && chmod 1777 /tmp

# Default minimal VCL
RUN printf 'vcl 4.1;\nbackend default none;\n' > /etc/varnish/default.vcl

# Collect exactly the shared objects that ship, instead of copying /lib and
# /usr/lib whole into the final stage -- the wholesale copy also carried
# /lib/apk/db/installed and libapk.so, a package inventory and the package
# manager's library, into an image that is supposed to have neither.
#
# lddtree -l prints each binary, its transitive dependencies, symlinks together
# with their targets, and the loader for the architecture being built, so
# nothing hardcodes ld-musl-x86_64.so.1. VMODs are dlopen'd, so they are listed
# as roots rather than discovered -- and they live in /usr/lib/varnish/vmods/,
# not directly under /usr/lib/varnish/, so they are enumerated with find rather
# than a glob that silently matched nothing. The `test -n` refuses to build if
# that find ever comes back empty. This must run while /bin/sh is still the
# build shell, i.e. before the busybox step below. The .la libtool archives are
# dropped: they are link-time metadata, never read at runtime.
#
# The "Not found" guard matters more here qu'ailleurs : deux paquets runtime
# viennent de disparaitre (jemalloc, libstdc++), et TCC compile le VCL au
# demarrage du conteneur -- une bibliotheque manquante ne se verrait donc pas
# sur `varnishd -V` mais a la premiere requete. lddtree signale une dependance
# introuvable sur stderr et sort quand meme en 0.
#
# lddtree prints each binary it is handed, so this list holds the roots as well
# as their dependencies -- and varnishd, the six varnish* tools, tcc,
# libvarnishapi and the VMODs are all copied again, on their own COPY lines, in
# the final stage. Layers are not deduplicated, so 2,94 Mo of this image was
# going out twice. Those roots keep their individual COPY and are filtered out
# of the tar input here.
#
# /bin/busybox is deliberately NOT filtered: the final stage copies
# /bin/busybox-varnish, a different path, so this archive is its only source.
#
# The completeness check runs on the UNFILTERED list, above: a filter must
# never be able to hide a missing dependency.
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache lddtree \
 && mkdir -p /rootfs \
 && find /usr/lib/varnish -name '*.la' -delete \
 && test -n "$(find /usr/lib/varnish -name '*.so' -print -quit)" \
 && { lddtree -l \
        /usr/sbin/varnishd /usr/bin/varnishadm /usr/bin/varnishlog \
        /usr/bin/varnishstat /usr/bin/varnishncsa /usr/bin/varnishhist \
        /usr/bin/varnishtop /usr/bin/tcc /bin/busybox \
        /usr/lib/libvarnishapi.so; \
      find /usr/lib/varnish -name '*.so' -exec lddtree -l {} +; } \
      > /tmp/closure.list 2> /tmp/closure.err \
 && if grep -q 'Not found' /tmp/closure.list /tmp/closure.err; then \
      echo "closure incomplete -- a dependency is missing from this stage:" >&2; \
      grep 'Not found' /tmp/closure.list /tmp/closure.err >&2; \
      exit 1; \
    fi \
 && sort -u /tmp/closure.list -o /tmp/closure.list \
 && grep -v -E '^/usr/sbin/varnishd$|^/usr/bin/varnish(adm|log|stat|ncsa|hist|top)$|^/usr/bin/tcc$|^/usr/lib/libvarnishapi\.so|^/usr/lib/varnish/' \
      /tmp/closure.list > /tmp/closure.deps \
 && tar -cf /tmp/closure.tar -T /tmp/closure.deps \
 && tar -xf /tmp/closure.tar -C /rootfs \
 && rm -f /tmp/closure.list /tmp/closure.deps /tmp/closure.err /tmp/closure.tar

# Link-time inputs, invisible to any dependency closure: tcc reads them when it
# links the shared object it compiles from VCL, it does not dlopen them.
#   libtcc1.a  tcc's own runtime helpers
#   crti.o / crtn.o  prologue and epilogue for a -shared link
#   libc.so    symlink to the musl loader, without it tcc reports "library 'c'
#              not found"
# Everything else musl-dev installs is left behind on purpose -- notably
# libc.a (9.4 MB of static libc that a -shared link never touches), crt1.o,
# Scrt1.o, rcrt1.o and the empty stub archives. Established by removing them
# one at a time and re-running a tcc -fpic -shared compile until it broke.
RUN mkdir -p /rootfs/usr/lib \
 && cp -a /usr/lib/tcc /rootfs/usr/lib/ \
 && cp -a /usr/lib/crti.o /usr/lib/crtn.o /usr/lib/libc.so /rootfs/usr/lib/

# Busybox symlinks for varnishd system() calls (MUST be last — breaks /bin/sh).
# This is the container's *runtime* /bin/sh (what varnishd's system() calls
# use once shipped), not the build-time shell -- SHELL wouldn't apply here.
# hadolint ignore=DL4005
RUN cp /bin/busybox /bin/busybox-varnish \
    && rm -f /bin/sh /bin/rm \
    && ln -s /bin/busybox-varnish /bin/sh \
    && ln -s /bin/busybox-varnish /bin/rm

# --- Stage 4: FROM scratch — final hardened image ----------------------
FROM scratch

ARG VARNISH_VERSION
LABEL org.opencontainers.image.title="varnish-hardened" \
      org.opencontainers.image.description="Varnish Cache ${VARNISH_VERSION} hardened (Tier Platine: FROM scratch, Go init, tini PID 1)" \
      org.opencontainers.image.vendor="jbsky" \
      org.opencontainers.image.source="https://github.com/jbsky/varnish-hardened" \
      org.opencontainers.image.licenses="BSD-2-Clause" \
      security.hardening.tier="platine"

# passwd/group for non-root
COPY --link --from=prep /etc/passwd /etc/passwd
COPY --link --from=prep /etc/group /etc/group

# TLS certificates + timezone data
COPY --link --from=prep /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --link --from=prep /usr/share/zoneinfo/ /usr/share/zoneinfo/

# Runtime closure: loader, shared libraries and their symlinks, resolved at
# build time by lddtree in prep -- not /lib and /usr/lib whole
COPY --link --from=prep /rootfs/ /

# musl-dev headers (needed by TCC for VCL → C → .so)
COPY --link --from=prep /usr/include/ /usr/include/

# tini-static as PID 1
COPY --link --from=prep /sbin/tini-static /sbin/tini

# Minimal shell (required by varnishd system() calls for cleanup)
COPY --link --from=prep /bin/busybox-varnish /bin/busybox-varnish
COPY --link --from=prep /bin/sh /bin/sh
COPY --link --from=prep /bin/rm /bin/rm

# TCC compiler (already in /usr/lib/ via bulk copy, just need binaries)
COPY --link --from=prep /usr/bin/tcc /usr/bin/tcc
COPY --link --from=prep /usr/bin/cc /usr/bin/cc
COPY --link --from=prep /usr/bin/gcc /usr/bin/gcc

# Varnish binaries + shared libs + vmods
COPY --link --from=prep /usr/sbin/varnishd /usr/sbin/
COPY --link --from=prep /usr/bin/varnishadm /usr/bin/
COPY --link --from=prep /usr/bin/varnishlog /usr/bin/
COPY --link --from=prep /usr/bin/varnishstat /usr/bin/
COPY --link --from=prep /usr/bin/varnishncsa /usr/bin/
COPY --link --from=prep /usr/bin/varnishhist /usr/bin/
COPY --link --from=prep /usr/bin/varnishtop /usr/bin/
COPY --link --from=prep /usr/lib/libvarnishapi.so* /usr/lib/
COPY --link --from=prep /usr/lib/varnish/ /usr/lib/varnish/

# Go init (entrypoint + healthcheck)
COPY --link --from=prep /usr/local/bin/init /usr/local/bin/init

# Runtime directories + default VCL
COPY --link --from=prep /var/lib/varnish/ /var/lib/varnish/
COPY --link --from=prep /etc/varnish/ /etc/varnish/
COPY --link --from=prep /tmp/ /tmp/

ENV VARNISH_SIZE=256M \
    PATH="/usr/sbin:/usr/bin:/usr/local/bin:/sbin:/bin"

USER 6081:65534
WORKDIR /etc/varnish

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
    CMD ["/usr/local/bin/init", "--healthcheck"]

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/init"]
EXPOSE 8080 8443
