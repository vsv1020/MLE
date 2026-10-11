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
:root { --bg:#f6f5f2; --card:#fff; --text:#1f1d1a; --muted:#6e6a63; --line:#e4e1da; --accent:#c2552d; --accent-text:#fff; --ok:#2f7d4f; --err:#b3261e; }
@media (prefers-color-scheme: dark) { :root { --bg:#171614; --card:#211f1c; --text:#efece6; --muted:#a39e95; --line:#34312c; --accent:#e07a50; --accent-text:#1a1310; --ok:#6cc08f; --err:#f2827a; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:15px/1.55 -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif; }
main { max-width:720px; margin:0 auto; padding:24px 16px 48px; }
h1 { font-size:22px; margin:0 0 4px; }
h2 { font-size:16px; margin:0 0 12px; }
.sub { color:var(--muted); margin:0 0 20px; font-size:13px; }
.card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:18px; margin-bottom:16px; }
label { display:block; font-weight:600; margin:14px 0 6px; }
label:first-child { margin-top:0; }
input[type=text], textarea, select { width:100%; padding:10px 12px; border:1px solid var(--line); border-radius:8px; background:var(--bg); color:var(--text); font:inherit; }
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
</style>
</head>
<body>
<main>
  <h1>麻薯背单词 · 推送通知</h1>
  <p class="sub">给已开启通知的用户发送一条推送。建议先选“测试 sandbox”发给自己的测试机看看效果。</p>

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
        <button type="button" id="send" class="primary">发送</button>
      </div>
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

  function busy(on) { $('preview').disabled = on; $('send').disabled = on; }

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
})();
</script>
</body>
</html>
`;
}
