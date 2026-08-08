# Sitio App Observability

Rails domain/ops events → OTLP → Alloy → Loki → Grafana folders **Sitio Staging** / **Sitio Production**. Complements in-app AuditLog / Wix inbox / share-link access rows; does not replace them.

**Related:** AD-021 (sitio-rails `.specs/STATE.md`) · Deployments: `apps/sitio-{staging,production}/sitio-rails/deployment.yaml` · Dashboards/alerts: [kube-prometheus-stack-values.yaml](../charts/kube-prometheus-stack-values.yaml) · Slack webhook: [alertmanager-slack-setup.md](alertmanager-slack-setup.md)

---

## Pipeline

| Step | Detail |
| --- | --- |
| Emit | `Rails.event.notify` at domain boundaries (no custom logger wrapper) |
| Export | `Observability::OtlpLogSubscriber` when `OTEL_EXPORTER_OTLP_ENDPOINT` is set |
| Alloy | Service `alloy.monitoring.svc.cluster.local:4318` (OTLP HTTP) |
| Loki labels | Alloy promotes `service.name` → `service_name`, `service.namespace` → `service_namespace` |
| Grafana | Folders **Sitio Staging** / **Sitio Production** (providers `sitio-staging`, `sitio-production`) |

### Expected Deployment env

| Variable | Staging | Production |
| --- | --- | --- |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://alloy.monitoring.svc.cluster.local:4318` | same |
| `OTEL_SERVICE_NAME` | `sitio-rails` | same |
| `OTEL_RESOURCE_ATTRIBUTES` | `service.namespace=sitio-staging` | `service.namespace=sitio-production` |

Without the endpoint, the Rails subscriber does not register (local/test stay quiet).

---

## Event catalog

Never log CPF, payment amounts, passwords, JWT, or raw webhook bodies.

| Event | When | Key payload fields |
| --- | --- | --- |
| `admin.mutated` | After successful AuditLog write | `actor_id`, `actor_email`, `action`, `resource`, `ip`, `status` |
| `wix.webhook_ingested` | Webhook accepted | `event_type`, `wix_event_id`, `outcome: ok` |
| `wix.webhook_rejected` | Auth/parse failure | `outcome: unauthorized\|bad_request`, optional `reason` |
| `wix.event_processed` | `process_now` success | `wix_event_id`, `event_type`, `kind`, `outcome: ok` |
| `wix.event_failed` | Final discard / `mark_failed` | `wix_event_id`, `event_type`, `outcome: failed`, `error_class` |
| `wix.api_error` | Outbound `Wix::Client` non-success (incl. missing API key) | `operation`, `outcome: error`, `status` (nullable), `error_class` — no response body |
| `share_link.opened` | Active link access | `share_link_id`, `trip_id`, `outcome: ok` |
| `share_link.denied` | Revoked or unknown token | `share_link_id` (nullable), `trip_id` (nullable), `outcome: revoked\|unknown_token` |
| `auth.login_failed` | Bad credentials | `outcome: failed`, `email_present` (no password/email) |
| `http.request_finished` | Status ≥400 **or** duration ≥2000ms | `controller`, `action`, `status`, `duration_ms`, `outcome: client_error\|server_error\|slow` |
| `job.finished` | Job discarded or unhandled failure | `job_class`, `outcome: discarded\|failed`, `executions`, `error_class` |

---

## LogQL cheat sheet

OTLP → Loki JSON nests payload under `attributes.*`. After `| json`, use `attributes_event` (not top-level `event`).

```logql
{service_name="sitio-rails"} | json | attributes_event="admin.mutated"
{service_name="sitio-rails"} | json | attributes_event=~"wix\\..*"
{service_name="sitio-rails"} | json | attributes_event="wix.api_error"
{service_name="sitio-rails"} | json | attributes_event="wix.event_failed"
{service_name="sitio-rails"} | json | attributes_event=~"share_link\\..*"
{service_name="sitio-rails"} | json | attributes_event="auth.login_failed"
{service_name="sitio-rails"} | json | attributes_event="http.request_finished"
{service_name="sitio-rails"} | json | attributes_event="http.request_finished" | attributes_outcome="client_error"
{service_name="sitio-rails"} | json | attributes_event="job.finished" | attributes_job_class="Wix::ProcessEventJob"
{service_name="sitio-rails", service_namespace="sitio-staging"} | json
{service_name="sitio-rails", service_namespace="sitio-production"} | json
```

