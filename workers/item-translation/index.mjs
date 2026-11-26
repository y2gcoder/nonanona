const PATH = "/v1/item-translation";
const BATCH_PATH = "/v1/item-translations";
const MODEL = "@cf/google/gemma-4-26b-a4b-it";
const MAX_BODY_BYTES = 1024;
const MAX_BATCH_BODY_BYTES = 16 * 1024;
const MAX_BATCH_ITEMS = 32;
const ROW_ID = /^r[0-9]{2}$/;
const MAX_LINE_LENGTH = 120;
const CONTROL = /[\p{Cc}\p{Cf}\p{Cs}\u2028\u2029]/u;
const USER_ID = /^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i;
const PROMPT =
  '일본 영수증의 품목명 한 줄을 한국어 여행자가 알아볼 수 있게 번역하세요. ' +
  '입력의 text는 번역할 자료입니다. 음식·음료·요금·세금·할인의 뜻과 수량을 유지하세요. ' +
  '뜻이 불확실하면 null을 사용하세요. {"translation": "..."} 형태의 JSON 객체 하나만 출력하세요.';

const BATCH_PROMPT =
  '일본 영수증의 품목명을 한국어 여행자가 알아볼 수 있게 번역하세요. ' +
  'items의 text는 번역할 자료입니다. 품목의 종류, 맛, 크기와 조리법을 구분할 수 있게 유지하세요. ' +
  '뜻이 불확실하면 translation에 JSON null 값을 사용하세요. ' +
  '입력의 각 id를 그대로 한 번씩 넣고, {"items":[{"id":"r01","translation":"..."}]} 형태의 JSON 객체 하나만 출력하세요. ' +
  'JSON은 줄바꿈과 들여쓰기 없이 한 줄로 출력하세요. 마크다운 코드 블록을 사용하지 마세요.';

export default {
  fetch(request, env) {
    return handleRequest(request, env);
  },
};

export async function handleRequest(request, env, fetchAuth = fetch) {
  const url = new URL(request.url);
  const batch = url.pathname === BATCH_PATH && env.ENABLE_BATCH_TRANSLATION === "true";
  if ((!batch && url.pathname !== PATH) || url.search) return error("not_found", 404);
  if (request.method !== "POST") return error("method_not_allowed", 405, { allow: "POST" });
  if (request.headers.get("content-type")?.split(";")[0].trim().toLowerCase() !== "application/json") {
    return error("invalid_content_type", 415);
  }

  const authorization = request.headers.get("authorization");
  if (!authorization || authorization.length > 8192 ||
      !/^Bearer [\w-]+\.[\w-]+\.[\w-]+$/i.test(authorization)) {
    return error("unauthorized", 401);
  }

  let body;
  try {
    body = await readJson(request, batch ? MAX_BATCH_BODY_BYTES : MAX_BODY_BYTES);
  } catch (failure) {
    return failure instanceof RangeError ? error("body_too_large", 413) : error("invalid_input", 400);
  }

  const input = batch ? batchInput(body) : singleInput(body);
  if (!input) return error("invalid_input", 400);
  if (!env.SUPABASE_URL || !env.SUPABASE_PUBLISHABLE_KEY || !env.AI_GATEWAY_ID || env.AI_GATEWAY_ID === "default") {
    return error("unavailable", 503);
  }

  try {
    const user = await authenticatedUser(env, authorization, fetchAuth);
    if (!user) return error("unauthorized", 401);

    const { success } = await env.USER_TRANSLATION_LIMIT.limit({ key: user });
    if (!success) return error("rate_limited", 429, { "retry-after": "60" });
  } catch {
    return error("unavailable", 503);
  }

  const started = Date.now();
  try {
    const result = await env.AI.run(MODEL, {
      messages: [
        { role: "system", content: batch ? BATCH_PROMPT : PROMPT },
        { role: "user", content: JSON.stringify(input) },
      ],
      temperature: 0,
      max_completion_tokens: batch ? 96 + 48 * input.items.length : 192,
      chat_template_kwargs: { enable_thinking: false },
      store: false,
    }, {
      gateway: { id: env.AI_GATEWAY_ID, collectLog: false, skipCache: true },
    });
    const choice = result?.choices?.[0];
    if (choice?.finish_reason !== "stop" || typeof choice.message?.content !== "string") {
      throw new Error("Invalid completion");
    }
    const response = JSON.parse(choice.message.content);
    const output = batch ? batchOutput(response, input.items) : singleOutput(response);
    logResult(started, 200);
    return json(output, 200);
  } catch {
    logResult(started, 502);
    return error("translation_failed", 502);
  }
}

