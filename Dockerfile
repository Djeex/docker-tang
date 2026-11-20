FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS builder

# Alpine ships no tang package, so tang and jose are built from their release
# tags (same code as padhihomelab/tang: tangd 15 + jose 15).
# renovate: datasource=github-tags depName=latchset/jose
ARG JOSE_VERSION=v15
# renovate: datasource=github-tags depName=latchset/tang
ARG TANG_VERSION=v16

RUN apk add --no-cache \
        build-base \
        git \
        http-parser-dev \
        jansson-dev \
        meson \
        openssl-dev \
        pkgconf \
        zlib-dev

RUN git clone --depth 1 --branch "$JOSE_VERSION" https://github.com/latchset/jose.git /src/jose \
    && meson setup /src/jose/build /src/jose --prefix=/usr/local --buildtype=release \
    && meson install -C /src/jose/build

RUN git clone --depth 1 --branch "$TANG_VERSION" https://github.com/latchset/tang.git /src/tang \
    && meson setup /src/tang/build /src/tang --prefix=/usr/local --buildtype=release \
    && meson install -C /src/tang/build


FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS base

# apk upgrade pulls Alpine security fixes released after the base image was
# cut; the weekly scheduled CI rebuild relies on it.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
        http-parser \
        jansson \
        libcrypto3 \
        socat \
        su-exec \
        tini \
        zlib \
    && rm -rf /var/cache/apk/* /tmp/*

# Same paths as padhihomelab/tang, so overridden commands and mounted
# entrypoint scripts keep working.
COPY --from=builder /usr/local/bin/jose /usr/local/bin/jose
COPY --from=builder /usr/local/lib/libjose.so.0.0.0 /usr/local/lib/libjose.so.0.0.0
COPY --from=builder /usr/local/libexec/tangd /usr/local/bin/tangd
COPY --from=builder /usr/local/libexec/tangd-keygen /usr/local/bin/tangd-keygen
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint
COPY start-servers.sh /usr/local/bin/start-servers
COPY check-servers.sh /usr/local/bin/check-servers
COPY entrypoint-scripts/ /etc/docker-entrypoint.d/99-extra-scripts/
COPY VERSION /VERSION

RUN ln -s libjose.so.0.0.0 /usr/local/lib/libjose.so.0 \
    && chmod +x /usr/local/bin/docker-entrypoint \
        /usr/local/bin/start-servers \
        /usr/local/bin/check-servers \
        /etc/docker-entrypoint.d/99-extra-scripts/*.sh \
    && mkdir -p /db

ENV ENABLE_IPv4=1
ENV ENABLE_IPv6=0


FROM base AS test

RUN apk add --no-cache bash bats curl jq procps

WORKDIR /app
COPY VERSION /app/
COPY tests/ /app/tests/


FROM base AS lint

RUN apk add --no-cache shellcheck
COPY tests/compat.sh /app/tests/compat.sh
RUN shellcheck --severity=error -s sh \
        /usr/local/bin/docker-entrypoint \
        /usr/local/bin/start-servers \
        /usr/local/bin/check-servers \
        /etc/docker-entrypoint.d/99-extra-scripts/*.sh \
    && shellcheck --severity=warning -s bash /app/tests/compat.sh


# Reference image and clevis client used by the compatibility test only
# (tests/compat.sh); declared here so Renovate keeps their digests current.
FROM padhihomelab/tang:latest@sha256:3a9a5b1d07c70e97d6a3b56919acedf2abcd6b5e9ded132531123c719e0b267e AS padhi-reference


FROM debian:13-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS clevis

RUN apt-get update \
    && apt-get install -y --no-install-recommends clevis curl \
    && rm -rf /var/lib/apt/lists/*


# Kept as the last stage so `docker build .` (no --target) still produces
# the lean prod image, not the test/lint/reference stages above.
FROM base

EXPOSE 8080
VOLUME [ "/db" ]

ENTRYPOINT [ "tini", "/usr/local/bin/docker-entrypoint" ]
CMD [ "start-servers" ]

HEALTHCHECK --start-period=5s --timeout=3s \
    CMD [ "check-servers" ]
