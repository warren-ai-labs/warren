FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY relayassets.go ./
COPY Web/dist ./Web/dist
COPY RelayService ./RelayService
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/warren-relay ./RelayService/cmd/warren-relay

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/warren-relay /warren-relay
VOLUME ["/data"]
ENV WARREN_RELAY_LISTEN=:8080
ENV WARREN_RELAY_DATA=/data/registry.json
ENV WARREN_RELAY_TUNNEL_BASE_DOMAIN=tunnel.local
EXPOSE 8080
ENTRYPOINT ["/warren-relay"]
