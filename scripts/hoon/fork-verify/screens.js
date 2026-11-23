// Screen comparison for fork-verify.sh, run through `playwright-cli run-code`.
// fork_verify.py replaces __CONFIG__ with a JSON object and deletes the file
// after the run (it carries the two bearer tokens).
//
// Production is read only: every non-GET request, to any origin or path, is
// aborted and counted, and every WebSocket is replaced by a silent stub.
// The candidate replays production's GET responses recorded in this run, so
// both frontends draw the same data; a request production never made goes to
// the candidate backend with the production workspace id swapped for the
// test workspace. The chat endpoints answer from a synthetic fixture on both
// sides, so the chips under test never show real chat titles.
async page => {
  const C = __CONFIG__;
  const browser = page.context().browser();
  const recorded = new Map();
  const freezeCss = '*,*::before,*::after{animation:none!important;transition:none!important;caret-color:transparent!important}';
  const maskCss = C.mask.map((s) => `${s}{filter:blur(8px)!important}`).join('\n');

  function fixtureFor(u) {
    const p = u.pathname;
    if (p === '/api/chat/sessions') return C.fixture.sessions;
    if (p === '/api/chat/pending-tasks') return C.fixture.pending;
    if (p === '/api/chat/pending-tasks/has-any') return { has_pending: C.fixture.pending.tasks.length > 0 };
    const sm = /^\/api\/chat\/sessions\/([^/]+)\/(messages(?:\/page)?|pending-task|draft-restores|wakeups)$/.exec(p);
    if (sm) {
      const msgs = C.fixture.messages[sm[1]] || [];
      if (sm[2] === 'messages') return msgs;
      if (sm[2] === 'messages/page') return { messages: msgs, limit: 50, has_more: false, next_cursor: null };
      if (!msgs.length) return null;
      return sm[2] === 'pending-task' ? {} : sm[2] === 'draft-restores' ? { restores: [] } : [];
    }
    if (/^\/api\/chat\/sessions\/[^/]+$/.test(p)) {
      const id = p.split('/').pop();
      return C.fixture.sessions.find((s) => s.id === id) || null;
    }
    return null;
  }

  async function makeContext(side, width) {
    const ctx = await browser.newContext({ viewport: { width, height: C.height }, deviceScaleFactor: 1, locale: C.locale, timezoneId: C.timezone });
    side.stats = side.stats || { blocked: [], replayed: 0, recorded: 0, passthrough: [] };
    await ctx.addCookies([{ name: 'multica_logged_in', value: '1', url: side.origin }]);
    await ctx.addInitScript(([tok, extra]) => {
      try {
        localStorage.setItem('multica_token', tok);
        for (const [k, v] of Object.entries(extra)) localStorage.setItem(k, v);
      } catch (e) {}
    }, [side.token, side.localStorage || {}]);
    await ctx.routeWebSocket(side.name === 'prod' ? /.*/ : /\/(ws|api\/daemon\/ws)(\?|$)/, () => {});
    await ctx.route('**/*', async (route) => {
      const req = route.request();
      const u = new URL(req.url());
      // Production is read only: any request that could change state, to any
      // origin or path (server actions, /v1, a separate API host), is aborted.
      if (side.name === 'prod' && !['GET', 'HEAD', 'OPTIONS'].includes(req.method())) {
        side.stats.blocked.push(`${req.method()} ${u.pathname}`);
        return route.abort();
      }
      if (u.origin !== side.origin) return route.continue();
      if (!(u.pathname.startsWith('/api/') || u.pathname.startsWith('/auth/'))) return route.continue();
      if (!['GET', 'HEAD', 'OPTIONS'].includes(req.method())) {
        side.stats.blocked.push(`${req.method()} ${u.pathname}`);
        return route.abort();
      }
      const fx = fixtureFor(u);
      if (fx !== null) return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(fx) });
      const key = u.pathname + u.search;
      if (side.name === 'prod') {
        const resp = await route.fetch();
        const body = await resp.body();
        recorded.set(key, { status: resp.status(), contentType: resp.headers()['content-type'] || 'application/json', body });
        side.stats.recorded++;
        return route.fulfill({ response: resp, body });
      }
      const rec = recorded.get(key);
      if (rec) {
        side.stats.replayed++;
        return route.fulfill({ status: rec.status, contentType: rec.contentType, body: rec.body });
      }
      if (!side.stats.passthrough.includes(key)) side.stats.passthrough.push(key);
      const headers = { ...req.headers() };
      if (headers['x-workspace-id']) headers['x-workspace-id'] = C.cand.wsId;
      return route.continue({ url: req.url().split(C.prod.wsId).join(C.cand.wsId), headers });
    });
    const p = await ctx.newPage();
    await p.clock.setFixedTime(new Date(C.now));
    return { ctx, p };
  }

  async function settle(p) {
    try { await p.waitForSelector('[data-mc="page"]', { timeout: 30000 }); } catch (e) {}
    try { await p.waitForLoadState('networkidle', { timeout: 15000 }); } catch (e) {}
    await p.addStyleTag({ content: freezeCss + '\n' + maskCss });
    await p.waitForTimeout(C.settleMs);
  }

  async function rectOf(p, sel) {
    const el = await p.$(sel);
    if (!el) return null;
    const b = await el.boundingBox();
    return b ? { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.width), h: Math.round(b.height) } : null;
  }

  async function selectorCounts(p, sels) {
    const out = {};
    for (const s of sels) out[s] = (await p.$$(s)).length;
    return out;
  }

  // Chip and overflow state of the bottom chat bar, then the scenario's two
  // interactions: the wheel scrolls the strip sideways, and a click on the
  // right-most chip opens the chat window with that chip in view.
  async function chatBarProbe(p, interact) {
    const r = { bar: (await p.$$('[data-slot="chat-bar"]')).length };
    if (!r.bar) return r;
    r.chips = (await p.$$('[data-slot="chat-bar"] [data-chat-anchor]:not([data-chat-anchor="new"])')).length;
    r.overflowButtons = await p.$$eval('[data-slot="chat-bar"] button', (els) =>
      els.filter((e) => /^\+\d+$/.test((e.textContent || '').trim()) || /\d+ more chat|채팅 \d+개 더 보기/i.test(e.getAttribute('aria-label') || '')).length);
    const strip = await p.$('[data-slot="chat-bar-chips"]');
    r.strip = !!strip;
    if (!interact || !strip) return r;
    const m = await strip.evaluate((s) => ({ sw: s.scrollWidth, cw: s.clientWidth, left: s.scrollLeft }));
    r.stripScrollable = m.sw > m.cw;
    const team = await rectOf(p, '[data-slot="app-bottom-bar"] > div:first-child');
    const sb = await strip.boundingBox();
    await p.mouse.move(sb.x + sb.width / 2, sb.y + sb.height / 2);
    await p.mouse.wheel(0, 400);
    await p.waitForTimeout(400);
    r.wheelScrolled = (await strip.evaluate((s) => s.scrollLeft)) !== m.left;
    const teamAfter = await rectOf(p, '[data-slot="app-bottom-bar"] > div:first-child');
    r.teamStatusKeptWidth = !team || !teamAfter || team.w === teamAfter.w;
    const chips = await p.$$('[data-slot="chat-bar-chips"] [data-chat-anchor]');
    const last = chips[chips.length - 1];
    await last.click();
    await p.waitForTimeout(1200);
    r.windowOpen = (await p.$$('[data-mc="chat-window"]')).length > 0;
    r.clickedChipInView = await p.evaluate(() => {
      const s = document.querySelector('[data-slot="chat-bar-chips"]');
      const cs = s ? s.querySelectorAll('[data-chat-anchor]') : [];
      const c = cs[cs.length - 1];
      if (!s || !c) return false;
      const a = s.getBoundingClientRect(), b = c.getBoundingClientRect();
      return b.left >= a.left - 1 && b.right <= a.right + 1;
    });
    return r;
  }

  // Mod+Alt+[ / ] in an open chat: press back once per sent message, then forward
  // back to the newest one, and read the top-most visible row after every press.
  async function promptNavProbe(p, cfg) {
    const r = { list: (await p.$$(cfg.listSelector)).length, rows: 0 };
    const list = await p.$(cfg.listSelector);
    if (!list) return r;
    const read = () => list.evaluate((el) => {
      const top = el.getBoundingClientRect().top;
      let best = null;
      for (const row of el.querySelectorAll('[data-item-index]')) {
        const b = row.getBoundingClientRect();
        if (b.bottom <= top + 2) continue;
        if (!best || b.top < best.b.top) best = { row, b };
      }
      if (!best) return null;
      const msg = best.row.querySelector('[data-mc="chat-message"]');
      const kind = best.row.querySelector('[data-slot="chat-wakeup-divider"]') ? 'divider' : msg && msg.getAttribute('data-role') === 'user' ? 'user' : 'reply';
      const m = /fv-prompt-\d+/.exec(best.row.textContent || '');
      return { kind, token: kind === 'divider' ? 'divider' : m ? m[0] : null, index: Number(best.row.getAttribute('data-item-index')),
        offset: Math.round(best.b.top - top), scroll: Math.round(el.scrollTop) };
    });
    // Hidden until Virtuoso has landed on the newest message; the keys are ignored before that.
    for (let i = 0; i < 100 && await list.evaluate((el) => el.classList.contains('invisible')); i++) await p.waitForTimeout(100);
    r.rows = (await list.$$('[data-mc="chat-message"]')).length;
    const composer = await p.$(cfg.composerSelector);
    if (composer) {
      try { await composer.click({ timeout: 1500 }); } catch (e) { await composer.focus(); }
    }
    const focused = () => composer ? composer.evaluate((el) => el === document.activeElement || el.contains(document.activeElement)) : false;
    r.composerFocused = await focused();
    // The jump lands within a frame or two, then holds the row at the top for about a second.
    const mod = (await p.evaluate(() => navigator.platform)).toLowerCase().includes('mac') ? 'Meta' : 'Control';
    r.seen = {};
    const note = async () => {
      for (const sel of cfg.selectors || []) r.seen[sel] = Math.max(r.seen[sel] || 0, (await p.$$(sel)).length);
    };
    const press = async (key) => {
      await p.keyboard.press(`${mod}+Alt+${key}`);
      await p.waitForTimeout(250);
      let last = null;
      for (let t0 = Date.now(); Date.now() - t0 < 3000; await p.waitForTimeout(120)) {
        const s = await read();
        if (s && last && s.scroll === last.scroll && Math.abs(s.offset) <= cfg.alignPx) return s;
        last = s;
      }
      return read();
    };
    const row = (s) => s ? { kind: s.kind, token: s.token, index: s.index, offset: s.offset } : { kind: null, token: null, index: null, offset: null };
    r.back = [];
    for (let i = 0; i < cfg.expect.length; i++) { r.back.push(row(await press('['))); await note(); }
    r.forward = [];
    for (let i = 1; i < cfg.expect.length; i++) { r.forward.push(row(await press(']'))); await note(); }
    r.focusKept = await focused();
    return r;
  }

  const shots = [];
  for (const shot of C.shots) {
    const out = { id: shot.id, width: shot.width, path: shot.path, sides: {} };
    for (const side of [C.prod, C.cand]) {
      const { ctx, p } = await makeContext(side, shot.width);
      const res = { error: null };
      try {
        await p.goto(side.origin + shot.path, { waitUntil: 'load', timeout: 60000 });
        await settle(p);
        res.url = new URL(p.url()).pathname;
        res.page = (await p.$$('[data-mc="page"]')).length > 0;
        res.selectors = await selectorCounts(p, shot.selectors || []);
        res.region = await rectOf(p, C.regionSelector);
        await p.screenshot({ path: `${C.outDir}/${shot.id}.${side.name}.png` });
        if (shot.probe === 'prompt-nav') {
          res.probe = await promptNavProbe(p, shot.promptNav);
          // The list is virtualized: a row the probe stepped past may already be
          // unmounted, so a selector counts if it matched before or during the run.
          for (const [sel, n] of Object.entries(res.probe.seen || {})) res.selectors[sel] = Math.max(res.selectors[sel] || 0, n);
          await p.screenshot({ path: `${C.outDir}/${shot.id}-open.${side.name}.png` });
        }
        if (shot.probe === 'chat-bar') {
          res.probe = await chatBarProbe(p, shot.interact);
          if (shot.interact && res.probe.windowOpen) {
            await p.waitForTimeout(300);
            await p.screenshot({ path: `${C.outDir}/${shot.id}-open.${side.name}.png` });
            res.openShot = true;
          }
        }
      } catch (e) {
        res.error = String(e && e.message ? e.message : e).slice(0, 300);
      }
      out.sides[side.name] = res;
      await ctx.close();
    }
    shots.push(out);
  }
  const stats = (s) => ({ blocked: s.stats ? s.stats.blocked.length : 0, blockedSample: s.stats ? s.stats.blocked.slice(0, 5) : [],
    recorded: s.stats ? s.stats.recorded : 0, replayed: s.stats ? s.stats.replayed : 0, passthrough: s.stats ? s.stats.passthrough : [] });
  return JSON.stringify({ shots, prod: stats(C.prod), cand: stats(C.cand) });
}
