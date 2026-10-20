## pi-sandbox — build the sandbox image: melange packages (./melange) → apko image (./apko.yaml)
##
## Usage: make <target>
##

# ── Variables ─────────────────────────────────────────────────────────────────

dotenv  = $(shell sed -n 's/^$(1)=//p' .env 2>/dev/null | tail -n 1)
lockval = $(shell sed -n 's/^$(1)=//p' images.lock 2>/dev/null | tail -n 1)

# Sandbox image name. Compose runs SANDBOX_IMAGE from .env, so that is the fallback.
IMAGE := $(or $(IMAGE),$(call dotenv,SANDBOX_IMAGE),abagile/tokyo3-pi-sandbox)
OUT   ?= pi-sandbox.tar
# Version record written beside OUT: tool images and versions, and the apko lock hash.
VERSIONS := $(basename $(OUT)).versions.json
# LOAD=1 loads OUT into the local docker daemon and tags it as IMAGE (the tarball
# carries per-arch tags such as <IMAGE>:latest-arm64). LOAD=0 only writes OUT.
LOAD  ?= 1
# Architectures for melange and apko. `host` builds only this machine's arch;
# list several (ARCH=x86_64,aarch64) only where cross-building is available.
ARCH  ?= host
# `host` resolves to this machine's apk arch, so stamps stay correct when the
# machine changes. ARCH_TAG names the stamps and the apko lock file for the architecture set.
ARCH_NAME := $(if $(filter host,$(ARCH)),$(shell uname -m | sed -e 's/arm64/aarch64/'),$(ARCH))
ARCH_TAG  := $(shell printf '%s' '$(ARCH_NAME)' | tr ',' '_')

# ── Tool images ───────────────────────────────────────────────────────────────

# melange and apko run from their Chainguard images. `make refresh` pulls :latest, records the
# digests in images.lock, and regenerates the apko lock file. Builds use the recorded digests,
# so they are reproducible until the next refresh. Package stamps and the image depend on
# images.lock, so a tool change rebuilds them.
MELANGE_REPO         ?= cgr.dev/chainguard/melange
APKO_REPO            ?= cgr.dev/chainguard/apko
MELANGE_DIGEST       := $(call lockval,MELANGE_DIGEST)
APKO_DIGEST          := $(call lockval,APKO_DIGEST)
MELANGE_IMAGE        ?= $(if $(MELANGE_DIGEST),$(MELANGE_REPO)@$(MELANGE_DIGEST),$(error images.lock is missing or incomplete: run make refresh))
APKO_IMAGE           ?= $(if $(APKO_DIGEST),$(APKO_REPO)@$(APKO_DIGEST),$(error images.lock is missing or incomplete: run make refresh))
# The containers see the project through a volume subpath, so no host path is needed. WORK_SUBPATH is
# this directory inside the project volume (SANDBOX_PROJ), and it is mounted at /work. Run make from
# that directory: the host-side steps use the current directory.
SANDBOX_PROJ := $(or $(SANDBOX_PROJ),$(call dotenv,SANDBOX_PROJ),tokyo3_hq_proj)
WORK_SUBPATH ?= $(or $(call dotenv,SANDBOX_SUBPATH),abagile/sandbox)
WORK_MOUNT   ?= --mount type=volume,src=$(SANDBOX_PROJ),dst=/work,volume-subpath=$(WORK_SUBPATH)

# The tools run with /work as the working directory, so recipes, melange.rsa, packages/,
# .melange.cache/, and the outputs are all relative to it. Containers write as root, so their
# outputs are chowned back to the invoking user with chown_back.
# Instead of --privileged: bubblewrap needs user namespaces, which the default seccomp and AppArmor
# profiles block, and CAP_SYS_ADMIN (tested: without it, the build fails with permission denied).
MELANGE_RUN = docker run --rm --cap-add SYS_ADMIN --security-opt seccomp=unconfined --security-opt apparmor=unconfined -w /work $(WORK_MOUNT) $(MELANGE_IMAGE)
APKO_RUN    = docker run --rm -w /work $(WORK_MOUNT) $(APKO_IMAGE)
# $(1) is the chown flags, $(2) the paths relative to /work.
define chown_back
docker run --rm -w /work $(WORK_MOUNT) $(HELPER_IMAGE) chown $(1) $$(id -u):$$(id -g) $(2)
endef

