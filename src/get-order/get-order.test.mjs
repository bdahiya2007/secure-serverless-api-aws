import { test } from "node:test";
import assert from "node:assert/strict";
import { createHandler, parseOrderId, toItem } from "./get-order.mjs";

const ctx = { awsRequestId: "req-1" };
const event = (orderId) => ({ pathParameters: { orderId } });

function setup(queryImpl) {
  const calls = [];
  const query = async (params) => {
    calls.push(params);
    return queryImpl(params);
  };
  return { calls, handler: createHandler({ query, tableName: "Orders" }) };
}

test("returns the order's items with 200", async () => {
  const { handler, calls } = setup(async () => ({
    Items: [
      { orderId: "o-1", itemId: "i-1", quantity: 2, price: 9.99, createdAt: "2026-10-10T00:00:00.000Z" },
      { orderId: "o-1", itemId: "i-2", createdAt: "2026-10-10T00:00:01.000Z" },
    ],
  }));
  const res = await handler(event("o-1"), ctx);
  const body = JSON.parse(res.body);

  assert.equal(res.statusCode, 200);
  assert.equal(body.orderId, "o-1");
  assert.equal(body.itemCount, 2);
  assert.deepEqual(body.items[0], { itemId: "i-1", quantity: 2, price: 9.99, createdAt: "2026-10-10T00:00:00.000Z" });
  assert.equal(body.truncated, false);
  assert.equal(calls.length, 1);
});

test("missing optional attributes become null, not undefined or empty", () => {
  assert.deepEqual(toItem({ itemId: "i", createdAt: "t" }), { itemId: "i", quantity: null, price: null, createdAt: "t" });
  assert.deepEqual(toItem({ itemId: "i", quantity: 0, price: 0, createdAt: "t" }), { itemId: "i", quantity: 0, price: 0, createdAt: "t" });
});

test("returns 404 when the order has no items", async () => {
  const { handler } = setup(async () => ({ Items: [] }));
  const res = await handler(event("o-9"), ctx);
  assert.equal(res.statusCode, 404);
  assert.equal(JSON.parse(res.body).message, "Order not found");
});

test("query asks for a strongly consistent read capped at 100 items, with the id as a value", async () => {
  const { handler, calls } = setup(async () => ({ Items: [{ itemId: "i", createdAt: "t" }] }));
  await handler(event("o-1"), ctx);
  const q = calls[0];
  assert.equal(q.TableName, "Orders");
  assert.equal(q.ConsistentRead, true);
  assert.equal(q.Limit, 100);
  assert.equal(q.KeyConditionExpression, "orderId = :orderId");
  assert.equal(q.ExpressionAttributeValues[":orderId"], "o-1");
  assert.ok(!q.KeyConditionExpression.includes("o-1"));
});

test("reports truncation when DynamoDB has more items than the cap", async () => {
  const { handler } = setup(async () => ({ Items: [{ itemId: "i", createdAt: "t" }], LastEvaluatedKey: { orderId: "o-1", itemId: "i" } }));
  const body = JSON.parse((await handler(event("o-1"), ctx)).body);
  assert.equal(body.truncated, true);
});

test("rejects bad ids with 400 without calling DynamoDB", async () => {
  const { handler, calls } = setup(async () => ({ Items: [] }));
  const bad = ["a b", 'a"b', "a'b", "a\\b", "a%22b", "x".repeat(129), "", "../x", "a/b"];
  for (const id of bad) {
    const res = await handler(event(id), ctx);
    assert.equal(res.statusCode, 400, `id ${JSON.stringify(id)} should be rejected`);
    assert.ok(!res.body.includes(id) || id === "", "response must not echo the input");
  }
  for (const e of [undefined, {}, { pathParameters: {} }, { pathParameters: { orderId: 5 } }]) {
    assert.equal((await handler(e, ctx)).statusCode, 400);
  }
  assert.equal(calls.length, 0);
});

test("accepts the full allowed character set and 128 characters", () => {
  assert.deepEqual(parseOrderId(event("Abc-1_2.3")), { orderId: "Abc-1_2.3" });
  assert.deepEqual(parseOrderId(event("x".repeat(128))), { orderId: "x".repeat(128) });
});

test("returns a generic 500 and does not leak error details or the id", async (t) => {
  const logs = [];
  t.mock.method(console, "error", (line) => logs.push(line));
  const { handler } = setup(async () => {
    throw Object.assign(new Error("secret internal detail"), { name: "ProvisionedThroughputExceededException" });
  });
  const res = await handler(event("o-secret-id"), ctx);
  assert.equal(res.statusCode, 500);
  assert.ok(!res.body.includes("secret"));
  const logged = logs.join("");
  assert.ok(logged.includes("ProvisionedThroughputExceededException") && logged.includes("req-1"));
  assert.ok(!logged.includes("secret internal detail") && !logged.includes("o-secret-id"));
});

test("consistentRead can be turned off (needed for DAX caching) and defaults to on", async () => {
  const calls = [];
  const query = async (p) => { calls.push(p); return { Items: [{ itemId: "i", createdAt: "t" }] }; };
  await createHandler({ query, tableName: "Orders", consistentRead: false })(event("o-1"), ctx);
  await createHandler({ query, tableName: "Orders" })(event("o-1"), ctx);
  assert.equal(calls[0].ConsistentRead, false);
  assert.equal(calls[1].ConsistentRead, true);
});
