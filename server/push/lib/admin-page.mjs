// The /push-admin page: one self-contained HTML document (no external resources).
// Nothing dynamic is interpolated into the HTML on the server except the CSP nonce (random hex).
// All data shown on the page is inserted in the browser with textContent, never innerHTML.
import { TITLE_MAX, BODY_MAX } from './validate.mjs';

export function adminPage(nonce) {
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>麻薯背单词 · 推送</title>
<style nonce="${nonce}">
:root { --bg:#f6f5f2; --card:#fff; --text:#1f1d1a; --muted:#6e6a63; --line:#e4e1da; --accent:#c2552d; --accent-text:#fff; --ok:#2f7d4f; --err:#b3261e; --warn:#b85c00; }
@media (prefers-color-scheme: dark) { :root { --bg:#171614; --card:#211f1c; --text:#efece6; --muted:#a39e95; --line:#34312c; --accent:#e07a50; --accent-text:#1a1310; --ok:#6cc08f; --err:#f2827a; --warn:#f0a35a; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:15px/1.55 -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif; }
main { max-width:720px; margin:0 auto; padding:24px 16px 48px; }
h1 { font-size:22px; margin:0 0 4px; }
h2 { font-size:16px; margin:0 0 12px; }
.sub { color:var(--muted); margin:0 0 20px; font-size:13px; }
.card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:18px; margin-bottom:16px; }
label { display:block; font-weight:600; margin:14px 0 6px; }
label:first-child { margin-top:0; }
input[type=text], input[type=password], textarea, select { width:100%; padding:10px 12px; border:1px solid var(--line); border-radius:8px; background:var(--bg); color:var(--text); font:inherit; }
textarea { min-height:96px; resize:vertical; }
.count { float:right; font-weight:400; color:var(--muted); font-size:12px; }
.count.over { color:var(--err); }
.radios { display:flex; gap:18px; flex-wrap:wrap; }
.radios label { display:flex; align-items:center; gap:6px; font-weight:400; margin:0; }
.actions { display:flex; gap:10px; margin-top:18px; flex-wrap:wrap; }
button { padding:10px 18px; border-radius:8px; border:1px solid var(--line); background:var(--card); color:var(--text); font:inherit; cursor:pointer; }
button.primary { background:var(--accent); color:var(--accent-text); border-color:var(--accent); font-weight:600; }
button:disabled { opacity:.5; cursor:default; }
#result { margin-top:14px; padding:12px; border-radius:8px; background:var(--bg); display:none; white-space:pre-wrap; }
#result.ok { display:block; border-left:3px solid var(--ok); }
#result.err { display:block; border-left:3px solid var(--err); }
.stats { display:grid; grid-template-columns:repeat(auto-fit, minmax(150px, 1fr)); gap:10px; }
.stat { background:var(--bg); border-radius:8px; padding:10px 12px; }
.stat b { font-size:20px; display:block; }
.stat span { color:var(--muted); font-size:12px; }
.history { list-style:none; margin:0; padding:0; }
.history li { border-top:1px solid var(--line); padding:10px 0; }
.history li:first-child { border-top:0; padding-top:0; }
.h-title { font-weight:600; }
.h-body { color:var(--text); margin:2px 0; overflow-wrap:anywhere; }
.h-meta { color:var(--muted); font-size:12px; }
.empty { color:var(--muted); }
.status { font-weight:600; margin:0 0 6px; overflow-wrap:anywhere; }
.status.ok { color:var(--ok); }
.status.warn { color:var(--warn); }
.status.err { color:var(--err); }
.help { color:var(--muted); font-size:13px; margin:0 0 4px; }
.help ol { margin:6px 0 0; padding-left:20px; }
.row { display:grid; grid-template-columns:1fr 1fr; gap:12px; }
@media (max-width: 480px) { .row { grid-template-columns:1fr; } }
textarea.mono, input.mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size:13px; }
.hint { color:var(--warn); font-size:13px; margin-top:10px; display:none; }
.hint.show { display:block; }
.msg { margin-top:14px; padding:12px; border-radius:8px; background:var(--bg); display:none; white-space:pre-wrap; overflow-wrap:anywhere; }
.msg.ok { display:block; border-left:3px solid var(--ok); }
.msg.err { display:block; border-left:3px solid var(--err); }
</style>
</head>
<body>
<main>
  <h1>麻薯背单词 · 推送通知</h1>
  <p class="sub">给已开启通知的用户发送一条推送。建议先选“测试 sandbox”发给自己的测试机看看效果。</p>

  <section class="card" id="apnsCard">
    <h2>推送设置（Apple 推送密钥）</h2>
    <p class="status" id="apnsStatus">加载中…</p>
    <div class="help">
      没有这三项就不能发送。在 <b>developer.apple.com → Certificates, IDs &amp; Profiles → Keys</b> 里找到（或点 + 新建）勾选了
      <b>Apple Push Notifications service (APNs)</b> 的 Key：
      <ol>
        <li>.p8 文件只能下载一次（文件名 AuthKey_XXXXXXXXXX.p8），用文本编辑器打开，全部复制粘贴到下面；</li>
        <li>Key ID 就是文件名 AuthKey_ 后面那 10 位；</li>
        <li>Team ID 在 developer.apple.com 的 Membership 页面（10 位）。</li>
      </ol>
      保存前会先让 Apple 试验一次，Apple 认可才会保存。保存后密钥只存在服务器上，这个页面不会再显示它。
    </div>
    <form id="apnsForm" autocomplete="off">
      <label for="keyP8">.p8 密钥</label>
      <textarea id="keyP8" class="mono" maxlength="4096" spellcheck="false" autocapitalize="off" autocorrect="off" placeholder="粘贴 .p8 文件的全部内容（包括 BEGIN/END 两行）"></textarea>
      <div class="row">
        <div>
          <label for="keyId">Key ID</label>
          <input type="text" id="keyId" class="mono" maxlength="10" spellcheck="false" autocapitalize="characters" placeholder="例如 ABC123DEFG">
        </div>
        <div>
          <label for="teamId">Team ID</label>
          <input type="text" id="teamId" class="mono" maxlength="10" spellcheck="false" autocapitalize="characters" placeholder="例如 TEAM123456">
        </div>
      </div>
      <div class="actions">
        <button type="button" id="apnsSave" class="primary">保存并检查</button>
        <button type="button" id="apnsCheck">重新检查</button>
        <button type="button" id="apnsDelete" hidden>删除后台保存的密钥</button>
      </div>
      <div id="apnsResult" class="msg" role="status"></div>
    </form>
  </section>

  <section class="card">
    <h2>已登记的设备</h2>
    <div class="stats" id="stats"><div class="empty">加载中…</div></div>
  </section>

  <section class="card">
    <h2>写一条推送</h2>
    <form id="form" autocomplete="off">
      <label for="title">标题 <span class="count" id="titleCount">0/${TITLE_MAX}</span></label>
      <input type="text" id="title" maxlength="${TITLE_MAX * 2}" placeholder="例如：今天的单词还没背哦">
      <label for="body">内容 <span class="count" id="bodyCount">0/${BODY_MAX}</span></label>
      <textarea id="body" maxlength="${BODY_MAX * 2}" placeholder="例如：花 5 分钟复习一下，记得更牢。"></textarea>
      <label for="language">发送对象</label>
      <select id="language">
        <option value="">全部用户</option>
        <option value="en">只发学英语的用户</option>
        <option value="fr">只发学法语的用户</option>
        <option value="th">只发学泰语的用户</option>
      </select>
      <label>环境</label>
      <div class="radios">
        <label><input type="radio" name="env" value="production" checked> 正式 production（App Store / TestFlight 用户）</label>
        <label><input type="radio" name="env" value="sandbox"> 测试 sandbox（Xcode 直接装的开发机）</label>
      </div>
      <div class="actions">
        <button type="button" id="preview">先预览人数</button>
        <button type="button" id="send" class="primary" disabled>发送</button>
      </div>
      <div class="hint" id="sendHint">还没有配置 Apple 推送密钥，暂时不能发送（可以先预览人数）。请先在上面的“推送设置”里填写。</div>
      <div id="result" role="status"></div>
    </form>
  </section>

  <section class="card">
    <h2>最近发送记录</h2>
    <ul class="history" id="history"><li class="empty">加载中…</li></ul>
  </section>
</main>
<script nonce="${nonce}">
(function () {
  'use strict';
  var TITLE_MAX = ${TITLE_MAX}, BODY_MAX = ${BODY_MAX};
  var LANG = { '': '全部用户', en: '学英语的用户', fr: '学法语的用户', th: '学泰语的用户' };
  var ENV = { production: '正式 production', sandbox: '测试 sandbox' };
  var $ = function (id) { return document.getElementById(id); };
  var len = function (s) { return Array.from(s.trim()).length; };

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = String(text);
    return e;
  }

  function counter(input, out, max) {
    var n = len(input.value);
    out.textContent = n + '/' + max;
    out.classList.toggle('over', n > max);
  }
  $('title').addEventListener('input', function () { counter($('title'), $('titleCount'), TITLE_MAX); });
  $('body').addEventListener('input', function () { counter($('body'), $('bodyCount'), BODY_MAX); });

  function form(dryRun) {
    var env = document.querySelector('input[name=env]:checked').value;
    var lang = $('language').value;
    var data = { title: $('title').value, body: $('body').value, environment: env, dryRun: dryRun };
    if (lang) data.language = lang;
    return data;
  }

  function show(kind, text) {
    var r = $('result');
    r.className = kind;
    r.textContent = text;
  }

  async function api(method, path, data) {
    var res = await fetch(path, {
      method: method,
      credentials: 'same-origin',
      headers: data ? { 'Content-Type': 'application/json' } : {},
      body: data ? JSON.stringify(data) : undefined,
    });
    var json = null;
    try { json = await res.json(); } catch (e) { /* not JSON */ }
    if (!res.ok) throw new Error((json && json.error) || ('HTTP ' + res.status));
    return json;
  }

  function check() {
    var t = len($('title').value), b = len($('body').value);
    if (!t || !b) { show('err', '标题和内容都要填写。'); return false; }
    if (t > TITLE_MAX) { show('err', '标题最多 ' + TITLE_MAX + ' 个字。'); return false; }
    if (b > BODY_MAX) { show('err', '内容最多 ' + BODY_MAX + ' 个字。'); return false; }
    return true;
  }

  var apnsReady = false, isBusy = false;
  function busy(on) { isBusy = on; $('preview').disabled = on; $('send').disabled = on || !apnsReady; }

  function describe(d) { return ENV[d.environment] + ' · ' + LANG[d.language || '']; }

  $('preview').addEventListener('click', async function () {
    if (!check()) return;
    busy(true);
    try {
      var d = form(true), r = await api('POST', '/api/push/send', d);
      show('ok', '预览：' + describe(d) + '，共 ' + r.targeted + ' 台设备会收到。（还没有发送）');
    } catch (e) { show('err', '预览失败：' + e.message); }
    busy(false);
  });

  $('send').addEventListener('click', async function () {
    if (!check()) return;
    busy(true);
    try {
      var d = form(true), pre = await api('POST', '/api/push/send', d);
      if (pre.targeted === 0) { show('err', '没有符合条件的设备（' + describe(d) + '），没有发送。'); busy(false); return; }
      var ok = window.confirm('确定发送吗？\\n\\n对象：' + describe(d) + '\\n设备数：' + pre.targeted +
        '\\n\\n标题：' + d.title.trim() + '\\n内容：' + d.body.trim() + '\\n\\n发出后无法撤回。');
      if (!ok) { show('err', '已取消，没有发送。'); busy(false); return; }
      d.dryRun = false;
      show('ok', '发送中…');
      var r = await api('POST', '/api/push/send', d);
      var lines = ['发送完成：目标 ' + r.targeted + '，成功 ' + r.sent + '，失败 ' + r.failed + '，清理失效设备 ' + r.removed + '。'];
      if (r.reasons && Object.keys(r.reasons).length) {
        lines.push('失败原因：' + Object.keys(r.reasons).map(function (k) { return k + ' × ' + r.reasons[k]; }).join('，'));
      }
      show(r.failed && !r.sent ? 'err' : 'ok', lines.join('\\n'));
      load();
    } catch (e) { show('err', '发送失败：' + e.message); }
    busy(false);
  });

  function stat(n, label) {
    var d = el('div', 'stat');
    d.appendChild(el('b', '', n));
    d.appendChild(el('span', '', label));
    return d;
  }

  async function load() {
    try {
      var o = await api('GET', '/api/push/admin/overview');
      var s = $('stats');
      s.replaceChildren();
      ['production', 'sandbox'].forEach(function (env) {
        var b = (o.breakdown && o.breakdown[env]) || { total: 0, en: 0, fr: 0, th: 0 };
        s.appendChild(stat(b.total, ENV[env] + '（英 ' + b.en + ' / 法 ' + b.fr + ' / 泰 ' + b.th + '）'));
      });
      var h = $('history');
      h.replaceChildren();
      if (!o.history.length) h.appendChild(el('li', 'empty', '还没有发送过。'));
      o.history.forEach(function (x) {
        var li = el('li');
        li.appendChild(el('div', 'h-title', x.title));
        li.appendChild(el('div', 'h-body', x.body));
        var when = new Date(x.time).toLocaleString('zh-CN', { hour12: false });
        li.appendChild(el('div', 'h-meta', when + ' · ' + describe(x) + ' · 目标 ' + x.targeted +
          '，成功 ' + x.sent + '，失败 ' + x.failed + '，清理 ' + x.removed));
        h.appendChild(li);
      });
    } catch (e) {
      $('stats').replaceChildren(el('div', 'empty', '加载失败：' + e.message));
    }
  }
  load();

  // ---------------------------------------------------------------- 推送设置
  var SOURCE = { admin: '后台设置', env: '服务器环境变量' };
  function mark(r) { return r && r.ok ? '✓' : '✗'; }
  function fmtTime(iso) { return iso ? new Date(iso).toLocaleString('zh-CN', { hour12: false }) : ''; }

  function showApns(kind, text) {
    var r = $('apnsResult');
    r.className = 'msg ' + kind;
    r.textContent = text;
  }

  function renderApns(s) {
    apnsReady = Boolean(s && s.configured);
    var st = $('apnsStatus');
    if (!apnsReady) {
      st.className = 'status warn';
      st.textContent = '未配置 —— 现在还不能发送推送';
    } else {
      var parts = ['已配置', 'Key ID ' + s.keyId, 'Team ID ' + s.teamId, '来源：' + (SOURCE[s.source] || s.source)];
      if (s.updatedAt) parts.push('保存于 ' + fmtTime(s.updatedAt));
      var c = s.lastCheck, bad = false;
      if (c && c.production && c.sandbox) {
        parts.push('上次检查 ' + fmtTime(c.at) + ' 正式环境 ' + mark(c.production) + ' 测试环境 ' + mark(c.sandbox));
        bad = !(c.production.ok && c.sandbox.ok);
      } else {
        parts.push('还没检查过');
      }
      st.className = 'status ' + (bad ? 'err' : 'ok');
      st.textContent = parts.join(' · ');
      if (!$('keyId').value) $('keyId').value = s.keyId || '';
      if (!$('teamId').value) $('teamId').value = s.teamId || '';
    }
    $('apnsCheck').disabled = !apnsReady;
    $('apnsDelete').hidden = !(s && s.source === 'admin');
    $('sendHint').classList.toggle('show', !apnsReady);
    busy(isBusy);
  }

  async function loadApns() {
    try { renderApns(await api('GET', '/api/push/admin/apns')); }
    catch (e) { $('apnsStatus').className = 'status err'; $('apnsStatus').textContent = '读取推送设置失败：' + e.message; }
  }

  function apnsBusy(on) {
    $('apnsSave').disabled = on;
    $('apnsCheck').disabled = on || !apnsReady;
    $('apnsDelete').disabled = on;
  }

  function upper(input) {
    input.addEventListener('input', function () {
      var v = input.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
      if (v !== input.value) input.value = v;
    });
  }
  upper($('keyId'));
  upper($('teamId'));

  var ID_RE = /^[A-Z0-9]{10}$/;
  $('apnsSave').addEventListener('click', async function () {
    var keyP8 = $('keyP8').value.trim(), keyId = $('keyId').value.trim(), teamId = $('teamId').value.trim();
    if (!keyP8) { showApns('err', '请粘贴 .p8 文件的全部内容（包括 BEGIN/END 两行）。'); return; }
    if (keyP8.indexOf('-----BEGIN') !== 0 || keyP8.indexOf('-----END') < 0) { showApns('err', '.p8 内容要包括 -----BEGIN PRIVATE KEY----- 和 -----END PRIVATE KEY----- 两行。'); return; }
    if (!ID_RE.test(keyId)) { showApns('err', 'Key ID 必须正好是 10 位大写字母或数字。'); return; }
    if (!ID_RE.test(teamId)) { showApns('err', 'Team ID 必须正好是 10 位大写字母或数字。'); return; }
    apnsBusy(true);
    showApns('ok', '正在让 Apple 检查这把密钥…');
    try {
      var r = await api('POST', '/api/push/admin/apns', { keyP8: keyP8, keyId: keyId, teamId: teamId });
      $('keyP8').value = '';
      showApns('ok', '已保存，马上生效。' + (r.message || ''));
      renderApns(r);
    } catch (e) { showApns('err', e.message); }
    apnsBusy(false);
  });

  $('apnsCheck').addEventListener('click', async function () {
    apnsBusy(true);
    showApns('ok', '正在检查…');
    try {
      var r = await api('POST', '/api/push/admin/apns/check', {});
      showApns(r.ok ? 'ok' : 'err', r.message || (r.ok ? '检查通过。' : '检查没有通过。'));
      renderApns(r);
    } catch (e) { showApns('err', '检查失败：' + e.message); }
    apnsBusy(false);
  });

  $('apnsDelete').addEventListener('click', async function () {
    if (!window.confirm('删除后台保存的 Apple 推送密钥吗？\\n\\n删除后如果服务器环境变量里也没有配置，就不能发送推送了。')) return;
    apnsBusy(true);
    try {
      var r = await api('DELETE', '/api/push/admin/apns', {});
      $('keyId').value = ''; $('teamId').value = '';
      showApns('ok', r.configured ? '已删除，现在使用服务器环境变量里的密钥。' : '已删除，现在没有配置 Apple 推送密钥。');
      renderApns(r);
    } catch (e) { showApns('err', '删除失败：' + e.message); }
    apnsBusy(false);
  });

  loadApns();
})();
</script>
</body>
</html>
`;
}
