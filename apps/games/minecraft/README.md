# minecraft

Vanilla Minecraft **Java 1.7.10** server on the OCI cluster.

| Item | Value |
|------|-------|
| Address | `play.artr.com.br:25565` (matches the wildcard `*.artr.com.br` → NLB reserved IP) |
| Version | 1.7.10 vanilla (`TYPE=VANILLA`) |
| Namespace | `games` |
| Image | `itzg/minecraft-server:java8@sha256:70c6e30e…` |
| World | PVC `minecraft-data` (10Gi, `nfs-client`, Retain) |

## Why `java8`

Pre-1.13 servers break on JDK 9+ (`LaunchWrapper` casts the system classloader to
`java.net.URLClassLoader`, which only exists on Java 8). The `java8` tag is
multi-arch and the only correct base for 1.7.10. The digest is pinned; Renovate
tracks tag and digest together.

## Traffic path

```text
player → NLB 204.216.137.207:25565 (listener "minecraft-tcp-25565")
       → backend set "minecraft-backendset" (TCP health check on 30565)
       → node 10.0.1.226:30565 (Service NodePort)
       → pod :25565
```

The listener, backend set, backends and the NLB ingress rule for `25565` live in
`artieeez/oracle-cluster` → `modules/oke/main.tf`
(`local.minecraft_node_port = 30565`, keep it in sync with `service.yaml`).
The nodes NSG already allows `30000-32767` from anywhere, so no extra node rule
is needed. Traefik is **not** in this path.

## Sizing (single 2 OCPU / 12 GB node)

This node is the cluster's hard ceiling: ~1.5 idle cores and roughly 2.3 GiB of
reclaimable-free memory at the time of writing.

| Knob | Value | Rationale |
|------|-------|-----------|
| `MEMORY` | `1536M` | Comfortable for ~6 players on vanilla 1.7.10 |
| CPU request | `100m` | Only ~124m of node requests were free; requests gate scheduling |
| CPU limit | `1200m` | Real usage is ~0.46 cores, so bursting is safe |
| Memory request/limit | `1800Mi` / `2300Mi` | Heap + JDK 8 metaspace/off-heap headroom |
| `VIEW_DISTANCE` | `8` | 1.7.10 chunk ticking is CPU-bound; raise only after measuring TPS |

`startupProbe` allows 15 minutes for the first world generation on 2 shared
cores, and there is deliberately **no liveness probe** — a legacy server can
stall during heavy generation without being dead.

## Ops

```bash
kubectl -n games logs deploy/minecraft -f          # server console output
kubectl -n games exec deploy/minecraft -- rcon-cli list
kubectl -n games exec deploy/minecraft -- rcon-cli op <player>
kubectl -n games exec deploy/minecraft -- rcon-cli whitelist add <player>
kubectl -n games exec deploy/minecraft -- rcon-cli whitelist on
```

`rcon-cli` picks up `RCON_HOST`/`RCON_PORT`/`RCON_PASSWORD` from the pod env.
The password lives in SealedSecret `minecraft-rcon` and 25575 is never exposed
by the Service.

1.7.10 quirks worth remembering: `/kill` takes **no** arguments (passing a
player name silently resets the RCON connection), and `keepInventory` defaults
to `false`.

## Known gaps

- **No backups yet.** `minecraft-data` is annotated `Prune=false,Delete=false`
  and uses the Retain `nfs-client` class, but that only protects against Argo —
  not against a bad restart or `/kill @e`. Next step if the world matters:
  RCON `save-off` → `save-all flush` → tar → upload to the existing OCI Object
  Storage S3 endpoint (same pattern as `sitio-rails-backup`).
- **Whitelist off.** The server is public and `online-mode=true`, so only
  premium accounts can join, but anyone can build. Enable the whitelist via RCON
  once the player list is known.
- Client must also be 1.7.10; PojavLauncher needs its **JRE 8** runtime
  component installed for that version.
