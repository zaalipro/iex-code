# IexCode deployment

This records the reviewed `iex.llmotions.com` deployment on SSH alias `hostkey`.
It is intentionally narrow: do not use it for AccessGate, other nginx sites, other
containers, DNS, firewall changes, data migration, or SSH/server credential changes.

## Deployed release

- Source: `9475da59a0c238c1e069232cfd36f47fbc977e03`
- Image: `iex-code:9475da59a0c238c1e069232cfd36f47fbc977e03`
- Host bind: `127.0.0.1:14052`
- State: `/var/lib/iex-code-web`
- Workspaces: `/srv/iex-code-workspaces`
- Private env: `/etc/iex-code-web/app.env`
- Owner delivery: `/etc/iex-code-web/owner-credential.txt` (root `0600`, do not read into logs)
- Certificate config: `/etc/iex-code-web/acme`
- ACME webroot: `/var/www/certbot/iex-code`

The release was staged from `git archive` of the reviewed commit. On 2026-10-11 the app
container was healthy, 35 migrations were applied, and the packaged bounded-directory
helper had been invoked inside the image under limits of 16 entries, 4,096 output bytes,
and five seconds. All eight inspected application tables still had zero rows after the
anonymous checks. Do not rebuild or reinitialize this release.

The trusted certificate covers exactly `iex.llmotions.com`, expires on 2027-01-09,
and was verified without a TLS exception. Owner login and the native-tool flow remain
**pending private user credential entry**, not passed deployment validation.

## Certificate and nginx commands

Issuance is already complete; do not register or issue again to resume validation.
The commands below show the scoped operations used on `hostkey`. `ACME_CONTACT`
represents the approved operator contact, deliberately omitted here. The exact
executed commands and guarded nginx phases are retained in the mission's
`runtime/deployment/tls-continuation.py`.

```sh
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes hostkey \
  'certbot --version'

certbot --config-dir /etc/iex-code-web/acme/config \
  --work-dir /etc/iex-code-web/acme/work \
  --logs-dir /etc/iex-code-web/acme/logs \
  certonly --webroot --webroot-path /var/www/certbot/iex-code \
  --cert-name iex.llmotions.com --domain iex.llmotions.com \
  --email "$ACME_CONTACT" --agree-tos --non-interactive

certbot --config-dir /etc/iex-code-web/acme/config \
  --work-dir /etc/iex-code-web/acme/work \
  --logs-dir /etc/iex-code-web/acme/logs \
  renew --non-interactive --cert-name iex.llmotions.com \
  --dry-run --run-deploy-hooks

nginx -t
systemctl reload nginx
systemctl is-enabled iex-code-cert-renew.timer
systemctl is-active iex-code-cert-renew.timer
systemctl is-enabled certbot.timer
systemctl is-active certbot.timer
```

`is-enabled` and `is-active` return nonzero for disabled/inactive units. Treat these
as expected metadata for the package-global timer, not an instruction to enable it.

The HTTP site has one exception for `/.well-known/acme-challenge/`; all other
anonymous HTTP requests redirect to HTTPS. The HTTPS site proxies only to
`127.0.0.1:14052`. The deploy hook runs `nginx -t` and then performs a graceful reload.
The scoped timer is enabled/active and the package-global timer is disabled/inactive.
Existing nginx site metadata and unrelated container identities were unchanged.
The scoped service runs:

```sh
/usr/bin/certbot renew --non-interactive --cert-name iex.llmotions.com \
  --config-dir /etc/iex-code-web/acme/config \
  --work-dir /etc/iex-code-web/acme/work \
  --logs-dir /etc/iex-code-web/acme/logs
```

`iex-code-cert-renew.timer` runs daily with a randomized delay of up to 12 hours and
`Persistent=true`. Its root-only deploy hook is
`/etc/iex-code-web/acme/config/renewal-hooks/deploy/10-iex-nginx-reload`.

## Validation

Readiness is checked directly, without following a login redirect:

```sh
curl --fail --silent https://iex.llmotions.com/health/ready
```

Expected public results:

- `/health/ready`: `200 ok`
- `/login`: `200`
- protected HTTP and report routes: `302 /login`
- websocket and longpoll handshake/poll/send without an owner session: `403`
- plain HTTP: `301` to the exact HTTPS hostname

The owner must enter the private generated credential in a fresh browser. After login,
use only the deployment-owned synthetic smoke workspace and invoke one harmless
authorized `read_file` or `grep_search` operation. Do not use production/user content,
paid model calls, or the credential delivery file as application input. If the private
entry is unavailable, leave the app deployed and report the login/tool validation as
pending rather than generating replacement credentials.

The prepared fixture is `/srv/iex-code-workspaces/smoke/README.md` on the host,
visible as `/workspaces/smoke/README.md` inside the application container. Its only
line is `IexCode deployment smoke fixture: read-only validation.` No application
project/session/run has yet been created for it.
