import assert from "node:assert/strict";
import test from "node:test";
import { handleRequest } from "./index.mjs";

const UID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

function fixture() {
  const calls = { auth: [], limit: [], model: [] };
  const env = {
    SUPABASE_URL: "https://synthetic.supabase.co",
    SUPABASE_PUBLISHABLE_KEY: "synthetic-publishable-key",
    AI_GATEWAY_ID: "nonanona-translation-test",
    USER_TRANSLATION_LIMIT: {
      async limit(input) {
        calls.limit.push(input);
        return { success: true };
      },
    },
    AI: {
      async run(...args) {
        calls.model.push(args);
        return completion('{"translation":"차가운 두부"}');
      },
    },
  };
  const fetchAuth = async (url, init) => {
    calls.auth.push([url.href, init]);
    return Response.json({ id: UID, is_anonymous: false });
  };
  return { env, calls, fetchAuth };
}

function completion(content, stop = "stop") {
  return { choices: [{ finish_reason: stop, message: { content } }] };
}

function request(options = {}) {
  const {
    path = "/v1/item-translation",
    body = JSON.stringify({ text: "冷や奴" }),
    headers = {},
    ...init
  } = options;
  return new Request(`https://worker.example${path}`, {
    method: "POST",
    headers: { "content-type": "application/json; charset=UTF-8", authorization: "Bearer a.b.c", ...headers },
    body,
    ...init,
  });
}

test("relays one name through the configured gateway and returns only its suggestion", async () => {
  const { env, calls, fetchAuth } = fixture();
  const response = await handleRequest(request(), env, fetchAuth);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), { translation: "차가운 두부" });
  assert.equal(calls.auth[0][0], "https://synthetic.supabase.co/auth/v1/user");
  assert.equal(calls.auth[0][1].headers.authorization, "Bearer a.b.c");
  assert.equal(calls.auth[0][1].redirect, "error");
  assert.deepEqual(calls.limit, [{ key: UID }]);
  const [[model, input, options]] = calls.model;
  assert.equal(model, "@cf/google/gemma-4-26b-a4b-it");
  assert.deepEqual(JSON.parse(input.messages[1].content), { text: "冷や奴" });
  assert.equal(input.store, false);
  assert.deepEqual(options.gateway, { id: "nonanona-translation-test", collectLog: false, skipCache: true });
});

test("anonymous users, rejected tokens and failed Auth lookups never reach the model", async () => {
  const { env, calls } = fixture();
  for (const [auth, status] of [
    [() => Response.json({ id: UID, is_anonymous: true }), 401],
    [() => new Response(null, { status: 401 }), 401],
    [() => new Response(null, { status: 503 }), 503],
  ]) {
    assert.equal((await handleRequest(request(), env, auth)).status, status);
  }
  assert.deepEqual(calls.limit, []);
  assert.deepEqual(calls.model, []);
});

test("rejects token shape, wrong media types and malformed or overbroad input before Auth", async () => {
  const { env, calls, fetchAuth } = fixture();
  for (const [input, status] of [
    [request({ headers: { authorization: "" } }), 401],
    [request({ headers: { "content-type": "text/plain" } }), 415],
    [request({ body: "{" }), 400],
    [request({ body: '{"text":"冷や奴","receiptId":"synthetic"}' }), 400],
    [request({ body: '{"text":["冷や奴"]}' }), 400],
    [request({ body: JSON.stringify({ text: "冷や奴\n生ビール" }) }), 400],
    [request({ body: JSON.stringify({ text: "品".repeat(121) }) }), 400],
  ]) {
    assert.equal((await handleRequest(input, env, fetchAuth)).status, status);
  }
  assert.deepEqual(calls.auth, []);
  assert.deepEqual(calls.model, []);
});

test("bounds a streamed request even without a Content-Length header", async () => {
  const { env, calls, fetchAuth } = fixture();
  const body = new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array(600));
      controller.enqueue(new Uint8Array(425));
      controller.close();
    },
  });
  assert.equal((await handleRequest(request({ body, duplex: "half" }), env, fetchAuth)).status, 413);
  assert.deepEqual(calls.auth, []);
});

test("rate-limited users and missing gateway configuration cannot reach inference", async () => {
  const { env, calls, fetchAuth } = fixture();
  env.USER_TRANSLATION_LIMIT = { async limit() { return { success: false }; } };
  const limited = await handleRequest(request(), env, fetchAuth);
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get("retry-after"), "60");
  for (const id of ["", "default"]) {
    env.AI_GATEWAY_ID = id;
    assert.equal((await handleRequest(request(), env, fetchAuth)).status, 503);
  }
  assert.deepEqual(calls.model, []);
});

