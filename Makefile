.PHONY: help build up down logs ps scan test clean

DC := docker compose

# versions.json is the single source of truth for the Varnish version --
# the Dockerfile has no default, so it has to be passed in.
VARNISH_VERSION := $(shell jq -r .varnish versions.json)
export VARNISH_VERSION

help:
	@echo "Cibles disponibles :"
	@echo "  make build   - Build de l'image hardenee"
	@echo "  make up      - Demarre le conteneur"
	@echo "  make down    - Arrete le conteneur"
	@echo "  make logs    - Tail des logs"
	@echo "  make ps      - Etat du conteneur"
	@echo "  make test    - Test healthcheck + cache"
	@echo "  make scan    - Scan Trivy de l'image"
	@echo "  make clean   - Supprime volumes + image"

build:
	@test -n "$(VARNISH_VERSION)" -a "$(VARNISH_VERSION)" != "null" \
	  || { echo "versions.json: .varnish illisible"; exit 1; }
	@echo "Build Varnish $(VARNISH_VERSION) (versions.json)"
	DOCKER_BUILDKIT=1 $(DC) build --pull

up:
	$(DC) up -d

down:
	$(DC) down

logs:
	$(DC) logs -f --tail=200

ps:
	$(DC) ps

test:
	./scripts/test.sh

scan:
	trivy image --severity HIGH,CRITICAL --ignore-unfixed localhost/varnish-hardened:latest

clean:
	$(DC) down -v
	docker image rm localhost/varnish-hardened:latest 2>/dev/null || true
