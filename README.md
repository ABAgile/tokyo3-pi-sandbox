# pi-sandbox

`pi-sandbox` is the container image for an agent sandbox: a Wolfi-based environment with the
pi coding agent, herdr, playwright-cli, and common developer tools. Its network access goes
through **veilgated**, a secret-aware egress proxy from the sibling `veilgate` project. The
proxy allows only the hosts a client policy lists, and it can substitute secrets so the
sandbox never sees them.

This repository builds the image and runs the local stack with Docker Compose:

| Service | Image | Role |
|---|---|---|
| `sandbox` | `abagile/tokyo3-pi-sandbox` (built here) | The agent environment. Runs as `agent` (UID 1000) on an internal network with `cap_drop: ALL`. Its only route out is the proxy. |
| `veilgated` | `ghcr.io/abagile/tokyo3-veilgate:0.2.1` (`VEILGATED_IMAGE`) | The egress proxy and the operator console. |
| `postgres` | `postgres:17-alpine` | Development database for the sandbox (tmpfs, dev credentials). |
| `nats` | `nats:2.11-alpine` | Development message bus with JetStream (tmpfs, no auth). |

## Layout

```
.env.sample              template for .env (copy it; .env is git-ignored)
apko.yaml                image definition (packages, users, paths, environment, entrypoint)
melange/*.yaml           recipes for the local packages (herdr, pi-coding-agent, playwright-cli, sandbox-config)
melange.rsa{,.pub}       melange signing key pair (both git-ignored)
config/veilgate/         sample veilgated client and OAuth policies, seeded into the veilgate volume
compose.yml              the stack
compose.extra.yml        optional overlay that bind-mounts pi and chezmoi config into the sandbox
Makefile                 build, certificate, and trust targets
images.lock              digests of the melange and apko images (make refresh)
apko.<arch>.lock.json    apko lock of the Wolfi and local package versions (make refresh)
packages/                melange output: signed .apk files and APKINDEX (generated)
pi-sandbox.tar           the built image tarball (generated)
sbom-*.spdx.json         software bills of materials from apko (generated)
```

## Build pipeline: melange and apko

The image is assembled in two stages. Both tools run from their Chainguard images, so the host
needs only Docker, `make`, and `openssl`. `make refresh` pulls `:latest`, records the digests in
`images.lock`, and regenerates the apko lock file. Builds use the recorded digests.

**1. melange builds packages.** Each `melange/<name>.yaml` describes how to build one `.apk`
package from source. `make packages` runs melange on every recipe and signs the results with
`melange.rsa`. Output goes to `packages/<arch>/`, with an `APKINDEX`. The apk repository is
local, so the image is built from exactly these packages.

Melange does not record which recipes it has built, so the Makefile writes a stamp per recipe
and architecture set (`packages/.<name>.<arch>.stamp`). A recipe rebuilds when its YAML, the
signing key, or `images.lock` changes, so a tool upgrade rebuilds every package.

**2. apko assembles the image.** `apko.yaml` lists:

- **repositories:** the Wolfi OS repository and the local `./packages` repository. The keyring
  holds the Wolfi signing key and `./melange.rsa.pub`, so the local packages are verified.
- **packages:** pinned as `name=version`. Transitive dependencies are pinned by `apko.<arch>.lock.json`,
  which `make refresh` regenerates. After a recipe version change, run `make refresh` so the lock matches.
- **accounts, paths, environment, entrypoint:** the `agent` user, the mount-point directories
  for compose volumes, the environment (including the CA-bundle variables in the trust section
  below), and `tini` as the entrypoint with `/usr/bin/herdr server` as the command (a headless server; clients attach with `docker compose exec sandbox /usr/bin/herdr`).

`make image` writes the OCI tarball `pi-sandbox.tar`, with SBOMs next to it, and
`pi-sandbox.versions.json` beside it. The record holds the melange and apko image digests, what each
tool reports for `version --json`, and the hash of the apko lock file.
`pi-sandbox.sha256` lists the tarball and its SBOMs in `sha256sum` format, so `sha256sum -c` checks them.
It also loads the image into the
local Docker daemon as `SANDBOX_IMAGE` (`LOAD=0` skips the load). `make image` depends on
`make packages`, so a plain build runs both stages.

### Signing key

