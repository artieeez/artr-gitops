# apps/coding-box — personal dev box

Two pods (`coding-box` and `coding-box-2`) in namespace `coding-box`, image
`coding-box` (built by [artieeez/coding-box](https://github.com/artieeez/coding-box),
formerly `pi-cloud`), placed on separate nodes (`podAntiAffinity` on
`coding-box-2` against `app: coding-box`) and reached only over Tailscale.

| Container | Role |
| --- | --- |
| `coding-box` | `herdr-core serve` (`hc`). The Herdr apps' terminals run here, with `GH_TOKEN` and the Claude login (`CLAUDE_CODE_OAUTH_TOKEN`) |
| `ssh` | Non-root sshd (UID 10000, user `arturwebber`, key-only, port 2222). No secrets in its env; `hc connect` attaches to the `coding-box` container's herdr-core over the shared socket `/run/hc/hc.sock` |
| `postgres` | Postgres 17 on `127.0.0.1:5432`, user/password `postgres`. emptyDir with fsync off: **wiped on every restart**, for test runs only |

Init containers set up the home every boot: `artieeez/claude-config` →
`~/.claude`, `artieeez/nvim-config` → `~/.config/nvim` (LazyVim), git
identity, and the SSH keys.

## Storage

PVCs `coding-box-data` and `coding-box-2-data` (NFS, Retain, one per instance):

- `home` → `/home/arturwebber`, the `arturwebber` user's HOME (passwd entry baked into the image)
- `workspace` → `/opt/data/workspace`, for clones and worktrees

## Postgres

Every shell has `PGHOST`, `PGUSER`, `PGPASSWORD` and `DATABASE_URL` set, so
`psql`, `createdb` and Rails work with no extra config. This is true in SSH
sessions too (`sshd_config` `SetEnv`). `CF_TEST_POSTGRES_URL` points at the
same server for code-factory's tests.

## Access

```text
Mac / phone (Tailscale) ── ssh arturwebber@coding-box ── ssh container
                                                      │ /run/hc/hc.sock (emptyDir)
                               coding-box container ── herdr-core serve
```

```bash
ssh arturwebber@coding-box                  # shell (instance 1)
ssh arturwebber@coding-box-2                # shell (instance 2)
kubectl -n coding-box exec -it deploy/coding-box -c coding-box -- bash
kubectl -n coding-box exec -it deploy/coding-box-2 -c coding-box -- bash
```

Herdr desktop and mobile apps: add the machine `coding-box.<tailnet>.ts.net`
(and/or `coding-box-2.<tailnet>.ts.net`), user `arturwebber`, port 22, then add
the app's public key as below.

## SSH keys

`~/.ssh/authorized_keys` is **replaced from the sealed Secret on every boot**.
A key added by hand inside the pod disappears on the next restart. To add a
key (for example a Herdr app's), save it to a file and run:

```bash
./scripts/seal-coding-box.sh ssh herdr-phone.pub   # keeps existing keys and the host key
```

Commit `apps/coding-box/coding-box-ssh-sealed.yaml`. After Argo CD syncs, run
`kubectl -n coding-box rollout restart deployment/coding-box deployment/coding-box-2`.

## Secrets

`scripts/seal-coding-box.sh` writes all three SealedSecrets:

| Secret | Keys |
| --- | --- |
| `coding-box-ssh` | `authorized_keys`, `ssh_host_ed25519_key(.pub)` |
| `coding-box-secrets` | `GH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`) |
| `ocir-pull` | OCIR `.dockerconfigjson` |

Rotate the tokens: `ROTATE=1 ./scripts/seal-coding-box.sh secrets` prompts for
each one (input hidden). Commit, then restart the Deployment.

## Image

Deploys are manual: in artieeez/coding-box, run Actions → "Promote coding-box
image". It rewrites every `image:` line for the coding-box image in
`deployment.yaml`. Immutable `sha-<rev>` tags use `IfNotPresent`.

## Claude Code policy

`configmap.yaml` `managed-settings.json` is mounted at
`/etc/claude-code/managed-settings.json`. It sets `bypassPermissions`, plus
deny rules for force-push, pushing to `main`, `gh pr merge`, `gh repo delete`
and `gh release`. Branch protection is the real guard.
