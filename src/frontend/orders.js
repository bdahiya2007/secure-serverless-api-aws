// Input checks that mirror the API's rules (the API stays the authority: it validates again) and view-model helpers.

const ID_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;
const ID_RULE = "1 to 128 characters: letters, numbers, '.', '_' or '-'";

export function validateOrderId(value) {
  const v = String(value ?? "").trim();
  return ID_PATTERN.test(v) ? { ok: true, value: v } : { ok: false, error: `The order ID must be ${ID_RULE}.` };
}

// Form text in, a clean order object (empty optional fields omitted) or a list of problems out.
export function parseOrderForm({ orderId, itemId, quantity, price }) {
  const errors = [];
  const order = {};

  const o = validateOrderId(orderId);
  if (o.ok) order.orderId = o.value;
  else errors.push(o.error);

  const i = String(itemId ?? "").trim();
  if (ID_PATTERN.test(i)) order.itemId = i;
  else errors.push(`The item ID must be ${ID_RULE}.`);

  const q = String(quantity ?? "").trim();
  if (q !== "") {
    if (/^\d+$/.test(q) && Number(q) >= 1 && Number(q) <= 10000) order.quantity = Number(q);
    else errors.push("The quantity must be a whole number from 1 to 10000.");
  }

  const p = String(price ?? "").trim();
  if (p !== "") {
    if (/^\d+(\.\d+)?$/.test(p) && Number.isFinite(Number(p))) order.price = Number(p);
    else errors.push("The price must be a number that is 0 or more (for example 9.99).");
  }

  return { order, errors };
}

export function formatMs(ms) {
  if (!Number.isFinite(ms)) return "n/a";
  return ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(2)} s`;
}

const dash = (v) => (v === null || v === undefined ? "—" : String(v));

// What the table needs from a read response (direct or via Lambda).
export function describeRead(data) {
  const items = Array.isArray(data?.items) ? data.items : [];
  return {
    orderId: String(data?.orderId ?? ""),
    itemCount: Number.isInteger(data?.itemCount) ? data.itemCount : items.length,
    // Only the Lambda read reports it; the direct read cannot say whether the 100-item cap cut the list off.
    truncated: typeof data?.truncated === "boolean" ? data.truncated : null,
    rows: items.map((x) => ({ itemId: dash(x.itemId), quantity: dash(x.quantity), price: dash(x.price), createdAt: dash(x.createdAt) })),
  };
}

// One sentence comparing the two read paths, or an explanation when one of them did not succeed.
export function compareReads(direct, lambda) {
  if (!direct.ok || !lambda.ok) {
    const failed = [!direct.ok ? "direct read" : null, !lambda.ok ? "Lambda read" : null].filter(Boolean).join(" and ");
    return `Not compared: the ${failed} did not succeed.`;
  }
  const diff = direct.ms - lambda.ms;
  const same = Math.abs(diff) < 5;
  const text = same
    ? "The two reads took about the same time"
    : `The Lambda read was ${formatMs(Math.abs(diff))} ${diff > 0 ? "faster" : "slower"} than the direct read`;
  return `${text} (direct ${formatMs(direct.ms)}, Lambda ${formatMs(lambda.ms)}). One measurement from this browser; repeat it before drawing a conclusion.`;
}
