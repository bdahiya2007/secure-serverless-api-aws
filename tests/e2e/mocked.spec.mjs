// Browser tests of the front end against a FAKE sign-in and a FAKE API (no AWS, no secrets): they drive the real page in a real
// Chromium and check the DOM wiring, the sign-in protocol, the error messages and the security properties. A Content Security
// Policy violation or an uncaught error in the page fails any test.
import { createHash } from "node:crypto";
import { expect, test } from "@playwright/test";
import { FAKE, PORT, config } from "./fixtures.mjs";

const REDIRECT = `http://localhost:${PORT}/`;
const AUTH = `https://${FAKE.host}`;
const API = `${FAKE.api}/dev`;

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const idToken = (claims = {}) => `${b64({ alg: "none" })}.${b64({ email: "tester@example.com", token_use: "id", exp: Math.floor(Date.now() / 1000) + 3600, ...claims })}.sig`;
const json = (status, body, extra = {}) => ({ status, contentType: "application/json", body: JSON.stringify(body), headers: { ...extra } });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const ITEM = { itemId: "i-1", quantity: 2, price: 9.99, createdAt: "2026-10-13T10:00:00.000Z" };
const readBody = (items = [ITEM], extra = {}) => ({ orderId: "t-1", itemCount: items.length, items, ...extra });

// ---- the fake world: Cognito's pages and token endpoint, and the API. Each test can replace parts of it.
async function world(page, over = {}) {
  const seen = { authorize: [], token: [], api: [], logout: 0 };
  const cors = (request) => ({
    "access-control-allow-origin": request.headers().origin ?? "*",
    "access-control-allow-headers": "authorization,content-type",
    "access-control-allow-methods": "GET,POST,OPTIONS",
    vary: "Origin",
  });

  await page.route(`${AUTH}/oauth2/authorize*`, async (route, request) => {
    const u = new URL(request.url());
    seen.authorize.push(Object.fromEntries(u.searchParams));
    const location = over.authorize ? over.authorize(u) : `${REDIRECT}?code=FAKECODE&state=${encodeURIComponent(u.searchParams.get("state"))}`;
    await route.fulfill({ status: 302, headers: { location } });
  });

  await page.route(`${AUTH}/oauth2/token`, async (route, request) => {
    if (request.method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors(request) });
    seen.token.push(Object.fromEntries(new URLSearchParams(request.postData() ?? "")));
    const r = over.token ? over.token() : json(200, { id_token: idToken(), access_token: "a", refresh_token: "r", expires_in: 3600 });
    await route.fulfill({ ...r, headers: { ...cors(request), ...r.headers } });
  });

  await page.route(`${AUTH}/logout*`, async (route) => {
    seen.logout += 1;
    await route.fulfill({ status: 302, headers: { location: REDIRECT } });
  });

  await page.route(`${API}/**`, async (route, request) => {
    if (request.method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors(request) });
    const url = new URL(request.url());
    seen.api.push({ method: request.method(), path: url.pathname.replace("/dev", ""), search: url.search, auth: request.headers().authorization, body: request.postData() });
    const r = await (over.api ?? defaultApi)(request, url);
    await route.fulfill({ ...r, headers: { ...cors(request), ...r.headers } });
  });
  return seen;
}

async function defaultApi(request, url) {
  const path = url.pathname.replace("/dev", "");
  if (request.method() === "POST" && path === "/orders") return json(201, { orderId: "t-1", itemId: "i-1", createdAt: ITEM.createdAt });
  if (request.method() === "GET" && path.startsWith("/orders-via-lambda/")) return json(200, readBody([ITEM], { truncated: false }));
  if (request.method() === "GET" && path.startsWith("/orders/")) return json(200, readBody());
  return json(404, { message: "Not found" });
}

const signIn = async (page) => {
  await page.click("#sign-in");
  await expect(page.locator("#signed-in")).toBeVisible();
};

