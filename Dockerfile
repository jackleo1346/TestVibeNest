# syntax=docker/dockerfile:1
ARG GO_VERSION=1.24
ARG ALPINE_VERSION=3.21
ARG XRAY_VERSION=v26.9.9

# Stage 1 — Go Static Builder
FROM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS builder
WORKDIR /src
COPY main.go ./
COPY go.mod* ./
RUN set -eux; \
    test -f go.mod || go mod init bermuda-gateway; \
    CGO_ENABLED=0 GOOS=linux go build \
        -trimpath \
        -ldflags="-s -w -buildid=" \
        -o /out/bermuda-gateway main.go; \
    test -s /out/bermuda-gateway

# Stage 2 — Fetch Official Xray-core
FROM alpine:${ALPINE_VERSION} AS xray-downloader
ARG XRAY_VERSION
ARG TARGETARCH=amd64
RUN set -eux; \
    apk add --no-cache ca-certificates curl unzip; \
    case "${TARGETARCH}" in \
        amd64) XRAY_ARCH="64" ;; \
        arm64) XRAY_ARCH="arm64-v8a" ;; \
        *) echo "Unsupported target architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    XRAY_ZIP="Xray-linux-${XRAY_ARCH}.zip"; \
    XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${XRAY_ZIP}"; \
    echo "Downloading Xray-core ${XRAY_VERSION}..."; \
    curl -fsSL --retry 5 --retry-delay 2 -o /tmp/xray.zip "${XRAY_URL}"; \
    mkdir -p /out/bin /out/assets; \
    unzip -q /tmp/xray.zip xray -d /out/bin; \
    unzip -q /tmp/xray.zip geoip.dat geosite.dat -d /out/assets; \
    chmod 0755 /out/bin/xray

# Stage 3 — Hardened Runtime for VibeNest
FROM alpine:${ALPINE_VERSION}
RUN set -eux; \
    apk add --no-cache ca-certificates tzdata wget; \
    update-ca-certificates; \
    addgroup -g 10001 -S bermuda; \
    adduser -u 10001 -S -D -H -G bermuda -h /app -s /sbin/nologin bermuda; \
    mkdir -p /app /usr/local/share/xray /usr/local/bin; \
    chown -R bermuda:bermuda /app /usr/local/share/xray

COPY --from=builder --chown=bermuda:bermuda /out/bermuda-gateway /app/bermuda-gateway
COPY --from=xray-downloader --chown=bermuda:bermuda /out/bin/xray /usr/local/bin/xray
COPY --from=xray-downloader --chown=bermuda:bermuda /out/assets/geoip.dat /usr/local/share/xray/geoip.dat
COPY --from=xray-downloader --chown=bermuda:bermuda /out/assets/geosite.dat /usr/local/share/xray/geosite.dat
COPY --chown=bermuda:bermuda config.json /app/config.json

RUN set -eux; \
    chmod 0555 /app/bermuda-gateway /usr/local/bin/xray; \
    chmod 0444 /app/config.json /usr/local/share/xray/geoip.dat /usr/local/share/xray/geosite.dat

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray \
    BERMUDA_XRAY_BIN=/usr/local/bin/xray \
    BERMUDA_XRAY_CONFIG=/app/config.json \
    BERMUDA_BACKEND_XH=127.0.0.1:18443 \
    BERMUDA_BACKEND_WS=127.0.0.1:18444 \
    BERMUDA_PATH_XH=/bermuda-xhttp \
    BERMUDA_PATH_WS=/bermuda-ws \
    GOMEMLIMIT=160MiB \
    GOMAXPROCS=1 \
    GOGC=35 \
    GODEBUG=madvdontneed=1 \
    TZ=UTC

HEALTHCHECK --interval=20s --timeout=3s --start-period=15s --retries=3 \
    CMD wget -q --spider http://127.0.0.1:8080/healthz || exit 1

USER bermuda:bermuda
WORKDIR /app
EXPOSE 8080
CMD ["/app/bermuda-gateway"]
