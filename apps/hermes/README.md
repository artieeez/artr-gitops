# apps/hermes — Hermes Agent

[Hermes Agent](https://hermes-agent.nousresearch.com) (Nous Research), image
`nousresearch/hermes-agent` (pinned in `deployment.yaml`). Model: DeepSeek.

| Surface | How |
| --- | --- |
| Dashboard | `https://hermes.artr.com.br` — Tinyauth (Pocket ID, group `admin`) **then** Hermes native OIDC (Pocket ID) |
| Slack | Socket Mode (outbound WebSocket, no ingress); only `SLACK_ALLOWED_USERS` may talk to it |
| GitHub | Remote MCP `api.githubcopilot.com/mcp/` + `GH_TOKEN` (fine-grained PAT, artieeez repos, read/write) |
| Linear | Remote MCP `mcp.linear.app/mcp` with `LINEAR_API_KEY` |
| Grafana | `grafana-mcp` sidecar (127.0.0.1:8000), Viewer service account, `--disable-write` |
| kubectl | Read-only ServiceAccount `hermes` (`view` + `hermes-read-extra`; no Secrets, no exec) |
| Webhooks | `https://hermes.artr.com.br/webhooks/<route>` → listener :8644, no Tinyauth; each route's HMAC secret is the gate |

## Webhooks

Routes are created in the dashboard (not in `configmap.yaml`). The dashboard
shows `http://localhost:8644/webhooks/<route>` — that is the in-pod address;
give senders `https://hermes.artr.com.br/webhooks/<route>` instead.

Linear (`linear-push`):

1. Linear → Settings → API → Webhooks → new webhook, URL
   `https://hermes.artr.com.br/webhooks/linear-push`, data change events:
   **Comments** only. Copy Linear's **signing secret**.
2. In the Hermes route: signature `linear`, secret = that signing secret
   (Linear generates it; a Hermes-generated secret won't match).
3. Template the payload into the prompt — a prompt without `{…}` fields
   sends only the literal text, e.g.:

   ```text
   Follow the instructions in this Linear comment.
   Issue: {data.issue.title} — {url}
   Author: {data.user.name}
   Comment: {data.body}
   ```

Payload text is untrusted: anyone who can comment in the workspace can
instruct the agent, which holds a GitHub write token.

Check delivery: Linear's webhook page shows response codes (`404` = bad
signature or unknown route).

## Bootstrap (once, before the first push)

1. **Pocket ID** → OIDC Clients → new client `hermes`:
   - **Public client** on, PKCE on (Hermes does not support client secrets)
   - Callback URL: `https://hermes.artr.com.br/auth/callback`
   - Allowed user groups: `admin` — Hermes has no user allowlist of its own;
     anyone Pocket ID admits gets full dashboard access
   - Copy the client ID → `HERMES_DASHBOARD_OIDC_CLIENT_ID`
2. **Slack** → create app (from scratch) → enable **Socket Mode** → app-level
   token with `connections:write` (`xapp-…`, `SLACK_APP_TOKEN`). Bot scopes per
   the [Hermes Slack guide](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/slack)
   (at least `app_mentions:read`, `chat:write`, `im:history`, `im:read`,
   `im:write`, `channels:history`), subscribe to `app_mention` + `message.im`,
   install → bot token (`xoxb-…`, `SLACK_BOT_TOKEN`). Your member ID
   (profile → ⋯ → Copy member ID) → `SLACK_ALLOWED_USERS` (comma-separated).
3. **GitHub** → fine-grained PAT, owner `artieeez`, all repos (or selected),
   permissions: Contents, Issues, Pull requests, Actions = read/write;
   Metadata = read → `GH_TOKEN`.
4. **Linear** → Settings → Security & access → Personal API key → `LINEAR_API_KEY`.
5. **Grafana** → Administration → Service accounts → `hermes`, role **Viewer**
   → token → `GRAFANA_SERVICE_ACCOUNT_TOKEN`.
6. **DeepSeek** → API key → `DEEPSEEK_API_KEY`.
7. Seal everything (prompts for each value, never echoed):

   ```bash
   ./scripts/seal-hermes-secrets.sh
   ```

Then commit `apps/hermes/hermes-secrets-sealed.yaml` with the rest and push.

## Rotating a key

```bash
./scripts/seal-hermes-secrets.sh LINEAR_API_KEY        # one or more key names
# commit + push, then:
kubectl rollout restart deployment/hermes -n hermes
```

## Verify

```bash
kubectl -n hermes get pods                     # 2/2 Running
kubectl -n hermes exec deploy/hermes -c hermes -- hermes doctor
kubectl -n hermes exec deploy/hermes -c hermes -- hermes status --full
kubectl -n hermes exec deploy/hermes -c hermes -- kubectl auth can-i get secrets -A   # must be "no"
```

In Slack, DM the bot: *"list pods in sitio-production and the 5xx count from
Loki over the last hour"* — that exercises Slack, kubectl and Grafana at once.

## Notes

- **Config is GitOps-managed:** `configmap.yaml` is copied over
  `/opt/data/config.yaml` on every boot. Changes made in the dashboard or via
  `hermes config set` are lost on restart — port them to the ConfigMap.
- **SQLite on NFS:** `database.journal_mode: delete` (WAL breaks on NFS). Keep
  `replicas: 1` / `Recreate` — Slack also allows only one Socket Mode connection.
- **`dashboard.trusted_proxies`** must contain Traefik's pod IP (default
  `10.244.0.0/16`); check with `kubectl get pod -n traefik -o wide`.
- **Linear MCP auth:** if `hermes doctor` shows `linear` failing with 401, drop
  the `headers` block in `configmap.yaml` and complete the OAuth flow once via
  `kubectl exec … hermes mcp` — the token persists on the PVC.
- The agent's terminal tool runs inside this container (`local` backend), so
  the container *is* the sandbox; its only cluster power is the read-only SA.