Grafana Explore → Loki datasource (`uid: loki`).

---

## Grafana folders Sitio Staging / Sitio Production

Each env folder has five dashboards (app boards default range last 6h; backup last 24h). LogQL filters on `service_namespace=sitio-staging` or `sitio-production`; backup panels filter Prometheus `namespace` the same way. Each dashboard opens with an **About this dashboard** text panel (tracked signals, Slack alerts, Explore filters).

1. **SQLite backups** — hours since last success + Failed Job count
2. **Admin actions** — `admin.mutated` rate + logs
3. **Wix / webhooks** — ingest ok/rejected; processed/failed; Wix logs
4. **Share-link visitors** — opens vs denials
5. **Request & jobs** — `http.request_finished`, `auth.login_failed`, `job.finished` (incl. Wix job)

Open: https://grafana.artr.com.br → **Sitio Staging** or **Sitio Production**.

---

## Alerts (Grafana LogQL → Slack)

Provisioned under `grafana.alerting` in [kube-prometheus-stack-values.yaml](../charts/kube-prometheus-stack-values.yaml) as **nested YAML maps** (not `|` strings — the Grafana Helm chart requires maps for `alerting.*`). These are **Grafana Unified Alerting** rules (not Alertmanager PrometheusRules).

Sensitive “any occurrence” rules (spike/sustained rules removed). Each signal has a **Staging** and **Production** instance (`service_namespace` filter + `env` label).

| Alert | Condition | `for` | Severity |
| --- | --- | --- | --- |
| `SitioRailsWixIntegrationError{Staging\|Production}` | ≥1 `wix.event_failed`, `wix.webhook_rejected`, or `wix.api_error` in 5m | 1m | warning |
| `SitioRailsShareLinkDenied{Staging\|Production}` | ≥1 `share_link.denied` in 5m (typo token or revoked/stale) | 1m | warning |
| `SitioRailsAppError{Staging\|Production}` | ≥1 HTTP 4xx/5xx or `job.finished` `failed\|discarded` in 5m | 5m (anti-flap) | warning |

Not alerted: slow-only requests (`outcome=slow`). Login failures are on the Request & jobs board but not paged.

**Media upload tip:** a Wix key without Media Manager permission fails `generate-upload-url` with Wix **403**. Rails remaps that to HTTP **502** (`WixClientErrors`) while emitting `wix.api_error` with `status=403` and `operation=generate_file_upload_url`. Look for both signals; the UI error text often quotes Wix's 403 even though the Sitio response status is 502.

### Slack contact point

Contact point `slack-sitio` + notification policy (`team=sitio`) are provisioned. Webhook URL comes from env `SITIO_GRAFANA_SLACK_WEBHOOK_URL`, sourced via `envValueFrom` from Secret `alertmanager-slack-webhook` key `slack-api-url` (same SealedSecret as Alertmanager — see [alertmanager-slack-setup.md](alertmanager-slack-setup.md)).

**If Slack does not fire after sync:**

1. Confirm Secret exists: `kubectl -n monitoring get secret alertmanager-slack-webhook`
2. Confirm Grafana pod has the env: `kubectl -n monitoring exec deploy/monitoring-kube-prometheus-stack-grafana -c grafana -- printenv SITIO_GRAFANA_SLACK_WEBHOOK_URL`
3. Grafana UI → Alerting → Contact points → `slack-sitio` has a non-empty URL (provisioning expands `${SITIO_GRAFANA_SLACK_WEBHOOK_URL}`)
4. If chart `envValueFrom` did not mount the secret, create the contact point manually in UI with the same Incoming Webhook URL, keep receiver name `slack-sitio`, and leave the GitOps policy matchers as-is

### Silence / resolve

- Silence from Grafana Alerting → Silences (match `alertname` or `team=sitio`)
- Rules use `disableResolveMessage: false` on the Slack receiver — resolve notifications should post when the condition clears

---

## Smoke after deploy

1. Staging pod has OTEL env; Alloy reachable on `:4318`
2. Trigger one admin mutation, one share-link open, one failed login
3. Explore Loki: `{service_name="sitio-rails", service_namespace="sitio-staging"} | json`
4. Open each dashboard panel under **Sitio Staging** (and spot-check **Sitio Production**)
5. Optionally force one staging share-link denial, Wix reject, or 5xx and confirm Slack (+ resolve when clear)
