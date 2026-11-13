# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.27.4-alpine AS builder
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
# VERSION/COMMIT werden vom CI-Build-Step gesetzt (siehe deploy-*.yml
# build-args) — release-please pflegt die Monorepo-weite `VERSION`-
# Datei im Repo-Root. Ohne Build-Arg (lokales `docker compose up
# --build`) bleibt es bei den version.go-Defaults ("dev"/"unknown"),
# was einen unversionierten Dev-Build absichtlich sichtbar macht statt
# ihn stillschweigend als Release auszugeben.
#
# deploy-*.yml pushen bei JEDEM Push auf main/staging, auch bei reinen
# iOS-Commits ohne Backend-Änderung — COMMIT ändert sich damit auf
# jedem Build und würde ohne Cache-Mount den kompletten go-build-Layer
# neu kompilieren lassen, obwohl der Quellcode identisch ist. Der
# BuildKit-Cache-Mount hält GOCACHE zwischen Builds warm, damit ein
# reiner Version-Bump trotzdem ein Sekunden- statt Minuten-Rebuild ist.
ARG VERSION=dev
ARG COMMIT=unknown
ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags="-s -w -X go.mett.io/fwd-backend/internal/version.Version=${VERSION} -X go.mett.io/fwd-backend/internal/version.Commit=${COMMIT}" -o /out/fieldworksdiary .

FROM alpine:3.24.3
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=builder /out/fieldworksdiary /app/fieldworksdiary
EXPOSE 8090
# Health-Probe für Container-Orchestratoren. compose-files können das
# überschreiben (siehe docker-compose.yml healthcheck-Block).
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8090/api/health >/dev/null 2>&1 || exit 1
CMD ["/app/fieldworksdiary", "serve", "--http=0.0.0.0:8090"]
# TODO(Trivy DS-0002 / docs/adr/0007): Non-root USER fehlt absichtlich
# noch — pb_data wird per Bind-Mount reingereicht (siehe
# docker-compose*.yml), und das Owner-/UID-Setup auf den Docker-
# Hosts ist heute root. Ein USER-Switch ohne abgestimmtes Host-
# Vorbereitungs-Skript würde Deploys lautlos brechen. Tracked als
# eigener Workstream.
