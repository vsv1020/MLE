#!/usr/bin/env bash
# 麻薯背单词推送服务 —— 安装 / 更新脚本（Debian / Ubuntu；也尽量支持 dnf/yum 系统）
#
# 用法（在服务器上，以 root 身份，在 server/push 目录或任意目录执行都可以）：
#   sudo bash deploy/install.sh
#
# 可以重复执行（幂等）：第一次是安装，之后再执行就是更新代码并重启服务。
# 它会：
#   1. 没有 Node.js 20+ 时自动安装（优先用系统软件源，版本不够就用 NodeSource）
#   2. 创建系统用户 mashu-push、数据目录 /var/lib/mashu-push、配置目录 /etc/mashu-push
#   3. 把程序复制到 /opt/mashu-push
#   4. 首次安装时生成 /etc/mashu-push.env（带随机后台密码），以后不会覆盖它
#   5. 安装并启动 systemd 服务 mashu-push
# 它【不会】修改 nginx 配置 —— 最后会打印需要你手动添加的内容。
set -euo pipefail

NODE_MAJOR_MIN=20
NODE_MAJOR_INSTALL="${NODE_MAJOR_INSTALL:-22}"   # 需要安装时装哪个大版本（LTS）
APP_USER=mashu-push
APP_DIR=/opt/mashu-push
DATA_DIR=/var/lib/mashu-push
CONF_DIR=/etc/mashu-push
ENV_FILE=/etc/mashu-push.env
UNIT_FILE=/etc/systemd/system/mashu-push.service
PORT_DEFAULT=8787

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[注意]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行：sudo bash $0"
[ -f "$SRC_DIR/server.mjs" ] && [ -d "$SRC_DIR/lib" ] || die "找不到 $SRC_DIR/server.mjs —— 请把整个 server/push 目录上传到服务器后再运行。"
command -v systemctl >/dev/null || die "这台机器没有 systemd（systemctl），本脚本不适用。"

# ---------------------------------------------------------------- Node.js
node_major() { command -v node >/dev/null && node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }

install_node() {
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    local cand
    cand="$(apt-cache policy nodejs 2>/dev/null | awk '/Candidate:/ {print $2}' | sed -E 's/^[0-9]+://' | cut -d. -f1)"
    if [[ "$cand" =~ ^[0-9]+$ ]] && [ "$cand" -ge "$NODE_MAJOR_MIN" ]; then
      say "用系统软件源安装 Node.js ${cand}"
      apt-get install -y -qq nodejs
    else
      say "系统软件源的 Node.js 版本太旧，改用 NodeSource 安装 Node.js ${NODE_MAJOR_INSTALL}.x"
      apt-get install -y -qq ca-certificates curl gnupg
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR_INSTALL}.x" -o /tmp/nodesource_setup.sh
      bash /tmp/nodesource_setup.sh
      rm -f /tmp/nodesource_setup.sh
      apt-get install -y -qq nodejs
    fi
  elif command -v dnf >/dev/null || command -v yum >/dev/null; then
    local pm; pm="$(command -v dnf || command -v yum)"
    say "用 NodeSource 安装 Node.js ${NODE_MAJOR_INSTALL}.x"
    curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR_INSTALL}.x" -o /tmp/nodesource_setup.sh
    bash /tmp/nodesource_setup.sh
    rm -f /tmp/nodesource_setup.sh
    "$pm" install -y nodejs
  else
    die "无法自动安装 Node.js（没有 apt/dnf/yum）。请手动安装 Node.js ${NODE_MAJOR_MIN}+ 后重新运行。"
  fi
}

if [ "$(node_major)" -lt "$NODE_MAJOR_MIN" ]; then
  install_node
fi
[ "$(node_major)" -ge "$NODE_MAJOR_MIN" ] || die "Node.js 版本仍然低于 ${NODE_MAJOR_MIN}（当前：$(node -v 2>/dev/null || echo 无)）。"
NODE_BIN="$(command -v node)"
NODE_BIN="$(readlink -f "$NODE_BIN")"
say "Node.js $("$NODE_BIN" -v) —— $NODE_BIN"

# ---------------------------------------------------------------- 用户和目录
NOLOGIN="$(command -v nologin || echo /usr/sbin/nologin)"
if ! id "$APP_USER" >/dev/null 2>&1; then
  say "创建系统用户 $APP_USER"
  useradd --system --no-create-home --home-dir "$DATA_DIR" --shell "$NOLOGIN" "$APP_USER"
fi

install -d -o "$APP_USER" -g "$APP_USER" -m 700 "$DATA_DIR"
install -d -o root -g "$APP_USER" -m 750 "$CONF_DIR"
if [ -f "$CONF_DIR/AuthKey.p8" ]; then
  chown "$APP_USER:$APP_USER" "$CONF_DIR/AuthKey.p8"
  chmod 600 "$CONF_DIR/AuthKey.p8"
