// =====================================================================
// 모일날 Edge Function: link-preview
//
// 네이버지도·카카오맵 링크의 미리보기(가게 이름, 사진, 설명)를 읽어서 돌려준다.
//   요청: POST { "url": "https://naver.me/..." }
//   응답: { "title": "...", "image": "https://..." | null, "description": "...", "finalUrl": "https://..." }
//   오류: 400 { "error": "invalid_url" | "not_allowed" }, 502 { "error": "fetch_failed" }
//
// 안전장치
//   * https + 허용 도메인만. 리다이렉트는 직접 따라가며 매번 허용 도메인인지 확인 (최대 5회)
//   * 전체 5초 제한, 응답 본문은 1MB까지만 읽음
//   * 결과는 link_previews 테이블에 7일 캐시 (service role 키로만 접근, 키가 없으면 캐시 없이 동작)
//
// 배포: Supabase 대시보드 → Edge Functions → 이름 link-preview, "Verify JWT" 끔
//       (화면은 publishable 키로 호출하는데, publishable 키는 JWT 가 아니라서)
//       Secret 추가 필요 없음: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY 는 자동 제공.
//       레거시 키를 끈 프로젝트라면 MOILNAL_SECRET_KEY 에 sb_secret_... 키를 넣는다.
// =====================================================================

import { createClient } from 'npm:@supabase/supabase-js@2.57.4';

const ALLOWED_HOSTS = new Set([
  'naver.me',
  'map.naver.com',
  'm.map.naver.com',
  'm.place.naver.com',
  'pcmap.place.naver.com',
  'kko.to',
  'map.kakao.com',
  'place.map.kakao.com',
  'applink.map.kakao.com',
]);

const MAX_REDIRECTS = 5;
const TIMEOUT_MS = 5000;
const MAX_BYTES = 1024 * 1024;
const CACHE_DAYS = 7;
const TITLE_MAX = 40;

// ----- CORS: 모일날 주소(+ 로컬 확인용)에서만 -----
function allowedOrigin(origin: string | null): string | null {
  if (!origin) return null;
  if (origin === 'https://moilnal.github.io') return origin;
  if (/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin)) return origin;
  return null;
}

function corsHeaders(req: Request): Record<string, string> {
  const origin = allowedOrigin(req.headers.get('Origin'));
  const h: Record<string, string> = {
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  };
  if (origin) h['Access-Control-Allow-Origin'] = origin;
  return h;
}

function json(req: Request, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req), 'Content-Type': 'application/json; charset=utf-8' },
  });
}

// ----- URL 검사 -----
function checkUrl(raw: string): URL | null {
  let u: URL;
  try { u = new URL(raw); } catch { return null; }
  if (u.protocol !== 'https:') return null;
  if (u.username || u.password || u.port) return null;
  return u;
}

function isAllowed(u: URL): boolean {
  return ALLOWED_HOSTS.has(u.hostname.toLowerCase());
}

// ----- 캐시 (service role, 함수 안에서만) -----
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('MOILNAL_SECRET_KEY') ?? '';
const admin = SUPABASE_URL && SERVICE_KEY
  ? createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } })
  : null;

type Preview = { title: string; image: string | null; description: string; finalUrl: string };

async function readCache(url: string): Promise<Preview | null> {
  if (!admin) return null;
  try {
    const since = new Date(Date.now() - CACHE_DAYS * 86400000).toISOString();
    const { data } = await admin
      .from('link_previews')
      .select('title, image, description, final_url')
      .eq('url', url)
      .gte('fetched_at', since)
      .maybeSingle();
    if (!data) return null;
    return { title: data.title ?? '', image: data.image ?? null, description: data.description ?? '', finalUrl: data.final_url ?? url };
  } catch {
    return null;
  }
}

async function writeCache(url: string, p: Preview): Promise<void> {
  if (!admin) return;
  try {
    await admin.from('link_previews').upsert({
      url, title: p.title, image: p.image, description: p.description,
      final_url: p.finalUrl, fetched_at: new Date().toISOString(),
    });
  } catch {
    // 캐시 실패는 무시
  }
}

// ----- 가져오기: 리다이렉트를 직접 따라가며 매번 허용 도메인 확인 -----
const HEADERS = {
  'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
  'Accept': 'text/html,application/xhtml+xml',
  'Accept-Language': 'ko-KR,ko;q=0.9',
};

type Page = { html: string; finalUrl: string; visited: string[] };

async function fetchPage(start: URL, signal: AbortSignal): Promise<Page> {
  let cur = start;
  const visited = [cur.href];
  for (let i = 0; ; i++) {
    const res = await fetch(cur.href, { redirect: 'manual', headers: HEADERS, signal });
    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get('Location');
      await res.body?.cancel();
      if (!loc || i >= MAX_REDIRECTS) throw new Error('too_many_redirects');
      const next = checkUrl(new URL(loc, cur).href);
      if (!next || !isAllowed(next)) throw new Error('redirect_not_allowed');
      cur = next;
      visited.push(cur.href);
      continue;
    }
    if (!res.ok) {
      await res.body?.cancel();
      throw new Error('bad_status');
    }
    return { html: await readLimited(res), finalUrl: cur.href, visited };
  }
}

async function readLimited(res: Response): Promise<string> {
  if (!res.body) return '';
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (total < MAX_BYTES) {
    const { done, value } = await reader.read();
    if (done) break;
    const room = MAX_BYTES - total;
    const part = value.length > room ? value.subarray(0, room) : value;
    chunks.push(part);
    total += part.length;
  }
  await reader.cancel().catch(() => {});
  const all = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) { all.set(c, off); off += c.length; }
  return new TextDecoder('utf-8').decode(all);
}

