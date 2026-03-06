# Stage 1: Build
FROM golang:1.22.1-alpine3.19 AS builder
WORKDIR /app

# Install git for cloning
RUN apk add --no-cache git

# 1. Optimization: Download dependencies first to leverage Docker cache
# This ensures that 'go mod download' only runs if go.mod or go.sum changes.
RUN git clone https://github.com/containous/foobar-api.git .
RUN go mod download 

# 2. Build: Static binary for high portability
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o foobar-api . 

# Stage 2: Final Image
FROM alpine:3.19
RUN apk add --no-cache ca-certificates 

# 3. Security: Implement non-root execution
RUN addgroup -S appgroup && adduser -S appuser -G appgroup 
USER appuser
WORKDIR /home/appuser/

# Copy the binary from the builder stage
COPY --from=builder /app/foobar-api . 

EXPOSE 8080 [cite: 4]
ENTRYPOINT ["./foobar-api"] [cite: 4]