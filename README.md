# server-infra

Config for one Ubuntu 24.04 VPS that hosts many apps behind one Traefik, with one monitoring stack. No panel: each app deploys with plain `docker compose` from its own repo on a push to `main`. It runs well on 4 vCPU and 8 GB RAM.

What you get:

- Traefik with Let's Encrypt TLS, HTTP/3, secure headers, compression, and rate limits.
- Prometheus, Grafana, Loki, Tempo, and Alloy: metrics, logs, traces, and browser telemetry, with dashboards and alert rules.
- Push to deploy: GitHub Actions sends the commit over SSH, the server builds it, waits for healthy, and rolls back on a failure.
- Host hardening: ufw that Docker cannot bypass, fail2ban, key-only SSH, unattended upgrades, swap, and log limits.
- Nightly Postgres and data backups, 7 days.

## Quick start

1. On a fresh Ubuntu 24.04 server, add your SSH key, then:

   ```sh
   sudo git clone https://github.com/Taha-daboussi/server-infra /srv/infra
   sudo ADMIN_USER="$USER" /srv/infra/host/setup.sh
   ```

2. Start Traefik: `cd /srv/infra/traefik && sudo docker compose up -d`.
3. Configure and start the monitoring stack:

   ```sh
   cd /srv/infra/monitoring
   sudo install -m 600 .env.example .env        # then set your domains
   sudo install -d -m 700 secrets
   openssl rand -base64 24 | sudo tee secrets/grafana_admin_password >/dev/null
   sudo docker compose --env-file .env up -d
   ```

4. Point the DNS of `GRAFANA_DOMAIN` and `TELEMETRY_DOMAIN` to the server. With no domain yet, use `<name>.<ip with dashes>.sslip.io`.
5. Add your apps (see "Add an app").

## Layout on the server

| Path | What |
|---|---|
| `/srv/infra` | This repo (root owned, read only for apps) |
| `/srv/infra/traefik` | Traefik and the Docker socket proxy (project `traefik`) |
| `/srv/infra/monitoring` | Prometheus, Grafana, Loki, Tempo, Alloy, cAdvisor, node-exporter (project `monitoring`) |
| `/srv/apps/<app>/repo` | The app checkout, at the deployed commit |
| `/srv/apps/<app>/.env` | The app env file, mode 600 |
| `/srv/apps/<app>/secrets/` | Files mounted as compose secrets |
| `/srv/apps/<app>/data/` | Bind mounts that must survive (uploads, crawler state). Backed up nightly |
| `/srv/apps/<app>/.deployed` | The commit that runs now |
| `/srv/grafana/dashboards/<app>/` | The app dashboards, copied from `deploy/dashboards/` on each deploy |
| `/srv/backups/<date>/` | Nightly `pg_dump` and `data/` archives, 7 days |
| `/var/log/traefik/access.log` | JSON access log, rotated daily |

## Networks

- `edge` (172.30.0.0/24, external): Traefik is `172.30.0.10`. Put each public service on it with Traefik labels.
- `socket` (internal): only the socket proxy, Traefik and Alloy. Nothing else gets the Docker socket.
- `monitoring` (bridge `br-mon`, 172.31.0.0/24): the monitoring stack. node-exporter runs on the host network and listens on `172.31.0.1:9100`.
- Each app keeps its database and cache on its own internal network.

Docker publishes ports past ufw. The `DOCKER-USER` rules in `host/ufw-docker.rules` stop that: only the `ufw route allow` rules to `172.30.0.10` on 80 and 443 reach a container from outside. Never publish a container port on `0.0.0.0`; bind to `127.0.0.1` if you need a local port.

DNS trap: compose adds the service name as an alias on every network of the service, also on `edge`. Two apps with a service called `backend` on `edge` resolve to each other. Inside an app, call your own services on the app internal network, and never call another app by a bare service name.

## Add an app

1. In the app repo, add `deploy/compose.yml`:
   - `name: <app>`.
   - Image names `<app>-<service>:${IMAGE_TAG:-local}`. The deploy prunes old tags by this pattern.
   - A `healthcheck` and a `mem_limit` on each service. The deploy waits for healthy.
   - Paths under `${APP_DIR}` for data and secrets.
   - Public services on the external `edge` network with `traefik.enable: "true"` and a router on the `websecure` entrypoint.
   - The label `infra.backup.postgres: <db name>` on a Postgres service to back it up.
   - Optional: dashboards in `deploy/dashboards/*.json`. Use the datasource uids `prometheus`, `loki`, `tempo`.
