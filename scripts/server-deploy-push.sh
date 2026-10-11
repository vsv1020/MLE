#!/usr/bin/env bash
# Runs ON the server (as root), from .github/workflows/deploy-push.yml.
#
# Expects in /root/mashu-deploy/:
#   bundle.tgz   push-server/ and site/
#   secrets.env  PUSH_ADMIN_PASSWORD  (mode 600)
#
# The APNs key is NOT handled here: the owner pastes it into https://mle.doge6.com/push-admin
# (推送设置), where the service checks it with Apple and keeps it in /var/lib/mashu-push/apns.json.
#
# Idempotent. Never prints secrets. Changes nginx only by adding the two push locations to the
# mle.doge6.com HTTPS server block (backed up first, restored if `nginx -t` fails).
set -euo pipefail
DOMAIN=mle.doge6.com
WORK=/root/mashu-deploy
say() { printf '\n== %s\n' "$*"; }
die() { printf '::error::%s\n' "$*"; exit 1; }

cd "$WORK"
[ -f bundle.tgz ] && [ -f secrets.env ] || die "upload incomplete"
rm -rf src && mkdir src && tar -xzf bundle.tgz -C src
# shellcheck disable=SC1091
set -a; . ./secrets.env; set +a

# ---------------------------------------------------------------- nginx config for the domain
say "Finding the nginx config for $DOMAIN"
CONF=$(grep -rlE "server_name[^;]*\b${DOMAIN//./\\.}\b" /etc/nginx/ 2>/dev/null | grep -v '\.bak' | head -n1 || true)
[ -n "$CONF" ] || die "no nginx config mentions $DOMAIN"
echo "config: $CONF"
echo "--- $CONF (server blocks, for reference)"
grep -nE 'server_name|listen|root|alias|location|proxy_pass|index' "$CONF" || true
# The web root: a `root` (or `alias`) directive anywhere in the file, the first one wins.
WEBROOT=$(awk '$1=="root" || $1=="alias" {v=$2; gsub(";","",v); print v; exit}' "$CONF")
# Otherwise the site may be a container behind proxy_pass (mle-site: Caddy serving a read-only
# bind mount of /var/www/$DOMAIN); copying into that folder updates it live.
if [ -z "$WEBROOT" ] && command -v docker >/dev/null; then
  WEBROOT=$(docker inspect mle-site-web-1 --format '{{range .Mounts}}{{if eq .Destination "/srv"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)
fi
[ -z "$WEBROOT" ] && [ -f "/var/www/$DOMAIN/index.html" ] && WEBROOT=/var/www/$DOMAIN
STAMP=$(date +%Y%m%d-%H%M%S)

# ---------------------------------------------------------------- website files
say "Updating the website files"
if [ -n "$WEBROOT" ] && [ -d "$WEBROOT" ] && [ -f "$WEBROOT/index.html" ]; then
  echo "web root: $WEBROOT"
  tar -czf "/root/site-backup-$STAMP.tgz" -C "$WEBROOT" .
  cp -f src/site/* "$WEBROOT"/
  echo "backed up the old site to /root/site-backup-$STAMP.tgz and copied $(ls src/site | wc -l) files"
else
  echo "::warning::no clear web root with an index.html in $CONF (found: '${WEBROOT:-none}') — website files NOT updated; the push service is still deployed"
fi

# ---------------------------------------------------------------- push service
say "Installing the push service"
# install.sh creates the user, /opt/mashu-push, /etc/mashu-push.env (with a random password the
# first time) and starts the unit. Its output can contain that password, so it is not shown.
if ! bash src/push-server/deploy/install.sh > /root/mashu-push-install.log 2>&1; then
  tail -n 30 /root/mashu-push-install.log | grep -v -i 'password\|密码' || true
  die "install.sh failed (full log: /root/mashu-push-install.log on the server)"
fi
echo "install.sh finished"

ENV_FILE=/etc/mashu-push.env
setvar() {  # setvar KEY VALUE — replace or append, value never echoed
  local tmp; tmp=$(mktemp)
  grep -v "^$1=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
}
setvar ADMIN_USER admin
setvar ADMIN_PASSWORD "$PUSH_ADMIN_PASSWORD"
chmod 600 "$ENV_FILE"
systemctl restart mashu-push
sleep 2
systemctl is-active --quiet mashu-push || { journalctl -u mashu-push -n 30 --no-pager | grep -v -i password; die "mashu-push is not running"; }
journalctl -u mashu-push -n 30 --no-pager | grep -i -E 'apns|listening|config' | grep -v -i password || true

# ---------------------------------------------------------------- nginx locations
say "nginx"
if grep -q 'location /api/push/' "$CONF"; then
  echo "push locations already present — nginx left as it is"
else
  cp -p "$CONF" "$CONF.bak-$STAMP"
  SNIP=src/push-server/deploy/nginx-snippet.conf
  # Insert the two locations right after the first `listen 443` line of the HTTPS server block.
  awk -v snip="$SNIP" '
    { print }
    !done && /listen[ \t]+443/ {
      while ((getline line < snip) > 0) if (line !~ /^#/) print line
      done = 1
    }
    END { if (!done) exit 3 }
  ' "$CONF.bak-$STAMP" > "$CONF" || { cp -p "$CONF.bak-$STAMP" "$CONF"; die "no 'listen 443' line in $CONF — add the snippet by hand"; }
  if nginx -t 2>&1; then
    systemctl reload nginx
    echo "added the push locations (backup: $CONF.bak-$STAMP)"
  else
    cp -p "$CONF.bak-$STAMP" "$CONF"
    die "nginx -t failed — restored $CONF from the backup"
  fi
fi

# ---------------------------------------------------------------- checks
say "Checks"
curl -fsS --max-time 10 http://127.0.0.1:8787/api/push/health; echo
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/api/push/health" || true)
echo "https://$DOMAIN/api/push/health → $code"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/push-admin" || true)
echo "https://$DOMAIN/push-admin → $code (401 = asks for the password, as it should)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" || true)
echo "https://$DOMAIN/ → $code"

rm -f "$WORK/secrets.env"
cat <<'EOF'

done.
Next: open https://mle.doge6.com/push-admin (user: admin, password: the PUSH_ADMIN_PASSWORD secret)
and fill in 推送设置: paste the .p8, enter the Key ID and Team ID, press 保存并检查.
下一步：打开 https://mle.doge6.com/push-admin（用户名 admin，密码就是 PUSH_ADMIN_PASSWORD），
在“推送设置”里粘贴 .p8、填 Key ID 和 Team ID，点“保存并检查”。
EOF
