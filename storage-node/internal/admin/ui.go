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
h2 { font-size: 1rem; margin: 0 0 .5rem; }
.muted { opacity: .7; font-size: .9rem; }
.card { border: 1px solid color-mix(in srgb, CanvasText 20%, transparent);
  border-radius: 10px; padding: 1rem; margin: 1rem 0; }
button, input, select { font: inherit; padding: .4rem .7rem; }
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
  <p class="muted">无头节点管理面 · Noise 配对 / 浏览手删 / 用量 / 回收站 / 换机导入</p>
  <div class="card row">
    <label>Token <input id="token" type="password" placeholder="admin token" style="min-width:14rem"/></label>
    <button id="saveToken">保存</button>
    <button id="refresh">刷新</button>
  </div>
  <div class="card">
    <div class="row" style="justify-content:space-between">
      <h2>Noise 配对</h2>
      <button id="pairStart">开始配对</button>
    </div>
    <pre id="pairInfo" class="muted">点击「开始配对」生成 QR / 配对码，用 App 扫描后在此批准。</pre>
    <div id="pairPending"></div>
    <h2 style="margin-top:1rem">已配对设备</h2>
    <div id="peers"></div>
  </div>
  <div class="card">
    <h2>用量 stats</h2>
    <div class="row" style="justify-content:space-between;margin-bottom:.5rem">
      <span class="muted">启动时会自动 GC；也可手动触发。</span>
      <button id="runGc">GC staging/回收站</button>
    </div>
    <pre id="stats">…</pre>
    <h2 style="margin-top:1rem">设备镜像</h2>
    <p class="muted">永久删除他端镜像目录（不可进回收站；禁删本机）。</p>
    <div id="devices"></div>
  </div>
  <div class="card">
    <h2>分区浏览</h2>
    <p class="muted">对齐 App 存储浏览器：列出正式文件并删除（进回收站）。</p>
    <div class="row">
      <label>设备 <select id="browseDevice"></select></label>
      <label>分区 <select id="browseSpace">
        <option value="files">files</option>
        <option value="artifacts">artifacts</option>
        <option value="attachments">attachments</option>
        <option value="backups">backups</option>
      </select></label>
      <label>前缀 <input id="browsePath" placeholder="可选子路径" style="min-width:10rem"/></label>
      <button id="browseLoad">列出</button>
    </div>
    <div id="browse" style="margin-top:.75rem"></div>
  </div>
  <div class="card">
    <div class="row" style="justify-content:space-between">
      <h2>换机导入请求</h2>
    </div>
    <div id="imports"></div>
    <h2 style="margin-top:1rem">已签发授权</h2>
    <pre id="issued" class="muted">…</pre>
  </div>
  <div class="card">
    <div class="row" style="justify-content:space-between">
      <h2>回收站</h2>
      <button id="empty">清空回收站</button>
    </div>
    <div id="recycle"></div>
  </div>
  <div class="card">
    <h2>危险区</h2>
    <p class="muted">清空本机四分区正式文件与暂存（不删他端镜像、回收站、.system）。不可从回收站还原。</p>
    <div class="row">
      <input id="wipeConfirm" placeholder="输入 DELETE 确认" style="min-width:12rem"/>
      <button id="wipeSelf" style="color:#c62828">清空本机 store</button>
    </div>
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
function shortId(id) {
  id = String(id||'');
  return id.length > 8 ? id.slice(0,8) + '…' : id;
}
async function refresh() {
  $('msg').textContent = '';
  try {
    const stats = await api('/admin/api/stats');
    $('stats').textContent = JSON.stringify(stats, null, 2);
    const selfId = stats.self_device || stats.device || '';
    const devices = stats.devices || {};
    const ids = Object.keys(devices);
    if (!ids.length) {
      $('devices').innerHTML = '<p class="muted">无设备目录</p>';
    } else {
      let dhtml = '<table><thead><tr><th>device</th><th>占用</th><th></th></tr></thead><tbody>';
      for (const id of ids) {
        const spaces = devices[id] || {};
        let total = 0;
        for (const k of Object.keys(spaces)) total += Number(spaces[k])||0;
        const isSelf = id === selfId;
        dhtml += '<tr><td>' + shortId(id) + (isSelf ? ' <span class="muted">(本机)</span>' : '') +
          '</td><td>' + fmtBytes(total) + '</td><td>';
        if (!isSelf) {
          dhtml += '<button data-id="' + id + '" class="purgeDev">删除镜像</button>';
        }
        dhtml += '</td></tr>';
      }
      dhtml += '</tbody></table>';
      $('devices').innerHTML = dhtml;
      document.querySelectorAll('.purgeDev').forEach(btn => {
        btn.onclick = async () => {
          if (!confirm('永久删除设备 ' + shortId(btn.dataset.id) + ' 的镜像？不可还原。')) return;
          try {
            await api('/admin/api/devices/purge', {
              method:'POST', headers:{'Content-Type':'application/json'},
              body: JSON.stringify({device_id: btn.dataset.id})
            });
            refresh();
          } catch (e) { $('msg').textContent = String(e.message||e); }
        };
      });
    }

    // populate browse device select
    const browseSel = $('browseDevice');
    const prevBrowse = browseSel.value;
    const browseIds = ids.length ? ids.slice() : (selfId ? [selfId] : []);
    if (selfId && !browseIds.includes(selfId)) browseIds.unshift(selfId);
    browseSel.innerHTML = browseIds.map(id =>
      '<option value="' + id + '"' + (id === selfId ? ' selected' : '') + '>' +
      shortId(id) + (id === selfId ? ' (本机)' : '') + '</option>'
    ).join('');
    if (prevBrowse && browseIds.includes(prevBrowse)) browseSel.value = prevBrowse;

    try {
      const peers = await api('/admin/api/peers');
      const plist = peers.peers || [];
      if (!plist.length) {
        $('peers').innerHTML = '<p class="muted">暂无已配对设备</p>';
      } else {
        let phtml = '<table><thead><tr><th>名称</th><th>fingerprint</th><th></th></tr></thead><tbody>';
        for (const p of plist) {
          phtml += '<tr><td>' + (p.device_name||'') +
            '</td><td>' + shortId(p.fingerprint) +
            '</td><td><button data-fp="' + (p.fingerprint||'') +
            '" class="unpair">解除配对</button></td></tr>';
        }
        phtml += '</tbody></table>';
        $('peers').innerHTML = phtml;
        document.querySelectorAll('.unpair').forEach(btn => {
          btn.onclick = async () => {
            if (!confirm('解除配对 ' + shortId(btn.dataset.fp) + '？')) return;
            try {
              await api('/admin/api/peers/remove', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({fingerprint: btn.dataset.fp})
              });
              refresh();
            } catch (e) { $('msg').textContent = String(e.message||e); }
          };
        });
      }
      const pendingPair = await api('/admin/api/pairing/pending');
      const p = pendingPair.pending;
      if (!p) {
        $('pairPending').innerHTML = '';
      } else {
        $('pairPending').innerHTML = '<div class="row">入站请求：' +
          (p.device_name||'') + ' (' + shortId(p.fingerprint) + ') ' +
          '<button id="pairAccept">批准</button>' +
          '<button id="pairReject">拒绝</button></div>';
        $('pairAccept').onclick = async () => {
          await api('/admin/api/pairing/decide', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({accept:true})
          });
          refresh();
        };
        $('pairReject').onclick = async () => {
          await api('/admin/api/pairing/decide', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({accept:false})
          });
          refresh();
        };
      }
    } catch (_) {}

    const pending = await api('/admin/api/import/pending');
    const reqs = pending.requests || [];
    if (!reqs.length) {
      $('imports').innerHTML = '<p class="muted">暂无待审批请求</p>';
    } else {
      let html = '<table><thead><tr><th>新设备</th><th>旧设备</th><th></th></tr></thead><tbody>';
      for (const r of reqs) {
        html += '<tr><td>' + shortId(r.new_device) +
          '</td><td>' + shortId(r.old_device) +
          '</td><td class="row"><button data-id="' + r.request_id +
          '" class="grant">批准</button><button data-id="' + r.request_id +
          '" class="reject">拒绝</button></td></tr>';
      }
      html += '</tbody></table>';
      $('imports').innerHTML = html;
      document.querySelectorAll('.grant').forEach(btn => {
        btn.onclick = async () => {
          try {
            await api('/admin/api/import/grant', {
              method: 'POST',
              headers: {'Content-Type':'application/json'},
              body: JSON.stringify({request_id: btn.dataset.id})
            });
            refresh();
          } catch (e) { $('msg').textContent = String(e.message||e); }
        };
      });
      document.querySelectorAll('.reject').forEach(btn => {
        btn.onclick = async () => {
          try {
            await api('/admin/api/import/reject', {
              method: 'POST',
              headers: {'Content-Type':'application/json'},
              body: JSON.stringify({request_id: btn.dataset.id})
            });
            refresh();
          } catch (e) { $('msg').textContent = String(e.message||e); }
        };
      });
    }
    const issued = await api('/admin/api/import/grants?role=issued');
    $('issued').textContent = JSON.stringify(issued.grants || [], null, 2);

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
$('pairStart').onclick = async () => {
  try {
    const out = await api('/admin/api/pairing/start', {method:'POST'});
    $('pairInfo').textContent = 'code=' + out.code +
      '\nlocal=' + out.local_endpoint +
      (out.channel_endpoint ? ('\nchannel=' + out.channel_endpoint) : '') +
      '\nfp=' + out.fingerprint + '\n\n' + out.qr;
    refresh();
  } catch (e) { $('msg').textContent = String(e.message||e); }
};
$('empty').onclick = async () => {
  if (!confirm('确认清空回收站？不可还原。')) return;
  try {
    await api('/admin/api/recycle/empty', {method:'POST'});
    refresh();
  } catch (e) { $('msg').textContent = String(e.message||e); }
};
async function loadBrowse() {
  $('msg').textContent = '';
  try {
    const device = $('browseDevice').value;
    const space = $('browseSpace').value;
    const path = ($('browsePath').value || '').trim();
    const q = new URLSearchParams({device, space});
    if (path) q.set('path', path);
    const out = await api('/admin/api/browse?' + q.toString());
    const entries = out.entries || [];
    if (!entries.length) {
      $('browse').innerHTML = '<p class="muted">无文件</p>';
      return;
    }
    let html = '<table><thead><tr><th>路径</th><th>大小</th><th></th></tr></thead><tbody>';
    for (const e of entries) {
      html += '<tr><td>' + (e.path||'') + '</td><td>' + fmtBytes(e.size) +
        '</td><td><button data-path="' + encodeURIComponent(e.path||'') +
        '" class="browseDel">删除</button></td></tr>';
    }
    html += '</tbody></table>';
    $('browse').innerHTML = html;
    document.querySelectorAll('.browseDel').forEach(btn => {
      btn.onclick = async () => {
        const p = decodeURIComponent(btn.dataset.path);
        if (!confirm('删除 ' + p + '？将移入回收站。')) return;
        try {
          await api('/admin/api/browse/delete', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({
              device: $('browseDevice').value,
              space: $('browseSpace').value,
              path: p
            })
          });
          loadBrowse();
          refresh();
        } catch (e) { $('msg').textContent = String(e.message||e); }
      };
    });
  } catch (e) { $('msg').textContent = String(e.message||e); }
}
$('browseLoad').onclick = loadBrowse;
$('runGc').onclick = async () => {
  try {
    const out = await api('/admin/api/gc', {method:'POST'});
    alert('GC 完成：staging 清理 ' + (out.staging_removed||0) +
      ' 个，回收站释放 ' + fmtBytes(out.recycle_bytes));
    refresh();
  } catch (e) { $('msg').textContent = String(e.message||e); }
};
$('wipeSelf').onclick = async () => {
  const confirm = ($('wipeConfirm').value || '').trim();
  if (confirm !== 'DELETE') {
    $('msg').textContent = '请先在输入框输入 DELETE';
    return;
  }
  if (!window.confirm('确认清空本机 store？此操作不可从回收站还原。')) return;
  try {
    const out = await api('/admin/api/devices/wipe-self', {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({confirm: 'DELETE'})
    });
    $('wipeConfirm').value = '';
    $('msg').textContent = '';
    alert('已清空本机 store，释放 ' + fmtBytes(out.freed_bytes));
    refresh();
  } catch (e) { $('msg').textContent = String(e.message||e); }
};
refresh();
</script>
</body>
</html>
`
