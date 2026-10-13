// Small DOM helpers. Everything is built with createElement and textContent: no HTML string is ever parsed, so nothing the API
// returns (an order ID, an error message) can run as script or markup.

export function el(tag, { className, text, attrs } = {}, ...children) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  for (const [k, v] of Object.entries(attrs ?? {})) node.setAttribute(k, v);
  for (const c of children) if (c) node.append(c);
  return node;
}

export function clear(node) {
  node.replaceChildren();
}

export function show(node, visible) {
  node.hidden = !visible;
}

export function setBusy(buttons, busy) {
  for (const b of buttons) b.disabled = busy;
}

// A titled message: kind is "success" or "error". Details (validation messages) are shown as a list.
export function messageBox(kind, title, details = []) {
  const box = el("div", { className: `message ${kind}`, attrs: kind === "error" ? { role: "alert" } : {} }, el("p", { className: "title", text: title }));
  if (details.length > 0) box.append(el("ul", {}, ...details.map((d) => el("li", { text: d }))));
  return box;
}

export function itemsTable(summary, caption) {
  const head = el("tr", {}, ...["Item", "Quantity", "Price", "Created"].map((h) => el("th", { text: h, attrs: { scope: "col" } })));
  const body = summary.rows.map((r) => el("tr", {}, el("td", { text: r.itemId }), el("td", { text: r.quantity }), el("td", { text: r.price }), el("td", { text: r.createdAt })));
  return el("table", {}, el("caption", { text: caption }), el("thead", {}, head), el("tbody", {}, ...body));
}
