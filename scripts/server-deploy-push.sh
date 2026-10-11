#!/usr/bin/env bash
# Runs ON the server (as root), from .github/workflows/deploy-push.yml.
#
# Expects in /root/mashu-deploy/:
#   bundle.tgz   push-server/ and site/
#   secrets.env  APNS_KEY_ID, APPLE_TEAM_ID, PUSH_ADMIN_PASSWORD  (mode 600)
#   AuthKey.p8   the APNs key                                     (mode 600)
#
# Idempotent. Never prints secrets. Changes nginx only by adding the two push locations to the
# mle.doge6.com HTTPS server block (backed up first, restored if `nginx -t` fails).
set -euo pipefail
DOMAIN=mle.doge6.com
WORK=/root/mashu-deploy
say() { printf '\n== %s\n' "$*"; }
die() { printf '::error::%s\n' "$*"; exit 1; }

cd "$WORK"
[ -f bundle.tgz ] && [ -f secrets.env ] && [ -f AuthKey.p8 ] || die "upload incomplete"
rm -rf src && mkdir src && tar -xzf bundle.tgz -C src
# shellcheck disable=SC1091
set -a; . ./secrets.env; set +a

# ---------------------------------------------------------------- nginx config for the domain
say "Finding the nginx config for $DOMAIN"
CONF=$(grep -rlE "server_name[^;]*\b${DOMAIN//./\\.}\b" /etc/nginx/ 2>/dev/null | grep -v '\.bak' | head -n1 || true)
[ -n "$CONF" ] || die "no nginx config mentions $DOMAIN"
echo "config: $CONF"
WEBROOT=$(awk '/listen[ \t]+443/{h=1} h && $1=="root"{gsub(";","",$2); print $2; exit}' "$CONF")
[ -n "$WEBROOT" ] || WEBROOT=$(awk '$1=="root"{gsub(";","",$2); print $2; exit}' "$CONF")
[ -n "$WEBROOT" ] && [ -d "$WEBROOT" ] || die "could not find the web root in $CONF"
echo "web root: $WEBROOT"

# ---------------------------------------------------------------- website files
say "Updating the website files"
STAMP=$(date +%Y%m%d-%H%M%S)
tar -czf "/root/site-backup-$STAMP.tgz" -C "$WEBROOT" .
cp -f src/site/* "$WEBROOT"/
echo "backed up the old site to /root/site-backup-$STAMP.tgz and copied $(ls src/site | wc -l) files"

# ---------------------------------------------------------------- push service
say "Installing the push service"
# install.sh creates the user, /opt/mashu-push, /etc/mashu-push.env (with a random password the
# first time) and starts the unit. Its output can contain that password, so it is not shown.
if ! bash src/push-server/deploy/install.sh > /root/mashu-push-install.log 2>&1; then
  tail -n 30 /root/mashu-push-install.log | grep -v -i 'password\|密码' || true
  die "install.sh failed (full log: /root/mashu-push-install.log on the server)"
fi
echo "install.sh finished"

install -d -m 750 -o mashu-push -g mashu-push /etc/mashu-push
install -m 600 -o mashu-push -g mashu-push AuthKey.p8 /etc/mashu-push/AuthKey.p8

ENV_FILE=/etc/mashu-push.env
setvar() {  # setvar KEY VALUE — replace or append, value never echoed
  local tmp; tmp=$(mktemp)
  grep -v "^$1=" "$ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  cat "$tmp" > "$ENV_FILE"; rm -f "$tmp"
}
setvar APNS_KEY_PATH /etc/mashu-push/AuthKey.p8
setvar APNS_KEY_ID "$APNS_KEY_ID"
setvar APPLE_TEAM_ID "$APPLE_TEAM_ID"
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

rm -f "$WORK/secrets.env" "$WORK/AuthKey.p8"
echo "done"
