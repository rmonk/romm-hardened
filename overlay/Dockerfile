# syntax=docker/dockerfile:1
# Hardened romm: upstream's published image with security updates layered on top.
#
# Upstream's image is used as the base (pinned by digest in build/build-args) rather than
# rebuilt from source, because upstream injects its ScreenScraper developer credentials
# at build time from CI secrets; romm disables ScreenScraper without them. Everything
# else upstream built (frontend, emulators, RAHasher, sigil, the venv) is kept as is.
#
# Changes:
#   * Alpine packages: `apk upgrade` (libpq, nodejs, valkey, libexpat, curl, ...)
#   * nginx and its nginx.org modules (njs, acme, ...): upgraded together from the
#     nginx.org repo, then mod_zip is rebuilt for exactly that nginx version (nginx
#     refuses dynamic modules built for another version)
#   * Python venv: packages in hardening/python-floors.txt raised to a minimum version,
#     everything else held at upstream's versions; binary wheels only
#   * system pip removed (the app runs from the uv venv, which has no pip); this also
#     drops pip's vendored msgpack/setuptools/urllib3
# Entrypoint, CMD, ENV, VOLUME, user and layout are inherited unchanged.

ARG UPSTREAM_IMAGE
ARG UV_IMAGE

FROM ${UV_IMAGE} AS uv

FROM scratch AS hardening
COPY hardening/ /

# --- upgraded base -------------------------------------------------------------------
FROM ${UPSTREAM_IMAGE} AS patched
ARG ALPINE_VERSION
ARG EXCLUDE_NEWER
RUN set -eux; \
    grep -q "^${ALPINE_VERSION}\." /etc/alpine-release \
      || { echo "base is Alpine $(cat /etc/alpine-release), expected ${ALPINE_VERSION}"; exit 1; }; \
    test -f /etc/apk/keys/nginx_signing.rsa.pub; \
    echo "@nginx https://nginx.org/packages/alpine/v${ALPINE_VERSION}/main" >> /etc/apk/repositories; \
    nginx_pkgs="$(apk info | grep -E '^nginx(-module-.+)?$' | sed 's/$/@nginx/')"; \
    test -n "$nginx_pkgs"; \
    apk add --no-cache --upgrade $nginx_pkgs; \
    apk upgrade --no-cache; \
    apk version -l '<' | tee /tmp/apk-outdated; \
    [ "$(wc -l < /tmp/apk-outdated)" -le 1 ]; \
    rm /tmp/apk-outdated; \
    pyver="$(/src/.venv/bin/python -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')"; \
    rm -rf /usr/local/lib/python${pyver}/site-packages/pip /usr/local/lib/python${pyver}/site-packages/pip-*.dist-info \
           /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/bin/pip${pyver}; \
    nginx -v

RUN --mount=type=bind,from=uv,source=/uv,target=/usr/local/bin/uv \
    --mount=type=bind,from=hardening,target=/hardening \
    set -eux; \
    mkdir -p /tmp/floors; \
    /src/.venv/bin/python -I /hardening/python-floors.py /hardening/python-floors.txt /tmp/floors; \
    if [ -s /tmp/floors/requirements.txt ]; then \
      UV_NO_CACHE=1 uv pip install --python /src/.venv/bin/python --only-binary :all: \
        --exclude-newer "$EXCLUDE_NEWER" \
        -r /tmp/floors/requirements.txt -c /tmp/floors/constraints.txt; \
    fi; \
    uv pip check --python /src/.venv/bin/python; \
    rm -rf /tmp/floors

# --- mod_zip for the upgraded nginx --------------------------------------------------
FROM patched AS modzip-build
ARG NGINX_MOD_ZIP_COMMIT
RUN set -eux; \
    apk add --no-cache gcc git libc-dev make pcre-dev zlib-dev; \
    v="$(nginx -v 2>&1 | sed -E 's#^nginx version: nginx/##')"; \
    cd /tmp; \
    git clone https://github.com/evanmiller/mod_zip.git; \
    git -C mod_zip checkout "$NGINX_MOD_ZIP_COMMIT"; \
    git clone --branch "release-$v" --depth 1 https://github.com/nginx/nginx.git; \
    cd nginx; \
    ./auto/configure --with-compat --add-dynamic-module=../mod_zip/; \
    make -f ./objs/Makefile modules; \
    install -D -m 644 ./objs/ngx_http_zip_module.so /out/ngx_http_zip_module.so

# --- final ---------------------------------------------------------------------------
FROM patched
COPY --from=modzip-build /out/ngx_http_zip_module.so /usr/lib/nginx/modules/ngx_http_zip_module.so

ARG HARDENED_VERSION=unknown
ARG HARDENED_SOURCE=unknown
ARG UPSTREAM_VERSION=unknown
ARG UPSTREAM_DIGEST=unknown
LABEL org.opencontainers.image.version=$HARDENED_VERSION \
      org.romm-hardened.source=$HARDENED_SOURCE \
      org.romm-hardened.upstream-version=$UPSTREAM_VERSION \
      org.romm-hardened.upstream-digest=$UPSTREAM_DIGEST
