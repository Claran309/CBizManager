FROM golang:1.25.3-alpine AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/cbizdocsmanager-api ./cmd/api

FROM alpine:3.23

RUN addgroup -S app && adduser -S -G app app
WORKDIR /app
COPY --from=builder --chown=app:app /out/cbizdocsmanager-api ./cbizdocsmanager-api
COPY --from=builder --chown=app:app /src/config ./config
USER app
EXPOSE 8080
ENTRYPOINT ["/app/cbizdocsmanager-api"]