2. Point the DNS A record of each domain to the server IP.
3. On the server: `sudo /srv/infra/bin/add-app <app> <owner/repo>`. It makes a read-only deploy key and a GitHub Actions key. Add the read key to the repo (`gh repo deploy-key add`) and run it again to clone.
4. Fill `/srv/apps/<app>/.env` and `/srv/apps/<app>/secrets/`.
5. In the repo, set the secrets `DEPLOY_SSH_KEY` (the content of `/home/deploy/.ssh/gha-<app>`) and `DEPLOY_KNOWN_HOSTS` (`ssh-keyscan -t ed25519 <server-ip>`), and the variable `DEPLOY_HOST`.
6. Add `.github/workflows/deploy.yml` that runs `ssh deploy@$DEPLOY_HOST "$GITHUB_SHA"`. The key can only run `bin/deploy <app>`.
7. First deploy by hand: `sudo -u deploy /srv/infra/bin/deploy <app> <sha>`.

## Deploy

`bin/deploy <app> <sha>` (or the sha from the forced SSH command):

1. Takes a lock, so deploys of one app never overlap.
2. Fetches `main` and refuses a commit that is not on it.
3. Checks out the commit, builds the images on the server, and runs `up -d --wait`.
4. On a failure, prints the logs and goes back to the last good commit.
5. Copies the dashboards and prunes old images and build cache.

Each step logs to the journal with the tag `deploy`. The "Server overview" dashboard shows them.

## Monitoring

Grafana: `https://$GRAFANA_DOMAIN`, user `admin`, password in `/srv/infra/monitoring/secrets/grafana_admin_password`.

| Dashboard | Shows |
|---|---|
| Server overview | Host CPU, RAM, disk, swap; CPU and RAM by project; memory against the limit; requests, bytes, 5xx, and p95 by domain and router; TLS days left; deploy, backup, and error logs |
| Node Exporter Full | Every host metric |
| Traefik | Entrypoints, routers, services |
| Apps folder | The dashboards of each app |

Alert rules are in `monitoring/grafana/provisioning/alerting/rules.yaml`. No contact point is set yet, so alerts show only in Grafana (Alerting, Alert rules).

Browser telemetry (Grafana Faro): Alloy has one receiver for each app, behind `https://$TELEMETRY_DOMAIN`. Each receiver sets its own `service_name` and CORS origins (in `monitoring/.env`). The two receivers below are the apps on our server. For your apps, copy one `faro.receiver` block in `monitoring/alloy/config.alloy`, its env variable and Traefik labels in `monitoring/compose.yml`, and give it a free port.

| App | Public path | Alloy port | CORS variable |
|---|---|---|---|
| sheout | `/collect` | 12347 | `FARO_CORS_ORIGINS` |
| meherb | `/meherb/collect` (Traefik removes `/meherb`) | 12348 | `MEHERB_FARO_CORS_ORIGINS` |

Logs in Loki: `{job="docker", project="<app>"}` for containers, `{job="traefik"}` for the access log, `{job="journal"}` for the host (sshd, deploy, backup).

Traefik dashboard: `ssh -L 8080:127.0.0.1:8080 <admin>@<server-ip>`, then open http://localhost:8080.

## Host setup

`host/setup.sh` makes a fresh Ubuntu 24.04 match this server: Docker, the daemon log limits, ssh hardening, ufw with the Docker rules, fail2ban, swap, journald size, logrotate, the `deploy` user, `/srv`, the `edge` network, and the backup timer. Run it as root after you add your SSH key, with `ADMIN_USER` set to your SSH login user: `sudo ADMIN_USER=<you> host/setup.sh`. It is safe to run again.

## Update the stacks

```sh
cd /srv/infra/traefik && sudo docker compose up -d
cd /srv/infra/monitoring && sudo docker compose --env-file .env up -d
```

`monitoring/.env` is mode 600 and root owned, so the monitoring command needs `sudo`.

## Known problems

- Tempo (all versions since 2.9) and the prebuilt `sharp` binary need a CPU with x86-64-v2 or newer. They stop with "requires v2 microarchitecture" on the generic "QEMU Virtual CPU version 2.5+" model. On a new VPS, check that `grep -c sse4_2 /proc/cpuinfo` is not 0. If it is 0, ask the provider for the host CPU model (host-passthrough).
