FROM golang:1.24-alpine AS builder
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/weevilapp .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
WORKDIR /app
COPY --from=builder /out/weevilapp /app/weevilapp
EXPOSE 8090
CMD ["/app/weevilapp", "serve", "--http=0.0.0.0:8090"]
