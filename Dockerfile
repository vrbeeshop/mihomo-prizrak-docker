# syntax=docker/dockerfile:1
ARG GO_IMAGE=golang:1.26-alpine
ARG ALPINE_IMAGE=alpine:3.23
ARG DEBIAN_IMAGE=debian:trixie-slim
# Build on the builder's CPU; the Go binary is cross-compiled for the target.
FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS build
RUN apk add --no-cache ca-certificates git upx

ARG GO_IMAGE
ARG PRIZRAK_VERSION=latest
ARG PRIZRAK_COMMIT=""
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
ARG WITH_GVISOR=0
ARG UPX=0
WORKDIR /src

# A remote ADD revalidates the latest release file on each build, including
# cached builds. CI supplies its single resolved tag to keep all targets equal.
ADD https://github.com/legiz-ru/Prizrak-Core/releases/latest/download/version.txt /tmp/prizrak-latest-version.txt
RUN set -eu; \
    if [ "$PRIZRAK_VERSION" = latest ]; then \
        PRIZRAK_VERSION="$(tr -d '\r\n' < /tmp/prizrak-latest-version.txt)"; \
    fi; \
    case "$PRIZRAK_VERSION" in \
        ''|*[!a-zA-Z0-9._-]*) echo 'Invalid Prizrak-Core release tag' >&2; exit 1 ;; \
    esac; \
    git clone --depth=1 --branch="$PRIZRAK_VERSION" --single-branch \
        https://github.com/legiz-ru/Prizrak-Core.git .; \
    if [ -n "$PRIZRAK_COMMIT" ]; then \
        test "$(git rev-parse HEAD)" = "$PRIZRAK_COMMIT" || { \
            echo 'Prizrak-Core release commit differs from the resolved commit' >&2; exit 1; \
        }; \
    fi; \
    printf '%s\n' "$PRIZRAK_VERSION" > /tmp/prizrak-version

ENV GOCACHE=/var/cache/go-build \
    GOMODCACHE=/go/pkg/mod \
    CGO_ENABLED=0