`make keygen` creates `melange.rsa` and `melange.rsa.pub` in the melange image if they are missing.
`make packages` creates the private key if it is absent, and `make image` derives the public key if
that is absent. Both files are git-ignored. Copy the pair to a fresh checkout, or let make derive the
public key from the private key. `make clean` keeps the key, and refreshing the tool images never
regenerates it.

### Build targets

| Target | Purpose |
|---|---|
| `make` (`all`) | Proxy policy and trust bundle: runs `policy` and `trust` (`trust` runs `certs` first). Does not build packages or the image |
| `make packages` | Build every `melange/*.yaml` into `./packages` with the melange image, signed with `melange.rsa` |
| `make refresh` | Pull the latest melange and apko, record their digests in `images.lock`, rebuild the packages, and regenerate the apko lock file (`ARCH`) |
| `make apko-lock` | Regenerate the apko lock file for `ARCH` (run by `refresh`); the file is left untouched when nothing changed |
| `make image` | Build `pi-sandbox.tar` with the apko image, write `pi-sandbox.versions.json`, and load it into Docker (`LOAD=0` to skip) |
| `make load` | Load an existing `pi-sandbox.tar`; never rebuilds |
| `make keygen` | Create the signing key if missing |
| `make volumes` | Create the home, trust, and veilgate volumes if missing; set `etc/` and `lib/` ownership in the veilgate volume; `certs` and `policy` run it first |
| `make certs` | Create the intercept CA and proxy and console certificates in the veilgate volume |
| `make policy` | Seed `etc/clients.json` and `etc/oauth.json` in the veilgate volume (missing files only; the first run prints the proxy token) |
| `make trust` | Write the sandbox trust bundle into its volume; pulls `SANDBOX_IMAGE` if it is not local (falls back to `pi-sandbox.tar`); runs `certs` first |
| `make up` | Start the sandbox stack detached with `docker compose up -d --remove-orphans` (`RECREATE=1` to force recreate) |
| `make down` | Stop and remove the stack, including orphan containers |
| `make ps` | List all stack containers, including stopped ones |
| `make clean` | Remove `pi-sandbox.tar`, its version record and checksum file, `packages/`, and SBOMs (keeps the key and lock files) |
| `make help` | List the targets |

Useful variables: `ARCH` (default `host`; a list such as `x86_64,aarch64` needs cross-build
support), `IMAGE`, `OUT`, and `LOAD`. Container settings: `MELANGE_REPO` and `APKO_REPO` (image
repositories), `SANDBOX_PROJ` (the project volume), and
`WORK_SUBPATH` (this directory inside it, default `abagile/sandbox`; see below).

## Build prerequisites: Docker and the project volume

The packaging and image steps run in containers, so the host needs Docker, `make`, and `openssl`.

- **Project location.** The containers see this directory through a volume subpath. `WORK_SUBPATH`
  (default `abagile/sandbox`) is this directory inside `SANDBOX_PROJ`, the project volume, and it is
  mounted at `/work`. Run `make` from this directory: the host-side steps use the current directory.
  No host path is needed, so this works from a dev container. `SANDBOX_PROJ` must be a volume name.
- **Privileges.** melange runs with `--cap-add SYS_ADMIN` and `--security-opt seccomp=unconfined
  --security-opt apparmor=unconfined` instead of `--privileged`. bubblewrap needs user namespaces, which
  the default seccomp and AppArmor profiles block. Without `SYS_ADMIN` the build fails with permission
  denied, and with it the result matches `--privileged`. `SYS_ADMIN` is a broad capability, but it is
  narrower than `--privileged`, which also grants every capability and host devices. I haven't tested
  whether the two `--security-opt` options are still needed with `SYS_ADMIN`.
- **Ownership.** The containers write as root, so each step chowns what it writes back to you:
  `packages/`, `.melange.cache/`, the signing key, the apko lock, and the image tarball. A
  `.melange.cache/` left root-owned by an earlier run needs one `sudo chown -R` before it can be
  cleaned.
- **Caches.** `.melange.cache/` (fetched inputs and the apk cache) sits under `/work`, so it persists
  in the volume between runs.
- **Reruns.** Each recipe has a stamp, and the image depends on the stamps, so a rebuild with nothing
  changed does nothing.

## veilgated integration

### Volume layout

