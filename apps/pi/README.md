# apps/pi — pi.dev cloud box

Persistent SSH dev box running [pi](https://pi.dev) + Ruby. Image: `artieeez/pi-cloud`
(built/pushed by its GitHub Action, which bumps `deployment.yaml` here).

## Access

```bash
ssh root@pi.<tailnet>.ts.net     # via Tailscale operator Service (pi-ssh)
tmux attach -t pi
```

## Sealed secrets (namespace `pi`)

| SealedSecret | Keys | Purpose |
|---|---|---|
| `ocir-pull` | `.dockerconfigjson` | Pull `vcp.ocir.io/axtvnrdemzo7/pi-cloud` |
| `pi-secrets` | `authorized_keys`, `ssh_host_ed25519_key(.pub)`, `id_ed25519(.pub)`, `known_hosts` | sshd host keys + login keys; GitHub deploy key |
| `pi-auth` | `auth.json` | pi model auth (opencode-go, deepseek, google) — see `reseal-pi-auth.sh` |

`pi-secrets` is projected into `/secrets/ssh/*` and `/secrets/git/*` (see `deployment.yaml` items);
`pi-auth` (when added) mounts to `/secrets/pi/auth.json`. The container entrypoint assembles
these into `/root/.ssh` and `/root/.pi/agent`.

## Rotating / adding keys (e.g. a new phone)

```bash
# 1. build the plaintext Secret (same shape as pi-secrets) with the new values
# 2. reseal and replace the file (values never land in git):
kubeseal --controller-namespace=sealed-secrets --controller-name=sealed-secrets --format yaml \
  < secret.yaml > pi-secrets-sealed.yaml
# 3. commit + push; Argo syncs; restart the pod to re-project the volume.
```

To authorize a new SSH client: add its `~/.ssh/id_ed25519.pub` line to `authorized_keys`
before resealing (or append it on the PVC via `kubectl exec` and restart).

### Model keys for pi (`pi-auth`) — paste-only helper

`reseal-pi-auth.sh` adds/rotates a provider key in the `pi-auth` sealed secret
without the key ever touching the shell, history, or disk in plaintext
(`read -s` prompt → merge with the live secret → seal over stdin):

```bash
./reseal-pi-auth.sh google     # or: deepseek, opencode-go, any provider id
```

Review the diff (only the `auth.json` ciphertext line should change), confirm,
then commit + push + `kubectl rollout restart deployment/pi -n pi` (the
entrypoint re-merges auth at boot).

## Notes

- Image runs as root with key-only sshd — do **not** expose this app publicly (Tailscale only).
- `AUTO_PI=1` env boots pi inside the tmux session; default 0 (run `pi` on attach).
- Single replica (Recreate) — one box, persistent home on `pi-home` PVC (nfs-client, RWX).