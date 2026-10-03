import { test } from "node:test";
import assert from "node:assert/strict";
import { createHandler, extractOrder, validateOrder } from "./save-order.mjs";

const fixedNow = () => new Date("2026-10-03T12:00:00.000Z");
const ctx = { awsRequestId: "req-1" };

function setup(putItemImpl = async () => {}) {
  const calls = [];
  const putItem = async (params) => {
    calls.push(params);
    return putItemImpl(params);
  };
  return { calls, handler: createHandler({ putItem, tableName: "Orders", now: fixedNow }) };
}

test("saves a valid order and returns 201", async () => {
  const { handler, calls } = setup();
  const res = await handler({ orderId: "o-1", itemId: "i-1", quantity: 2, price: 9.99 }, ctx);

  assert.equal(res.statusCode, 201);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].TableName, "Orders");
  assert.deepEqual(calls[0].Item, {
    createdAt: "2026-10-03T12:00:00.000Z",
    orderId: "o-1",
    itemId: "i-1",
    quantity: 2,
    price: 9.99,
  });
  assert.match(calls[0].ConditionExpression, /attribute_not_exists\(orderId\)/);
});

test("optional fields may be omitted", async () => {
  const { handler, calls } = setup();
  const res = await handler({ orderId: "o-1", itemId: "i-1" }, ctx);
  assert.equal(res.statusCode, 201);
  assert.deepEqual(Object.keys(calls[0].Item).sort(), ["createdAt", "itemId", "orderId"]);
});

test("rejects missing keys without calling DynamoDB", async () => {
  const { handler, calls } = setup();
  const res = await handler({ itemId: "i-1" }, ctx);
  assert.equal(res.statusCode, 400);
  assert.equal(calls.length, 0);
});

test("rejects unknown fields (allow-list)", async () => {
  const { handler, calls } = setup();
  const res = await handler({ orderId: "o-1", itemId: "i-1", isAdmin: true }, ctx);
  assert.equal(res.statusCode, 400);
  assert.equal(calls.length, 0);
});

test("validates id format, quantity and price", () => {
  assert.ok(validateOrder({ orderId: "a b", itemId: "i" }).length > 0);
  assert.ok(validateOrder({ orderId: "o", itemId: "i", quantity: 0 }).length > 0);
  assert.ok(validateOrder({ orderId: "o", itemId: "i", quantity: 1.5 }).length > 0);
  assert.ok(validateOrder({ orderId: "o", itemId: "i", price: -1 }).length > 0);
  assert.ok(validateOrder({ orderId: "o", itemId: "i", price: "5" }).length > 0);
  assert.deepEqual(validateOrder({ orderId: "o", itemId: "i", quantity: 1, price: 0 }), []);
});

test("rejects non-object payloads", async () => {
  const { handler } = setup();
  for (const bad of [null, undefined, "x", 5, []]) {
    assert.equal((await handler(bad, ctx)).statusCode, 400);
  }
});

test("returns 409 when the item already exists", async () => {
  const { handler } = setup(async () => {
    throw Object.assign(new Error("exists"), { name: "ConditionalCheckFailedException" });
  });
  const res = await handler({ orderId: "o-1", itemId: "i-1" }, ctx);
  assert.equal(res.statusCode, 409);
});

test("returns a generic 500 and does not leak error details or order data", async (t) => {
  const logs = [];
  t.mock.method(console, "error", (line) => logs.push(line));
  const { handler } = setup(async () => {
    throw Object.assign(new Error("secret internal detail"), { name: "ProvisionedThroughputExceededException" });
  });

  const res = await handler({ orderId: "o-1", itemId: "i-1", price: 12.34 }, ctx);

  assert.equal(res.statusCode, 500);
  assert.ok(!res.body.includes("secret"));
  const logged = logs.join("");
  assert.ok(logged.includes("ProvisionedThroughputExceededException"));
  assert.ok(logged.includes("req-1"));
  assert.ok(!logged.includes("secret internal detail"));
  assert.ok(!logged.includes("12.34"));
});

// --- API Gateway proxy events ---

const proxyEvent = (body, extra = {}) => ({
  httpMethod: "POST",
  path: "/orders",
  requestContext: { stage: "dev" },
  body,
  isBase64Encoded: false,
  ...extra,
});

test("API Gateway event: saves the order from the JSON body", async () => {
  const { handler, calls } = setup();
  const res = await handler(proxyEvent(JSON.stringify({ orderId: "o-1", itemId: "i-1", quantity: 3 })), ctx);

  assert.equal(res.statusCode, 201);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].Item.orderId, "o-1");
  assert.equal(calls[0].Item.quantity, 3);
});

test("API Gateway event: decodes a base64 body", async () => {
  const { handler, calls } = setup();
  const body = Buffer.from(JSON.stringify({ orderId: "o-2", itemId: "i-2" })).toString("base64");
  const res = await handler(proxyEvent(body, { isBase64Encoded: true }), ctx);

  assert.equal(res.statusCode, 201);
  assert.equal(calls[0].Item.orderId, "o-2");
});

test("API Gateway event: malformed JSON returns 400 without echoing the input", async () => {
  const { handler, calls } = setup();
  const res = await handler(proxyEvent("{not json secret-value"), ctx);

  assert.equal(res.statusCode, 400);
  assert.ok(!res.body.includes("secret-value"));
  assert.equal(calls.length, 0);
});

test("API Gateway event: missing or null body returns 400", async () => {
  const { handler, calls } = setup();
  for (const body of [undefined, null, ""]) {
    assert.equal((await handler(proxyEvent(body), ctx)).statusCode, 400);
  }
  assert.equal(calls.length, 0);
});

test("API Gateway event: a valid JSON body is still validated", async () => {
  const { handler, calls } = setup();
  const res = await handler(proxyEvent(JSON.stringify({ itemId: "i-1", extra: true })), ctx);
  assert.equal(res.statusCode, 400);
  assert.equal(calls.length, 0);
});

test("API Gateway event: a JSON array or scalar body is rejected", async () => {
  const { handler } = setup();
  for (const body of ["[]", "5", '"x"', "null"]) {
    assert.equal((await handler(proxyEvent(body), ctx)).statusCode, 400);
  }
});

test("extractOrder passes direct invocations through unchanged", () => {
  const order = { orderId: "o", itemId: "i" };
  assert.equal(extractOrder(order).order, order);
});
