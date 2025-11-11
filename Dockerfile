# syntax=docker/dockerfile:1
# check=skip=SecretsUsedInArgOrEnv

# -- File has been modified by YEXT  -- #

# We start from my nginx fork which includes the proxy-connect module from tEngine
# Source is available at https://github.com/rpardini/nginx-proxy-connect-stable-alpine
# This is already multi-arch!
ARG BASE_IMAGE="docker.io/rpardini/nginx-proxy-connect-stable-alpine:nginx-1.26.3-alpine-3.21.3"
# Could be "-debug"
ARG BASE_IMAGE_SUFFIX=""
FROM ${BASE_IMAGE}${BASE_IMAGE_SUFFIX} as mitmproxy-builder

# apk packages that will be present in the final image both debug and release
RUN apk add --no-cache --update bash ca-certificates-bundle coreutils openssl

# If set to 1, enables building mitmproxy, which helps a lot in debugging, but is super heavy to build.
ARG DEBUG_BUILD="1"
ENV DO_DEBUG_BUILD="$DEBUG_BUILD"
# Required for mitmproxy
ENV LANG=en_US.UTF-8

# Build mitmproxy via pip. This is heavy, takes minutes do build and creates a 90mb+ layer. Oh well.
RUN [[ "a$DO_DEBUG_BUILD" == "a1" ]] && { echo "Debug build ENABLED." \
 && apk add --no-cache --update su-exec git g++ libffi libffi-dev libstdc++ openssl-dev python3 python3-dev py3-pip py3-wheel py3-six py3-idna py3-certifi py3-setuptools \
 && LDFLAGS=-L/lib pip install MarkupSafe==2.0.1 mitmproxy==5.2 \
 && apk del --purge git g++ libffi-dev openssl-dev python3-dev py3-pip py3-wheel \
 && rm -rf ~/.cache/pip \
 ; } || { \
    echo "Debug build disabled, creating empty directory."; \
    mkdir -p /opt/mitmproxy; \
}

# Final stage
FROM ${BASE_IMAGE}${BASE_IMAGE_SUFFIX}

# If set to 1, enables building mitmproxy, which helps a lot in debugging, but is super heavy to build.
ARG DEBUG_BUILD="1"
ENV DO_DEBUG_BUILD="$DEBUG_BUILD"
# Required for mitmproxy
ENV LANG=en_US.UTF-8

# Install runtime dependencies only
RUN apk add --no-cache bash ca-certificates-bundle coreutils openssl && \
    [[ "a$DO_DEBUG_BUILD" == "a1" ]] && { \
        apk add --no-cache su-exec libffi libstdc++ python3 py3-six py3-idna py3-certifi py3-setuptools; \
    } || true

# Copy mitmproxy from builder (only if built)
COPY --from=mitmproxy-builder /opt/mitmproxy /usr/local/

# Check the installed mitmproxy version, if built.
RUN [[ "a$DO_DEBUG_BUILD" == "a1" ]] && { mitmproxy --version && mitmweb --version ; } || { echo "Debug build disabled."; }

# Utilize existing nginx user from base image
ARG USER=nginx
ARG GROUP=nginx

# Customizable cache directory and certs directory via env vars
ARG CACHE_DIR
ENV CACHE_DIR=${CACHE_DIR:-/docker_mirror_cache}

ARG CERTS_DIR
ENV CERTS_DIR=${CERTS_DIR:-/certs}

# Create non-root user and group
# Create the cache directory and CA directory
# Assign ownership to the nginx user and group
RUN mkdir -p ${CACHE_DIR} /ca ${CERTS_DIR} /var/log/nginx /var/cache/nginx /var/run \
    /home/${USER}/.mitmproxy-incoming /home/${USER}/.mitmproxy-outgoing-hub  && \
    chown -R ${USER}:${GROUP} ${CACHE_DIR} /ca ${CERTS_DIR} /var/log/nginx /var/cache/nginx \
    /var/run /etc/nginx /home/${USER} && \
    chmod 1777 /tmp

# Expose it as a volume, so cache can be kept external to the Docker image
VOLUME ${CACHE_DIR}

# Expose /ca as a volume. Users are supposed to volume mount this, as to preserve it across restarts.
# Actually, its required; if not, then docker clients will reject the CA certificate when the proxy is run the second time
VOLUME /ca

# Add our configuration
COPY --chown=${USER}:${GROUP} nginx.conf /etc/nginx/nginx.conf
COPY --chown=${USER}:${GROUP} nginx.manifest.common.conf /etc/nginx/nginx.manifest.common.conf
COPY --chown=${USER}:${GROUP} nginx.manifest.stale.conf /etc/nginx/nginx.manifest.stale.conf

