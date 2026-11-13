# syntax=docker/dockerfile:1

ARG ELIXIR_IMAGE=hexpm/elixir:1.17.3-erlang-27.1.2-debian-bookworm-20241016-slim
ARG RUNNER_IMAGE=debian:bookworm-slim

# ---------------------------------------------------------------------------
# Build stage
# ---------------------------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS build

ENV MIX_ENV=prod \
    LANG=C.UTF-8

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       build-essential \
       ca-certificates \
       git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

RUN mkdir -p config
COPY config/config.exs config/prod.exs config/runtime.exs config/

RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY rel rel

RUN mix compile
RUN mix release

# ---------------------------------------------------------------------------
# Runner stage
# ---------------------------------------------------------------------------
FROM ${RUNNER_IMAGE} AS runner

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    HOME=/app \
    PORT=4000

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates \
       libncurses6 \
       libstdc++6 \
       locales \
       openssl \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# The release is immutable at runtime. Give the unprivileged account ownership
# of the application directory and run every BEAM process as `nobody`.
RUN chown nobody /app

COPY --from=build --chown=nobody:root /app/_build/prod/rel/marrylocal ./

RUN chmod +x /app/bin/*

USER nobody

EXPOSE 4000

# rel/overlays/bin/server runs Marrylocal.Release.migrate/0 before starting
# the Phoenix endpoint, so a container never serves traffic on an old schema.
CMD ["/app/bin/server"]
