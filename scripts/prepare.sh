#!/usr/bin/env bash
# Set up the hardened build context for romm at the pinned upstream version.
# Result: build/src (Docker context) with build/src/Dockerfile.hardened, and
# build/build-args (KEY=VALUE lines for docker build --build-arg).
#
# The overlay builds on upstream's published image, so it depends on how that image is
# built. Upstream's docker/Dockerfile at the same tag is read for the pins the overlay
# needs (Alpine version, uv version, mod_zip commit), and for the anchors below. If any
# anchor is missing, upstream changed its image layout: the script fails, and the overlay
# must be reviewed before the build can go on.
#
# Usage: scripts/prepare.sh [upstream-version]   (default: contents of UPSTREAM_VERSION)
# Needs: git, curl, jq.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ref="${1:-$(tr -d '[:space:]' < "$root/UPSTREAM_VERSION")}"
src="$root/build/src"
upstream_repo="${UPSTREAM_REPO:-https://github.com/rommapp/romm.git}"
image_repo="${UPSTREAM_IMAGE_REPO:-rommapp/romm}"
cooloff_days="${COOLOFF_DAYS:-14}"

rm -rf "$root/build"
mkdir -p "$src/hardening"
git clone --quiet --depth 1 --branch "$ref" "$upstream_repo" "$root/build/upstream" 2>/dev/null
echo "prepare: upstream $ref @ $(git -C "$root/build/upstream" rev-parse --short HEAD)"
df="$root/build/upstream/docker/Dockerfile"

need() {  # need <description> <extended regex>: the line must occur exactly once
  local n
  n="$(grep -cE "$2" "$df" || true)"
  if [ "$n" != 1 ]; then
    echo "prepare: anchor '$1' matched $n times in upstream docker/Dockerfile (expected 1)." >&2
    echo "prepare: upstream changed its image build; review overlay/Dockerfile against it." >&2
    exit 1
  fi
}
arg() { sed -nE "s/^ARG $1=([^[:space:]]+).*/\1/p" "$df"; }

need "production stage on official nginx alpine" '^FROM nginx:\$\{NGINX_VERSION\}-alpine\$\{ALPINE_VERSION\}.* AS production-stage$'
need "mod_zip module copied in"                  '^COPY --from=nginx-build \./nginx/objs/ngx_http_zip_module\.so /usr/lib/nginx/modules/$'
need "mod_zip commit pin"                         '^ARG NGINX_MOD_ZIP_COMMIT=[0-9a-f]{40}$'
need "venv at /src/.venv"                         '^COPY --from=backend-build /src/\.venv /src/\.venv$'
need "python copied from python image"            '^COPY --from=python-runtime /usr/local/lib/python\$\{PYTHON_VERSION\} '
need "ScreenScraper dev creds baked as ENV"       '^ENV SCREENSCRAPER_DEV_ID=\$\{SCREENSCRAPER_DEV_ID\}$'
need "published target is full-image"             '^FROM slim-image AS full-image$'

alpine_version="$(arg ALPINE_VERSION)"
uv_version="$(arg UV_VERSION)"
mod_zip_commit="$(arg NGINX_MOD_ZIP_COMMIT)"
for v in alpine_version uv_version mod_zip_commit; do
  [ -n "${!v}" ] || { echo "prepare: could not read $v from upstream Dockerfile" >&2; exit 1; }
done
echo "prepare: alpine $alpine_version, uv $uv_version, mod_zip $mod_zip_commit"

# Pin upstream's published image (multi-arch index) by digest.
token="$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$image_repo:pull" | jq -r .token)"
digest="$(curl -fsSI -H "Authorization: Bearer $token" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  "https://registry-1.docker.io/v2/$image_repo/manifests/$ref" \
  | tr -d '\r' | sed -nE 's/^docker-content-digest: *(sha256:[0-9a-f]{64})$/\1/Ip')"
[ -n "$digest" ] || { echo "prepare: could not resolve docker.io/$image_repo:$ref" >&2; exit 1; }
echo "prepare: base docker.io/$image_repo:$ref@$digest"

# Python floors resolve only against releases at least $cooloff_days days old.
exclude_newer="$(date -u -d "$cooloff_days days ago" +%Y-%m-%dT%H:%M:%SZ)"

cp "$root/overlay/Dockerfile" "$src/Dockerfile.hardened"
cp "$root/overlay/python-floors.py" "$root/overlay/python-floors.txt" "$src/hardening/"

cat > "$root/build/build-args" <<EOF
UPSTREAM_IMAGE=docker.io/$image_repo:$ref@$digest
UPSTREAM_VERSION=$ref
UPSTREAM_DIGEST=$digest
UV_IMAGE=ghcr.io/astral-sh/uv:$uv_version
ALPINE_VERSION=$alpine_version
NGINX_MOD_ZIP_COMMIT=$mod_zip_commit
EXCLUDE_NEWER=$exclude_newer
EOF
echo "prepare: build context ready at $src"