test.beforeEach(async ({ page }) => {
  // Record Content Security Policy violations and uncaught errors for every test.
  await page.addInitScript(() => {
    window.__csp = [];
    document.addEventListener("securitypolicyviolation", (e) => window.__csp.push(`${e.violatedDirective} ${e.blockedURI}`));
  });
  page.__errors = [];
  page.on("pageerror", (e) => page.__errors.push(e.message));
});

test.afterEach(async ({ page }) => {
  const violations = await page.evaluate(() => window.__csp).catch(() => []);
  expect(violations, "Content Security Policy violations").toEqual([]);
  expect(page.__errors, "uncaught errors in the page").toEqual([]);
});

test.describe("signed out", () => {
  test("shows only the sign-in view", async ({ page }) => {
    await world(page);
    await page.goto("/");
    await expect(page.locator("h1")).toHaveText("Orders");
    await expect(page.locator("#sign-in")).toBeVisible();
    await expect(page.locator("#signed-in")).toBeHidden();
    await expect(page.locator("#sign-out")).toBeHidden();
    await expect(page.locator("#fatal")).toBeHidden();
  });

  test("a missing page shows the 404 page with a link home", async ({ page }) => {
    const r = await page.goto("/nothing-here.html");
    expect(r.status()).toBe(404);
    await expect(page.getByText("Page not found").first()).toBeVisible();
  });

  test("a configuration for a different address disables sign-in", async ({ page }) => {
    await world(page);
    await page.route("**/config.json", (route) => route.fulfill(json(200, config({ redirectUri: "http://localhost:9999/" }))));
    await page.goto("/");
    await expect(page.locator("#fatal")).toContainText("different address");
    await expect(page.locator("#sign-in")).toBeHidden();
  });

  test("a broken config.json is reported without exposing values", async ({ page }) => {
    await world(page);
    await page.route("**/config.json", (route) => route.fulfill(json(200, { apiBaseUrl: "http://insecure.example.test", cognito: {} })));
    await page.goto("/");
    await expect(page.locator("#fatal")).toContainText("not usable");
    await expect(page.locator("#fatal")).not.toContainText("insecure.example.test");
  });
});

