import { test } from "node:test";
import assert from "node:assert/strict";
import { compareReads, describeRead, formatMs, parseOrderForm, validateOrderId } from "./orders.js";

test("order IDs follow the API's rule", () => {
  for (const ok of ["o-1", "A.b_c-9", "x".repeat(128)]) assert.equal(validateOrderId(ok).ok, true, ok);
  for (const bad of ["", " ", "has space", "a/b", "é", "x".repeat(129), null, "<script>"]) assert.equal(validateOrderId(bad).ok, false, String(bad));
  assert.equal(validateOrderId("  o-1  ").value, "o-1");
});

test("a full order parses to numbers and trims", () => {
  const { order, errors } = parseOrderForm({ orderId: " o-1 ", itemId: "i-1", quantity: "3", price: "9.99" });
  assert.deepEqual(errors, []);
  assert.deepEqual(order, { orderId: "o-1", itemId: "i-1", quantity: 3, price: 9.99 });
});

test("empty optional fields are left out", () => {
  const { order, errors } = parseOrderForm({ orderId: "o-1", itemId: "i-1", quantity: "", price: " " });
  assert.deepEqual(errors, []);
  assert.deepEqual(order, { orderId: "o-1", itemId: "i-1" });
});

test("every problem is reported, in plain words", () => {
  const { errors } = parseOrderForm({ orderId: "", itemId: "a b", quantity: "0", price: "-1" });
  assert.equal(errors.length, 4);
  assert.ok(errors.every((e) => e.endsWith(".")));
});

test("quantity must be a whole number from 1 to 10000", () => {
  for (const q of ["1", "10000"]) assert.deepEqual(parseOrderForm({ orderId: "o", itemId: "i", quantity: q }).errors, [], q);
  for (const q of ["0", "10001", "1.5", "-2", "abc", "1e3", "0x10"]) assert.equal(parseOrderForm({ orderId: "o", itemId: "i", quantity: q }).errors.length, 1, q);
});

test("price must be a plain non-negative number", () => {
  for (const p of ["0", "9", "9.99", "1000000.5"]) assert.deepEqual(parseOrderForm({ orderId: "o", itemId: "i", price: p }).errors, [], p);
  for (const p of ["-1", "9,99", "1e3", "NaN", "Infinity", ".5", "9."]) assert.equal(parseOrderForm({ orderId: "o", itemId: "i", price: p }).errors.length, 1, p);
});

test("formatMs", () => {
  assert.equal(formatMs(312.4), "312 ms");
  assert.equal(formatMs(1234), "1.23 s");
  assert.equal(formatMs(NaN), "n/a");
});

test("describeRead builds table rows with dashes for missing values", () => {
  const d = describeRead({ orderId: "o-1", itemCount: 2, items: [{ itemId: "i-1", quantity: 2, price: null, createdAt: "t" }, { itemId: "i-2", quantity: null, price: 1.5, createdAt: "u" }] });
  assert.equal(d.itemCount, 2);
  assert.equal(d.truncated, null);
  assert.deepEqual(d.rows[0], { itemId: "i-1", quantity: "2", price: "—", createdAt: "t" });
  assert.equal(d.rows[1].quantity, "—");
});

test("describeRead reports the truncation flag only when the API sent it", () => {
  assert.equal(describeRead({ items: [], truncated: true }).truncated, true);
  assert.equal(describeRead({ items: [], truncated: false }).truncated, false);
  assert.equal(describeRead({}).rows.length, 0);
  assert.equal(describeRead(null).itemCount, 0);
});

test("compareReads says which read was faster, and refuses when one failed", () => {
  const ok = (ms) => ({ ok: true, ms });
  assert.match(compareReads(ok(350), ok(320)), /Lambda read was 30 ms faster/);
  assert.match(compareReads(ok(300), ok(340)), /Lambda read was 40 ms slower/);
  assert.match(compareReads(ok(300), ok(302)), /about the same/);
  assert.match(compareReads({ ok: false }, ok(1)), /direct read did not succeed/);
  assert.match(compareReads({ ok: false }, { ok: false }), /direct read and Lambda read/);
  assert.match(compareReads(ok(300), ok(340)), /One measurement/);
});
