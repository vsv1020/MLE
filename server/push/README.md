# 麻薯背单词 · 推送通知服务（mashu-push）

这是给 iOS App **麻薯背单词**（Bundle ID / APNs topic：`com.vocabloop.app`）用的一个很小的推送服务器。

- App 打开通知权限后，把自己的设备 token 发给服务器登记（`/api/push/register`）。
- 你在网页后台 **https://mle.doge6.com/push-admin** 写标题和内容，选发给谁，点“发送”。
- 服务器通过 Apple 的 APNs 把通知推到用户手机上；已经卸载 App / 失效的设备会被自动清理。

特点：只用 Node.js 自带功能，**没有任何 npm 依赖**（不用 `npm install`）；只监听本机 `127.0.0.1:8787`，由现有的 nginx 转发；数据存成 JSON 文件。

---

## 目录

1. [文件说明](#文件说明)
2. [部署步骤（第一次）](#部署步骤第一次)
3. [推送设置（Apple 推送密钥）](#推送设置apple-推送密钥)
4. [怎么发推送](#怎么发推送)
5. [更新程序](#更新程序)
6. [备份数据](#备份数据)
7. [常见问题排查](#常见问题排查)
8. [给 App 开发用的接口说明](#给-app-开发用的接口说明)
9. [给服务器上的 AI 助手的说明](#给服务器上的-ai-助手的说明)

---

## 文件说明

```
server/push/
├── server.mjs                  程序入口
├── lib/                        程序代码（校验、存储、APNs 发送、后台页面……）
├── test/                       自动测试（node --test）
├── package.json                只用来写 `npm test` 的快捷命令，没有依赖
└── deploy/
    ├── install.sh              一键安装 / 更新脚本（Debian / Ubuntu）
    ├── mashu-push.service      systemd 服务文件
    ├── mashu-push.env.example  配置文件模板（中文注释）
    └── nginx-snippet.conf      需要加到 nginx 里的两段 location
```

安装后服务器上的位置：

| 内容 | 位置 |
| --- | --- |
| 程序 | `/opt/mashu-push/` |
| 配置（后台用户名和密码） | `/etc/mashu-push.env`（权限 600） |
| Apple 推送密钥（在后台“推送设置”里保存的） | `/var/lib/mashu-push/apns.json`（属主 mashu-push，权限 600） |
| 数据（设备 token、发送记录） | `/var/lib/mashu-push/tokens.json`、`history.json` |
| 服务 | `systemctl status mashu-push`，日志 `journalctl -u mashu-push` |

---

## 部署步骤（第一次）

需要：一台已经用 nginx 跑着 mle.doge6.com 的 Linux 服务器（Debian / Ubuntu 最省事），root 权限。

> **最省事的办法：用 GitHub Actions 部署。** 仓库里的 **Deploy push service** 工作流（`.github/workflows/deploy-push.yml`）
> 会自动完成下面第 2–5 步（上传、安装、加 nginx 转发、检查）。它只需要两个 secret：`DEPLOY_SSH_KEY` 和
> `PUSH_ADMIN_PASSWORD`（后台密码，12 位以上，只用字母和数字）。**部署不涉及 Apple 推送密钥**——部署完成后
> 打开后台 → 推送设置 → 粘贴 .p8、填 Key ID / Team ID → 保存并检查（第 6 步）。

### 第 1 步：准备 Apple 推送密钥（在电脑上）

1. 登录 [Apple Developer](https://developer.apple.com/account/resources/authkeys/list) → **Certificates, IDs & Profiles → Keys**。
2. 如果已经有勾选了 **Apple Push Notifications service (APNs)** 的 Key，直接用它（.p8 只能下载一次，找找之前下载的 `AuthKey_XXXXXXXXXX.p8`）；
   没有的话点 **+** 新建一个，勾选 APNs，下载 `.p8` 文件。
3. 记下两个 10 位的编号：
   - **Key ID**：就是文件名 `AuthKey_` 后面那 10 位；
   - **Team ID**：在 Apple Developer 页面右上角或 **Membership** 页面里。

这三样东西先留在自己电脑上，**不用上传到服务器**，第 6 步在网页后台里粘贴即可。

### 第 2 步：把程序上传到服务器

在电脑上（项目根目录）执行，把 `server/push` 整个目录传上去（`你的服务器` 换成 IP 或域名）：

```bash
scp -r server/push root@你的服务器:/root/mashu-push-src
```

（如果服务器上能 `git clone` 这个仓库，也可以直接 clone，然后进入 `server/push` 目录。）

### 第 3 步：运行安装脚本

登录服务器：

```bash
ssh root@你的服务器
cd /root/mashu-push-src
bash deploy/install.sh
```

脚本会自动：安装 Node.js（没有或版本低于 20 时）、创建用户 `mashu-push`、复制程序到 `/opt/mashu-push`、
生成配置文件 `/etc/mashu-push.env`（**里面有一个随机生成的后台密码，屏幕上会显示一次，请记下来**）、安装并启动服务。
它**不会**改动 nginx。可以重复运行，不会覆盖已有的配置和数据。

想改后台用户名 / 密码，编辑 `/etc/mashu-push.env` 里的 `ADMIN_USER`、`ADMIN_PASSWORD`（密码至少 12 位，只用字母和数字最省心），
然后 `systemctl restart mashu-push`。**Apple 推送密钥不用写在这里**，第 6 步在网页后台里填。

### 第 4 步：在 nginx 里加转发

先找到 mle.doge6.com 的 nginx 配置文件：

```bash
grep -rl "mle.doge6.com" /etc/nginx/
```

用 `nano` 打开它，找到带 `listen 443 ssl` 的那个 `server { ... }` 块（如果用 certbot 开了 HTTPS，会有两个 server 块，**要放进 443 那个**），
把 `deploy/nginx-snippet.conf` 里的两段 `location` 粘贴进去，和已有的 `location / { ... }` 放在同一层。大概长这样：

```nginx
server {
    server_name mle.doge6.com;
    root /var/www/...;               # 原有内容，不要动
    location / { ... }               # 原有内容，不要动

    location /api/push/ { ... }      # ← 新加的
    location = /push-admin { ... }   # ← 新加的

    listen 443 ssl;                  # 原有内容（certbot 加的），不要动
    ...
}
```

检查并重载：

```bash
nginx -t && systemctl reload nginx
```

`nginx -t` 报错的话**不要** reload，先把错误修好（通常是少了 `}` 或粘贴到了 server 块外面）。

### 第 5 步：检查

```bash
curl https://mle.doge6.com/api/push/health
```

应该返回（还没填推送密钥时 `apns` 是 `false`，正常）：

```json
{"ok":true,"apns":false,"tokens":{"production":0,"sandbox":0}}
```

- 返回网页 404 → nginx 那一步没生效（放错了 server 块，或者没 reload）。
- `502 Bad Gateway` → 服务没在运行，看 `journalctl -u mashu-push -n 50 --no-pager`。

### 第 6 步：在后台填写 Apple 推送密钥

浏览器打开 **https://mle.doge6.com/push-admin**，输入用户名和密码，然后在最上面的 **推送设置（Apple 推送密钥）** 里：

1. 用文本编辑器打开 `AuthKey_XXXXXXXXXX.p8`，把**全部内容**（包括 `-----BEGIN PRIVATE KEY-----` 和 `-----END PRIVATE KEY-----` 两行）粘贴到大文本框；
2. 填 **Key ID** 和 **Team ID**（各 10 位）；
3. 点 **保存并检查**。

服务器会先拿这把密钥向 Apple 的正式环境和测试环境各试一次，**Apple 两边都认可才会保存**，保存后立即生效（不用重启）。
状态行变成绿色的“已配置 · Key ID … · 上次检查 … 正式环境 ✓ 测试环境 ✓”就好了，此时 health 也会变成 `"apns":true`。
App 用户打开通知后，“已登记的设备”数字会慢慢增加。

---

## 推送设置（Apple 推送密钥）

后台页面最上面的“推送设置”卡片：

- **状态行**：`已配置 · Key ID ABCD123456 · Team ID … · 来源 · 上次检查 … 正式环境 ✓ 测试环境 ✓`；没配置时显示橙色的 **未配置**，此时“发送”按钮不可用（预览人数仍可用）。
- **保存并检查**：粘贴 .p8、填 Key ID / Team ID 后点它。Apple 不认（例如 `InvalidProviderToken`：三样东西对不上或 Key 已吊销）时**不会保存**，并用中文说明原因；
  服务器连不上 Apple 时也不保存（提示“连不上 Apple”，多半是出站 443 被防火墙 / 安全组拦了）。保存成功后文本框会自动清空。
- **重新检查**：用当前在用的密钥再向 Apple 试一次（不发给任何用户）。
- **删除后台保存的密钥**：删掉后台保存的设置，改用环境变量里的（如果有的话）。
- 换密钥：直接粘贴新的 .p8、填新的 Key ID，再点“保存并检查”即可，立即生效。

安全：密钥保存在服务器的 `/var/lib/mashu-push/apns.json`（权限 600，只有服务自己能读）。后台页面和任何接口都**不会再显示**密钥，日志里只记录
`apns settings updated (key …最后4位KeyID)`。

**备选做法（环境变量）**：也可以像以前一样在 `/etc/mashu-push.env` 里写 `APNS_KEY_PATH`（或 `APNS_KEY_P8`）、`APNS_KEY_ID`、`APPLE_TEAM_ID`
并重启服务（见 `deploy/mashu-push.env.example`）。**后台保存的设置优先**；后台没保存（或删除了）时才用环境变量。

---

## 怎么发推送

1. 打开 https://mle.doge6.com/push-admin ，登录。（第一次用先在“推送设置”里填好 Apple 推送密钥，否则“发送”按钮是灰的。）
2. 填 **标题**（最多 50 字）和 **内容**（最多 200 字）。
3. 选 **发送对象**：全部用户 / 只发学英语 / 法语 / 泰语 的用户。
4. 选 **环境**：
   - **正式 production**：App Store 和 TestFlight 安装的用户（真正的用户都在这里）。
   - **测试 sandbox**：用 Xcode 直接装到手机上的开发版。想先给自己试发，就选这个。
5. 点 **先预览人数**：只算会发给多少台设备，不会真的发送。
6. 点 **发送**：会弹出确认框，显示发送对象和设备数，确认后才发送。发出后无法撤回。
7. 完成后显示：目标数、成功数、失败数、清理掉的失效设备数；下方“最近发送记录”保留最近 100 条。

小提示：

- 失败里有 `Unregistered` / `BadDeviceToken` 是正常的（用户卸载了 App 等），这些设备会被自动删掉，下次就不会再发。
- 不要频繁群发，用户会关掉通知甚至卸载。
- 同一时间只能进行一次发送；如果提示“another send is in progress”，等上一次完成即可。

---

## 更新程序

把新版的 `server/push` 目录再上传一次，然后重新运行安装脚本即可（配置、后台保存的推送密钥、数据都会保留）。
用 GitHub Actions 的话，重新运行 **Deploy push service** 即可。

```bash
cd /root/mashu-push-src && bash deploy/install.sh
```

---

## 备份数据

所有数据就是这几个文件：

- `/var/lib/mashu-push/tokens.json` —— 已登记的设备（最重要）
- `/var/lib/mashu-push/history.json` —— 发送记录
- `/var/lib/mashu-push/apns.json` —— 后台保存的 Apple 推送密钥（含私钥，备份时同样要保密；丢了也没关系，在后台重新粘贴 .p8 即可）

程序写文件时是“先写临时文件再改名”，任何时候直接复制都是完整的，不需要停服务。手动备份：

```bash
mkdir -p /root/backup
cp /var/lib/mashu-push/tokens.json /root/backup/tokens-$(date +%F).json
cp /var/lib/mashu-push/history.json /root/backup/history-$(date +%F).json
```

每天自动备份（保留 30 天），执行一次下面这条：

```bash
cat > /etc/cron.d/mashu-push-backup <<'EOF'
15 4 * * * root mkdir -p /root/backup/mashu-push && cp /var/lib/mashu-push/tokens.json /root/backup/mashu-push/tokens-$(date +\%F).json && find /root/backup/mashu-push -name 'tokens-*.json' -mtime +30 -delete
EOF
```

**恢复**：

```bash
systemctl stop mashu-push
cp /root/backup/tokens-2026-10-01.json /var/lib/mashu-push/tokens.json
chown mashu-push:mashu-push /var/lib/mashu-push/tokens.json
chmod 600 /var/lib/mashu-push/tokens.json
systemctl start mashu-push
```

另外记得把 `AuthKey_XXXXXXXXXX.p8` 和 `/etc/mashu-push.env` 也存一份在安全的地方（不要放进公开的地方或 git 仓库）。
即使 tokens.json 丢了也不是大问题：App 每次启动都会重新登记，用户会慢慢回来。

---

## 常见问题排查

先看日志，大部分问题日志里都写得很清楚：

```bash
systemctl status mashu-push
journalctl -u mashu-push -n 100 --no-pager
journalctl -u mashu-push -f          # 实时看（Ctrl+C 退出）
```

| 现象 / 错误 | 原因 | 解决 |
| --- | --- | --- |
| 服务起不来，日志 `config error: ADMIN_PASSWORD ...` | 后台密码没填或少于 12 位 | 改 `/etc/mashu-push.env`，`systemctl restart mashu-push` |
| 后台“推送设置”保存时提示 **Apple 没有接受这把密钥 … InvalidProviderToken** | Key ID、Team ID 和 .p8 对不上，或这个 Key 已被吊销 / 没勾选 APNs | 核对三者是同一个 Key（Key ID = 文件名 `AuthKey_` 后 10 位）；必要时在 Apple 新建 Key。没保存，原来的设置不受影响 |
| 保存时提示 **连不上 Apple**（HTTP 502） | 服务器连不上 Apple（防火墙 / 云安全组拦了出站 443） | `curl -v https://api.push.apple.com` 测试；放行出站 TCP 443 后再点“保存并检查” |
| 保存时提示 **.p8 内容无法识别** / **不是 Apple 推送用的密钥** | 粘贴得不完整，或粘贴了别的文件 | 用文本编辑器打开 `AuthKey_XXXXXXXXXX.p8`，全选复制（包括 BEGIN/END 两行） |
| 日志 `the APNs settings saved in apns.json are unusable` | apns.json 被手动改坏 | 在后台重新保存一次，或“删除后台保存的密钥” |
| `config error: cannot read APNS_KEY_PATH ...`（只在用环境变量方式时） | 私钥路径写错 / 权限不对 | 改用后台“推送设置”并删掉 env 里的 APNS_* 三行；或 `chown mashu-push:mashu-push` + `chmod 600` 那个文件 |
| `the APNs key could not be parsed` / `APNS_KEY_ID must be ...`（只在用环境变量方式时） | env 里的密钥或编号不对 | 同上，推荐改用后台“推送设置” |
| `tokens.json is not valid JSON` | 数据文件被手动改坏了 | 从备份恢复，或把它改名移走（会丢失已登记设备） |
| 发送后失败原因是 **403 InvalidProviderToken** | Key ID、Team ID 和 .p8 对不上，或这个 Key 已被吊销 / 没勾选 APNs | 核对三者是同一个 Key；必要时在 Apple 新建 Key |
| **403 ExpiredProviderToken** | 服务器时间不准 | `timedatectl` 查看，开启时间同步：`timedatectl set-ntp true` |
| **400 BadDeviceToken**（大量） | 环境选错：开发版（Xcode 装的）token 只能用 sandbox，App Store / TestFlight 的只能用 production | 发送时选对环境；这些设备已被自动清理，App 下次启动会以正确环境重新登记 |
| **400 DeviceTokenNotForTopic** | token 不属于 com.vocabloop.app | 自动清理，无需处理 |
| **410 Unregistered** | 用户卸载了 App 或关闭了通知 | 自动清理，正常现象 |
| **400 TopicDisallowed** | 这个 Key 所在的团队没有这个 App | 确认 Key 和 App 属于同一个 Apple 开发者团队 |
| **429 TooManyRequests** | 短时间给同一台设备发太多 | 过一会再发 |
| `network: ...` | 服务器连不上 Apple（防火墙 / 云安全组拦了出站 443） | `curl -v https://api.push.apple.com` 测试；放行出站 TCP 443 |
| 浏览器打开 /push-admin 是 404 | nginx 没加转发或没 reload | 第 4 步 |
| 502 Bad Gateway | 服务没运行 | `systemctl status mashu-push` 看原因 |
| 登录后台一直弹窗 | 用户名或密码错 | 看 `/etc/mashu-push.env` 里的 `ADMIN_USER` / `ADMIN_PASSWORD`；连续输错 10 次要等 1 分钟 |
| 手机收不到，但后台显示成功 | 手机关了通知 / 专注模式 / 低电量；生产环境偶尔会延迟 | 检查手机的通知设置；sandbox 环境用开发版测试 |

---

## 给 App 开发用的接口说明

App 直接调用（不需要登录）：

**登记设备** `POST https://mle.doge6.com/api/push/register`，`Content-Type: application/json`

```json
{
  "token": "a1b2c3...（设备 token 的十六进制字符串，64–200 位）",
  "environment": "production",
  "language": "en",
  "appVersion": "1.2.0",
  "locale": "zh-Hans_CN"
}
```

- `environment`：`"sandbox"`（Debug / Xcode 安装）或 `"production"`（App Store / TestFlight）。
- `language`：用户在学的语言，`"en"` / `"fr"` / `"th"`。
- `appVersion`、`locale` 可选。其他字段会被忽略（新版 App 多带字段也能登记）。
- 成功返回 `204`；同一个 token 重复登记会更新信息。建议每次 App 启动拿到 token、或用户切换学习语言时都调用一次。

**注销设备** `POST /api/push/unregister`，body `{"token":"..."}` → `204`（重复调用也是 204）。

**健康检查** `GET /api/push/health` → `{"ok":true,"apns":true,"tokens":{"production":n,"sandbox":n}}`

限制：请求体最大 4 KB；每个 IP 每分钟最多 30 次请求，超过返回 `429`。

后台接口（需要 HTTP Basic 登录，后台页面自己会调用；写操作要求 `Content-Type: application/json`，且浏览器的 Origin 必须是本站）：

- `POST /api/push/send`、`GET /api/push/admin/overview`
- `GET /api/push/admin/apns` → `{"configured":true,"source":"admin"|"env"|null,"keyId":"…","teamId":"…","updatedAt":"…","lastCheck":{"at":"…","production":{"ok":true,"status":400,"reason":"BadDeviceToken"},"sandbox":{…}}}`（**从不返回密钥**）
- `POST /api/push/admin/apns`，body `{"keyP8":"-----BEGIN PRIVATE KEY-----…","keyId":"ABC123DEFG","teamId":"TEAM123456"}`：先向 Apple 检查（给 64 个 0 的假设备 token 推送，两个环境都返回 `400 BadDeviceToken` 才算通过），
  通过才保存并立即生效 → 返回同上；Apple 不认 → `400`（中文原因，不保存）；连不上 Apple → `502`（不保存）
- `DELETE /api/push/admin/apns` → 删除后台保存的设置，改用环境变量（如果有）
- `POST /api/push/admin/apns/check` → 用当前密钥重新检查，返回 `{…状态, "ok":true|false, "message":"…"}`

### 本地开发和测试

```bash
cd server/push
npm test                       # 或：node --test test/*.test.mjs   （不联网，不需要 Apple 凭据）
ADMIN_PASSWORD=local-dev-password DATA_DIR=./data node server.mjs
# 然后打开 http://127.0.0.1:8787/push-admin（用户名 admin）
```

---

## 给服务器上的 AI 助手的说明

如果你让服务器上的 AI 助手（例如 Claude Code）帮你部署，把下面整段复制给它（先把 `server/push` 目录上传到服务器，并把尖括号里的内容换成实际值）。
Apple 推送密钥**不要**交给 AI 助手，部署完成后你自己在后台“推送设置”里粘贴（见第 6 步）。

````text
请在这台服务器上部署“麻薯背单词”的推送服务 mashu-push。要求严格按下面步骤做，每一步做完检查结果再继续；遇到不确定的情况先停下来问我，不要猜。

背景：
- 程序代码在 <上传位置，例如 /root/mashu-push-src>（里面有 server.mjs、lib/、deploy/、README.md）。先完整阅读 README.md 和 deploy/ 里的文件。
- Apple 推送密钥不归你处理：我会在部署完成后自己在网页后台填写。不要去找、创建或配置任何 .p8 文件，也不要修改 /etc/mashu-push.env 里的 APNS_* 项。
- 网站 mle.doge6.com 已经由 nginx 提供静态页面并有 HTTPS，不能影响它，也不能影响这台服务器上的其他网站。

步骤：
1. 以 root 运行：cd <上传位置> && bash deploy/install.sh 。记下它打印的后台密码，最后告诉我。
2. 用 journalctl -u mashu-push -n 30 --no-pager 确认日志里有 "mashu-push listening" 且没有 "config error"（"apns NOT configured" 是正常的）。
3. 用 grep -rl "mle.doge6.com" /etc/nginx/ 找到 mle.doge6.com 的配置文件。先备份（cp 文件 文件.bak-$(date +%F)）。把 deploy/nginx-snippet.conf 里的两段 location（/api/push/ 和 = /push-admin）原样加进 mle.doge6.com 的 HTTPS（listen 443）server 块里，与已有 location / 同级。不要修改该文件里的任何其他内容，不要改其他站点的配置。如果已经存在 /api/push/ 的 location，先停下来问我。
4. 运行 nginx -t。只有通过时才运行 systemctl reload nginx；失败就用备份恢复原文件并把错误告诉我。
5. 验证：
   - curl -s https://mle.doge6.com/api/push/health 返回 {"ok":true,"apns":false,...}（apns 是 false 正常，等我在后台填密钥）
   - curl -s -o /dev/null -w "%{http_code}\n" https://mle.doge6.com/push-admin 返回 401（说明需要登录，正常）
   - curl -s -o /dev/null -w "%{http_code}\n" https://mle.doge6.com/ 仍然返回 200（原网站没受影响）
   - 确认服务器能连到 Apple：curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 https://api.push.apple.com 有返回码（不是超时）；超时就告诉我出站 443 被拦了
6. 可选：按 README “备份数据”一节添加每天自动备份的 cron。

不要做的事：不要关闭防火墙、不要改 SSH 配置、不要安装 npm 包（这个程序没有依赖）、不要把 8787 端口对公网开放（它只监听 127.0.0.1）、不要删除 /var/lib/mashu-push 里的数据、不要读取或打印 /var/lib/mashu-push/apns.json。

完成后告诉我：每一步的结果、后台地址 https://mle.doge6.com/push-admin、用户名和密码、health 的返回内容。
最后提醒我：打开后台 → 推送设置 → 粘贴 .p8、填 Key ID / Team ID → 保存并检查。
````
