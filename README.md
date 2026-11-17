# romm-hardened

Takes upstream [romm](https://github.com/rommapp/romm)'s published image for a release, applies current security
updates on top, gates each build on a Trivy scan and a smoke test, and publishes the result to `ghcr.io/rmonk/romm`.

No fork and no rebuild from source. Each build starts from `docker.io/rommapp/romm:<UPSTREAM_VERSION>`, pinned by
digest. Upstream injects its ScreenScraper developer credentials into the image from CI secrets at build time, and
romm turns ScreenScraper off without them (`ss_handler.has_dev_credentials`), so a build from source would lose
ScreenScraper metadata. Building on the published image keeps those credentials, and everything else upstream built
(frontend, emulators, RAHasher, sigil, the venv), unchanged.

At 5.4.1 (tested 2026-11-17): Trivy findings dropped from 169 (1 critical, 76 high, 40 medium, 51 low, 1 unknown)
to 2 (medium, `opentelemetry-api`, see below). The image grew from 849 MB to 937 MB, because the changes are
layers on top of upstream's.

## What gets changed

| Area | Upstream image | Hardened |
|---|---|---|
| Alpine packages | frozen at the release build (`apk upgrade` on that day) | `apk upgrade`, rebuilt weekly; the build fails if anything is still outdated |
| nginx + nginx.org modules (njs, acme, geoip, image-filter, xslt) | nginx.org packages from the base image | upgraded together from the nginx.org repo (`@nginx` tag) |
| `mod_zip` nginx module | built for the base image's nginx | rebuilt at upstream's pinned commit for the upgraded nginx (nginx refuses modules built for another version) |
| Python venv | upstream's `uv.lock` | packages in `overlay/python-floors.txt` raised to a minimum, with a cap; every other package frozen at upstream's version; binary wheels only, at least 14 days old |
| System `pip` | pip 26.2.2 (vendors msgpack, setuptools, urllib3) | removed: the app runs from the uv venv, which has no pip |

The entrypoint, CMD, ENV, volumes, ports and layout come from the base image unchanged.

`scripts/prepare.sh` reads upstream's `docker/Dockerfile` at the same tag for the pins the overlay needs (Alpine
version, uv version, mod_zip commit) and checks anchors that the overlay relies on: production stage on the official
nginx Alpine image, mod_zip copied in, venv at `/src/.venv`, ScreenScraper credentials baked as `ENV`, `full-image`
as the published target. If an anchor is missing, the build fails rather than shipping something that only looks
hardened.

## Python floors

`overlay/python-floors.txt` lines are `<name> <minimum> <cap>`. `overlay/python-floors.py` runs inside the build
with the venv's interpreter. Like grimmory-hardened's Gradle floors, a floor only ever raises a version. Once upstream
ships the floor or newer, the build log reports `no-op (remove this floor)`; delete the line then.

| Package | Floor | Why |
|---|---|---|
| `authlib` | 1.9.1 (< 1.10) | CVE-2026-96760 (critical, JWS signature bypass) + 3 HIGH; OIDC login. Upstream master moved to `~=1.9.1` |
| `dnspython` | 2.9.2 (< 3) | 2 HIGH; used by `email-validator` |
| `oauthlib` | 4.0.1 (< 5) | 2 HIGH; used by `requests-oauthlib` (apprise notifiers), which accepts `oauthlib>=3` |
| `joserfc` | 1.7.6 (< 1.8) | CVE-2026-119284 (medium); inside romm's own `~= 1.7.5` pin |

Floors resolve only against releases at least 14 days old (`uv --exclude-newer`; `COOLOFF_DAYS` in
`scripts/prepare.sh`). If a floor's fix is newer than that, the build fails at the floors step until it ages in.

## Known remaining findings

- `opentelemetry-api` 1.44.0: CVE-2026-114603, CVE-2026-126360 (medium, fixed in 1.45.x). The API, SDK, exporters and
  instrumentations are released in lockstep and pinned together in upstream's lock, so bumping the API alone does
  not resolve. Left for upstream. romm's init wraps its processes in `opentelemetry-instrument` unless
  `OTEL_SDK_DISABLED=true` is set; deployments without a collector should set it, which also keeps this code idle.

## Tags

- `latest-hardened`: newest successful build of the current `UPSTREAM_VERSION`
- `<upstream>-hardened`, e.g. `5.4.1-hardened`
- `<upstream>-hardened-<YYYYMMDD>`: immutable, use this to pin or roll back

amd64 only.

## Automation

- `build.yml`: runs on push/PR, manually, and weekly (Mon 05:37 UTC). It runs prepare, then build, then the Trivy
  gate (fixable CRITICAL/HIGH fail the build; exceptions go in `.trivyignore.yaml`, scoped to a package URL with a
  reason and an expiry date), then the smoke test, then pushes (on main only). The Trivy JSON/table output is kept
  as a build artifact. If the `HC_PING_URL` secret is set, a successful run pings it.
- `watch-upstream.yml`: runs daily. When romm publishes a new (non-prerelease) release, it opens a PR that bumps
  `UPSTREAM_VERSION` and dispatches the build on that branch. Merge it when it is green.

## Smoke test

`scripts/smoke-test.sh` starts the image with MariaDB and checks:
- migrations run and the app answers `/api/heartbeat`, with the setup wizard on a fresh database
- nginx serves the frontend, `nginx -t` passes with `mod_zip` and njs loaded, valkey answers
- the first admin can be created (CSRF flow, email validation), and OAuth2 password login reads `/api/users/me`
- the floored packages import, pip is gone, and RAHasher, rom-converto, 7z, node and bsdtar are present
- ScreenScraper developer credentials are still set (checked for presence only, never printed)
- a restart with the same volumes keeps the user, with no tracebacks in the logs

## Local build

```bash
scripts/prepare.sh
podman build -f build/src/Dockerfile.hardened $(sed 's/^/--build-arg /' build/build-args) \
  -t romm:hardened build/src
DOCKER=podman scripts/smoke-test.sh romm:hardened
```
