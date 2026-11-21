# Entwickler-Kommandos für Legulus. `make help` listet die Ziele.

# Lokaler Port, auf den der Tunnel zeigt: 8090 ist das Dev-Backend
# (`docker compose up`), 8092 die Test-Instanz der iOS-Tests.
TUNNEL_PORT ?= 8090
# Name des Tunnels auf dem sish-Server; ergibt die Subdomain, unter der
# das Gerät das Backend erreicht.
TUNNEL_NAME ?= tabularius
TUNNEL_HOST ?= legulus.app
TUNNEL_SSH_PORT ?= 2222
TUNNEL_KEY ?= $(HOME)/.ssh/legulus_tunnel

.DEFAULT_GOAL := help

.PHONY: help
help: ## Ziele auflisten
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-22s %s\n", $$1, $$2}'

.PHONY: tabularius-tunnel
tabularius-tunnel: ## SSH-Tunnel zum lokalen Backend (TUNNEL_PORT=8090 Dev, 8092 Test)
	@if ! curl -s -m 3 -o /dev/null http://127.0.0.1:$(TUNNEL_PORT)/api/health; then \
		echo "Auf 127.0.0.1:$(TUNNEL_PORT) antwortet kein Backend."; \
		echo "Dev-Backend starten: docker compose up --build"; \
		exit 1; \
	fi
	@echo "Tunnel $(TUNNEL_NAME) -> 127.0.0.1:$(TUNNEL_PORT) (Strg-C beendet ihn)"
	ssh -p $(TUNNEL_SSH_PORT) \
		-i $(TUNNEL_KEY) \
		-o IdentitiesOnly=yes \
		-o ServerAliveInterval=30 \
		-o ExitOnForwardFailure=yes \
		-R $(TUNNEL_NAME):80:127.0.0.1:$(TUNNEL_PORT) \
		$(TUNNEL_HOST)