test.describe("sign-in", () => {
  test("the whole round trip: PKCE, state, token exchange, a clean address, nothing stored", async ({ page, context }) => {
    const seen = await world(page);
    await page.goto("/");
    await signIn(page);

    // what the page asked Cognito for
    expect(seen.authorize).toHaveLength(1);
    const a = seen.authorize[0];
    expect(a).toMatchObject({ response_type: "code", client_id: FAKE.clientId, redirect_uri: REDIRECT, scope: "openid email", code_challenge_method: "S256" });
    expect(a.code_challenge).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(a.state.length).toBeGreaterThanOrEqual(16);

    // the code exchange proves possession of the verifier whose hash was sent first
    expect(seen.token).toHaveLength(1);
    const t = seen.token[0];
    expect(t).toMatchObject({ grant_type: "authorization_code", code: "FAKECODE", client_id: FAKE.clientId, redirect_uri: REDIRECT });
    expect(createHash("sha256").update(t.code_verifier).digest("base64url")).toBe(a.code_challenge);

    // the signed-in view, a clean address, and no token anywhere that survives a reload
    await expect(page.locator("#who")).toContainText("Signed in as tester@example.com");
    await expect(page.locator("#sign-out")).toBeVisible();
    expect(new URL(page.url()).search).toBe("");
    expect(await page.evaluate(() => localStorage.length)).toBe(0);
    expect(await page.evaluate(() => sessionStorage.length)).toBe(0);
    expect(await context.cookies()).toEqual([]);
    expect(await page.evaluate(() => document.cookie)).toBe("");
  });

  test("a reload signs the user out (the token is only in memory)", async ({ page }) => {
    await world(page, { authorize: () => `${REDIRECT}` });
    await page.goto("/");
    await page.evaluate(() => sessionStorage.clear());
    await world(page);
    await signIn(page);
    await page.reload();
    await expect(page.locator("#signed-out")).toBeVisible();
    await expect(page.locator("#signed-in")).toBeHidden();
  });

  test("a state that does not match is refused and no token is requested", async ({ page }) => {
    const seen = await world(page, { authorize: () => `${REDIRECT}?code=FAKECODE&state=not-the-state` });
    await page.goto("/");
    await page.click("#sign-in");
    await expect(page.locator("#status")).toContainText("could not be verified");
    await expect(page.locator("#signed-out")).toBeVisible();
    expect(seen.token).toHaveLength(0);
    expect(new URL(page.url()).search).toBe("");
  });

  test("a callback with no pending sign-in is refused", async ({ page }) => {
    const seen = await world(page);
    await page.goto("/?code=SOMECODE&state=whatever");
    await expect(page.locator("#status")).toContainText("could not be verified");
    expect(seen.token).toHaveLength(0);
    expect(new URL(page.url()).search).toBe("");
  });

  test("an error from Cognito is shown, and the address is cleaned", async ({ page }) => {
    await world(page, { authorize: () => `${REDIRECT}?error=access_denied&error_description=No` });
    await page.goto("/");
    await page.click("#sign-in");
    await expect(page.locator("#status")).toContainText("access_denied");
    await expect(page.locator("#signed-out")).toBeVisible();
    expect(new URL(page.url()).search).toBe("");
  });

  test("a failed token exchange shows Cognito's error code and nothing else", async ({ page }) => {
    await world(page, { token: () => json(400, { error: "invalid_grant", internal: "do-not-show" }) });
    await page.goto("/");
    await page.click("#sign-in");
    await expect(page.locator("#status")).toContainText("invalid_grant");
    await expect(page.locator("#status")).not.toContainText("do-not-show");
    await expect(page.locator("#signed-out")).toBeVisible();
  });

  test("signing out clears the session and calls the hosted logout", async ({ page }) => {
    const seen = await world(page);
    await page.goto("/");
    await signIn(page);
    await page.click("#sign-out");
    await expect(page.locator("#signed-out")).toBeVisible();
    expect(seen.logout).toBe(1);
    await expect(page.locator("#who")).toBeHidden();
  });
});

test.describe("creating an order item", () => {
  test("invalid input is explained and nothing is sent", async ({ page }) => {
    const seen = await world(page);
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").first().fill("has space");
    await page.getByLabel("Item ID").fill("");
    await page.getByLabel(/Quantity/).fill("0");
    await page.getByLabel(/Price/).fill("-1");
    await page.click("#create-submit");
    const box = page.locator("#create-result");
    await expect(box).toContainText("Please fix the following");
    await expect(box.locator("li")).toHaveCount(4);
    expect(seen.api).toHaveLength(0);
  });

  test("a valid item is sent with the raw token (no Bearer) and reported saved", async ({ page }) => {
    const seen = await world(page);
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").first().fill("t-1");
    await page.getByLabel("Item ID").fill("i-1");
    await page.getByLabel(/Quantity/).fill("2");
    await page.getByLabel(/Price/).fill("9.99");
    await page.click("#create-submit");
    await expect(page.locator("#create-result")).toContainText("Saved item i-1 in order t-1");
    expect(seen.api).toHaveLength(1);
    expect(seen.api[0]).toMatchObject({ method: "POST", path: "/orders" });
    expect(JSON.parse(seen.api[0].body)).toEqual({ orderId: "t-1", itemId: "i-1", quantity: 2, price: 9.99 });
    expect(seen.api[0].auth).toMatch(/^[\w-]+\.[\w-]+\.[\w-]+$/);
    expect(seen.api[0].auth.startsWith("Bearer")).toBe(false);
    expect(seen.api[0].search).toBe("");
  });

  test("a duplicate (409), too many requests (429) and a server error (500) each get their own message", async ({ page }) => {
    let next = 409;
    await world(page, { api: async () => json(next, { message: "x" }) });
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").first().fill("t-1");
    await page.getByLabel("Item ID").fill("i-1");
    for (const [status, text] of [[409, "already exists"], [429, "Too many requests"], [500, "Something went wrong"]]) {
      next = status;
      await page.click("#create-submit");
      await expect(page.locator("#create-result")).toContainText(text);
    }
  });

  test("the API's validation messages are listed", async ({ page }) => {
    await world(page, { api: async () => json(400, { message: "Invalid order", errors: ["quantity must be an integer between 1 and 10000"] }) });
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").first().fill("t-1");
    await page.getByLabel("Item ID").fill("i-1");
    await page.click("#create-submit");
    await expect(page.locator("#create-result li")).toContainText("quantity must be an integer");
  });
});

