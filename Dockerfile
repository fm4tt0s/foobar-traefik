# multi-stage build, non-root user
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
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# create the directory and set ownership before switching users
RUN mkdir -p /home/appuser && chown -R appuser:appgroup /home/appuser
USER appuser
WORKDIR /home/appuser/

# ensure the binary and all files copied are owned by our non-root user
COPY --from=builder --chown=appuser:appgroup /app/ .

EXPOSE 8080
ENTRYPOINT ["./foobar-api"]