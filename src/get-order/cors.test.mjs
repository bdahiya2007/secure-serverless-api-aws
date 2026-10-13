import { test } from "node:test";
import assert from "node:assert/strict";
import { corsHeaders, parseAllowedOrigins } from "./cors.mjs";
import { createHandler } from "./get-order.mjs";

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

const rows = [{ itemId: "i-1", quantity: 2, price: 3, createdAt: "2026-10-03T12:00:00.000Z" }];
const event = (origin, orderId = "o-1") => ({ ...from(origin), pathParameters: { orderId } });
const found = async () => ({ Items: rows });
const empty = async () => ({ Items: [] });

test("handler: found, not found, invalid id and server error all carry the CORS headers for an allowed origin", async () => {
  const cases = [
    [found, "o-1", 200],
    [empty, "o-1", 404],
    [found, "bad id!", 400],
    [async () => { throw new Error("boom"); }, "o-1", 500],
  ];
  for (const [query, orderId, status] of cases) {
    const handler = createHandler({ query, tableName: "Orders", allowedOrigins: ALLOWED });
    const res = await handler(event("http://localhost:8765", orderId), ctx);
    assert.equal(res.statusCode, status);
    assert.equal(res.headers["Access-Control-Allow-Origin"], "http://localhost:8765", `status ${status}`);
    assert.equal(res.headers.Vary, "Origin");
  }
});

test("handler: a disallowed origin gets no allow header, and the response is otherwise unchanged", async () => {
  const handler = createHandler({ query: found, tableName: "Orders", allowedOrigins: ALLOWED });
  const res = await handler(event("https://evil.example.test"), ctx);
  assert.equal(res.statusCode, 200);
  assert.equal(res.headers["Access-Control-Allow-Origin"], undefined);
});

test("handler: with no allowed origins configured the headers are exactly what they were before", async () => {
  const handler = createHandler({ query: found, tableName: "Orders" });
  const res = await handler(event("https://orders.example.test"), ctx);
  assert.deepEqual(res.headers, { "Content-Type": "application/json" });
});