The volume is named by `SANDBOX_VEILGATE` (default `tokyo3_sandbox_veilgate`) and declared external in
`compose.yml`. It is split by subpath:

| Subpath | Mounted in `veilgated` at | Contents |
|---|---|---|
| `etc/` | `/etc/veilgate`, read-only | Certificates, keys, `clients.json`, `oauth.json`, and optional `secrets.json` |
| `lib/` | `/var/lib/veilgate` | Runtime state: the flow store (`flows.db`) and, with the OAuth broker enabled, `auth.json` |

The volume is external, so `docker compose down -v` does not remove it. It holds `auth.json` and the
flow store, and both must survive a `down -v`. `make volumes` creates it if missing, along with the home
and trust volumes, and sets `etc/` and `lib/` to `VEILGATED_UID:VEILGATED_GID` (default `65532:65532`, the
image's non-root user). `make certs` and `make policy` both run it first.

`docker volume rm tokyo3_sandbox_veilgate` discards the intercept CA, the proxy token, and the OAuth
state. The next `make` then generates new ones, and `.env` and the trust bundle must follow.

The `sandbox` service never mounts this volume.

### Certificates and policy in `etc/`

| File | Created by | Used for |
|---|---|---|
| `intercept-ca.crt`, `intercept-ca.key` | `make certs` (`veilgated ca init`) | Signs the proxy certificate. The public certificate becomes part of the sandbox trust bundle. The key never leaves the volume. |
| `proxy.crt`, `proxy.key` | `make certs` (`veilgated ca sign`, signed by the intercept CA) | The HTTPS proxy listener. SANs: `veilgated-proxy`, `veilgated`. |
| `console.crt`, `console.key` | `make certs` (mkcert) | The operator console listener, published at `https://127.0.0.1:8081`. |
| `clients.json` | `make policy` | Client policy: each client's bearer token and its allowed hosts, ports, and interception modes. |
| `oauth.json` | `make policy` | OAuth token broker policy: which clients may use which provider hosts and token fields. It holds no secrets, but seeding it enables the broker. |

`make certs` never overwrites a complete pair. If one file of a pair is missing, it stops and
asks you to remove the leftover file. It reuses a mkcert `dev.localhost` certificate from the
mkcert CA root when that certificate covers `localhost`, `127.0.0.1`, and `*.dev.localhost`.

`make policy` seeds `clients.json` and `oauth.json` from `config/veilgate/`, and writes
only the files the volume lacks. The sample `clients.json` has one client, `agent-dev`, which may
reach 20 hosts on port 443: model providers
and their OAuth issuers, GitHub, Google Cloud Storage, the Go and npm registries, PyPI, and the pi,
herdr, and Wolfi hosts. `api.openai.com` is not on the list, so direct OpenAI API calls are denied;
the OpenAI OAuth path (`auth.openai.com`, `chatgpt.com`) is allowed. The sample's token is a
placeholder. The target replaces it with a new random 48-character hex token and prints the
`SANDBOX_PROXY` line to put in `.env`. Edit the host list to narrow or widen the sandbox's reach.

The client uses `intercept_mode` `inspect`, so the sample needs no `opaque_hosts` or
`intercept_hosts`. Both stay in the sample as empty arrays for reference. Under `inspect`, a host
that no broker names is read-only unless an `allowed_rules` entry says otherwise: only `GET` and
`HEAD` without a body pass, and other methods get `403`. This blocks `git fetch`, `git clone`, and
`git push` over HTTPS, which send POST requests to the server, and it blocks `npm publish`. Hosts
named by a broker are intercepted instead, so the read-only rule does not apply to them. Those are
the Anthropic API host, `chatgpt.com`, and the OAuth issuers, once `oauth.json` is seeded.

The sample `oauth.json` holds no secrets: only provider hosts, token paths, and field names. The broker it configures is
enabled for `agent-dev`. It stores real access and refresh tokens in `lib/auth.json` in
plaintext, and veilgated logs that warning at startup. Delete `etc/oauth.json` to turn the broker
off.

`clients.json` is re-read on `SIGHUP` (`docker compose kill -s HUP veilgated`). An invalid file
keeps the previous policy.

Keep `clients.json` private. Its tokens authenticate the sandbox to the proxy.

The proxy token is generated only when `etc/clients.json` is missing. Running `make` or
`make policy` again keeps the file, so the token does not change, and the `SANDBOX_PROXY`
line is printed only on the first seeding. To read the token later:

```sh
docker run --rm -v tokyo3_sandbox_veilgate:/veilgate:ro alpine:3.21 cat /veilgate/etc/clients.json
```

To rotate it, remove the file, reseed, update `.env`, and reload both services:

```sh
docker run --rm -v tokyo3_sandbox_veilgate:/veilgate alpine:3.21 rm /veilgate/etc/clients.json
make policy                   # prints the new SANDBOX_PROXY line; put it in .env
docker compose kill -s HUP veilgated   # the old token stops working
docker compose up -d sandbox           # recreate the sandbox with the new SANDBOX_PROXY
```

### How the sandbox reaches the proxy

The sandbox sends its traffic to `https://veilgated-proxy:8080` with Basic proxy credentials
(`client-name:token`). Compose passes this URL through `SANDBOX_PROXY` as `HTTPS_PROXY`,
`HTTP_PROXY`, and `ALL_PROXY`:

```
SANDBOX_PROXY=https://agent-dev:<token>@veilgated-proxy:8080
```

The sandbox is on the internal `default` network only, and that network has no route to the
internet. The proxy is also on the `egress` network, so the proxy is the sandbox's only way out.
The console is on `egress` only, so the sandbox cannot reach it.

### Sandbox trust (`make trust`)

The proxy presents a certificate signed by the intercept CA, so the sandbox must trust that CA.
`make trust` writes that trust into a separate volume, `tokyo3_sandbox_trust`:

1. It reads the image's `/etc/ssl/certs/ca-certificates.crt` (the base Wolfi roots) and checks
   that it parses.
2. It reads `etc/intercept-ca.crt` through a helper container. It refuses the file if it
   contains a private key or is not a CA (`basicConstraints CA:TRUE`).
3. It appends the intercept CA and writes `ca-certificates.crt` and a `ca-bundle.crt` symlink
   into the trust volume. It then reads the file back and compares it with the bundle it built.

Compose mounts this volume read-only at `/etc/ssl/certs` in the `sandbox` service. A mount over
that path hides the directory the image shipped with, so the bundle has to contain every root,
and it does. The image sets `SSL_CERT_FILE` to this bundle. `NODE_USE_SYSTEM_CA` and `UV_SYSTEM_CERTS`
tell Node and uv to use the system store.

`make trust` depends on `make certs` only; it does not build the image. If `SANDBOX_IMAGE` is not in the local
daemon, it runs `docker pull` on it. If the pull fails and `pi-sandbox.tar` exists, it loads the tarball instead.
Otherwise it stops and asks you to set `SANDBOX_IMAGE` to a pullable reference or run `make image`.
The bundle is a snapshot. Rerun
it after rebuilding the base image or regenerating the intercept CA. A process that is already
running keeps the old bundle until it restarts.

### mkcert and console trust

mkcert signs only the **console** certificate, which operators open in a browser. The sandbox never
uses mkcert, and the mkcert root is not in the sandbox trust bundle.

- `make certs` signs `console.crt` with the CA on the machine that runs it. That CA lives in
  `mkcert -CAROOT` on that machine, and the browser must trust that CA.
- **Browser on the same machine as `make`:** run `mkcert -install` before `make`. It creates the CA and
  trusts it, so the console works with no further step.
- **Browser on a different machine:** do not run `mkcert -install` there. That creates a second CA,
  which did not sign the console certificate. Copy only `rootCA.pem` from `mkcert -CAROOT` on the
  `make` host to the browser's machine, and install it there as a trusted root. Never copy
  `rootCA-key.pem`.
- **Console access from another machine:** the console listens on `127.0.0.1` of the Docker host.
  Forward the port with `ssh -L 8081:127.0.0.1:8081 <host>`, then open `https://127.0.0.1:8081` on the
  browser's machine. The certificate covers `127.0.0.1` and `localhost`.
- `MKCERT` overrides the mkcert binary path. `CONSOLE_CERT_NAMES` overrides the names on the console
  certificate.

## Bootstrap

Prerequisites: Docker with Compose v2, `make`, `openssl`, and `mkcert`. Run the
steps on the host that runs the stack.

```sh
# 1. Configuration. Fill in the CHANGE_ME values after step 4.
cp .env.sample .env && chmod 600 .env

# 2. Volumes. Compose refuses to start without them. tokyo3_hq_proj holds your project checkout, so
#    create it yourself; make volumes creates the home, trust, and veilgate volumes.
docker volume create tokyo3_hq_proj
make volumes                          # veilgate etc/ and lib/ get the veilgate user's ownership

# 3. Only when the browser runs on this same machine: trust the console CA before the make steps.
mkcert -install

# 4. Proxy policy (etc/clients.json, etc/oauth.json). Safe to rerun.
make policy                           # the first run prints SANDBOX_PROXY=https://agent-dev:<token>@veilgated-proxy:8080

# 5. Certificates and trust bundle. Pulls SANDBOX_IMAGE if it is not local. Safe to rerun.
make trust
```

> **Console browser trust is a separate step from `make`.** Step 3 covers the same-machine case. If the
> browser runs on another machine, do not run `mkcert -install` there. Copy `rootCA.pem` from the `make`
> host instead. See [mkcert and console trust](#mkcert-and-console-trust).

Paste the printed `SANDBOX_PROXY` line into `.env`, replacing the placeholder. Also set
`VEILGATED_CONSOLE_USERNAME` and `VEILGATED_CONSOLE_PASSWORD`. veilgated refuses to start
without them, because the console listens on a non-loopback address.

```sh
# 6. Start the stack. Compose pulls SANDBOX_IMAGE if it is not local.
make up
docker compose logs -f veilgated      # look for "veilgate starting"
```

`make ps` lists the containers. `make down` stops and removes the stack; volumes are kept.

`make trust` does not build the image. To build it locally instead of pulling, run `make image`
before `make trust`; it loads `pi-sandbox.tar` as `SANDBOX_IMAGE`.

To check the path end to end, send a request from the sandbox to an allowed host. Any HTTP
status from the upstream means the proxy and the trust bundle work. A TLS certificate error
means the trust bundle is missing the intercept CA.

```sh
docker compose exec sandbox curl -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/v1/models
```

### Optional overlay

`compose.extra.yml` bind-mounts host config into the sandbox: `SANDBOX_PI` at `~/.pi` and
`SANDBOX_CHEZMOI` at the chezmoi source directory. Both must be set to host paths in `.env`.
`make up` adds the overlay automatically when both are set.

## Configuration

`.env.sample` documents every variable that compose and the Makefile read. Notes:

- `SANDBOX_PROJ` and `SANDBOX_HOME` take either a volume name declared in `compose.yml` (the
  defaults `tokyo3_hq_proj` and `tokyo3_sandbox_home`) or an absolute host path.
- `SANDBOX_VEILGATE` and `SANDBOX_TRUST` name the external veilgate and trust volumes. Compose and the
  Makefile read the same keys, so they always use the same volumes. Any volume name works. Renaming
  points the stack at a different, empty volume unless you copy the data.
- `VEILGATED_UID`, `VEILGATED_GID`, `VEILGATED_*`, and `SANDBOX_*` are read from `.env` by compose;
  the Makefile reads `SANDBOX_IMAGE`, `VEILGATED_IMAGE`, `VEILGATED_UID`, and `VEILGATED_GID` from `.env` too.

## Security notes

- `.env` holds the proxy token and the console password. Keep it `chmod 600`, and never commit it.
- `melange.rsa` is the package signing key. Anyone with it can produce packages that this build
  accepts. Keep it private.
- Never mount `intercept-ca.key`, `proxy.key`, or `console.key` into the sandbox. The sandbox
  receives only the public `intercept-ca.crt`, through the trust volume.
- The sandbox runs with `cap_drop: ALL` on an internal network. Its only egress is the proxy.
- The postgres credentials (`agent`/`agent`) and the NATS setup (no auth) are for local
  development only. `nats` publishes ports 4222 and 8222 on all host interfaces.
- The console is published on `127.0.0.1` only and needs the username and password from `.env`.
- The flow store holds recorded traffic. `auth.json` holds real OAuth access and refresh tokens in
  plaintext while the broker is enabled, which the seeded `oauth.json` does by default. Protect the
  `lib/` subpath and its backups.
- `docker compose down -v` does not remove the veilgate volume, because it is external. `docker volume rm
  tokyo3_sandbox_veilgate` does, and it discards the intercept CA, the proxy token, and `auth.json`.
