# Build the single Nocturne server binary, then run it on a tiny base that has CA roots (needed for APNs TLS).
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -ldflags "-s -w" -o /nocturne-server .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /nocturne-server /usr/local/bin/nocturne-server
VOLUME /data
ENV DATA_DIR=/data PORT=8990
EXPOSE 8990
ENTRYPOINT ["/usr/local/bin/nocturne-server"]
