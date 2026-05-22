FROM golang:1.26.3-alpine AS builder
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/fieldworksdiary .

FROM alpine:3.23.4
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
