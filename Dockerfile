# =====================================================================
#  Varnish Hardened — Tier Platine (FROM scratch)
#  4-stage: builder → gobuilder → prep → scratch
# =====================================================================
ARG VARNISH_VERSION=7.7.3
# ALPINE_VERSION kept for check-versions.sh/versions.json reference only --
# the FROM lines below pin tag+digest together as a literal so a version
# bump requires deliberately re-resolving the digest, not a silent drift
# if this ARG changes without the pin being updated to match.
ARG ALPINE_VERSION=3.21

# --- Stage 1: Build Varnish + TCC from source --------------------------
FROM alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d AS builder

ARG VARNISH_VERSION
ENV CFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIE -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
    CXXFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIE -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
    LDFLAGS="-Wl,-z,relro,-z,now,-z,noexecstack -pie"

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
        pcre2-dev libedit-dev ncurses-dev jemalloc-dev linux-headers \
        libunwind-dev

# Build TCC from source (mob branch — compiler + empty libtcc1.a stub)
# VCL shared libs don't need libtcc1 symbols, but TCC requires the file to exist
RUN unset CFLAGS CXXFLAGS LDFLAGS \
    && apk add --no-cache git \
    && git clone --depth=1 https://repo.or.cz/tinycc.git /tcc-src \
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
    && wget -q "https://varnish-cache.org/_downloads/varnish-${VARNISH_VERSION}.tgz" \
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
FROM golang:1.24-alpine@sha256:8bee1901f1e530bfb4a7850aa7a479d17ae3a18beb6e09064ed54cfd245b7191 AS gobuilder

WORKDIR /src
COPY go.mod init.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags='-s -w' -trimpath -o /init .

# --- Stage 3: Prep — assemble runtime filesystem -----------------------
FROM alpine:3.21@sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d AS prep

# Proxy-aware: HTTP repos
RUN sed -i 's|https://|http://|g' /etc/apk/repositories

# Runtime libraries only (no compilers, no package manager in final)
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache \
        pcre2 libedit ncurses-libs jemalloc libunwind \
        libstdc++ libgcc \
        musl-dev \
        tini-static ca-certificates tzdata

# Create non-root user
RUN adduser -D -u 6081 -H -s /sbin/nologin -G nogroup varnish

# Copy Varnish compiled artifacts
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

# Busybox symlinks for varnishd system() calls (MUST be last — breaks /bin/sh)
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

# Dynamic linker + all runtime libraries
COPY --link --from=prep /lib/ /lib/
COPY --link --from=prep /usr/lib/ /usr/lib/

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