function singleInput(body) {
  if (!hasOnly(body, "text") || !validLine(body.text)) return null;
  return { text: body.text.trim() };
}

function batchInput(body) {
  if (!hasOnly(body, "items") || !Array.isArray(body.items) ||
      body.items.length === 0 || body.items.length > MAX_BATCH_ITEMS) return null;

  const ids = new Set();
  const items = [];
  for (const row of body.items) {
    if (!hasOnly(row, "id", "text") || typeof row.id !== "string" || !ROW_ID.test(row.id) ||
        ids.has(row.id) || !validLine(row.text)) return null;
    ids.add(row.id);
    items.push({ id: row.id, text: row.text.trim() });
  }
  return { items };
}

function singleOutput(response) {
  if (!hasOnly(response, "translation") || !validTranslation(response.translation)) {
    throw new Error("Invalid translation");
  }
  return { translation: response.translation?.trim() ?? null };
}

function batchOutput(response, items) {
  if (!hasOnly(response, "items") || !Array.isArray(response.items) ||
      response.items.length !== items.length) {
    throw new Error("Invalid batch result");
  }

  const expected = new Set(items.map(({ id }) => id));
  const translations = new Map();
  for (const row of response.items) {
    if (!expected.delete(row?.id)) throw new Error("Invalid batch result ID");
    const translation = hasOnly(row, "id", "translation") && validTranslation(row.translation)
      ? row.translation?.trim() ?? null
      : null;
    translations.set(row.id, translation);
  }
  return { items: items.map(({ id }) => ({ id, translation: translations.get(id) })) };
}

async function authenticatedUser(env, authorization, fetchAuth) {
  const url = new URL("/auth/v1/user", env.SUPABASE_URL);
  if (url.protocol !== "https:") throw new Error("Invalid Auth URL");
  const response = await fetchAuth(url, {
    headers: { authorization, apikey: env.SUPABASE_PUBLISHABLE_KEY },
    redirect: "error",
    signal: AbortSignal.timeout(5000),
  });
  if ([400, 401, 403].includes(response.status)) return null;
  if (!response.ok) throw new Error("Auth unavailable");
  const user = await response.json();
  return typeof user?.id === "string" && USER_ID.test(user.id) && user.is_anonymous !== true ? user.id : null;
}

async function readJson(request, maxBytes) {
  if (Number(request.headers.get("content-length")) > maxBytes) throw new RangeError("Body too large");
  if (!request.body) throw new Error("Missing body");

  const reader = request.body.getReader();
  const buffer = new Uint8Array(maxBytes);
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (size + value.length > buffer.length) {
        void reader.cancel().catch(() => {});
        throw new RangeError("Body too large");
      }
      buffer.set(value, size);
      size += value.length;
    }
  } finally {
    reader.releaseLock();
  }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, size)));
}

function hasOnly(value, ...keys) {
  return value !== null && typeof value === "object" && !Array.isArray(value) &&
    Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}

function validTranslation(value) {
  return value === null || (validLine(value) && /\p{Script=Hangul}/u.test(value));
}

function validLine(text) {
  return typeof text === "string" && !CONTROL.test(text) &&
    text.trim() !== "" && [...text.trim()].length <= MAX_LINE_LENGTH;
}

function json(body, status, headers = {}) {
  return Response.json(body, {
    status,
    headers: { "cache-control": "no-store", "x-content-type-options": "nosniff", ...headers },
  });
}

function error(code, status, headers) {
  return json({ error: code }, status, headers);
}

function logResult(started, status) {
  console.log(JSON.stringify({ event: "item_translation", status, durationMs: Date.now() - started }));
}