fi

# ---------------------------------------------------------------- 程序文件
say "复制程序到 $APP_DIR"
install -d -o root -g root -m 755 "$APP_DIR"
rm -rf "$APP_DIR/lib" "$APP_DIR/deploy"
cp -r "$SRC_DIR/lib" "$SRC_DIR/deploy" "$APP_DIR/"
install -m 644 "$SRC_DIR/server.mjs" "$APP_DIR/server.mjs"
for f in package.json README.md; do
  [ -f "$SRC_DIR/$f" ] && install -m 644 "$SRC_DIR/$f" "$APP_DIR/$f"
done
chown -R root:root "$APP_DIR"
chmod -R u=rwX,go=rX "$APP_DIR"

# ---------------------------------------------------------------- 配置文件
if [ ! -f "$ENV_FILE" ]; then
  say "生成配置文件 $ENV_FILE（含随机后台密码）"
  PASS="$("$NODE_BIN" -e 'process.stdout.write(require("crypto").randomBytes(16).toString("hex"))')"
  sed "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${PASS}|" "$SRC_DIR/deploy/mashu-push.env.example" > "$ENV_FILE"
  chown root:root "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  NEW_PASSWORD="$PASS"
else
  chown root:root "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "保留已有的 $ENV_FILE（不会覆盖）"
fi

# ---------------------------------------------------------------- systemd
say "安装 systemd 服务 $UNIT_FILE"
sed "s|^ExecStart=.*|ExecStart=${NODE_BIN} ${APP_DIR}/server.mjs|" "$SRC_DIR/deploy/mashu-push.service" > "$UNIT_FILE.tmp"
mv "$UNIT_FILE.tmp" "$UNIT_FILE"
chmod 644 "$UNIT_FILE"
systemctl daemon-reload
systemctl enable mashu-push >/dev/null 2>&1
systemctl reset-failed mashu-push >/dev/null 2>&1 || true
systemctl restart mashu-push

PORT="$(sed -n 's/^PORT=\([0-9]\{1,5\}\).*/\1/p' "$ENV_FILE" | tail -1)"; PORT="${PORT:-$PORT_DEFAULT}"
HEALTH=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  HEALTH="$("$NODE_BIN" -e '
    require("http").get("http://127.0.0.1:" + process.argv[1] + "/api/push/health", (r) => {
      let b = ""; r.on("data", (d) => b += d); r.on("end", () => { process.stdout.write(b); });
    }).on("error", () => {});' "$PORT" 2>/dev/null || true)"
  [ -n "$HEALTH" ] && break
done

if [ -n "$HEALTH" ]; then
  say "服务已运行：$HEALTH"
else
  warn "服务没有正常启动。查看原因：journalctl -u mashu-push -n 50 --no-pager"
fi

# ---------------------------------------------------------------- 下一步
cat <<EOF

------------------------------------------------------------------------
安装完成。接下来需要你手动做的事：
------------------------------------------------------------------------
EOF
if [ -n "${NEW_PASSWORD:-}" ]; then
cat <<EOF
★ 后台登录信息（只显示这一次，请记下来；以后可在 $ENV_FILE 里查看/修改）：
    地址：https://mle.doge6.com/push-admin
    用户名：admin
    密码：$NEW_PASSWORD

EOF
fi
cat <<EOF
1) 上传 Apple 推送私钥（.p8）并设置权限：
     cp AuthKey_XXXXXXXXXX.p8 $CONF_DIR/AuthKey.p8
     chown $APP_USER:$APP_USER $CONF_DIR/AuthKey.p8
     chmod 600 $CONF_DIR/AuthKey.p8

2) 编辑配置文件，填入 APNS_KEY_PATH / APNS_KEY_ID / APPLE_TEAM_ID：
     nano $ENV_FILE
   然后重启：
     systemctl restart mashu-push
     journalctl -u mashu-push -n 20 --no-pager     # 应看到 "apns configured"

3) 在 nginx 里给 mle.doge6.com 加转发（本脚本不会自动改 nginx）：
   找到配置文件：  grep -rl "mle.doge6.com" /etc/nginx/
   把下面的内容粘贴进 listen 443 的那个 server { } 块里（和 location / 同一层）：
------------------------------------------------------------------------
$(sed -n '/^    # App 注册/,$p' "$SRC_DIR/deploy/nginx-snippet.conf")
------------------------------------------------------------------------
   然后检查并重载：
     nginx -t && systemctl reload nginx

4) 检查：
     curl https://mle.doge6.com/api/push/health
   应返回：{"ok":true,"apns":true,"tokens":{"production":0,"sandbox":0}}

详细说明见 $APP_DIR/README.md
EOF