RUN --mount=type=cache,id=prizrak-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=prizrak-go-build,target=/var/cache/go-build \
    set -eu; \
    case "$TARGETOS/$TARGETARCH/$TARGETVARIANT" in \
        linux/amd64/*) export GOAMD64=v1 ;; \
        linux/arm64/*) ;; \
        linux/arm/v7) export GOARM=7 ;; \
        linux/arm/v5) export GOARM=5 ;; \
        *) echo "Unsupported target: $TARGETOS/$TARGETARCH/$TARGETVARIANT" >&2; exit 1 ;; \
    esac; \
    BUILD_TAGS=""; \
    case "$WITH_GVISOR" in 0) ;; 1) BUILD_TAGS="with_gvisor" ;; *) exit 1 ;; esac; \
    BUILDTIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; \
    PRIZRAK_VERSION="$(cat /tmp/prizrak-version)"; \
    GOOS="$TARGETOS" GOARCH="$TARGETARCH" go build -tags "$BUILD_TAGS" -trimpath \
        -ldflags "-w -s -buildid= -X github.com/metacubex/mihomo/constant.Version=$PRIZRAK_VERSION -X github.com/metacubex/mihomo/constant.BuildTime=$BUILDTIME" \
        -o /out/usr/bin/prizrak-core .; \
    mkdir -p /out/usr/share/prizrak-core; \
    printf 'version=%s\ncommit=%s\ngo_version=%s\nbuilder_image=%s\nwith_gvisor=%s\nplatform=%s\nbuilt_at=%s\n' \
        "$PRIZRAK_VERSION" "$(git rev-parse HEAD)" "$(go env GOVERSION)" \
        "$GO_IMAGE" "$WITH_GVISOR" "$TARGETOS/$TARGETARCH${TARGETVARIANT:+/$TARGETVARIANT}" "$BUILDTIME" \
        > /out/usr/share/prizrak-core/build-info

RUN set -eu; \
    UPX_ENABLED="$UPX"; unset UPX; \
    case "$UPX_ENABLED" in 0|1) ;; *) exit 1 ;; esac; \
    UPX_APPLIED=0; \
    if [ "$UPX_ENABLED" = 1 ] && [ "$TARGETARCH/$TARGETVARIANT" != arm/v5 ]; then \
        upx --best --lzma /out/usr/bin/prizrak-core; \
        upx -t /out/usr/bin/prizrak-core; \
        UPX_APPLIED=1; \
    fi; \
    printf 'upx=%s\n' "$UPX_APPLIED" >> /out/usr/share/prizrak-core/build-info

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS config-build
ARG TARGETOS
ARG TARGETARCH
ARG TARGETVARIANT
WORKDIR /src
COPY tools/config/ ./
ENV CGO_ENABLED=0 \
    GOCACHE=/var/cache/go-build \
    GOMODCACHE=/go/pkg/mod
RUN --mount=type=cache,id=prizrak-go-mod,target=/go/pkg/mod \
    --mount=type=cache,id=prizrak-go-build,target=/var/cache/go-build \
    set -eu; \
    go test ./...; \
    case "$TARGETOS/$TARGETARCH/$TARGETVARIANT" in \
        linux/amd64/*) export GOAMD64=v1 ;; \
        linux/arm64/*) ;; \
        linux/arm/v7) export GOARM=7 ;; \
        linux/arm/v5) export GOARM=5 ;; \
        *) echo 'Unsupported configuration-tool target' >&2; exit 1 ;; \
    esac; \
    GOOS="$TARGETOS" GOARCH="$TARGETARCH" go build -trimpath \
        -ldflags '-s -w -buildid=' -o /out/prizrak-config .

FROM ${ALPINE_IMAGE} AS linux-amd64
FROM ${ALPINE_IMAGE} AS linux-arm64
FROM ${ALPINE_IMAGE} AS linux-armv7
# Alpine does not support ARMv5; use a glibc runtime for those routers.
FROM ${DEBIAN_IMAGE} AS linux-armv5
FROM linux-${TARGETARCH}${TARGETVARIANT} AS runtime
ARG TARGETARCH
ARG TARGETVARIANT
ARG ALPINE_IMAGE
ARG DEBIAN_IMAGE
ARG APP_VERSION=0.1.2
LABEL org.opencontainers.image.title="Prizrak-Core Docker" \
      org.opencontainers.image.source="https://github.com/vrbeeshop/mihomo-prizrak-docker" \
      org.opencontainers.image.version="$APP_VERSION"

RUN set -eu; \
    if [ "$TARGETARCH/$TARGETVARIANT" = arm/v5 ]; then \
        apt-get update; \
        apt-get install -y --no-install-recommends bash ca-certificates gettext-base \
            iproute2 iptables nftables kmod tini tzdata curl util-linux; \
        update-alternatives --set iptables /usr/sbin/iptables-legacy; \
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy; \
        rm -rf /var/lib/apt/lists/*; \
    else \
        apk add --no-cache bash ca-certificates envsubst iproute2 iptables \
            iptables-legacy nftables kmod tini tzdata curl; \
        for family in iptables ip6tables; do \
            for suffix in '' -save -restore; do \
                ln -sf "$(command -v "${family}-legacy${suffix}")" \
                    "$(command -v "${family}${suffix}")"; \
            done; \
        done; \
    fi
COPY --from=build /out/ /
COPY --from=config-build /out/prizrak-config /usr/bin/prizrak-config
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
COPY --chmod=0644 runtime/subscription.sh /usr/lib/prizrak/subscription.sh
COPY mihomo-fs/ /
RUN set -eu; \
    chmod 0755 /usr/lib/prizrak; \
    ln -s prizrak-core /usr/bin/mihomo; \
    mkdir -p /etc/mihomo; \
    RUNTIME_IMAGE="$ALPINE_IMAGE"; \
    if [ "$TARGETARCH/$TARGETVARIANT" = arm/v5 ]; then RUNTIME_IMAGE="$DEBIAN_IMAGE"; fi; \
    . /etc/os-release; \
    printf 'project_version=%s\nruntime_image=%s\nruntime_os_name=%s\nruntime_os_version=%s\n' \
        "$APP_VERSION" "$RUNTIME_IMAGE" "$ID" "$VERSION_ID" \
        >> /usr/share/prizrak-core/build-info

ENV NETWORK_MODE="proxy" \
    LOG_LEVEL="info" \
    EXTERNAL_UI_URL="https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip" \
    DISABLE_NFTABLES=1 \
    CONFIG="default_config.yaml" \
    WORKDIR="/etc/mihomo" \
    HEALTH_CHECK_ENABLE="true" \
    HEALTH_CHECK_URL="https://www.gstatic.com/generate_204" \
    HEALTH_CHECK_INTERVAL=300 \
    HEALTH_CHECK_TIMEOUT=5000 \
    HEALTH_CHECK_LAZY="true" \
    HEALTH_CHECK_EXPECTED_STATUS=204 \
    TOLERANCE=10 \
    MIXED_PORT=20170 \
    UI_PORT=9090 \
    EXTERNAL_CONTROLLER_ADDRESS="0.0.0.0" \
    TUN_STACK="mips" \
    TUN_INET4_ADDRESS="198.19.0.1/30" \
    TUN_INET6_ADDRESS="fdfe:dcba:9876::1/126" \
    TUN_AUTO_REDIRECT="false" \
    TUN_AUTO_DETECT_INTERFACE="true" \
    TUN_AUTO_ROUTE="true" \
    TUN_DISABLE_ICMP_FORWARDING="true" \
    EXTERNAL_UI_PATH="ui" \
    IPV6="true" \
    IP_VERSION="dual" \
    PROVIDER_INTERVAL=3600 \
    SUBSCRIPTION_TIMEOUT=30 \
    DNS_ENABLE="true" \
    DNS_USE_SYSTEM_HOSTS="true" \
    DNS_CACHE_ALGORITHM="arc" \
    DNS_PREFER_H3="false" \
    DNS_LISTEN="0.0.0.0:1053" \
    DNS_ENHANCED_MODE="fake-ip" \
    DNS_FAKE_IP_RANGE="198.18.0.0/15" \
    DNS_FAKE_IP_TTL=1 \
    DNS_BOOTSTRAP="system" \
    DNS="system" \
    DNS_DEFAULT_NAMESERVER="\$DNS_BOOTSTRAP" \
    DNS_NAMESERVER="\$DNS" \
    DNS_PROXY_SERVER_NAMESERVER="\$DNS" \
    DNS_RESPECT_RULES="true" \
    DNS_FAKE_IP_FILTER_MODE="blacklist" \
    TCP_CONCURRENT="true" \
    KEEP_ALIVE_IDLE=60 \
    KEEP_ALIVE_INTERVAL=30 \
    FIND_PROCESS_MODE="off" \
    STORE_SELECTED="true" \
    STORE_FAKE_IP="true" \
    UNIFIED_DELAY="true" \
    LOADBALANCE_STRATEGY="consistent-hashing"


EXPOSE 20170/tcp 20170/udp 9090/tcp 1053/tcp 1053/udp
ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
