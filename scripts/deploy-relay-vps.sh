#!/usr/bin/env bash
set -euo pipefail

# Deploy only the usAIge relay service and its dedicated nginx API location.
# The static website and existing project routes are not part of this archive.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
remote="${RELAY_SSH_TARGET:-root@pmrichq.com}"
: "${SSH_IDENTITY:?Set SSH_IDENTITY to the existing pmrichq.com SSH identity file}"
node_version="v22.23.3"
node_archive="${RELAY_NODE_ARCHIVE:-/tmp/usaige-relay-node-${node_version}-linux-x64.tar.xz}"
node_sha="df450af89261115ef9f9e3830c3eeb2cc9213b63c720b1af623cb5dcbe2e02de"
release="$(date -u +%Y%m%dT%H%M%SZ)"
deployment_archive="$(mktemp /tmp/usaige-relay-deploy.XXXXXX.tar.gz)"
trap 'rm -f "$deployment_archive"' EXIT
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes -i "$SSH_IDENTITY")

if [[ ! -f "$node_archive" ]]; then
    curl --fail --location --silent --show-error --max-time 180 \
        "https://nodejs.org/dist/${node_version}/node-${node_version}-linux-x64.tar.xz" \
        --output "$node_archive"
fi
actual_sha="$(shasum -a 256 "$node_archive" | awk '{print $1}')"
[[ "$actual_sha" == "$node_sha" ]] || { echo "Node runtime checksum mismatch" >&2; exit 1; }
test -f "$project_root/site/server/index.mjs"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$deployment_archive" -C "$project_root/site" server worker/relay-api.ts
scp "${ssh_options[@]}" "$deployment_archive" "$remote:/tmp/usaige-relay-${release}.tar.gz"
if ! ssh "${ssh_options[@]}" "$remote" "test -x /opt/usaige-relay/runtime/node-${node_version}-linux-x64/bin/node"; then
    scp "${ssh_options[@]}" "$node_archive" "$remote:/tmp/usaige-relay-node-${node_version}.tar.xz"
fi

ssh "${ssh_options[@]}" "$remote" bash -s -- "$release" "$node_version" "$node_sha" <<'REMOTE_SCRIPT'
set -euo pipefail
release="$1"
node_version="$2"
node_sha="$3"
service_root=/opt/usaige-relay
nginx_config=/etc/nginx/sites-available/pmrichq
nginx_backup="${nginx_config}.usaige-${release}.bak"
service_unit=/etc/systemd/system/usaige-relay.service
nginx_snippet=/etc/nginx/snippets/usaige-relay.conf
unit_backup="${service_unit}.${release}.bak"
snippet_backup="${nginx_snippet}.${release}.bak"
previous_release="$(readlink "$service_root/current" 2>/dev/null || true)"
activated=false
configuration_changed=false
rollback() {
    result=$?
    if (( result != 0 )); then
        if [[ "$activated" == true && -z "$previous_release" ]]; then
            systemctl disable --now usaige-relay || true
        fi
        if [[ "$configuration_changed" == true ]]; then
            if [[ -f "$nginx_backup" ]]; then cp "$nginx_backup" "$nginx_config"; fi
            if [[ -f "$unit_backup" ]]; then cp "$unit_backup" "$service_unit"; else rm -f "$service_unit"; fi
            if [[ -f "$snippet_backup" ]]; then cp "$snippet_backup" "$nginx_snippet"; else rm -f "$nginx_snippet"; fi
            systemctl daemon-reload
        fi
        if [[ "$activated" == true ]]; then
            if [[ -n "$previous_release" ]]; then
                ln -sfn "$previous_release" "$service_root/current"
                systemctl restart usaige-relay || true
            else
                systemctl disable --now usaige-relay || true
                rm -f "$service_root/current"
            fi
        fi
        nginx -t && systemctl reload nginx || true
    fi
    exit "$result"
}
trap rollback EXIT
[[ "$(uname -m)" == x86_64 ]] || { echo "Expected x86_64 server" >&2; exit 1; }
if [[ ! -x "$service_root/runtime/node-${node_version}-linux-x64/bin/node" ]]; then
    echo "$node_sha  /tmp/usaige-relay-node-${node_version}.tar.xz" | sha256sum --check --status
