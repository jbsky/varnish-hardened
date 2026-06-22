# =====================================================================
#  Varnish Hardened — Tier Platine (FROM scratch)
#  4-stage: builder → gobuilder → prep → scratch
# =====================================================================
ARG VARNISH_VERSION=7.7.3
ARG ALPINE_VERSION=3.21

# --- Stage 1: Build Varnish + TCC from source --------------------------
FROM alpine:${ALPINE_VERSION} AS builder

ARG VARNISH_VERSION
ENV CFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIE -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
    CXXFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIE -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
    LDFLAGS="-Wl,-z,relro,-z,now,-z,noexecstack -pie"

# Build dependencies
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache \
        build-base autoconf automake libtool pkgconfig \
        python3 py3-docutils py3-sphinx \
        pcre2-dev libedit-dev ncurses-dev jemalloc-dev linux-headers \
        libunwind-dev

# Build TCC from source (mob branch — only the compiler binary, not libtcc1)
# libtcc1.a/bcheck incompatible with musl 1.2+ — not needed for VCL .so compilation
RUN unset CFLAGS CXXFLAGS LDFLAGS \
    && apk add --no-cache git \
    && git clone --depth=1 https://repo.or.cz/tinycc.git /tcc-src \
    && cd /tcc-src \
    && ./configure --prefix=/usr \
    && make tcc \
    && mkdir -p /tcc-out/usr/bin \
    && cp tcc /tcc-out/usr/bin/tcc \
    && strip /tcc-out/usr/bin/tcc

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
FROM golang:1.24-alpine AS gobuilder

WORKDIR /src
COPY go.mod init.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags='-s -w' -trimpath -o /init .

# --- Stage 3: Prep — assemble runtime filesystem -----------------------
FROM alpine:${ALPINE_VERSION} AS prep

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
COPY --from=builder /out/usr/include/varnish/ /usr/include/varnish/

# TCC binary as cc/gcc (Varnish VCC_CC defaults to "exec gcc")
COPY --from=builder /tcc-out/usr/bin/tcc /usr/bin/tcc
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

# Dynamic linker + runtime libraries
COPY --link --from=prep /lib/ld-musl-x86_64.so.1 /lib/
COPY --link --from=prep /lib/libc.musl-x86_64.so.1 /lib/
COPY --link --from=prep /usr/lib/libpcre2-8.so* /usr/lib/
COPY --link --from=prep /usr/lib/libedit.so* /usr/lib/
COPY --link --from=prep /usr/lib/libncursesw.so* /usr/lib/
COPY --link --from=prep /usr/lib/libjemalloc.so* /usr/lib/
COPY --link --from=prep /usr/lib/libunwind*.so* /usr/lib/
COPY --link --from=prep /usr/lib/liblzma.so* /usr/lib/
COPY --link --from=prep /usr/lib/libstdc++.so* /usr/lib/
COPY --link --from=prep /usr/lib/libgcc_s.so* /usr/lib/
COPY --link --from=prep /lib/libz.so* /lib/

# musl-dev headers (needed by TCC for VCL → C → .so compilation)
COPY --link --from=prep /usr/include/ /usr/include/

# tini-static as PID 1
COPY --link --from=prep /sbin/tini-static /sbin/tini

# Minimal shell (required by varnishd system() calls for cleanup)
COPY --link --from=prep /bin/busybox-varnish /bin/busybox-varnish
COPY --link --from=prep /bin/sh /bin/sh
COPY --link --from=prep /bin/rm /bin/rm

# TCC compiler (VCL → C → .so at runtime)
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
