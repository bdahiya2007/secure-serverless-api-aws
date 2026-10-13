// The orders page: sign in with Cognito's hosted pages (authorization code + PKCE), then create and look up orders.
// Tokens are kept in memory only. Everything shown comes from textContent (see view.js), never from parsed HTML.

import { loadConfig } from "./config.js";
import { createPkce } from "./pkce.js";
import { buildAuthorizeUrl, buildLogoutUrl, createSession, exchangeCode, parseCallback, savePending, takePending } from "./auth.js";
import { createApi } from "./api.js";
import { compareReads, describeRead, formatMs, parseOrderForm, validateOrderId } from "./orders.js";
import { clear, itemsTable, messageBox, setBusy, show } from "./view.js";

const $ = (id) => document.getElementById(id);

function say(text, isError = false) {
  const box = $("status");
  box.textContent = text;
  box.classList.toggle("error", isError);
  box.setAttribute("role", isError ? "alert" : "status");
  show(box, text !== "");
}

function fatal(text) {
  $("fatal").textContent = text;
  show($("fatal"), true);
  show($("signed-out"), false);
  show($("signed-in"), false);
}

async function main() {
  let cfg;
  try {
    cfg = await loadConfig();
  } catch (e) {
    fatal(e.message);
    return;
  }
  // A page served from one address with a configuration for another would sign in and then be sent somewhere else.
  if (new URL(cfg.redirectUri).origin !== location.origin) {
    fatal("This page's configuration is for a different address, so sign-in is disabled.");
    return;
  }

  const session = createSession();
  const api = createApi({
    baseUrl: cfg.apiBaseUrl,
    getToken: () => session.token(),
    onUnauthorized: () => {
      session.clear();
      render();
      say("Your session has ended. Please sign in again.", true);
    },
  });

  function render() {
    const signedIn = session.signedIn();
    show($("signed-out"), !signedIn);
    show($("signed-in"), signedIn);
    show($("sign-out"), signedIn);
    const who = $("who");
    who.textContent = signedIn ? `Signed in${session.email() ? ` as ${session.email()}` : ""} until ${new Date(session.expiresAt()).toLocaleTimeString()}` : "";
    show(who, signedIn);
  }

  async function finishSignIn() {
    const cb = parseCallback(location.search);
    if (cb === null) return;
    history.replaceState(null, "", location.pathname); // the code is single-use and must not stay in the address bar or history
    const pending = takePending(sessionStorage);
    if (cb.error) {
      say(`Sign-in was not completed (${cb.error}).`, true);
      return;
    }
    if (pending === null || pending.state !== cb.state) {
      say("Sign-in could not be verified. Please try again.", true);
      return;
    }
    try {
      session.set(await exchangeCode(cfg, { code: cb.code, verifier: pending.verifier }));
      say("");
    } catch (e) {
      say(e.message, true);
    }
  }

  // ---- sign in and out
  $("sign-in").addEventListener("click", async () => {
    const pkce = await createPkce();
    savePending(sessionStorage, pkce);
    location.assign(buildAuthorizeUrl(cfg, pkce));
  });
  $("sign-out").addEventListener("click", () => {
    session.clear();
    location.assign(buildLogoutUrl(cfg));
  });

  // ---- create
  const createButtons = [$("create-submit")];
  $("create-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const out = $("create-result");
    clear(out);
    const { order, errors } = parseOrderForm({
      orderId: $("create-order-id").value,
      itemId: $("create-item-id").value,
      quantity: $("create-quantity").value,
      price: $("create-price").value,
    });
    if (errors.length > 0) {
      out.append(messageBox("error", "Please fix the following.", errors));
      return;
    }
    setBusy(createButtons, true);
    const r = await api.createOrder(order);
    setBusy(createButtons, false);
    if (r.ok) {
      out.append(messageBox("success", `Saved item ${order.itemId} in order ${order.orderId} (${formatMs(r.ms)}).`));
    } else {
      out.append(messageBox("error", r.message, r.details));
    }
  });

  // ---- look up
  const lookupButtons = [$("read-direct"), $("read-lambda"), $("read-both")];
  async function lookup(which) {
    const out = $("lookup-result");
    clear(out);
    const id = validateOrderId($("lookup-order-id").value);
    if (!id.ok) {
      out.append(messageBox("error", id.error));
      return;
    }
    setBusy(lookupButtons, true);
    const results = {};
    if (which !== "lambda") results.direct = await api.getOrderDirect(id.value);
    if (which !== "direct") results.lambda = await api.getOrderViaLambda(id.value);
    setBusy(lookupButtons, false);

    for (const [name, label] of [["direct", "Direct read"], ["lambda", "Lambda read"]]) {
      const r = results[name];
      if (!r) continue;
      if (!r.ok) {
        out.append(messageBox("error", `${label}: ${r.message}`, r.details));
        continue;
      }
      const s = describeRead(r.data);
      out.append(itemsTable(s, `${label}: ${s.itemCount} item${s.itemCount === 1 ? "" : "s"} in order ${s.orderId} (${formatMs(r.ms)})`));
      if (s.truncated === true) out.append(messageBox("error", "The list was cut off at 100 items: more items exist than are shown."));
    }
    if (which === "both") out.append(messageBox("success", compareReads(results.direct, results.lambda)));
  }
  $("read-direct").addEventListener("click", () => lookup("direct"));
  $("read-lambda").addEventListener("click", () => lookup("lambda"));
  $("read-both").addEventListener("click", () => lookup("both"));
  $("lookup-form").addEventListener("submit", (e) => {
    e.preventDefault();
    lookup("lambda");
  });

  await finishSignIn();
  render();
  // Notice an expired session without waiting for a failed call.
  setInterval(() => {
    if (!session.signedIn() && !$("signed-in").hidden) {
      render();
      say("Your session has ended. Please sign in again.", true);
    }
  }, 30_000);
}

main();