test.describe("looking up an order", () => {
  test("the direct read shows a table and the time it took", async ({ page }) => {
    const seen = await world(page);
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").last().fill("t-1");
    await page.click("#read-direct");
    const out = page.locator("#lookup-result");
    await expect(out.locator("caption")).toContainText("Direct read: 1 item in order t-1");
    await expect(out.locator("tbody tr")).toHaveCount(1);
    await expect(out.locator("tbody td").nth(0)).toHaveText("i-1");
    await expect(out.locator("tbody td").nth(1)).toHaveText("2");
    expect(seen.api.map((c) => c.path)).toEqual(["/orders/t-1"]);
  });

  test("the Lambda read reports that the list was cut off", async ({ page }) => {
    await world(page, { api: async () => json(200, readBody([ITEM], { truncated: true })) });
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").last().fill("t-1");
    await page.click("#read-lambda");
    await expect(page.locator("#lookup-result")).toContainText("cut off at 100 items");
  });

  test("comparing runs both reads and says which was faster", async ({ page }) => {
    const seen = await world(page, {
      api: async (request, url) => { await sleep(url.pathname.includes("via-lambda") ? 30 : 160); return defaultApi(request, url); },
    });
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").last().fill("t-1");
    await page.click("#read-both");
    const out = page.locator("#lookup-result");
    await expect(out.locator("table")).toHaveCount(2);
    await expect(out).toContainText(/Lambda read was .* faster than the direct read/);
    await expect(out).toContainText("One measurement");
    expect(seen.api.map((c) => c.path)).toEqual(["/orders/t-1", "/orders-via-lambda/t-1"]);
  });

  test("a missing order, throttling and a server error each get a clear message", async ({ page }) => {
    let next = 404;
    await world(page, { api: async () => json(next, { message: "x" }) });
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").last().fill("t-1");
    for (const [status, text] of [[404, "No such order."], [429, "Too many requests"], [500, "Something went wrong"]]) {
      next = status;
      await page.click("#read-direct");
      await expect(page.locator("#lookup-result")).toContainText(text);
    }
  });

  test("an invalid order ID is explained and nothing is sent", async ({ page }) => {
    const seen = await world(page);
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").last().fill("a/b");
    await page.click("#read-direct");
    await expect(page.locator("#lookup-result")).toContainText("The order ID must be");
    expect(seen.api).toHaveLength(0);
  });

  test("pressing Enter in the lookup field does a Lambda read", async ({ page }) => {
    const seen = await world(page);
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").last().fill("t-1");
    await page.getByLabel("Order ID").last().press("Enter");
    await expect(page.locator("#lookup-result table")).toHaveCount(1);
    expect(seen.api.map((c) => c.path)).toEqual(["/orders-via-lambda/t-1"]);
  });

  test("a network or cross-origin failure is reported", async ({ page }) => {
    await world(page);
    await page.route(`${API}/**`, (route) => route.abort("failed"));
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").last().fill("t-1");
    await page.click("#read-direct");
    await expect(page.locator("#lookup-result")).toContainText("Could not reach the API");
  });
});

