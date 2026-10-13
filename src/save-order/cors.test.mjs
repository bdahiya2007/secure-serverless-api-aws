import { test } from "node:test";
import assert from "node:assert/strict";
import { corsHeaders, parseAllowedOrigins } from "./cors.mjs";
import { createHandler } from "./save-order.mjs";

const ALLOWED = ["https://orders.example.test", "http://localhost:8765"];
const ctx = { awsRequestId: "req-1" };
const from = (origin, extra = {}) => ({ headers: origin === undefined ? {} : { Origin: origin }, ...extra });

test("parseAllowedOrigins splits, trims and drops empty entries", () => {
  assert.deepEqual(parseAllowedOrigins(" https://a.example.test, http://localhost:8765 ,,"), ["https://a.example.test", "http://localhost:8765"]);
  assert.deepEqual(parseAllowedOrigins(""), []);
  assert.deepEqual(parseAllowedOrigins(undefined), []);
});

test("no allowed origins configured: no CORS headers at all (the default behaviour)", () => {
  assert.deepEqual(corsHeaders(from("https://orders.example.test"), []), {});
  assert.deepEqual(corsHeaders(from("https://orders.example.test"), undefined), {});
});

test("an allowed origin is echoed exactly, with Vary: Origin", () => {
  assert.deepEqual(corsHeaders(from("https://orders.example.test"), ALLOWED), {
    Vary: "Origin",
    "Access-Control-Allow-Origin": "https://orders.example.test",
  });
  assert.equal(corsHeaders(from("http://localhost:8765"), ALLOWED)["Access-Control-Allow-Origin"], "http://localhost:8765");
});

test("the Origin header is found whatever its case", () => {
  assert.equal(corsHeaders({ headers: { origin: "https://orders.example.test" } }, ALLOWED)["Access-Control-Allow-Origin"], "https://orders.example.test");
  assert.equal(corsHeaders({ headers: { ORIGIN: "https://orders.example.test" } }, ALLOWED)["Access-Control-Allow-Origin"], "https://orders.example.test");
});

test("an origin that is not on the list gets only Vary, never an allow header and never a wildcard", () => {
  for (const origin of ["https://evil.example.test", "https://orders.example.test.evil.test", "http://orders.example.test", "https://orders.example.test/", "null", "*", ""]) {
    assert.deepEqual(corsHeaders(from(origin), ALLOWED), { Vary: "Origin" }, origin);
  }
});

test("no Origin header, or odd events: only Vary, and nothing throws", () => {
  assert.deepEqual(corsHeaders(from(undefined), ALLOWED), { Vary: "Origin" });
  assert.deepEqual(corsHeaders({}, ALLOWED), { Vary: "Origin" });
  assert.deepEqual(corsHeaders(null, ALLOWED), { Vary: "Origin" });
  assert.deepEqual(corsHeaders({ headers: null }, ALLOWED), { Vary: "Origin" });
  assert.deepEqual(corsHeaders({ headers: { Origin: 5 } }, ALLOWED), { Vary: "Origin" });
});

const okPut = async () => {};
const orderBody = JSON.stringify({ orderId: "o-1", itemId: "i-1", quantity: 1 });
const proxy = (origin, body = orderBody) => ({ ...from(origin), requestContext: {}, body });

test("handler: success, validation error, conflict and server error all carry the CORS headers for an allowed origin", async () => {
  const conflict = Object.assign(new Error("x"), { name: "ConditionalCheckFailedException" });
  const cases = [
    [okPut, orderBody, 201],
    [okPut, "{bad json", 400],
    [okPut, JSON.stringify({ orderId: "bad id!", itemId: "i-1" }), 400],
    [async () => { throw conflict; }, orderBody, 409],
    [async () => { throw new Error("boom"); }, orderBody, 500],
  ];
  for (const [putItem, body, status] of cases) {
    const handler = createHandler({ putItem, tableName: "Orders", allowedOrigins: ALLOWED });
    const res = await handler(proxy("https://orders.example.test", body), ctx);
    assert.equal(res.statusCode, status);
    assert.equal(res.headers["Access-Control-Allow-Origin"], "https://orders.example.test", `status ${status}`);
    assert.equal(res.headers.Vary, "Origin");
    assert.equal(res.headers["Content-Type"], "application/json");
  }
});

test("handler: a disallowed origin gets no allow header, and the response is otherwise unchanged", async () => {
  const handler = createHandler({ putItem: okPut, tableName: "Orders", allowedOrigins: ALLOWED });
  const res = await handler(proxy("https://evil.example.test"), ctx);
  assert.equal(res.statusCode, 201);
  assert.equal(res.headers["Access-Control-Allow-Origin"], undefined);
});

test("handler: with no allowed origins configured the headers are exactly what they were before", async () => {
  const handler = createHandler({ putItem: okPut, tableName: "Orders" });
  const res = await handler(proxy("https://orders.example.test"), ctx);
  assert.deepEqual(res.headers, { "Content-Type": "application/json" });
});