// ----- HTML 에서 og 태그 읽기 -----
function decodeEntities(s: string): string {
  return s
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => safeChar(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => safeChar(parseInt(d, 10)))
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&');
}
function safeChar(n: number): string {
  try { return String.fromCodePoint(n); } catch { return ''; }
}

function readMeta(html: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of html.matchAll(/<meta\b[^>]*>/gi)) {
    const tag = m[0];
    const key = /\b(?:property|name)\s*=\s*["']([^"']+)["']/i.exec(tag)?.[1]?.toLowerCase();
    const content = /\bcontent\s*=\s*"([^"]*)"/i.exec(tag)?.[1] ?? /\bcontent\s*=\s*'([^']*)'/i.exec(tag)?.[1];
    if (key && content !== undefined && !(key in out)) out[key] = decodeEntities(content).trim();
  }
  const title = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html)?.[1];
  if (title && !out['title']) out['title'] = decodeEntities(title).trim();
  return out;
}

// 제목 꼬리말 정리 + 일반적인 제목이면 빈 값
const GENERIC_TITLES = new Set(['네이버 지도', '네이버지도', 'naver map', '네이버', 'naver', '카카오맵', '카카오 맵', 'kakao map', 'kakaomap', '다음지도']);
function cleanTitle(raw: string): string {
  let t = (raw || '').replace(/\s+/g, ' ').trim();
  t = t.replace(/\s*[:|\-–]\s*(네이버\s*지도|네이버|naver\s*map|naver|카카오\s*맵|kakao\s*map|kakaomap)\s*$/i, '').trim();
  if (GENERIC_TITLES.has(t.toLowerCase())) return '';
  return [...t].slice(0, TITLE_MAX).join('');
}

// 지도 서비스 공용 이미지(가게 사진이 아님)는 사진 없음으로 (화면의 GENERIC_IMAGES 와 같게 유지)
const GENERIC_IMAGES = [
  'https://ssl.pstatic.net/static/maps/assets/images/og-map-',
  'https://t1.kakaocdn.net/localimg/localimages/07/common/ogtag',
];

function cleanImage(raw: string | undefined, base: string): string | null {
  if (!raw) return null;
  let v = raw.trim();
  if (v.startsWith('//')) v = 'https:' + v;
  try {
    const u = new URL(v, base);
    if (u.protocol !== 'https:') return null;
    if (GENERIC_IMAGES.some(p => u.href.startsWith(p))) return null;
    return u.href.length <= 2000 ? u.href : null;
  } catch {
    return null;
  }
}

// 카카오 장소 id 찾기: applink.map.kakao.com/...?id=123, map.kakao.com/?itemId=123, place.map.kakao.com/123
function kakaoPlaceId(urls: string[]): string | null {
  for (const s of urls) {
    let u: URL;
    try { u = new URL(s); } catch { continue; }
    const host = u.hostname.toLowerCase();
    if (host === 'place.map.kakao.com') {
      const m = /^\/(?:m\/)?(\d{3,})/.exec(u.pathname);
      if (m) return m[1];
    }
    if (host === 'applink.map.kakao.com' || host === 'map.kakao.com') {
      const id = u.searchParams.get('id') ?? u.searchParams.get('itemId');
      if (id && /^\d{3,}$/.test(id)) return id;
    }
  }
  return null;
}

function toPreview(html: string, finalUrl: string): Preview {
  const meta = readMeta(html);
  return {
    title: cleanTitle(meta['og:title'] || meta['twitter:title'] || meta['title'] || ''),
    image: cleanImage(meta['og:image'] || meta['twitter:image'], finalUrl),
    description: (meta['og:description'] || meta['description'] || '').slice(0, 200),
    finalUrl,
  };
}

async function buildPreview(start: URL): Promise<Preview> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);
  try {
    const page = await fetchPage(start, ctrl.signal);
    let preview = toPreview(page.html, page.finalUrl);

    // 카카오맵: 장소 id 가 보이면 place.map.kakao.com/{id} 를 다시 읽음
    const id = kakaoPlaceId([...page.visited, page.finalUrl]);
    if (id && !(new URL(page.finalUrl).hostname === 'place.map.kakao.com' && preview.title)) {
      try {
        const placeUrl = new URL(`https://place.map.kakao.com/${id}`);
        const p2 = await fetchPage(placeUrl, ctrl.signal);
        const second = toPreview(p2.html, p2.finalUrl);
        preview = {
          title: second.title || preview.title,
          image: second.image || preview.image,
          description: second.description || preview.description,
          finalUrl: placeUrl.href,
        };
      } catch {
        // 두 번째 읽기에 실패하면 첫 결과 사용
      }
    }
    return preview;
  } finally {
    clearTimeout(timer);
  }
}

// ----- 진입점 -----
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders(req) });
  if (req.method !== 'POST') return json(req, 405, { error: 'method_not_allowed' });

  let raw = '';
  try {
    const body = await req.json();
    raw = typeof body?.url === 'string' ? body.url.trim() : '';
  } catch {
    return json(req, 400, { error: 'invalid_url' });
  }
  if (raw.length > 2000) return json(req, 400, { error: 'invalid_url' });

  const start = checkUrl(raw);
  if (!start) return json(req, 400, { error: 'invalid_url' });
  if (!isAllowed(start)) return json(req, 400, { error: 'not_allowed' });

  const cached = await readCache(start.href);
  if (cached) return json(req, 200, cached);

  try {
    const preview = await buildPreview(start);
    if (preview.title) await writeCache(start.href, preview);   // 이름을 읽은 결과만 캐시
    return json(req, 200, preview);
  } catch {
    return json(req, 502, { error: 'fetch_failed' });
  }
});