test.describe("sessions and safety", () => {
  test("a 401 ends the session and asks to sign in again", async ({ page }) => {
    await world(page, { api: async () => json(401, { message: "Unauthorized" }) });
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").last().fill("t-1");
    await page.click("#read-direct");
    await expect(page.locator("#signed-out")).toBeVisible();
    await expect(page.locator("#status")).toContainText("session has ended");
    await expect(page.locator("#signed-in")).toBeHidden();
  });

  test("a token that has expired is not sent: the page asks to sign in", async ({ page }) => {
    const seen = await world(page, { token: () => json(200, { id_token: idToken(), expires_in: 1 }) });
    await page.goto("/");
    await signIn(page);
    await sleep(1500);
    await page.getByLabel("Order ID").last().fill("t-1");
    await page.click("#read-direct");
    await expect(page.locator("#lookup-result")).toContainText("Please sign in first");
    expect(seen.api).toHaveLength(0);
  });

  test("text from the API is never run as markup or script (XSS)", async ({ page }) => {
    const evil = [{ itemId: '<img src=x onerror="window.__xss=1">', quantity: 1, price: null, createdAt: "<script>window.__xss=2</script>" }];
    let mode = "ok";
    await world(page, {
      api: async () => (mode === "ok" ? json(200, readBody(evil)) : json(400, { errors: ['<script>window.__xss=3</script><b>bold</b>'] })),
    });
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").last().fill("t-1");
    await page.click("#read-direct");
    await expect(page.locator("#lookup-result")).toContainText('<img src=x onerror="window.__xss=1">');
    mode = "bad";
    await page.click("#read-direct");
    await expect(page.locator("#lookup-result")).toContainText("<script>window.__xss=3</script>");
    expect(await page.evaluate(() => window.__xss)).toBeUndefined();
    await expect(page.locator("#lookup-result img, #lookup-result script, #lookup-result b")).toHaveCount(0);
  });

  test("the page and its files come with the security headers", async ({ page }) => {
    const r = await page.goto("/");
    const h = r.headers();
    expect(h["content-security-policy"]).toContain("default-src 'none'");
    expect(h["content-security-policy"]).toContain("frame-ancestors 'none'");
    expect(h["content-security-policy"]).not.toMatch(/unsafe-inline|unsafe-eval|\*/);
    expect(h["x-content-type-options"]).toBe("nosniff");
    expect(h["x-frame-options"]).toBe("DENY");
  });

  test("an inline script or style would be blocked by the policy (the policy is really enforced)", async ({ page }) => {
    await world(page);
    await page.goto("/");
    await page.evaluate(() => {
      const s = document.createElement("script");
      s.textContent = "window.__injected = 1";
      document.body.append(s);
    });
    expect(await page.evaluate(() => window.__injected)).toBeUndefined();
    expect(await page.evaluate(() => window.__csp.length)).toBeGreaterThan(0);
    await page.evaluate(() => { window.__csp = []; }); // expected here: do not fail the test for the violation we caused
  });
});

test.describe("accessibility and layout", () => {
  test("every field and button has an accessible name, and the page has one main heading", async ({ page }) => {
    await world(page);
    await page.goto("/");
    await signIn(page);
    await expect(page.locator("html")).toHaveAttribute("lang", "en");
    await expect(page.locator("h1")).toHaveCount(1);
    for (const input of await page.locator("input").all()) {
      const id = await input.getAttribute("id");
      expect(await page.locator(`label[for="${id}"]`).count(), `label for ${id}`).toBe(1);
    }
    for (const button of await page.locator("button:visible").all()) {
      expect((await button.innerText()).trim().length, "button text").toBeGreaterThan(0);
    }
    await expect(page.locator("#status")).toHaveAttribute("aria-live", "polite");
  });

  test("a phone-sized screen does not scroll sideways", async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 740 });
    await world(page);
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").last().fill("t-1");
    await page.click("#read-both");
    await expect(page.locator("#lookup-result table")).toHaveCount(2);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
  });

  test("the forms can be reached and used with the keyboard", async ({ page }) => {
    await world(page);
    await page.goto("/");
    await signIn(page);
    await page.getByLabel("Order ID").first().focus();
    await page.keyboard.press("Tab");
    await expect(page.getByLabel("Item ID")).toBeFocused();
    await page.keyboard.press("Tab");
    await expect(page.getByLabel(/Quantity/)).toBeFocused();
  });
});