APKO_LOCK   := apko.$(ARCH_TAG).lock.json
MELANGE_SRC := $(wildcard melange/*.yaml)
PKG_STAMPS  := $(patsubst melange/%.yaml,packages/.%.$(ARCH_TAG).stamp,$(MELANGE_SRC))

# ── Phony targets ─────────────────────────────────────────────────────────────

.PHONY: all image load packages keygen refresh apko-lock volumes certs policy trust up down ps clean help

# Certificates and policy are seeded before the image and trust bundle are built.
all: policy trust

# ── Lock and refresh ──────────────────────────────────────────────────────────

## refresh: Pull the latest melange and apko, record their digests in images.lock, and regenerate the apko lock file (ARCH)
refresh:
	@set -eu; \
	for repo in $(MELANGE_REPO) $(APKO_REPO); do docker pull "$$repo:latest" >/dev/null; done; \
	m=$$(docker image inspect --format '{{index .RepoDigests 0}}' "$(MELANGE_REPO):latest" | sed 's/^.*@//'); \
	a=$$(docker image inspect --format '{{index .RepoDigests 0}}' "$(APKO_REPO):latest" | sed 's/^.*@//'); \
	new=$$(printf '# Written by make refresh. Builds use these digests; refresh to move to newer releases.\nMELANGE_DIGEST=%s\nAPKO_DIGEST=%s\n' "$$m" "$$a"); \
	if [ "$$new" = "$$(cat images.lock 2>/dev/null)" ]; then echo "  images.lock unchanged"; else printf '%s\n' "$$new" > images.lock; echo "  images.lock updated: melange $$m, apko $$a"; fi
	$(MAKE) --no-print-directory packages
	$(MAKE) --no-print-directory apko-lock

## apko-lock: Regenerate the apko lock file for ARCH from the Wolfi index and ./packages; keeps the file if unchanged (run by refresh)
apko-lock:
	$(APKO_RUN) lock --arch $(ARCH_NAME) --output $(APKO_LOCK).new apko.yaml
	$(call chown_back,,$(APKO_LOCK).new)
	@if cmp -s $(APKO_LOCK).new $(APKO_LOCK); then rm -f $(APKO_LOCK).new; echo "  $(APKO_LOCK) unchanged"; else mv $(APKO_LOCK).new $(APKO_LOCK); echo "  $(APKO_LOCK) updated"; fi

# Written by make refresh. A missing file stops any build that needs it.
images.lock:
	@echo "images.lock is missing: run 'make refresh' first" >&2; exit 1

$(APKO_LOCK):
	@echo "$@ is missing: run 'make refresh' first (ARCH=$(ARCH_NAME))" >&2; exit 1

# ── Signing key ───────────────────────────────────────────────────────────────

## keygen: Create the melange signing key (melange.rsa + melange.rsa.pub) if missing, with the melange image
keygen: melange.rsa melange.rsa.pub

# No prerequisites on purpose: refreshing the tool images must never regenerate an existing key.
melange.rsa:
	$(MELANGE_RUN) keygen melange.rsa
	$(call chown_back,,melange.rsa melange.rsa.pub)

# keygen writes both halves. If only the private key is present (for example a fresh
# checkout that copied it over), derive the public key from it.
melange.rsa.pub: melange.rsa
	openssl rsa -in melange.rsa -pubout -out melange.rsa.pub

# ── Packages ──────────────────────────────────────────────────────────────────

## packages: Build every melange/*.yaml into ./packages with the melange image, signed with melange.rsa
packages: $(PKG_STAMPS)

# melange does not record which recipes it has built, so each recipe gets a stamp per
# architecture set. A recipe rebuilds when its YAML, the signing key, or the tool images change.
# --git-commit: melange otherwise records HEAD in the apk, so every commit (including the lock) would change the package.
packages/.%.$(ARCH_TAG).stamp: melange/%.yaml melange.rsa images.lock
	mkdir -p .melange.cache/apk
	$(MELANGE_RUN) build melange/$*.yaml --signing-key melange.rsa --arch $(ARCH_NAME) --runner bubblewrap \
	  --git-commit $$(git hash-object melange/$*.yaml) \
	  --cache-dir .melange.cache --apk-cache-dir .melange.cache/apk --out-dir packages
	$(call chown_back,-R,packages .melange.cache)
	@touch $@

# ── Image ─────────────────────────────────────────────────────────────────────

## image: Build the image tarball (OUT) with the apko image, write its version record, and load it into docker as IMAGE (LOAD=0 to skip)
image: $(OUT) $(VERSIONS)

$(OUT): apko.yaml melange.rsa.pub images.lock $(PKG_STAMPS) $(APKO_LOCK)
	$(APKO_RUN) build apko.yaml $(IMAGE) $@ --arch $(ARCH_NAME) --lockfile $(APKO_LOCK)
	$(call chown_back,,$@)
	@echo "  built $(OUT) as $(IMAGE)"
	@if [ "$(LOAD)" = 1 ]; then $(MAKE) --no-print-directory load; fi

# The record: the exact tool images, what each tool reports for its version, and the apko lock used.
# The checksum file covers the tarball and its SBOMs, so `sha256sum -c` can verify them.
$(VERSIONS): $(OUT) images.lock $(APKO_LOCK)
	@set -eu; \
	mel=$$($(MELANGE_RUN) version --json); \
	apk=$$($(APKO_RUN) version --json); \
	printf '{\n  "melange": {"image": "%s", "version": %s},\n  "apko": {"image": "%s", "version": %s},\n  "arch": "%s",\n  "apko_lock": "%s",\n  "apko_lock_sha256": "%s"\n}\n' \
	  '$(MELANGE_IMAGE)' "$$mel" '$(APKO_IMAGE)' "$$apk" '$(ARCH_NAME)' '$(APKO_LOCK)' "$$(sha256sum $(APKO_LOCK) | cut -d' ' -f1)" > $@; \
	sha256sum $(OUT) sbom-*.spdx.json > $(basename $(OUT)).sha256
	@echo "  wrote $(VERSIONS) and $(basename $(OUT)).sha256"

## load: Load the existing tarball (OUT) into docker and tag it as IMAGE; never rebuilds
load:
	@test -f $(OUT) || { echo "$(OUT) not found; run 'make image LOAD=0' first"; exit 1; }
	@ref=$$(docker load -i $(OUT) | sed -n 's/^Loaded image: //p'); \
	test -n "$$ref" || { echo "docker load printed no image name"; exit 1; }; \
	docker tag "$$ref" $(IMAGE) && echo "  loaded $$ref, tagged as $(IMAGE)"

## clean: Remove the image tarball, its version record, SBOMs, and ./packages (keeps the signing key and lock files)
clean:
	rm -rf $(OUT) $(VERSIONS) $(basename $(OUT)).sha256 packages sbom-*.spdx.json

# ── Certificates ──────────────────────────────────────────────────────────────

# certs writes the veilgate material straight into the veilgate volume: etc/ holds the
# certificates and keys (mounted read-only at /etc/veilgate), lib/ holds state (mounted at
# /var/lib/veilgate). No host bind mounts are used, so it also works from a dev container.
# Files are owned by VEILGATED_UID:VEILGATED_GID, which must match the user the veilgate
# service runs as. Compose reads .env but Make does not, so both values fall back to .env
# unless set in the environment or on the command line. VEILGATED_IMAGE is also read by compose.yml.
VEILGATED_VOLUME   := $(or $(VEILGATED_VOLUME),$(call dotenv,SANDBOX_VEILGATE),tokyo3_sandbox_veilgate)
VEILGATED_IMAGE    ?= $(or $(call dotenv,VEILGATED_IMAGE),ghcr.io/abagile/tokyo3-veilgate:0.2.1)
VEILGATED_UID      := $(or $(VEILGATED_UID),$(call dotenv,VEILGATED_UID),65532)
VEILGATED_GID      := $(or $(VEILGATED_GID),$(call dotenv,VEILGATED_GID),65532)
HELPER_IMAGE       ?= alpine:3.21
MKCERT             ?= mkcert
# The proxy is only reached by name on the sandbox network; it never listens on loopback.
PROXY_CERT_SAN     ?= DNS:veilgated-proxy,DNS:veilgated
CONSOLE_CERT_NAMES ?= '*.dev.localhost' localhost 127.0.0.1

# ── Volumes ───────────────────────────────────────────────────────────────────

# The sandbox's external volumes are named in .env: SANDBOX_HOME, SANDBOX_TRUST, and SANDBOX_VEILGATE.
# compose reads the same keys, so both always use the same volumes. External volumes survive
# `docker compose down -v`. SANDBOX_HOME may also be a host path (starting with /, ./, or ~/), which
# compose bind-mounts instead; it is not created here.
SANDBOX_HOME := $(or $(SANDBOX_HOME),$(call dotenv,SANDBOX_HOME),tokyo3_sandbox_home)

## volumes: Create the home, trust, and veilgate volumes if missing; set etc/ and lib/ in the veilgate volume to VEILGATED_UID:VEILGATED_GID
volumes:
	@set -eu; \
	command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }; \
	case "$(SANDBOX_HOME)" in /*|./*|~/*) echo "  $(SANDBOX_HOME) is a host path; not created";; *) docker volume create "$(SANDBOX_HOME)" >/dev/null && echo "  volume $(SANDBOX_HOME) ready";; esac; \
	docker volume create "$(TRUST_VOLUME)" >/dev/null && echo "  volume $(TRUST_VOLUME) ready"; \
	docker volume create "$(VEILGATED_VOLUME)" >/dev/null; \
	docker run --rm --user 0:0 -v "$(VEILGATED_VOLUME):/veilgate" --entrypoint sh "$(HELPER_IMAGE)" \
	  -c 'mkdir -p /veilgate/etc /veilgate/lib && chown -R $(VEILGATED_UID):$(VEILGATED_GID) /veilgate/etc /veilgate/lib'; \
	echo "  volume $(VEILGATED_VOLUME): etc/ and lib/ owned by $(VEILGATED_UID):$(VEILGATED_GID)"

## certs: Write the intercept CA, proxy, and console certificates into the veilgate volume; existing files are kept
certs: volumes
	@set -eu; \
	command -v "$(MKCERT)" >/dev/null || { echo "$(MKCERT) is required; install mkcert first" >&2; exit 1; }; \
	command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }; \
	caroot="$$("$(MKCERT)" -CAROOT)"; \
	have=$$(docker run --rm --user 0:0 -v "$(VEILGATED_VOLUME):/veilgate" --entrypoint sh "$(HELPER_IMAGE)" \
	  -c 'ls -1 /veilgate/etc'); \
	has() { printf '%s\n' "$$have" | grep -qx "$$1"; }; \
	pair() { \
	  if has "$$1" && has "$$2"; then return 0; fi; \
	  if has "$$1" || has "$$2"; then echo "  incomplete: $$1 / $$2 in $(VEILGATED_VOLUME); remove the remaining file and retry" >&2; exit 1; fi; \
	  return 1; \
	}; \
	dev_pair() { \
	  c="$$1/dev.localhost.crt"; k="$$1/dev.localhost.key"; r="$$1/rootCA.pem"; \
	  if [ ! -e "$$c" ] && [ ! -e "$$k" ]; then return 1; fi; \
	  if [ ! -f "$$c" ] || [ ! -f "$$k" ]; then echo "  incomplete: $$c / $$k; remove the remaining file and retry" >&2; exit 1; fi; \
	  if [ "$$(openssl x509 -in "$$c" -noout -pubkey | openssl pkey -pubin -outform DER | sha256sum)" != "$$(openssl pkey -in "$$k" -pubout -outform DER | sha256sum)" ]; then echo "  $$c does not match $$k" >&2; exit 1; fi; \
	  openssl verify -CAfile "$$r" "$$c" >/dev/null 2>&1 || { echo "  $$c is not signed by $$r, or has expired" >&2; exit 1; }; \
	  { openssl x509 -in "$$c" -noout -checkhost localhost | grep -q 'does match' && \
	    openssl x509 -in "$$c" -noout -checkip 127.0.0.1 | grep -q 'does match' && \
	    openssl x509 -in "$$c" -noout -checkhost probe.dev.localhost | grep -q 'does match'; } \
	    || { echo "  $$c does not cover localhost, 127.0.0.1, and *.dev.localhost" >&2; exit 1; }; \
	  return 0; \
	}; \
	veilgate() { docker run --rm --user "$(VEILGATED_UID):$(VEILGATED_GID)" -v "$(VEILGATED_VOLUME):/veilgate" "$(VEILGATED_IMAGE)" "$$@"; }; \
	if pair intercept-ca.crt intercept-ca.key; then \
	  echo "  using existing intercept-ca.crt and intercept-ca.key"; \
	else \
	  veilgate ca init --cert /veilgate/etc/intercept-ca.crt --key /veilgate/etc/intercept-ca.key; \
	  echo "  wrote intercept-ca.crt and intercept-ca.key"; \
	fi; \
	if pair proxy.crt proxy.key; then \
	  echo "  using existing proxy.crt and proxy.key"; \
	else \
	  veilgate ca sign --ca-cert /veilgate/etc/intercept-ca.crt --ca-key /veilgate/etc/intercept-ca.key \
	    --cert /veilgate/etc/proxy.crt --key /veilgate/etc/proxy.key --san "$(PROXY_CERT_SAN)"; \
	  echo "  wrote proxy.crt and proxy.key signed by intercept-ca.crt"; \
	fi; \
	if pair console.crt console.key; then \
	  echo "  using existing console.crt and console.key"; \
	else \
	  tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; \
	  if dev_pair "$$caroot"; then \
	    cp "$$caroot/dev.localhost.crt" "$$tmp/console.crt"; cp "$$caroot/dev.localhost.key" "$$tmp/console.key"; \
	    echo "  reused dev.localhost.crt and dev.localhost.key from $$caroot"; \
	  else \
	    "$(MKCERT)" -cert-file "$$tmp/console.crt" -key-file "$$tmp/console.key" $(CONSOLE_CERT_NAMES) >/dev/null; \
	    echo "  wrote console.crt and console.key (mkcert $(CONSOLE_CERT_NAMES))"; \
	  fi; \
	  tar -C "$$tmp" -cf - console.crt console.key | docker run -i --rm --user "$(VEILGATED_UID):$(VEILGATED_GID)" -v "$(VEILGATED_VOLUME):/veilgate" --entrypoint tar "$(HELPER_IMAGE)" -xf - -C /veilgate/etc; \
	fi; \
	echo "  volume $(VEILGATED_VOLUME): etc/ (certificates) and lib/ (state), owned by $(VEILGATED_UID):$(VEILGATED_GID)"; \
	echo "  operators trust the console via $$caroot/rootCA.pem (run '$(MKCERT) -install' once)"

# ── Client policy ─────────────────────────────────────────────────────────────

# The sample files are a client policy with a placeholder token and an OAuth broker policy that
# holds no secrets. policy seeds etc/clients.json and etc/oauth.json, writing only the
# files the volume lacks; existing files are kept. veilgated reads both at startup, and
# clients.json is also re-read on SIGHUP.
VEILGATE_SAMPLE_POLICY ?= config/veilgate/clients.example.json
VEILGATE_SAMPLE_OAUTH  ?= config/veilgate/oauth.example.json

## policy: Seed etc/clients.json and etc/oauth.json in the veilgate volume (missing files only; existing files are kept)
policy: volumes
	@set -eu; \
	test -f "$(VEILGATE_SAMPLE_POLICY)" || { echo "$(VEILGATE_SAMPLE_POLICY) not found" >&2; exit 1; }; \
	test -f "$(VEILGATE_SAMPLE_OAUTH)" || { echo "$(VEILGATE_SAMPLE_OAUTH) not found" >&2; exit 1; }; \
	missing=$$(docker run --rm --user 0:0 -v "$(VEILGATED_VOLUME):/veilgate" --entrypoint sh "$(HELPER_IMAGE)" \
	  -c '{ [ -e /veilgate/etc/clients.json ] || echo clients.json; [ -e /veilgate/etc/oauth.json ] || echo oauth.json; }'); \
	if [ -z "$$missing" ]; then echo "  using existing etc/clients.json and etc/oauth.json in $(VEILGATED_VOLUME)"; exit 0; fi; \
	tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; \
	token="$$(openssl rand -hex 24)"; \
	if printf '%s\n' "$$missing" | grep -qx clients.json; then \
	  sed "s/@PROXY_TOKEN@/$$token/" "$(VEILGATE_SAMPLE_POLICY)" > "$$tmp/clients.json"; \
	  grep -q "$$token" "$$tmp/clients.json" || { echo "  $(VEILGATE_SAMPLE_POLICY) has no @PROXY_TOKEN@ placeholder" >&2; exit 1; }; \
	  echo "  seeding etc/clients.json from $(VEILGATE_SAMPLE_POLICY)"; \
	fi; \
	if printf '%s\n' "$$missing" | grep -qx oauth.json; then \
	  cp "$(VEILGATE_SAMPLE_OAUTH)" "$$tmp/oauth.json"; \
	  echo "  seeding etc/oauth.json from $(VEILGATE_SAMPLE_OAUTH)"; \
	fi; \
	chmod 600 "$$tmp"/*; \
	tar -C "$$tmp" -cf - $$missing | docker run -i --rm --user "$(VEILGATED_UID):$(VEILGATED_GID)" -v "$(VEILGATED_VOLUME):/veilgate" --entrypoint tar "$(HELPER_IMAGE)" -xf - -C /veilgate/etc; \
	if printf '%s\n' "$$missing" | grep -qx clients.json; then \
	  if [ -t 1 ]; then b=$$(printf '\033[1;33m'); r=$$(printf '\033[0m'); else b=''; r=''; fi; \
	  printf '  %sset in .env: SANDBOX_PROXY=https://agent-dev:%s@veilgated-proxy:8080%s\n' "$$b" "$$token" "$$r"; \
	fi

# ── Sandbox CA trust ─────────────────────────────────────────────────────────────

# trust gives the sandbox its trust bundle: the base image's roots plus the intercept
# CA, written to TRUST_VOLUME and mounted read-only at /etc/ssl/certs. Only the public
# certificate is read from the veilgate volume. The bundle is a snapshot: rerun after
# rebuilding the base image or regenerating the CA. Running sandbox processes keep the old
# bundle until restarted; new processes see the new one.
TRUST_VOLUME       := $(or $(TRUST_VOLUME),$(call dotenv,SANDBOX_TRUST),tokyo3_sandbox_trust)

## trust: Write the sandbox trust bundle (base roots + intercept CA) into the trust volume
trust: certs
	@set -eu; \
	command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }; \
	if ! docker image inspect "$(IMAGE)" >/dev/null 2>&1; then \
	  if docker pull "$(IMAGE)" >/dev/null; then echo "  pulled $(IMAGE)"; \
	  elif [ -f "$(OUT)" ]; then $(MAKE) --no-print-directory load; \
	  else echo "  $(IMAGE) is not local or pullable, and $(OUT) does not exist; set SANDBOX_IMAGE to a pullable reference or run 'make image'" >&2; exit 1; fi; \
	fi; \
	tmp="$$(mktemp -d)"; trap 'rm -rf "$$tmp"' EXIT; \
	docker run --rm --entrypoint cat "$(IMAGE)" /etc/ssl/certs/ca-certificates.crt > "$$tmp/ca-certificates.crt"; \
	openssl crl2pkcs7 -nocrl -certfile "$$tmp/ca-certificates.crt" | openssl pkcs7 -print_certs -noout | grep -q '^subject=' \
	  || { echo "  $(IMAGE) has no parseable certificates in its bundle" >&2; exit 1; }; \
	docker run --rm -v "$(VEILGATED_VOLUME):/veilgate:ro" --entrypoint cat "$(HELPER_IMAGE)" /veilgate/etc/intercept-ca.crt > "$$tmp/intercept-ca.crt" \
	  || { echo "  etc/intercept-ca.crt not found in $(VEILGATED_VOLUME); run 'make certs' first" >&2; exit 1; }; \
	if grep -q 'PRIVATE KEY' "$$tmp/intercept-ca.crt"; then echo "  intercept-ca.crt contains a private key; refusing to use it" >&2; exit 1; fi; \
	openssl x509 -in "$$tmp/intercept-ca.crt" -noout -ext basicConstraints | grep -q 'CA:TRUE' || { echo "  intercept-ca.crt is not a CA certificate" >&2; exit 1; }; \
	printf '\n' >> "$$tmp/ca-certificates.crt"; \
	cat "$$tmp/intercept-ca.crt" >> "$$tmp/ca-certificates.crt"; \
	ln -sfn ca-certificates.crt "$$tmp/ca-bundle.crt"; \
	docker volume create "$(TRUST_VOLUME)" >/dev/null; \
	tar -C "$$tmp" -cf - ca-certificates.crt ca-bundle.crt | docker run -i --rm -v "$(TRUST_VOLUME):/trust" --entrypoint sh "$(HELPER_IMAGE)" \
	  -c 'rm -f /trust/ca-certificates.crt /trust/ca-bundle.crt && tar -xf - -C /trust'; \
	docker run --rm -v "$(TRUST_VOLUME):/trust:ro" --entrypoint cat "$(HELPER_IMAGE)" /trust/ca-certificates.crt | cmp -s - "$$tmp/ca-certificates.crt" \
	  || { echo "  readback of $(TRUST_VOLUME) does not match the bundle" >&2; exit 1; }; \
	echo "  wrote $(TRUST_VOLUME): ca-certificates.crt (base roots + intercept-ca) and ca-bundle.crt"

# ── Compose ───────────────────────────────────────────────────────────────────

# compose.extra.yml is added only when SANDBOX_PI and SANDBOX_CHEZMOI are both set (environment or .env).
# RECREATE=1 (any non-empty value) adds --force-recreate to up.
COMPOSE_FILES = -f compose.yml$(if $(and $(or $(SANDBOX_PI),$(call dotenv,SANDBOX_PI)),$(or $(SANDBOX_CHEZMOI),$(call dotenv,SANDBOX_CHEZMOI))), -f compose.extra.yml)
RECREATE_FLAG = $(if $(RECREATE),--force-recreate)

## up: Start the sandbox stack detached with docker compose (RECREATE=1 to force recreate)
up:
	docker compose $(COMPOSE_FILES) up -d --remove-orphans $(RECREATE_FLAG)

## down: Stop and remove the sandbox stack with docker compose, including orphan containers
down:
	docker compose $(COMPOSE_FILES) down --remove-orphans

## ps: List all sandbox stack containers, including stopped ones (docker compose ps -a)
ps:
	docker compose $(COMPOSE_FILES) ps -a

# ── Help ──────────────────────────────────────────────────────────────────────

## help: Show this help
help:
	@awk '/^##/ { \
	  line=$$0; sub(/^## ?/, "", line); \
	  if (line ~ /^[a-z0-9_.-]+:/) { \
	    target=line; sub(/:.*/, "", target); \
	    desc=line; sub(/^[^:]+:[[:space:]]*/, "", desc); \
	    names[++n]=target; docs[target]=desc; \
	  } else header[++h]=line; \
	} END { \
	  for (i=1; i<=h; i++) print header[i]; \
	  for (i=1; i<=n; i++) for (j=i+1; j<=n; j++) if (names[j] < names[i]) { tmp=names[i]; names[i]=names[j]; names[j]=tmp } \
	  for (i=1; i<=n; i++) printf "  %-14s %s\n", names[i], docs[names[i]]; \
	}' $(MAKEFILE_LIST)
