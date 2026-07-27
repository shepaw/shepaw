package admin

// Minimal headless admin page (M7). Token is prompted once and kept in sessionStorage.
const uiHTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>ShePaw Storage Admin</title>
<style>
:root { color-scheme: light dark; font-family: system-ui, sans-serif; }
body { margin: 0; padding: 1.25rem; max-width: 880px; }
h1 { font-size: 1.25rem; margin: 0 0 .5rem; }
.muted { opacity: .7; font-size: .9rem; }
.card { border: 1px solid color-mix(in srgb, CanvasText 20%, transparent);
  border-radius: 10px; padding: 1rem; margin: 1rem 0; }
button, input { font: inherit; padding: .4rem .7rem; }
button { cursor: pointer; }
.row { display: flex; gap: .5rem; flex-wrap: wrap; align-items: center; }
pre { white-space: pre-wrap; word-break: break-word; font-size: .85rem; }
.err { color: #c62828; }
table { width: 100%; border-collapse: collapse; font-size: .9rem; }
td, th { text-align: left; padding: .35rem .25rem; border-bottom: 1px solid
  color-mix(in srgb, CanvasText 12%, transparent); }
</style>
</head>
<body>
  <h1>ShePaw Storage Admin</h1>
  <p class="muted">无头节点管理面 · 用量 / 回收站（需 admin token 或本机 loopback）</p>
  <div class="card row">
    <label>Token <input id="token" type="password" placeholder="admin token" style="min-width:14rem"/></label>
    <button id="saveToken">保存</button>
    <button id="refresh">刷新</button>
  </div>
  <div class="card">
    <h2 style="font-size:1rem;margin:0 0 .5rem">用量 stats</h2>
    <pre id="stats">…</pre>
  </div>
  <div class="card">
    <div class="row" style="justify-content:space-between">
      <h2 style="font-size:1rem;margin:0">回收站</h2>
      <button id="empty">清空回收站</button>
    </div>
    <div id="recycle"></div>
  </div>
  <p id="msg" class="err"></p>
<script>
const $ = (id) => document.getElementById(id);
const tokenKey = 'shepaw_admin_token';
$('token').value = sessionStorage.getItem(tokenKey) || '';
$('saveToken').onclick = () => {
  sessionStorage.setItem(tokenKey, $('token').value.trim());
  refresh();
};
function headers() {
  const t = sessionStorage.getItem(tokenKey) || '';
  const h = {'Accept':'application/json'};
  if (t) h['Authorization'] = 'Bearer ' + t;
  return h;
}
async function api(path, opts={}) {
  const res = await fetch(path, {...opts, headers: {...headers(), ...(opts.headers||{})}});
  if (res.status === 401) throw new Error('unauthorized — 检查 token');
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.message || data.error || res.statusText);
  return data;
}
function fmtBytes(n) {
  n = Number(n)||0;
  if (n < 1024) return n + ' B';
  if (n < 1048576) return (n/1024).toFixed(1) + ' KB';
  if (n < 1073741824) return (n/1048576).toFixed(1) + ' MB';
  return (n/1073741824).toFixed(1) + ' GB';
}
async function refresh() {
  $('msg').textContent = '';
  try {
    const stats = await api('/admin/api/stats');
    $('stats').textContent = JSON.stringify(stats, null, 2);
    const rec = await api('/admin/api/recycle');
    const entries = rec.entries || [];
    if (!entries.length) {
      $('recycle').innerHTML = '<p class="muted">回收站为空</p>';
      return;
    }
    let html = '<table><thead><tr><th>路径</th><th>大小</th><th></th></tr></thead><tbody>';
    for (const e of entries) {
      const path = (e.space||'') + '/' + (e.origin_path||'');
      html += '<tr><td>' + path + '<div class="muted">' + (e.recycle_path||'') +
        '</div></td><td>' + fmtBytes(e.size) +
        '</td><td><button data-path="' + encodeURIComponent(e.recycle_path||'') +
        '" class="restore">还原</button></td></tr>';
    }
    html += '</tbody></table>';
    $('recycle').innerHTML = html;
    document.querySelectorAll('.restore').forEach(btn => {
      btn.onclick = async () => {
        try {
          await api('/admin/api/recycle/restore', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({recycle_path: decodeURIComponent(btn.dataset.path)})
          });
          refresh();
        } catch (e) { $('msg').textContent = String(e.message||e); }
      };
    });
  } catch (e) {
    $('msg').textContent = String(e.message||e);
  }
}
$('refresh').onclick = refresh;
$('empty').onclick = async () => {
  if (!confirm('确认清空回收站？不可还原。')) return;
  try {
    await api('/admin/api/recycle/empty', {method:'POST'});
    refresh();
  } catch (e) { $('msg').textContent = String(e.message||e); }
};
refresh();
</script>
</body>
</html>
`