# Add our very hackish entrypoint and ca-building scripts, make them executable
COPY --chown=${USER}:${GROUP} entrypoint.sh /entrypoint.sh
COPY --chown=${USER}:${GROUP} create_ca_cert.sh /create_ca_cert.sh
RUN chmod +x /create_ca_cert.sh /entrypoint.sh

USER ${USER}

# Clients should only use 3128, not anything else.
EXPOSE 3128

# In debug mode, 8081 exposes the mitmweb interface (for incoming requests from Docker clients)
EXPOSE 8081
# In debug-hub mode, 8082 exposes the mitmweb interface (for outgoing requests to DockerHub)
EXPOSE 8082

## Default envs.
# A space delimited list of registries we should proxy and cache; this is in addition to the central DockerHub.
ENV REGISTRIES="registry.k8s.io gcr.io quay.io ghcr.io" \
# A space delimited list of registry:user:password to inject authentication for
    AUTH_REGISTRIES="some.authenticated.registry:oneuser:onepassword another.registry:user:password" \
# Should we verify upstream's certificates? Default to true.
    VERIFY_SSL="true" \
# Enable debugging mode; this inserts mitmproxy/mitmweb between the CONNECT proxy and the caching layer
    DEBUG="false" \
# Enable debugging mode; this inserts mitmproxy/mitmweb between the caching layer and DockerHub's registry
    DEBUG_HUB="false" \
# Enable nginx debugging mode; this uses nginx-debug binary and enabled debug logging, which is VERY verbose so separate setting
    DEBUG_NGINX="false" \
# Manifest caching tiers. Disabled by default, to mimick 0.4/0.5 behaviour.
# Setting it to true enables the processing of the ENVs below.
# Once enabled, it is valid for all registries, not only DockerHub.
# The envs *_REGEX represent a regex fragment, check entrypoint.sh to understand how they're used (nginx ~ location, PCRE syntax).
    ENABLE_MANIFEST_CACHE="false" \
# 'Primary' tier defaults to 10m cache for frequently used/abused tags.
# - People publishing to production via :latest (argh) will want to include that in the regex
# - Heavy pullers who are being ratelimited but don't mind getting outdated manifests should (also) increase the cache time here
    MANIFEST_CACHE_PRIMARY_REGEX="(stable|nightly|production|test)" \
    MANIFEST_CACHE_PRIMARY_TIME="10m" \
# 'Secondary' tier defaults any tag that has 3 digits or dots, in the hopes of matching most explicitly-versioned tags.
# It caches for 60d, which is also the cache time for the large binary blobs to which the manifests refer.
# That makes them effectively immutable. Make sure you're not affected; tighten this regex or widen the primary tier.
    MANIFEST_CACHE_SECONDARY_REGEX="(.*)(\d|\.)+(.*)(\d|\.)+(.*)(\d|\.)+" \
    MANIFEST_CACHE_SECONDARY_TIME="60d" \
# The default cache duration for manifests that don't match either the primary or secondary tiers above.
# In the default config, :latest and other frequently-used tags will get this value.
    MANIFEST_CACHE_DEFAULT_TIME="1h" \
# Should we allow actions different than pull, default to false.
    ALLOW_PUSH="false" \
# If push is allowed, buffering requests can cause issues on slow upstreams.
# If you have trouble pushing, set this to false first, then fix remainig timouts.
# Default is true to not change default behavior.
    PROXY_REQUEST_BUFFERING="true" \
# Allow disabling IPV6 resolution, default to false
    DISABLE_IPV6="false"

# Timeouts
# ngx_http_core_module
ENV SEND_TIMEOUT="60s" \
    CLIENT_BODY_TIMEOUT="60s" \
    CLIENT_HEADER_TIMEOUT="60s" \
    KEEPALIVE_TIMEOUT="300s" \
# ngx_http_proxy_module
    PROXY_READ_TIMEOUT="60s" \
    PROXY_CONNECT_TIMEOUT="60s" \
    PROXY_SEND_TIMEOUT="60s" \
# ngx_http_proxy_connect_module - external module
    PROXY_CONNECT_READ_TIMEOUT="60s" \
    PROXY_CONNECT_CONNECT_TIMEOUT="60s" \
    PROXY_CONNECT_SEND_TIMEOUT="60s"

LABEL version="0.6.9" \
# Link image to original repository on GitHub
    org.opencontainers.image.source=https://github.com/yext/docker-registry-proxy

# Did you want a shell? Sorry, the entrypoint never returns, because it runs nginx itself. Use 'docker exec' if you need to mess around internally.
ENTRYPOINT ["/entrypoint.sh"]
