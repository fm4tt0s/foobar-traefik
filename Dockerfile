# secure multi-stage build: optimizing for minimal attack surface and build-cache efficiency
# stage 1 build
FROM golang:1.22.1-alpine3.19 AS builder
WORKDIR /app

# install git
RUN apk add --no-cache git

# optimization: download dependencies first to leverage Docker cache
RUN git clone https://github.com/containous/foobar-api.git .
RUN go mod download

# build: static binary for high portability
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o foobar-api .

# stage 2 final image
FROM alpine:3.19
RUN apk add --no-cache ca-certificates

# security: implement non-root execution
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser
WORKDIR /home/appuser/

# copy the binary from the builder stage
# COPY --from=builder /app/foobar-api .
COPY --from=builder /app/ .

EXPOSE 8080
ENTRYPOINT ["./foobar-api"]