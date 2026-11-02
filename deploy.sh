#!/usr/bin/env bash
# Deploys a release artifact built by the Jenkinsfile to production.
#
# Usage: ./deploy.sh ARTIFACT
#
# The artifact is a tar.gz with the contents of `build/default` and `nginx.conf` at its root.
# DEPLOY_HOST (user@host) and KNOWN_HOSTS (a known_hosts file with the server key) must be set,
# and an SSH agent must hold the deploy key. RELEASE_ID (YYYYMMDDHHMMSS, UTC) names the release
# directory; it defaults to the current time.

set -Eeuo pipefail

artifact="${1:?Artifact path is required}"
host="${DEPLOY_HOST:?DEPLOY_HOST is required}"

base_path="/var/www/production/stopwatch.vistro.ru"
release_id="${RELEASE_ID:-$(date -u '+%Y%m%d%H%M%S')}"
if [[ ! "$release_id" =~ ^[0-9]{14}$ ]]; then
    echo "RELEASE_ID must have the UTC format YYYYMMDDHHMMSS" >&2
    exit 1
fi
release_path="${base_path}/releases/${release_id}"

known_hosts="${KNOWN_HOSTS:?KNOWN_HOSTS must point to a known_hosts file with the server key}"

remote() {
    ssh -o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=yes "$host" "$@"
}

echo "==> Checking the server"

# Read-only: stop before uploading when another project already serves the domains.
# A missing certificate is caught by `nginx -t` below: /etc/letsencrypt/live is closed to deploy.
remote bash -s -- "$base_path" <<'REMOTE'
set -Eeuo pipefail
base_path="$1"

for domain in stopwatch.vistro.ru; do
    others="$(grep -lE "server_name[^;]*[[:space:]]${domain//./\\.}([[:space:];]|\$)" \
        /var/www/production/*/nginx.conf /var/www/sandbox/*/nginx.conf 2>/dev/null \
        | grep -vxF "${base_path}/nginx.conf" || true)"
    if [[ -n "$others" ]]; then
        echo "${domain} is already served by: ${others}" >&2
        exit 1
    fi
done
REMOTE

echo "==> Uploading release ${release_id}"

# logs/ is shared with nginx; 2775 keeps it writable for the www-data group, as on the rest of the server.
remote "mkdir -p ${base_path}/releases \
    && install -d -m 2775 ${base_path}/logs \
    && mkdir ${release_path} \
    && tar -xzf - --no-same-owner -C ${release_path}" < "$artifact"

echo "==> Activating release ${release_id}"

remote bash -s -- "$base_path" "$release_path" <<'REMOTE'
set -Eeuo pipefail
base_path="$1"
release="$2"

# Switch atomically: rename(2) replaces the link, so `current` never disappears.
ln -sfn "$release" "${base_path}/current.next"
mv -Tf "${base_path}/current.next" "${base_path}/current"

# nginx includes the config from the base path; it is not served from the release.
# A configuration nginx rejects is rolled back.
mv -f "${release}/nginx.conf" "${base_path}/nginx.conf.next"
if [[ -f "${base_path}/nginx.conf" ]]; then
    cp -p "${base_path}/nginx.conf" "${base_path}/nginx.conf.previous"
fi
mv -f "${base_path}/nginx.conf.next" "${base_path}/nginx.conf"
# Full paths, exactly as /etc/sudoers.d/deploy allows them.
if ! sudo /usr/sbin/nginx -t; then
    if [[ -f "${base_path}/nginx.conf.previous" ]]; then
        mv -f "${base_path}/nginx.conf.previous" "${base_path}/nginx.conf"
    else
        rm -f "${base_path}/nginx.conf"
    fi
    echo "nginx rejected the configuration of the release" >&2
    exit 1
fi
# The server is shared, so the configuration is reloaded, not restarted.
sudo /usr/sbin/service nginx reload

# Keep the previous releases for a quick rollback.
find "${base_path}/releases" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*' | sort -r | tail -n +4 | xargs -r rm -rf
REMOTE

echo "==> Production now runs release ${release_id}"
