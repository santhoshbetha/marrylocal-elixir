# MarryLocal API — Self-Hosted Kamal 2 Deployment Guide

This guide deploys the Phoenix JSON API (`marrylocal-elixir`) to a single VPS with Kamal 2, `kamal-proxy`, and a PostgreSQL 16 + PostGIS accessory.

The React frontend is **not** part of this deployment. It ships separately through Cloudflare Wrangler to `https://marrylocal.in`. No frontend Docker image and no Nginx configuration are required here.

```text
Internet
   │  HTTPS :443
   ▼
kamal-proxy  ──►  marrylocal-api container (Phoenix, :4000)
                        │
                        ▼
                 marrylocal-api-db (PostGIS, :5432)
                        │
                        ▼
                 marrylocal_pg_data volume
```

Kamal performs blue-green container replacement:

1. Build and push a new image.
2. Start the new container next to the old one.
3. Run `bin/server`, which applies migrations with `Marrylocal.Release.migrate/0`.
4. Start Phoenix with `PHX_SERVER=true`.
5. Poll `GET /api/health` until Phoenix and PostgreSQL both answer. Migrations are applied by the boot hook before Phoenix starts.
6. Switch `kamal-proxy` traffic to the new container.
7. Stop the old container only after the new one is healthy.

If any step fails, the old container keeps serving traffic.

---

## 1. Prerequisites

### Server

- A fresh Ubuntu 22.04 or 24.04 VPS with a public IPv4 address.
- At least 2 vCPU, 4 GB RAM, and 40 GB SSD for the API plus PostgreSQL/PostGIS.
- Root or passwordless sudo over SSH.
- Your SSH public key installed for the deployment user.

### Local machine

- Kamal 2 installed:

  ```bash
  gem install kamal
  kamal version
  ```

  Use Kamal **2.x** or newer.

- Docker Desktop or another local Docker engine, because Kamal builds the image locally by default.
- Access to a private container registry.
- The repository checked out with `config/deploy.yml` and the Dockerfile.

### DNS and ports

Before the first deploy:

- `api.marrylocal.in` must resolve to the VPS public IP.
- TCP **80** and **443** must be reachable from the internet.
- TCP **22** must be reachable from your administration network for Kamal SSH.
- **Do not expose 5432 publicly.** The compose configuration binds PostgreSQL to `127.0.0.1` only, and the app reaches it over the private `kamal` Docker network.

---

## 2. Firewall configuration

On the VPS:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
sudo ufw status verbose
```

Also open 80 and 443 in your cloud provider's firewall or security group. Keep 5432 closed at both layers.

Kamal needs SSH access. If you restrict SSH by source IP, add your CI/operator egress range.

---

## 3. DNS setup

Create this record at your DNS provider:

| Type | Name | Value | TTL | Proxy |
| --- | --- | --- | --- | --- |
| A | `api` | `<VPS_PUBLIC_IP>` | 300 | DNS only (grey cloud) for the first deploy |

`api.marrylocal.in` must resolve directly to the VPS so `kamal-proxy` can complete the Let's Encrypt HTTP-01 challenge on port 80. If you enable Cloudflare's orange-cloud proxy before the certificate exists, certificate issuance can fail. After the certificate is issued, you may proxy the API through Cloudflare only if you also configure a matching origin certificate or keep the proxy's SSL mode compatible. The simplest reliable setup is DNS-only for `api`.

Verify from your local machine:

```bash
dig +short api.marrylocal.in
```

It must return the VPS IP before you run `kamal setup`.

---

## 4. Private container registry

`config/deploy.yml` expects:

```yaml
image: marrylocal/marrylocal-api
registry:
  server: registry.example.com
  username: marrylocal
  password:
    - KAMAL_REGISTRY_PASSWORD
```

Create a private repository named `marrylocal/marrylocal-api` on your registry. Replace `registry.example.com` and the username with your real registry values.

Check access locally:

```bash
docker login registry.example.com
kamal registry login
```

Store the registry password in `KAMAL_REGISTRY_PASSWORD` as described below. Never commit it.

---

## 5. Configure deployment secrets

`.kamal/secrets` is git-ignored. It is a Kamal dotenv file, not an application config file. The checked-in template reads values from your shell environment or secret manager:

```dotenv
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
DATABASE_URL=$DATABASE_URL
SECRET_KEY_BASE=$SECRET_KEY_BASE
...
```

### 5.1 Generate strong values

```bash
# Phoenix cookie/session signing secret
mix phx.gen.secret

# PostgreSQL password (hex avoids URL-encoding problems)
openssl rand -hex 32