test("keeps uncertainty and rejects truncated, multiline or non-JSON model responses", async () => {
  const { env, fetchAuth } = fixture();
  const cases = [
    [completion('{"translation":null}'), 200, { translation: null }],
    [completion('{"translation":"차가운 두부"}', "length"), 502, { error: "translation_failed" }],
    [completion(JSON.stringify({ translation: "두부\n다른 이름" })), 502, { error: "translation_failed" }],
    [completion('{"translation":"冷や奴"}'), 502, { error: "translation_failed" }],
    [completion("not JSON"), 502, { error: "translation_failed" }],
  ];
  for (const [provider, status, body] of cases) {
    env.AI.run = async () => provider;
    const result = await handleRequest(request(), env, fetchAuth);
    assert.equal(result.status, status);
    assert.deepEqual(await result.json(), body);
  }
});

function batchRequest(items) {
  return request({ path: "/v1/item-translations", body: JSON.stringify({ items }) });
}

test("keeps batch translation disabled until it is explicitly enabled", async () => {
  const { env, calls, fetchAuth } = fixture();
  const response = await handleRequest(batchRequest([{ id: "r01", text: "冷や奴" }]), env, fetchAuth);
  assert.equal(response.status, 404);
  assert.deepEqual(calls.auth, []);
  assert.deepEqual(calls.model, []);
});

test("keeps valid batch suggestions when individual translations have invalid values", async () => {
  const { env, calls, fetchAuth } = fixture();
  env.ENABLE_BATCH_TRANSLATION = "true";
  const items = [
    { id: "r01", text: "冷や奴" },
    { id: "r02", text: "ミ■" },
    { id: "r03", text: "■■" },
    { id: "r04", text: "生中" },
    { id: "r05", text: "刺身" },
  ];
  env.AI.run = async (...args) => {
    calls.model.push(args);
    return completion(JSON.stringify({ items: [
      { id: "r04", translation: " 생맥주 중간 크기 " },
      { id: "r02", translation: "null" },
      { id: "r05", translation: "생선회\n다른 품목" },
      { id: "r01", translation: "차가운 두부" },
      { id: "r03", translation: null },
    ] }));
  };
  const response = await handleRequest(batchRequest(items), env, fetchAuth);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { items: [
    { id: "r01", translation: "차가운 두부" },
    { id: "r02", translation: null },
    { id: "r03", translation: null },
    { id: "r04", translation: "생맥주 중간 크기" },
    { id: "r05", translation: null },
  ] });
  assert.equal(calls.auth.length, 1);
  assert.deepEqual(calls.limit, [{ key: UID }]);
  const [[, input, options]] = calls.model;
  assert.deepEqual(JSON.parse(input.messages[1].content), { items });
  assert.equal(input.store, false);
  assert.deepEqual(options.gateway, { id: "nonanona-translation-test", collectLog: false, skipCache: true });
});

test("rejects batch results with missing, duplicate or unexpected IDs", async () => {
  const { env, fetchAuth } = fixture();
  env.ENABLE_BATCH_TRANSLATION = "true";
  const items = [{ id: "r01", text: "冷や奴" }, { id: "r02", text: "生中" }];
  const tofu = { id: "r01", translation: "차가운 두부" };
  const beer = { id: "r02", translation: "생맥주 중간 크기" };
  for (const returned of [[tofu], [tofu, tofu], [tofu, { ...beer, id: "r03" }]]) {
    env.AI.run = async () => completion(JSON.stringify({ items: returned }));
    const response = await handleRequest(batchRequest(items), env, fetchAuth);
    assert.equal(response.status, 502);
    assert.deepEqual(await response.json(), { error: "translation_failed" });
  }
});

test("rejects overbroad batch input before Auth", async () => {
  const { env, calls, fetchAuth } = fixture();
  env.ENABLE_BATCH_TRANSLATION = "true";
  const items = Array.from({ length: 33 }, (_, index) => ({
    id: `r${String(index + 1).padStart(2, "0")}`,
    text: "冷や奴",
  }));
  for (const input of [
    [],
    items,
    [{ ...items[0], price: 123 }],
    [{ ...items[0], id: "a-permanent-receipt-id" }],
    [{ ...items[0], text: "冷や奴\n生中" }],
    [items[0], items[0]],
  ]) {
    assert.equal((await handleRequest(batchRequest(input), env, fetchAuth)).status, 400);
  }
  assert.deepEqual(calls.auth, []);
  assert.deepEqual(calls.model, []);
});
