# =====================================================================
#  Varnish Hardened — Tier Or (Alpine + TCC)
#  Multi-stage build: builder → gobuilder → runtime
# =====================================================================
ARG VARNISH_VERSION=7.7.3
ARG ALPINE_VERSION=3.21

# --- Stage 1: Build Varnish from source --------------------------------
FROM alpine:${ALPINE_VERSION} AS builder

ARG VARNISH_VERSION
ENV CFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIE -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
    CXXFLAGS="-O2 -fstack-protector-strong -fstack-clash-protection -fPIE -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security" \
    LDFLAGS="-Wl,-z,relro,-z,now,-z,noexecstack -pie"

RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache \
        build-base autoconf automake libtool pkgconfig python3 \
        pcre2-dev libedit-dev ncurses-dev jemalloc-dev linux-headers

RUN --mount=type=secret,id=ca-certs,required=false \
    if [ -f /run/secrets/ca-certs ]; then cat /run/secrets/ca-certs >> /etc/ssl/certs/ca-certificates.crt; fi \
    && wget -q "https://varnish-cache.org/_downloads/varnish-${VARNISH_VERSION}.tgz" \
    && tar xzf "varnish-${VARNISH_VERSION}.tgz"

WORKDIR /varnish-${VARNISH_VERSION}

RUN ./configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --localstatedir=/var/lib \
        --with-jemalloc \
        --disable-dependency-tracking \
    && make -j"$(nproc)" \
    && make install DESTDIR=/out

# Strip all binaries
RUN find /out -type f -executable -exec sh -c \
        'file "$1" | grep -q ELF && strip --strip-unneeded "$1"' _ {} \;

# Keep headers for VCL compilation at runtime
RUN mkdir -p /out/usr/include/varnish \
    && cp -a /out/usr/include/varnish/* /out/usr/include/varnish/ 2>/dev/null || true \
    && cp -a include/*.h /out/usr/include/varnish/ 2>/dev/null || true

# --- Stage 2: Go init binary -------------------------------------------
FROM golang:1.24-alpine AS gobuilder

WORKDIR /src
COPY go.mod init.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags='-s -w' -trimpath -o /init .

# --- Stage 3: Runtime (Alpine minimal + TCC) ----------------------------
FROM alpine:${ALPINE_VERSION}

ARG VARNISH_VERSION
LABEL org.opencontainers.image.title="varnish-hardened" \
      org.opencontainers.image.description="Varnish Cache ${VARNISH_VERSION} hardened (Tier Or: Alpine+TCC, Go init, tini PID 1)" \
      org.opencontainers.image.vendor="jbsky" \
      org.opencontainers.image.source="https://github.com/jbsky/varnish-hardened" \
      org.opencontainers.image.licenses="BSD-2-Clause" \
      security.hardening.tier="or"

# Runtime dependencies + TCC as VCL compiler
RUN --mount=type=cache,target=/var/cache/apk \
    apk add --no-cache \
        tcc musl-dev \
        pcre2 libedit ncurses-libs jemalloc \
        tini-static ca-certificates tzdata \
    && adduser -D -u 6081 -H -s /sbin/nologin -G nogroup varnish \
    && ln -sf /usr/bin/tcc /usr/bin/cc \
    && mkdir -p /var/lib/varnish /etc/varnish /var/log/varnish \
    && chown -R 6081:65534 /var/lib/varnish /var/log/varnish

# Varnish binaries + libraries + vmods
COPY --from=builder /out/usr/sbin/varnishd /usr/sbin/
COPY --from=builder /out/usr/bin/ /usr/bin/
COPY --from=builder /out/usr/lib/ /usr/lib/
COPY --from=builder /out/usr/include/varnish/ /usr/include/varnish/

# Go init (entrypoint + healthcheck)
COPY --from=gobuilder /init /usr/local/bin/init

# Default VCL (minimal, overridden by ConfigMap in k8s)
RUN echo 'vcl 4.1;\nbackend default none;' > /etc/varnish/default.vcl

ENV VARNISH_SIZE=256M

USER 6081:65534
WORKDIR /etc/varnish

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
    CMD ["/usr/local/bin/init", "--healthcheck"]

ENTRYPOINT ["/sbin/tini-static", "--", "/usr/local/bin/init"]
EXPOSE 8080 8443