# KYC identity salt (stable for the lifetime of the data)
openssl rand -hex 32
```

### 5.2 Export the secrets

Run these in the shell that invokes Kamal, or load them from your password manager:

```bash
export KAMAL_REGISTRY_PASSWORD='registry-password'
export POSTGRES_PASSWORD='generated-postgres-password'
export DATABASE_URL="ecto://marrylocal:${POSTGRES_PASSWORD}@marrylocal-api-db:5432/marrylocal_production"
export SECRET_KEY_BASE='generated-phoenix-secret'
export KYC_IDENTITY_SALT='generated-kyc-salt'
export KYC_S3_BUCKET='marrylocal-kyc-private'
export RESEND_API_KEY='re_...'
export AWS_ACCESS_KEY_ID='r2-access-key-id'
export AWS_SECRET_ACCESS_KEY='r2-secret-access-key'
export R2_BUCKET_NAME='marrylocal'
export R2_ENDPOINT='https://<account-id>.r2.cloudflarestorage.com'
export PHONEPE_MERCHANT_ID='...'
export PHONEPE_SALT_KEY='...'
export PHONEPE_SALT_INDEX='1'
export ADMIN_INVITE_CODE='...'
```

Notes:

- `marrylocal-api-db` is the Docker DNS name of the Kamal accessory (`service: marrylocal-api` + accessory `db`).
- URL-encode the password inside `DATABASE_URL` if it contains `@`, `:`, `/`, or `#`. Hex passwords avoid this entirely.
- `DATABASE_SSL` is set to `"false"` in `config/deploy.yml` because the DB is a private container on the same Docker network. If you switch to a managed PostgreSQL service, remove that clear value or set it to `"true"`.
- `R2_ENDPOINT` may be a full URL. The runtime accepts either the full endpoint or the older `AWS_S3_HOST` form.

### 5.3 Remove a previously committed secrets file

If `.kamal/secrets` was ever committed, remove it from the Git index and rotate every value it contained:

```bash
git rm --cached .kamal/secrets
git commit -m "Stop tracking Kamal secrets"
```

`.gitignore` now contains:

```gitignore
/.kamal/secrets
/.kamal/secrets.*
```

---

## 6. Validate the configuration

Run from the repository root, where `config/deploy.yml` lives:

```bash
kamal config
```

This prints the resolved configuration. Confirm:

- `service: marrylocal-api`
- The VPS IP under `servers.web`
- `proxy.host: api.marrylocal.in`
- `proxy.healthcheck.path: /api/health`
- The PostGIS accessory and `marrylocal_pg_data` directory
- All required secrets are listed

---

## 7. Bootstrap the server

Install Docker and prepare the host:

```bash
kamal server bootstrap
```

This installs Docker on the VPS and performs the initial host preparation. It does not deploy the application.

If SSH is not on port 22 or uses a non-root user, configure it first:

```yaml
ssh:
  user: deploy
  port: 22
```

---

## 8. First deployment

```bash
kamal setup
```

`kamal setup` performs the complete first-run sequence:

1. Boots the PostgreSQL/PostGIS accessory and creates `marrylocal_pg_data`.
2. Builds the backend image from `Dockerfile`.
3. Pushes it to the private registry.
4. Starts the `marrylocal-api` container.
5. Runs `Marrylocal.Release.migrate/0` through `bin/server`.
6. Starts Phoenix and waits for `/api/health`.
7. Boots `kamal-proxy`, obtains the TLS certificate, and routes `https://api.marrylocal.in` to the container.

The first deploy can take several minutes while the Elixir release compiles and the database initializes.

---

## 9. Routine deployments

After the first setup, deploy new commits with:

```bash
kamal deploy
```

Kamal builds and pushes a new image, starts a new container, waits for `/api/health`, and only then moves proxy traffic. This is the zero-downtime blue-green path.

Useful variants:

```bash
# Build without deploying
kamal build

# Redeploy the current image
kamal redeploy

# Follow application logs
kamal app logs -f

# Follow proxy logs
kamal proxy logs -f

# Inspect running containers and images
kamal details
kamal app containers -q
```

### Migration safety rule

Migrations run before the new Phoenix process starts. Keep migrations backward compatible during the overlap window, because the old container may still serve requests against the newly migrated schema. Use expand/contract migrations:

1. Add nullable columns/tables/indexes.
2. Deploy code that writes both old and new shapes.
3. Backfill.
4. Remove the old shape in a later deploy.

---

## 10. Verify the deployment

### Health endpoint

```bash
curl -i https://api.marrylocal.in/api/health
```

Healthy response:

```http
HTTP/2 200
content-type: application/json

{"status":"ok","database":"connected"}
```

Unhealthy response:

```http
HTTP/2 503
content-type: application/json

{"status":"error","database":"unavailable"}
```

`MarrylocalWeb.HealthController` verifies that the PostgreSQL pool can answer
`SELECT 1`. Schema readiness is guaranteed earlier in the boot sequence:
`bin/server` runs `Marrylocal.Release.migrate/0` before Phoenix starts, and a
failed migration stops the container before Kamal can route traffic to it.

A container that fails the database ping never receives proxy traffic.

The endpoint is public and unauthenticated because kamal-proxy must reach it
before TLS termination and without application credentials.

### Database and PostGIS

```bash
kamal accessory details db
kamal accessory logs db -f
kamal accessory exec db "psql -U marrylocal -d marrylocal_production -c 'SELECT postgis_version();'"
```

### Application environment

```bash
kamal app exec --reuse "env | sort"
```

