#!/usr/bin/env bash
# Runs ON the web server (piped over SSH by .github/workflows/deploy-site.yml).
#
#   STAGE=prepare  — install nginx + rsync if missing, create the web root and an nginx server
#                    block for $DOMAIN on port 80 (only if no existing config already serves it).
#   STAGE=https    — get a Let's Encrypt certificate for $DOMAIN with certbot's nginx plugin
#                    (once; renewal is left to certbot's own timer/cron), then reload nginx.
#
# Idempotent: safe to run on every deploy. Never edits other sites' configs.
set -euo pipefail
: "${DOMAIN:?}" "${WEBROOT:?}" "${STAGE:?}"

install_pkgs() {
  if command -v apt-get >/dev/null; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  elif command -v dnf >/dev/null; then
    dnf install -y -q "$@"
  elif command -v yum >/dev/null; then
    yum install -y -q "$@"
  else
    echo "No supported package manager (apt/dnf/yum) to install: $*" >&2; return 1
  fi
}

reload_nginx() {
  nginx -t
  if systemctl is-active --quiet nginx; then systemctl reload nginx
  else systemctl enable --now nginx; fi
}

case "$STAGE" in
prepare)
  command -v nginx >/dev/null || install_pkgs nginx
  command -v rsync >/dev/null || install_pkgs rsync
  mkdir -p "$WEBROOT"
  CONF=/etc/nginx/conf.d/$DOMAIN.conf
  if grep -rqs "server_name[^;]*\b$DOMAIN\b" /etc/nginx/ --include=*.conf --include=*default* \
       && [ ! -f "$CONF" ]; then
    echo "An existing nginx config already serves $DOMAIN — leaving it alone."
  elif [ ! -f "$CONF" ]; then
    cat > "$CONF" <<NGINX
# Managed by VocabLoop's deploy-site workflow.
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root $WEBROOT;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
NGINX
    echo "Wrote $CONF"
  fi
  command -v restorecon >/dev/null && restorecon -R "$WEBROOT" || true
  reload_nginx
  ;;
https)
  if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    echo "Certificate for $DOMAIN already exists (certbot renews it)."
  else
    if ! command -v certbot >/dev/null; then
      install_pkgs certbot python3-certbot-nginx 2>/dev/null \
        || install_pkgs certbot certbot-nginx 2>/dev/null \
        || {
          # Distro without packaged certbot (e.g. Alibaba Cloud Linux without EPEL): use pip.
          install_pkgs python3 python3-pip >/dev/null 2>&1 || true
          python3 -m venv /opt/certbot
          /opt/certbot/bin/pip install -q --upgrade pip certbot certbot-nginx
          ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot
          echo "0 3 * * * root /opt/certbot/bin/certbot renew -q --deploy-hook 'systemctl reload nginx'" \
            > /etc/cron.d/certbot-renew
        }
    fi
    certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
      --register-unsafely-without-email --redirect || {
      echo "certbot failed. Check: DNS A record for $DOMAIN points at this server, and" >&2
      echo "ports 80 and 443 are open in the cloud security group / firewall." >&2
      exit 1
    }
  fi
  reload_nginx
  ;;
*) echo "unknown STAGE $STAGE" >&2; exit 2 ;;
esac
