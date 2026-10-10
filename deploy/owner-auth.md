# Owner authentication provisioning

Run the helper as root from an interactive TTY, before restarting the app:

```sh
sudo -n /usr/local/sbin/iex-code-owner-auth-provision /etc/iex-code-web/app.env
```

The only command-line argument is the existing private env-file path. The
helper reads `IEX_CODE_AUTH_USERNAME`, the password, and its confirmation
with terminal echo disabled. It accepts usernames matching
`[A-Za-z0-9_.@-]{1,64}` and passwords of at least 15 characters and at most
1,024 UTF-8 bytes. The stored
`IEX_CODE_AUTH_PASSWORD_HASH` uses the fixed
`pbkdf2_sha256$600000$<padded-base64-salt>$<padded-base64-digest>` format
(16-byte salt, 32-byte digest).

The parent directory must be root-owned and mode `0700`-style (no group or
other permissions); the env file must be a regular, nonsymlink, private file.
The helper rejects duplicate or multiline auth entries, preserves unrelated
bytes, writes both keys as single-quoted values, and replaces the file through
a same-directory exclusive temporary file, fsync, and atomic rename. It emits
only a generic result; restart is required after successful provisioning.
Do not pass credentials as arguments, pipe them into the helper, log the
terminal, or print the private env file or rendered Compose configuration.
Catchable interruption signals restore echo through `getpass`; uncatchable
`SIGKILL`/`SIGSTOP` cannot run cleanup.

Run the synthetic, unprivileged tests independently of the Mix/ExUnit lane:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 test/deploy/owner_auth_provision_test.py -v
```