Never paste secret values into tickets or logs.

---

## 11. Rollback

List available previous containers and image versions:

```bash
kamal app containers -q
```

Roll back to a known-good image version:

```bash
kamal rollback <VERSION>
```

Example:

```bash
kamal rollback 6ef8a6a84c525b123c5245345a8483f86d05a123
```

Rollback replaces the running container with the old image and waits for `/api/health` before routing traffic. It does **not** reverse database migrations. If the bad deploy included a destructive migration, restore from backup or run the release rollback explicitly:

```bash
kamal app exec --reuse "bin/marrylocal eval 'Marrylocal.Release.rollback(Marrylocal.Repo, 20261112150000)'"
```

Replace `20261112150000` with the version of the last migration that should remain applied. Prefer rolling forward with a corrective migration whenever possible.

---

## 12. Database persistence and backups

The accessory mounts:

```yaml
directories:
  - marrylocal_pg_data:/var/lib/postgresql/data
```

This host directory survives container replacements and `kamal deploy`. Do not run `kamal remove -y` unless you intend to destroy the data.

Create a logical backup:

```bash
kamal accessory exec db "pg_dump -U marrylocal -d marrylocal_production -Fc -f /var/lib/postgresql/data/marrylocal_$(date +%Y%m%d%H%M).dump"
```

Copy it off the server and store it in encrypted object storage. Test restores on a staging host regularly.

---

## 13. Troubleshooting

### `/api/health` returns 503 with `"database": "unavailable"`

- Confirm the DB accessory is running: `kamal accessory details db`.
- Check logs: `kamal accessory logs db`.
- Confirm `DATABASE_URL` points to `marrylocal-api-db:5432`, not `localhost`.
- Confirm `DATABASE_SSL` matches the database. The private accessory uses `false`; managed providers usually need `true`.
- Confirm the PostGIS image started cleanly and `POSTGRES_PASSWORD` is set.

### The new container exits during migration boot

- Inspect the new container's boot logs: `kamal app logs`.
- Run migrations manually inside a running container:

  ```bash
  kamal app exec --reuse "bin/marrylocal eval 'Marrylocal.Release.migrate()'"
  ```

- Re-run `curl https://api.marrylocal.in/api/health`.
- If a migration is genuinely broken, fix it forward, deploy again, or roll back the image.
- A failed migration stops `bin/server` before Phoenix starts, so the old container keeps serving traffic.

### New container never becomes healthy

```bash
kamal app logs
kamal app details
```

Common causes:

- `SECRET_KEY_BASE` missing.
- `DATABASE_URL` malformed or the password is not URL-encoded.
- Database accessory not booted.
- The release cannot bind port 4000.
- The `nobody` user cannot read the release files.

The Dockerfile copies the release with `--chown=nobody:root` and runs `chmod +x /app/bin/*`. If you add writable runtime paths, create and chown them for `nobody`.

### TLS certificate is not issued

- `dig +short api.marrylocal.in` must return the VPS IP.
- Ports 80 and 443 must be open at the host firewall and the cloud firewall.
- Disable Cloudflare orange-cloud proxying for the initial issuance.
- Check `kamal proxy logs`.

### `kamal deploy` cannot push the image

```bash
kamal registry login
docker login registry.example.com
```

Confirm the private repository exists and `KAMAL_REGISTRY_PASSWORD` is exported in the current shell.

### Re-running the first-time setup

`kamal setup` is intended for a fresh host. For normal changes, use `kamal deploy`. To manage the database container independently:

```bash
kamal accessory boot db
kamal accessory reboot db
kamal accessory logs db -f
```

---

## 14. Production launch checklist

- [ ] `api.marrylocal.in` A record points at the VPS and resolves publicly.
- [ ] TCP 80 and 443 are open; TCP 5432 is closed publicly.
- [ ] SSH access works for Kamal.
- [ ] Private registry repository exists.
- [ ] `KAMAL_REGISTRY_PASSWORD`, `POSTGRES_PASSWORD`, `DATABASE_URL`, and `SECRET_KEY_BASE` are exported.
- [ ] `KYC_IDENTITY_SALT` is unique and backed up securely.
- [ ] `KYC_S3_BUCKET` is a private R2 bucket, separate from the public media bucket.
- [ ] `R2_BUCKET_NAME` and `R2_ENDPOINT` point at the production bucket.
- [ ] `DATABASE_URL` uses `marrylocal-api-db` and the password is URL-safe.
- [ ] `.kamal/secrets` is not tracked by Git.
- [ ] `kamal config` renders without errors.
- [ ] `kamal server bootstrap` completed.
- [ ] `kamal setup` completed.
- [ ] `curl https://api.marrylocal.in/api/health` returns `200` with `{"status":"ok","database":"connected"}`.
- [ ] PostGIS is installed in the production database.
- [ ] A database backup has been taken and restore-tested.
- [ ] Frontend `https://marrylocal.in` can reach the API and CORS is configured for that origin.
- [ ] A rollback version is known and recorded (`kamal app containers -q`).
