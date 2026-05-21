FROM golang:1.26-alpine AS builder
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/fieldworksdiary .

FROM alpine:3.23
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=builder /out/fieldworksdiary /app/fieldworksdiary
EXPOSE 8090
CMD ["/app/fieldworksdiary", "serve", "--http=0.0.0.0:8090"]
