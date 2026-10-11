#!/usr/local/bin/node
// ZQuota BTT 版 —— BetterTouchTool TouchBar Shell Script Widget 数据渲染器
// 输出 BTT widget JSON：{"text": 双行文本, "font_color": RGBA, "icon_path": 双行电量条 PNG}
// 布局对齐 ZQuota APP：行1 = 5 小时窗 / 行2 = 周限额，每行 标题 剩余% 重置时间 | 倒计时
//
// 用法：
//   zquota-btt             常规输出（缓存 TTL 25s，避免与 30s widget 刷新叠加打 API）
//   zquota-btt --refresh   强制刷 API 并即时 refresh_widget（刷新按钮/点击 widget 用）
//
// 数据链路同 ~/.local/bin/zcode-quota：解密 credentials → api.z.ai quota/limit
import { createHash, createDecipheriv } from "node:crypto";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { execFileSync } from "node:child_process";
import { join } from "node:path";

const HOME = homedir();
const BTT_DIR = `${HOME}/ZCodeProject/zquota/btt`;
const ICONS = `${BTT_DIR}/icons`;
const CACHE_DIR = `${HOME}/.cache/zquota-btt`;
const CACHE = `${CACHE_DIR}/state.json`;
const UUID_FILE = `${BTT_DIR}/widget-uuid.txt`;
const TTL = 25_000;

const args = new Set(process.argv.slice(2));
const NODE = "/usr/local/bin/node";

function decrypt(blob) {
  const secret = process.env.ZCODE_CREDENTIAL_SECRET
    ?? `zcode-credential-fallback:${process.platform}:${HOME}:${userInfo().username}`;
  const key = createHash("sha256").update(secret).digest();
  const [head, tagB64, ctB64] = blob.split(".");
  const d = createDecipheriv("aes-256-gcm", key, Buffer.from(head.slice(7), "base64url"));
  d.setAuthTag(Buffer.from(tagB64, "base64url"));
  return Buffer.concat([d.update(Buffer.from(ctB64, "base64url")), d.final()]).toString();
}

// 凭据双源：优先 config.json 的 provider 明文 apiKey，回退 credentials.json 解密（与 App 的 ZCodeQuotaClient 一致）
function loadToken() {
  try {
    const cfg = JSON.parse(readFileSync(`${HOME}/.zcode/v2/config.json`, "utf8"));
    const apiKey = cfg?.provider?.["builtin:bigmodel-coding-plan"]?.options?.apiKey;
    if (apiKey) return apiKey;
  } catch {}
  return decrypt(JSON.parse(readFileSync(`${HOME}/.zcode/v2/credentials.json`, "utf8"))["oauth:bigmodel:access_token"]);
}

async function fetchQuota() {
  const token = loadToken();
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 10000);
  const r = await fetch("https://api.z.ai/api/monitor/usage/quota/limit", {
    headers: { Authorization: `Bearer ${token}` }, signal: ctrl.signal,
  });
  clearTimeout(timer);
  const body = await r.json();
  if (body.code !== 200) throw new Error(`接口返回 ${body.code} ${body.msg}`);
  // 窗口语义映射（与 App 的 makeSnapshot 一致）：unit=3&number=5 → 5h、unit=6 → 周；
  // 字段缺失回退按 nextResetTime 排序（周窗临近重置时排序会认错窗口，语义优先）
  const tokens = body.data.limits.filter((l) => l.type === "TOKENS_LIMIT");
  let fiveHour = tokens.find((l) => l.unit === 3 && (l.number ?? 5) === 5);
  let weekly = tokens.find((l) => l.unit === 6);
  if (!fiveHour || !weekly) {
    const sorted = [...tokens].sort((a, b) => (a.nextResetTime ?? 0) - (b.nextResetTime ?? 0));
    fiveHour = fiveHour ?? sorted[0];
    weekly = weekly ?? (sorted.length >= 2 ? sorted[1] : sorted[0]);
  }
  const windows = [fiveHour, weekly].filter(Boolean)
    .map((l) => ({ left: Math.round(100 - l.percentage), reset: l.nextResetTime }));
  return { ts: Date.now(), windows };
}

function readCache() {
  try { return JSON.parse(readFileSync(CACHE, "utf8")); } catch { return null; }
}

// 倒计时文案，与 ZQuota TouchBarRateLimitsView.resetCountdownText 一致
function countdown(resetMs) {
  const seconds = Math.max(0, Math.floor((resetMs - Date.now()) / 1000));
  const h = Math.floor(seconds / 3600), m = Math.floor((seconds % 3600) / 60);
  if (h >= 24) return `${Math.floor(h / 24)}天${h % 24}时后重置`;
  if (h >= 1) return `${h}时${m}分后重置`;
  return `${m}分后重置`;
}

function resetClock(resetMs) {
  const d = new Date(resetMs);
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getMonth() + 1}月${d.getDate()}日 ${p(d.getHours())}:${p(d.getMinutes())} 重置`;
}

// 电量条 PNG：不存在则懒渲染（组合有限，出现过的组合都会落盘复用）
function barIcon(p1, p2) {
  const f = `${ICONS}/bar_${p1}_${p2}.png`;
  if (!existsSync(f)) {
    execFileSync("swift", [`${BTT_DIR}/render-bars.swift`, "one", String(p1), String(p2), f, "23", "8"],
      { timeout: 60_000 });
  }
  return f;
}

function lineFor(title, w) {
  if (!w || w.left == null) return `${title} 剩余 --`;
  return `${title} 剩${w.left}% ${resetClock(w.reset)} | ${countdown(w.reset)}`;
}

function render(state) {
  const [w1, w2] = state.windows ?? [];
  // 与 ZQuota App 的 staleInterval 一致：超过 10 分钟未成功刷新即视为陈旧，前缀 ⚠
  const warn = state.ts && Date.now() - state.ts > 10 * 60_000 ? "⚠ " : "";
  const text = `${warn}${lineFor("5小时", w1)}\n${lineFor("周限额", w2)}`;
  return { text, font_color: "235,235,245,255", icon_path: barIcon(w1?.left ?? 0, w2?.left ?? 0) };
}

async function main() {
  let state = readCache();
  if (args.has("--refresh") || !state || Date.now() - state.ts > TTL) {
    try {
      state = await fetchQuota();
      mkdirSync(CACHE_DIR, { recursive: true });
      writeFileSync(CACHE, JSON.stringify(state));
    } catch (e) {
      if (!state) state = { ts: 0, windows: [] }; // 无缓存时展示占位
      process.stderr.write(`[zquota-btt] ${e.message}\n`);
    }
  }
  const out = render(state);
  console.log(JSON.stringify(out));

  // --refresh：让 BTT 立即重跑 widget 脚本上屏新内容（顺序：先写缓存再刷新）
  if (args.has("--refresh")) {
    try {
      const uuid = readFileSync(UUID_FILE, "utf8").trim();
      if (uuid) execFileSync("osascript", ["-e", `tell application "BetterTouchTool" to refresh_widget "${uuid}"`], { timeout: 15000 });
    } catch (e) {
      process.stderr.write(`[zquota-btt] refresh_widget 失败：${e.message}\n`);
    }
  }
}

main();
