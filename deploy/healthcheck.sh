#!/bin/sh
# Container healthcheck. This repo has no /health/ready endpoint yet, so a
# successful render of the homepage (following the login redirect) counts as
# healthy. If HealthController is added later, point this at /health/ready.
set -eu

exec curl --fail --silent --show-error --location \
  --connect-timeout 2 --max-time 4 \
  http://127.0.0.1:4000/ >/dev/null
