import { test } from "node:test";
import assert from "node:assert/strict";
import { createApi, kindForStatus } from "./api.js";

const respond = (status, body) => async () => ({ ok: status >= 200 && status < 300, status, json: async () => { if (body === undefined) throw new Error("no body"); return body; } });
const make = (fetchFn, extra = {}) => {
  let t = 0;
  return createApi({ baseUrl: "https://api.example.test/dev", getToken: () => "TOKEN", fetchFn, clock: () => (t += 40), ...extra });
};

test("a call sends the raw token (no Bearer), the right URL and method, and measures the time", async () => {
  let seen;
  const api = make(async (url, init) => { seen = { url, init }; return respond(200, { ok: 1 })(); });
  const r = await api.getOrderDirect("o-1");
  assert.deepEqual(r, { ok: true, status: 200, data: { ok: 1 }, ms: 40 });
  assert.equal(seen.url, "https://api.example.test/dev/orders/o-1");
  assert.equal(seen.init.method, "GET");
  assert.equal(seen.init.headers.Authorization, "TOKEN");
  assert.equal(seen.init.body, undefined);
});

test("the two reads use their own paths, and the order ID is encoded", async () => {
  const urls = [];
  const api = make(async (url) => { urls.push(url); return respond(200, {})(); });
  await api.getOrderViaLambda("a b/c");
  await api.getOrderDirect("x?y");
  assert.deepEqual(urls, ["https://api.example.test/dev/orders-via-lambda/a%20b%2Fc", "https://api.example.test/dev/orders/x%3Fy"]);
});

test("creating an order posts JSON", async () => {
  let seen;
  const api = make(async (url, init) => { seen = { url, init }; return respond(201, { orderId: "o-1" })(); });
  const r = await api.createOrder({ orderId: "o-1", itemId: "i-1" });
  assert.equal(r.status, 201);
  assert.equal(seen.url, "https://api.example.test/dev/orders");
  assert.equal(seen.init.method, "POST");
  assert.equal(seen.init.headers["Content-Type"], "application/json");
  assert.deepEqual(JSON.parse(seen.init.body), { orderId: "o-1", itemId: "i-1" });
});

test("without a token nothing is sent and the result says to sign in", async () => {
  let called = false;
  const api = createApi({ baseUrl: "https://api.example.test", getToken: () => null, fetchFn: async () => { called = true; } });
  const r = await api.getOrderDirect("o-1");
  assert.equal(r.ok, false);
  assert.equal(r.kind, "signin");
  assert.equal(called, false);
});

test("every status maps to a kind and a safe message", async () => {
  const cases = { 400: "invalid", 401: "unauthorized", 403: "forbidden", 404: "not_found", 409: "conflict", 429: "throttled", 500: "server", 502: "server", 418: "unexpected" };
  for (const [status, kind] of Object.entries(cases)) {
    const r = await make(respond(Number(status), { message: "internal detail" })).getOrderDirect("o-1");
    assert.equal(r.ok, false);
    assert.equal(r.kind, kind, status);
    assert.equal(kindForStatus(Number(status)), kind);
    assert.ok(r.message.length > 10);
    assert.ok(!r.message.includes("internal detail"), "server text is not shown");
  }
});

test("a 401 tells the page the session ended", async () => {
  let ended = 0;
  await make(respond(401, { message: "Unauthorized" }), { onUnauthorized: () => ended++ }).getOrderDirect("o-1");
  await make(respond(404, {}), { onUnauthorized: () => ended++ }).getOrderDirect("o-1");
  assert.equal(ended, 1);
});

test("validation details are passed on, limited to five short strings", async () => {
  const errors = ["a", "b", "c", "d", "e", "f", 7, "x".repeat(500)];
  const r = await make(respond(400, { errors })).createOrder({});
  assert.equal(r.details.length, 5);
  assert.ok(r.details.every((d) => typeof d === "string" && d.length <= 200));
  assert.deepEqual((await make(respond(400, {})).createOrder({})).details, []);
});

test("a network or cross-origin failure is reported as such, with the time spent", async () => {
  const r = await make(async () => { throw new TypeError("Failed to fetch"); }).getOrderDirect("o-1");
  assert.equal(r.kind, "network");
  assert.equal(r.status, 0);
  assert.ok(r.ms > 0);
});

test("an empty or non-JSON body does not break a successful or failed call", async () => {
  assert.equal((await make(respond(200)).getOrderDirect("o-1")).data, null);
  assert.equal((await make(respond(500)).getOrderDirect("o-1")).kind, "server");
});

test("the token never appears in a failure result", async () => {
  const r = await make(respond(500, { message: "TOKEN" })).getOrderDirect("o-1");
  assert.ok(!JSON.stringify(r).includes("TOKEN"));
});
