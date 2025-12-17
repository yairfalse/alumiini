# Stage 1: Build Rust binary
FROM rust:1.83-alpine AS rust-builder

RUN apk add --no-cache musl-dev openssl-dev openssl-libs-static pkgconfig

WORKDIR /build

# Copy Rust project
COPY nopea-git/Cargo.toml nopea-git/Cargo.lock* ./nopea-git/
COPY nopea-git/src ./nopea-git/src

# Build Rust binary
WORKDIR /build/nopea-git
RUN cargo build --release

# Stage 2: Build Elixir release
FROM elixir:1.16-alpine AS elixir-builder

RUN apk add --no-cache build-base git

WORKDIR /build

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Set environment
ENV MIX_ENV=prod

# Copy mix files
COPY mix.exs mix.lock ./

# Get dependencies
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy Rust binary from rust-builder
COPY --from=rust-builder /build/nopea-git/target/release/nopea-git ./priv/

# Copy source code
COPY lib ./lib
COPY config ./config

# Compile and build release
RUN mix compile
RUN mix release

# Stage 3: Runtime image
FROM alpine:3.19

RUN apk add --no-cache \
    libstdc++ \
    openssl \
    ncurses-libs \
    ca-certificates \
    git \
    openssh-client

WORKDIR /app

# Copy Elixir release
COPY --from=elixir-builder /build/_build/prod/rel/nopea ./

# Copy Rust binary to priv directory
COPY --from=rust-builder /build/nopea-git/target/release/nopea-git ./lib/nopea-*/priv/

# Create repos directory
RUN mkdir -p /tmp/nopea/repos

# Set environment
ENV HOME=/app
ENV RELEASE_COOKIE=nopea_cookie

# Expose port
EXPOSE 4000

# Run the application
CMD ["bin/nopea", "start"]