fi
if [[ -f "$service_unit" ]]; then cp "$service_unit" "$unit_backup"; fi
if [[ -f "$nginx_snippet" ]]; then cp "$nginx_snippet" "$snippet_backup"; fi
id usaige-relay >/dev/null 2>&1 || useradd --system --home /var/lib/usaige-relay --shell /usr/sbin/nologin usaige-relay
install -d -m 0755 "$service_root/runtime" "$service_root/releases/$release"
install -d -m 0700 -o usaige-relay -g usaige-relay /var/lib/usaige-relay
install -d -m 0755 /etc/usaige-relay /etc/nginx/snippets
if [[ ! -x "$service_root/runtime/node-${node_version}-linux-x64/bin/node" ]]; then
    tar -xJf "/tmp/usaige-relay-node-${node_version}.tar.xz" -C "$service_root/runtime"
fi
tar -xzf "/tmp/usaige-relay-${release}.tar.gz" -C "$service_root/releases/$release"
chmod -R a+rX,go-w "$service_root/releases/$release"
"$service_root/runtime/node-${node_version}-linux-x64/bin/node" --check "$service_root/releases/$release/server/index.mjs"
cp "$nginx_config" "$nginx_backup"
configuration_changed=true
if [[ ! -f /etc/usaige-relay/relay.env ]]; then
    cat >/etc/usaige-relay/relay.env <<'ENVIRONMENT'
RELAY_PUBLIC_URL=https://pmrichq.com/project/usaige
RELAY_DB_PATH=/var/lib/usaige-relay/relay.sqlite
RELAY_PORT=8788
ENVIRONMENT
    chmod 0600 /etc/usaige-relay/relay.env
fi
cat >"$service_unit" <<SERVICE
[Unit]
Description=usAIge usage relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=usaige-relay
Group=usaige-relay
WorkingDirectory=$service_root/current
Environment=NODE_ENV=production
EnvironmentFile=/etc/usaige-relay/relay.env
ExecStart=$service_root/runtime/node-${node_version}-linux-x64/bin/node --experimental-strip-types server/index.mjs
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/usaige-relay
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
SERVICE
cat >"$nginx_snippet" <<'NGINX'
location ^~ /project/usaige/api/v1/ {
    client_max_body_size 256k;
    proxy_pass http://127.0.0.1:8788;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header CF-Connecting-IP $remote_addr;
    proxy_connect_timeout 5s;
    proxy_send_timeout 30s;
    proxy_read_timeout 30s;
    proxy_intercept_errors off;
    access_log off;
}
NGINX
python3 - "$nginx_config" <<'PYTHON'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
include = "    include /etc/nginx/snippets/usaige-relay.conf;\n\n"
anchor = "    location = /project/usaige {"
if include.strip() not in text:
    if text.count(anchor) != 1:
        raise SystemExit("Cannot uniquely identify the usAIge nginx location")
    path.write_text(text.replace(anchor, include + anchor, 1))
PYTHON
nginx -t
ln -sfn "releases/$release" "$service_root/current"
activated=true
systemctl daemon-reload
systemctl enable usaige-relay >/dev/null
systemctl restart usaige-relay
for attempt in $(seq 1 20); do
    if curl --fail --silent http://127.0.0.1:8788/project/usaige/api/v1/health >/dev/null; then break; fi
    sleep 1
done
curl --fail --silent http://127.0.0.1:8788/project/usaige/api/v1/health
systemctl reload nginx
# Nginx's reload returns before new workers have taken over their listeners.
for attempt in $(seq 1 10); do
    if curl --fail --silent --max-time 10 --resolve pmrichq.com:443:127.0.0.1 https://pmrichq.com/project/usaige/api/v1/health >/dev/null; then break; fi
    sleep 1
done
curl --fail --silent --show-error --max-time 20 --resolve pmrichq.com:443:127.0.0.1 https://pmrichq.com/project/usaige/api/v1/health
systemctl is-active usaige-relay
rm -f "/tmp/usaige-relay-${release}.tar.gz" "/tmp/usaige-relay-node-${node_version}.tar.xz"
echo "usAIge relay release $release activated"
REMOTE_SCRIPT

curl --fail --silent --show-error --max-time 20 https://pmrichq.com/project/usaige/api/v1/health
