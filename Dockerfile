# syntax=docker/dockerfile:1.7
#
# Production image for iex-code (this repo).
#
# Built on the prod host by ./deploy.sh. No proxy stage: in production nginx
# on the host terminates TLS and proxies to the published loopback port
# (see compose.yaml). Release binary: /opt/iex-code/bin/iex_code.

ARG ELIXIR_IMAGE=elixir:1.18.4-otp-28-slim

FROM ${ELIXIR_IMAGE} AS build

ENV MIX_ENV=prod \
    LANG=C.UTF-8

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git nodejs npm python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY assets/package.json assets/package-lock.json ./assets/
RUN npm ci --prefix assets --no-audit --no-fund

COPY config ./config
COPY lib ./lib
COPY priv ./priv
COPY assets ./assets

RUN mix compile \
    && mix assets.deploy \
    && mix release --path /release

FROM ${ELIXIR_IMAGE} AS runtime

ARG APP_UID=10001
ARG APP_GID=10001

ENV HOME=/var/lib/iex-code/home \
    MIX_HOME=/var/lib/iex-code/home/.mix \
    HEX_HOME=/var/lib/iex-code/home/.hex \
    REBAR_CACHE_DIR=/var/lib/iex-code/home/.cache/rebar3 \
    LANG=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000

# Keep the coding toolchain in the runtime image. Runs and the interactive PTY
# intentionally execute Mix, Git, Python, Node, compilers, and ordinary shells
# inside mounted workspaces.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash build-essential ca-certificates curl git nodejs npm openssh-client \
      procps python3 sqlite3 tini zsh \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid "${APP_GID}" iexcode \
    && useradd --uid "${APP_UID}" --gid "${APP_GID}" --create-home \
      --home-dir /home/iexcode --shell /bin/bash iexcode \
    && mkdir -p /opt/iex-code /var/lib/iex-code/home /workspaces/default \
    && mkdir -p /opt/mix-seed \
    && MIX_HOME=/opt/mix-seed mix local.hex --force \
    && MIX_HOME=/opt/mix-seed mix local.rebar --force \
    && chown -R "${APP_UID}:${APP_GID}" \
      /opt/iex-code /opt/mix-seed /var/lib/iex-code /workspaces /home/iexcode

COPY --from=build --chown=${APP_UID}:${APP_GID} /release /opt/iex-code
COPY --chown=${APP_UID}:${APP_GID} deploy/entrypoint.sh /usr/local/bin/iex-code-entrypoint
COPY --chown=${APP_UID}:${APP_GID} deploy/healthcheck.sh /usr/local/bin/iex-code-healthcheck

RUN chmod 0555 /usr/local/bin/iex-code-entrypoint /usr/local/bin/iex-code-healthcheck

USER ${APP_UID}:${APP_GID}
WORKDIR /workspaces/default

EXPOSE 4000

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/iex-code-entrypoint"]
CMD ["/opt/iex-code/bin/iex_code", "start"]
