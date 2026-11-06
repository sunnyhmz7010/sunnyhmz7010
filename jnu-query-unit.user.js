// ==UserScript==
// @name         新版报销系统（线上审批）·本人收款信息速查
// @namespace    jnu.cw.local
// @version      1.0.0
// @description  在新版报销系统（线上审批）页面内按姓名/学号查询本人收款信息；同源调用，仅本机显示，不写入任何服务端
// @match        https://cw.jnu.edu.cn/znwb/*
// @match        https://cw.jnu.edu.cn/znwb
// @run-at       document-start
// @noframes
// @grant        none
// ==/UserScript==

(function () {
  'use strict';

  // ===== 接口常量（来自 HAR 抓包）=====
  // 查询校内人员（收款人）信息，返回明细含银行账号
  const API_QUERY = '/wbwg/ibps/expend/hallMyBill/queryUnitList';
  // 取付款方式列表，用于拿到 billTemplatePayId
  const API_PAYS = '/wbwg/ibps/expend/hallMyBill/getMakeCollections';
  const TEMPLATE_ID = '1532259590784901121';  // 报账单模板 id
  const PAY_FALLBACK = '1668464474396610563'; // 「转个人卡」付款方式 id 兜底
  const PAY_TTL = 10 * 60 * 1000;             // payId 缓存有效期
  const REQUEST_TIMEOUT = 10000;              // 单次请求超时（ms）
  const MAX_CANDIDATES = 4;                   // token 候选上限，控制请求次数
  const SS_PAY_ID = 'jnu_cw_payid_cache';
  const LS_TOKEN = 'jnu_cw_token_manual';
  const SS_CAPTURED = 'jnu_cw_token_captured';
  const SS_LAST_GOOD = 'jnu_cw_token_lastgood';
  const SS_REJECTED = 'jnu_cw_token_rejected';
  const LS_COLLAPSED = 'jnu_cw_collapsed';
  const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  // ===== 登录 token =====
  // 页面自己的请求会带真 token，这里旁路捕获，避免在 storage 里瞎猜。
  let capturedToken = '';

  function noteHeader(name, value) {
    if (!/access.?token/i.test(String(name))) return;
    const v = String(value == null ? '' : value).trim();
    // 值没变就不重复写 sessionStorage，页面轮询时每次都会走这里
    if (!UUID_RE.test(v) || v === capturedToken) return;
    capturedToken = v;
    sessionStorage.setItem(SS_CAPTURED, v);
  }

  function hookTokenCapture() {
    // 旧版本脚本同时启用时避免重复包裹 fetch/XHR
    if (window.__jnuQuickLookupHooked) return;
    window.__jnuQuickLookupHooked = true;
    // 页面可能用 axios/XHR，也可能用 fetch，两条都挂
    const origSetHeader = XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
      try { noteHeader(name, value); } catch (e) { /* 捕获失败不影响页面 */ }
      return origSetHeader.call(this, name, value);
    };
    const origFetch = window.fetch;
    if (origFetch) {
      window.fetch = function (input, init) {
        try {
          const h = init && init.headers;
          if (h) {
            if (typeof h.forEach === 'function') h.forEach((v, k) => noteHeader(k, v));
            else Object.keys(h).forEach((k) => noteHeader(k, h[k]));
          }
        } catch (e) { /* 忽略 */ }
        return origFetch.apply(this, arguments);
      };
    }
  }

  function storageTokenCandidates() {
    const strong = [];
    const loose = [];
    [localStorage, sessionStorage].forEach((store) => {
      for (let i = 0; i < store.length; i += 1) {
        const key = store.key(i);
        const val = (store.getItem(key) || '').trim();
        if (!val) continue;
        if (UUID_RE.test(val)) {
          // key 名像 token 的优先，其余当备用候选
          if (/token|auth|ticket|session/i.test(key)) strong.push(val);
          else loose.push(val);
        } else if (val[0] === '{' || val[0] === '[') {
          const m = val.match(/"access_?token"\s*:\s*"([0-9a-f-]{36})"/i);
          if (m) strong.push(m[1]);
        }
      }
    });
    // 有强候选就不再用弱候选，少发无谓请求
    return strong.length ? strong : loose;
  }

  // 候选顺序：上次成功的 > 手动填写 > 请求里捕获的 > storage 里像 token 的
  function tokenCandidates() {
    const raw = [
      sessionStorage.getItem(SS_LAST_GOOD),
      localStorage.getItem(LS_TOKEN),
      capturedToken,
      sessionStorage.getItem(SS_CAPTURED),
    ].concat(storageTokenCandidates());
    const out = [];
    const rejected = rejectedTokens();
    raw.forEach((t) => {
      const v = String(t == null ? '' : t).trim();
      if (UUID_RE.test(v) && out.indexOf(v) === -1 && rejected.indexOf(v) === -1
        && out.length < MAX_CANDIDATES) out.push(v);
    });
    return out;
  }

  // 被服务端否掉的 token：页面 storage 里可能还留着同一个无效值，记下来避免下次再试
  function rejectedTokens() {
    try {
      const raw = sessionStorage.getItem(SS_REJECTED);
      const list = raw ? JSON.parse(raw) : [];
      return Array.isArray(list) ? list : [];
    } catch (e) {
      return [];
    }
  }

  function noteTokenSuccess(token) {
    sessionStorage.setItem(SS_LAST_GOOD, token);
    // 成功过的 token 从黑名单里移除，避免误杀
    const rest = rejectedTokens().filter((t) => t !== token);
    if (!rest.length) sessionStorage.removeItem(SS_REJECTED);
    else sessionStorage.setItem(SS_REJECTED, JSON.stringify(rest));
  }

  // token 被服务端否掉时清掉本地缓存，并加入黑名单
  function forgetToken(token) {
    if (token === capturedToken) {
      capturedToken = '';
      sessionStorage.removeItem(SS_CAPTURED);
    }
    if (token === sessionStorage.getItem(SS_LAST_GOOD)) sessionStorage.removeItem(SS_LAST_GOOD);
    try {
      const list = rejectedTokens();
      if (list.indexOf(token) === -1) {
        list.push(token);
        sessionStorage.setItem(SS_REJECTED, JSON.stringify(list.slice(-8)));
      }
    } catch (e) { /* 存不下就算了 */ }
  }

  function isTokenError(err) {
    return /token|令牌|登录|鉴权|授权|认证|失效/i.test(String(err && err.message));
  }

  function isPayIdError(err) {
    return /付款方式|billTemplatePayId|支付方式|参数/i.test(String(err && err.message));
  }

  // ===== 请求封装 =====
  // 前端实际同时发下划线和连字符两个认证头；openresty/nginx 默认丢弃带下划线的头，
  // 网关真正认的是连字符版，所以两个都发。
  function headers(token) {
    return {
      'Content-Type': 'application/json',
      Accept: 'application/json, text/plain, */*',
      'X-Authorization-access_token': token,
      'X-Authorization-access-token': token,
      'X-Authorization-systemid': 'App061',
    };
  }

  async function request(url, init, token) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), REQUEST_TIMEOUT);
    try {
      const res = await fetch(url, {
        credentials: 'same-origin',
        ...init,
        headers: headers(token),
        signal: ctrl.signal,
      });
      if (!res.ok) throw new Error('HTTP ' + res.status + ' ' + res.statusText);
      let json;
      try {
        json = await res.json();
      } catch (e) {
        // 登录失效时网关可能直接回登录页 HTML
        throw new Error('响应不是 JSON（HTTP ' + res.status + '），登录可能已失效或被网关拦截');
      }
      if (!json || json.state !== 200 || json.success === false) {
        throw new Error((json && json.message) || '接口返回异常：state=' + (json && json.state));
      }
      return json;
    } catch (err) {
      if (err && err.name === 'AbortError') throw new Error('请求超时（' + REQUEST_TIMEOUT / 1000 + ' 秒）');
      throw err;
    } finally {
      clearTimeout(timer);
    }
  }

  // ===== billTemplatePayId：sessionStorage + 10 分钟 TTL，失败时清缓存重解析 =====
  function readCachedPayId() {
    try {
      const raw = sessionStorage.getItem(SS_PAY_ID);
      if (!raw) return '';
      const obj = JSON.parse(raw);
      if (obj && obj.id && Date.now() - obj.ts < PAY_TTL) return obj.id;
      sessionStorage.removeItem(SS_PAY_ID);
    } catch (e) {
      sessionStorage.removeItem(SS_PAY_ID);
    }
    return '';
  }

  function cachePayId(id) {
    try {
      sessionStorage.setItem(SS_PAY_ID, JSON.stringify({ id: id, ts: Date.now() }));
    } catch (e) { /* 存不下就不缓存 */ }
  }

  function clearPayIdCache() {
    try { sessionStorage.removeItem(SS_PAY_ID); } catch (e) { /* 忽略 */ }
  }

  async function resolvePayId(token) {
    const cached = readCachedPayId();
    if (cached) return cached;
    let json;
    try {
      json = await request(
        API_PAYS + '?billTemplateId=' + encodeURIComponent(TEMPLATE_ID),
        { method: 'GET' },
        token,
      );
    } catch (err) {
      // token 问题交给上层换候选；其它错误用兜底 id 继续
      if (isTokenError(err)) throw err;
      console.warn('[速查] 取付款方式失败，使用兜底 id：', err);
      return PAY_FALLBACK;
    }
    const list = (json.data || []);
    const hit = list.find((x) => x.num === 'xnryzk') || list.find((x) => x.id === PAY_FALLBACK);
    if (hit && hit.id) {
      cachePayId(hit.id);
      return hit.id;
    }
    return PAY_FALLBACK;
  }

  // 纯数字按学号/工号精确查，否则按姓名模糊查
  async function queryUnit(input, token) {
    const isNum = /^\d+$/.test(input);
    const payId = await resolvePayId(token);
    const body = {
      parameters: [
        { key: 'code', value: isNum ? input : '' },
        { key: 'name', value: isNum ? '' : input },
        { key: 'billTemplatePayId', value: payId },
      ],
      requestPage: { pageNo: 1, limit: 20, totalCount: null },
      sorts: [],
    };
    const json = await request(API_QUERY, { method: 'POST', body: JSON.stringify(body) }, token);
    return (json.data && json.data.dataResult) || [];
  }

  // ===== UI =====
  const CSS = `
  #jnu-quick-lookup {
    position: fixed; right: 16px; bottom: 16px; width: 384px; z-index: 2147483000;
    background: #fff; color: #1f2329; border: 1px solid #e3e6eb; border-radius: 10px;
    box-shadow: 0 8px 28px rgba(0,0,0,.16); font: 13px/1.5 -apple-system, "Segoe UI", "Microsoft YaHei", sans-serif;
  }
  #jnu-quick-lookup .jql-head {
    display: flex; align-items: center; justify-content: space-between;
    padding: 8px 12px; border-bottom: 1px solid #f0f2f5; font-weight: 600; cursor: default;
  }
  #jnu-quick-lookup .jql-toggle {
    border: 0; background: none; padding: 2px 4px; font-size: 12px; line-height: 1;
    cursor: pointer; color: #3370ff;
  }
  #jnu-quick-lookup .jql-body { padding: 10px 12px 12px; }
  #jnu-quick-lookup.jql-collapsed .jql-body { display: none; }
  #jnu-quick-lookup .jql-row { display: flex; gap: 8px; }
  #jnu-quick-lookup .jql-input {
    flex: 1; min-width: 0; height: 30px; padding: 0 8px; border: 1px solid #dcdfe6;
    border-radius: 6px; font: inherit; outline: none;
  }
  #jnu-quick-lookup .jql-input:focus { border-color: #3370ff; }
  #jnu-quick-lookup button.jql-go {
    height: 30px; padding: 0 14px; border: 0; border-radius: 6px; background: #3370ff;
    color: #fff; font: inherit; cursor: pointer;
  }
  #jnu-quick-lookup button.jql-go:disabled { background: #a8c1ff; cursor: default; }
  #jnu-quick-lookup .jql-status { min-height: 18px; margin-top: 6px; color: #8a919f; font-size: 12px; }
  #jnu-quick-lookup .jql-status.jql-err { color: #d83931; }
  #jnu-quick-lookup .jql-out { max-height: 320px; overflow: auto; margin-top: 4px; }
  #jnu-quick-lookup .jql-card { padding: 8px; border: 1px solid #eef0f4; border-radius: 8px; margin-bottom: 8px; }
  #jnu-quick-lookup .jql-name { font-weight: 600; }
  #jnu-quick-lookup .jql-code { font-weight: 400; color: #8a919f; margin-left: 6px; }
  #jnu-quick-lookup .jql-line { color: #4e5969; }
  #jnu-quick-lookup .jql-sub { color: #8a919f; font-size: 12px; }
  #jnu-quick-lookup details { margin-top: 4px; }
  #jnu-quick-lookup summary { color: #3370ff; cursor: pointer; font-size: 12px; }
  #jnu-quick-lookup pre {
    margin: 6px 0 0; padding: 8px; max-height: 180px; overflow: auto; background: #f7f8fa;
    border-radius: 6px; font-size: 12px; white-space: pre-wrap; word-break: break-all;
  }
  #jnu-quick-lookup .jql-token { margin-top: 8px; }
  #jnu-quick-lookup .jql-token-tip { color: #8a919f; font-size: 12px; margin-top: 2px; }
  #jnu-quick-lookup .jql-token input { width: 100%; height: 28px; padding: 0 8px; border: 1px solid #dcdfe6; border-radius: 6px; font: inherit; }
  @media (max-width: 480px) {
    #jnu-quick-lookup { left: 8px; right: 8px; bottom: 8px; width: auto; }
    #jnu-quick-lookup .jql-out { max-height: 40vh; }
  }
  `;

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;',
    }[c]));
  }

  function render(list) {
    if (!list.length) return '<div class="jql-status">没有匹配记录</div>';
    return list.map((it) => `
      <div class="jql-card">
        <div class="jql-name">${esc(it.name)}<span class="jql-code">${esc(it.code)}</span></div>
        <div class="jql-line">${esc(it.departmentName)}</div>
        <div class="jql-line">${esc(it.displayBankAccountNum || it.displayBankCardNum)}</div>
        <div class="jql-line jql-sub">${esc(it.mainBankName)} ${esc(it.subBranchName)}</div>
        <details><summary>原始 JSON</summary><pre>${esc(JSON.stringify(it, null, 2))}</pre></details>
      </div>`).join('');
  }

  function mount() {
    if (document.getElementById('jnu-quick-lookup')) return;

    const box = document.createElement('div');
    box.id = 'jnu-quick-lookup';
    box.innerHTML = `
      <div class="jql-head"><span>本人收款信息速查</span><button class="jql-toggle" title="收起">收起</button></div>
      <div class="jql-body">
        <div class="jql-row">
          <input class="jql-input" placeholder="姓名 或 学号/工号" />
          <button class="jql-go">查询</button>
        </div>
        <div class="jql-status"></div>
        <div class="jql-out"></div>
        <details class="jql-token">
          <summary>token 设置（一般不用填）</summary>
          <input placeholder="X-Authorization-access-token" />
          <div class="jql-token-tip">留空则自动使用页面请求里捕获的 token；识别失败时，从 DevTools 任一请求头复制值粘到这里。</div>
        </details>
      </div>`;

    const style = document.createElement('style');
    style.textContent = CSS;
    document.head.appendChild(style);
    document.body.appendChild(box);

    const input = box.querySelector('.jql-input');
    const go = box.querySelector('.jql-go');
    const status = box.querySelector('.jql-status');
    const out = box.querySelector('.jql-out');
    const tokenInput = box.querySelector('.jql-token input');

    tokenInput.value = localStorage.getItem(LS_TOKEN) || '';
    tokenInput.addEventListener('change', () => {
      const v = tokenInput.value.trim();
      if (v) localStorage.setItem(LS_TOKEN, v);
      else localStorage.removeItem(LS_TOKEN);
      status.className = 'jql-status';
      status.textContent = v ? '已保存手动 token' : '已清空手动 token';
    });

    const toggle = box.querySelector('.jql-toggle');
    const applyCollapse = (collapsed) => {
      box.classList.toggle('jql-collapsed', collapsed);
      toggle.textContent = collapsed ? '展开' : '收起';
      toggle.title = collapsed ? '展开' : '收起';
    };
    // 上次的折叠状态：收起后刷新/重进页面保持收起
    applyCollapse(localStorage.getItem(LS_COLLAPSED) === '1');
    toggle.addEventListener('click', () => {
      const collapsed = !box.classList.contains('jql-collapsed');
      applyCollapse(collapsed);
      localStorage.setItem(LS_COLLAPSED, collapsed ? '1' : '0');
    });

    async function run() {
      if (go.disabled) return; // Enter 能绕过按钮禁用，这里挡住并发
      const value = input.value.trim();
      if (!value) return;
      const list = tokenCandidates();
      if (!list.length) {
        status.className = 'jql-status jql-err';
        status.textContent = '还没拿到登录 token：先在系统里点开任意报账页面产生一次请求（脚本会自动捕获），或在下方手动粘贴。';
        return;
      }
      go.disabled = true;
      status.className = 'jql-status';
      out.innerHTML = '';
      let lastErr = null;
      for (let i = 0; i < list.length; i += 1) {
        const token = list[i];
        status.textContent = '查询中…（token 候选 ' + (i + 1) + '/' + list.length + '）';
        try {
          let res;
          try {
            res = await queryUnit(value, token);
          } catch (err) {
            // payId 可能已过期或和当前模板不匹配：清缓存重解析一次再试
            if (!isPayIdError(err)) throw err;
            clearPayIdCache();
            res = await queryUnit(value, token);
          }
          noteTokenSuccess(token);
          status.className = 'jql-status';
          status.textContent = '共 ' + res.length + ' 条';
          out.innerHTML = render(res);
          go.disabled = false;
          return;
        } catch (err) {
          lastErr = err;
          // 只有 token 类错误才换下一个候选；网络/接口错误直接报
          if (!isTokenError(err)) break;
          forgetToken(token);
        }
      }
      status.className = 'jql-status jql-err';
      status.textContent = '查询失败：' + (lastErr && lastErr.message ? lastErr.message : lastErr) +
        '（已试 ' + list.length + ' 个候选，可把 DevTools 里的正确 token 粘到下方）';
      go.disabled = false;
    }

    go.addEventListener('click', run);
    input.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter') return;
      // 中文输入法组词时的 Enter 只是在确认候选词，不能触发查询
      if (e.isComposing || e.keyCode === 229) return;
      run();
    });
  }

  // document-start 注入：先挂请求捕获，等 DOM 就绪再挂面板
  hookTokenCapture();
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', mount, { once: true });
  } else {
    mount();
  }
})();
