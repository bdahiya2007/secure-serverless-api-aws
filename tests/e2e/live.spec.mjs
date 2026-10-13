// The front end against the REAL sign-in and API, in a real browser. Run on demand only:
//   AWS_PROFILE=... npm run test:live      (E2E_LIVE=1; the config starts scripts/dev-frontend.py on http://localhost:8765)
// It creates ONE temporary Cognito user (password chosen at random, never printed) and a few order rows, and ALWAYS removes them.
// It proves what the mocked tests cannot: Cognito's real hosted login, the real token endpoint and CORS, the API's CORS answers
// and the real Content Security Policy working together in a browser.
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { expect, test } from "@playwright/test";

const DEV = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "terraform", "environments", "dev");
const sh = (cmd, args) => execFileSync(cmd, args, { encoding: "utf8", cwd: DEV }).trim();

const run = randomBytes(3).toString("hex");
const email = `live-${run}@example.com`;
const password = `Aa1!${randomBytes(12).toString("hex")}`;
const orderId = `live-${run}`;
let pool;

test.beforeAll(() => {
  pool = sh("terraform", ["output", "-raw", "user_pool_id"]);
  sh("aws", ["cognito-idp", "admin-create-user", "--user-pool-id", pool, "--username", email, "--message-action", "SUPPRESS",
    "--user-attributes", `Name=email,Value=${email}`, "Name=email_verified,Value=true"]);
  sh("aws", ["cognito-idp", "admin-set-user-password", "--user-pool-id", pool, "--username", email, "--password", password, "--permanent"]);
});

test.afterAll(() => {
  for (const itemId of ["i-1", "i-2"]) {
    try {
      sh("aws", ["dynamodb", "delete-item", "--table-name", "Orders", "--key", JSON.stringify({ orderId: { S: orderId }, itemId: { S: itemId } })]);
    } catch { /* nothing to delete */ }
  }
  try { sh("aws", ["cognito-idp", "admin-delete-user", "--user-pool-id", pool, "--username", email]); } catch { /* already gone */ }
});

test("real sign-in, create, read both ways, compare, sign out: no policy violation, no error, nothing stored", async ({ page, context }) => {
  await page.addInitScript(() => {
    window.__csp = [];
    document.addEventListener("securitypolicyviolation", (e) => window.__csp.push(`${e.violatedDirective} ${e.blockedURI}`));
  });
  const problems = [];
  page.on("pageerror", (e) => problems.push(`pageerror: ${e.message}`));
  page.on("console", (m) => {
    // The browser itself logs a console error for any HTTP error response. This test causes exactly two on purpose (409 for the duplicate
    // item, 404 for the missing order) and the browser asks for /favicon.ico on its own (the site has none). Anything else is a problem.
    const expected = /Failed to load resource: the server responded with a status of (404|409)/.test(m.text()) || /favicon/.test(m.location()?.url ?? "");
    if (m.type() === "error" && !expected) problems.push(`console: ${m.text()}`);
  });

  // signed out, then Cognito's real hosted login
  await page.goto("/");
  await expect(page.locator("#sign-in")).toBeVisible();
  await page.click("#sign-in");
  await page.waitForURL(/\.auth\.[a-z0-9-]+\.amazoncognito\.com\//);
  await page.locator('input[name="username"]:visible').fill(email);
  await page.locator('input[name="password"]:visible').fill(password);
  await page.locator('input[name="signInSubmitButton"]:visible').click();

  // back on the page, signed in, with a clean address and no stored token
  await page.waitForURL("http://localhost:8765/");
  await expect(page.locator("#who")).toContainText(`Signed in as ${email}`);
  expect(new URL(page.url()).search).toBe("");
  expect(await page.evaluate(() => localStorage.length)).toBe(0);
  expect(await page.evaluate(() => sessionStorage.length)).toBe(0);
  expect((await context.cookies("http://localhost:8765/")).length).toBe(0);

  // create an item, then the same item again
  await page.getByLabel("Order ID").first().fill(orderId);
  await page.getByLabel("Item ID").fill("i-1");
  await page.getByLabel(/Quantity/).fill("2");
  await page.getByLabel(/Price/).fill("9.99");
  await page.click("#create-submit");
  await expect(page.locator("#create-result")).toContainText(`Saved item i-1 in order ${orderId}`);
  await page.click("#create-submit");
  await expect(page.locator("#create-result")).toContainText("already exists");

  // read it both ways and compare
  const lookup = page.getByLabel("Order ID").last();
  await lookup.fill(orderId);
  await page.click("#read-direct");
  const out = page.locator("#lookup-result");
  await expect(out.locator("caption")).toContainText(`Direct read: 1 item in order ${orderId}`);
  await expect(out.locator("tbody td").nth(0)).toHaveText("i-1");
  await expect(out.locator("tbody td").nth(1)).toHaveText("2");
  await expect(out.locator("tbody td").nth(2)).toHaveText("9.99");
  await page.click("#read-lambda");
  await expect(out.locator("caption")).toContainText(`Lambda read: 1 item in order ${orderId}`);
  await page.click("#read-both");
  await expect(out.locator("table")).toHaveCount(2);
  await expect(out).toContainText(/Lambda read was .* (faster|slower) than the direct read|about the same time/);

  // an order that does not exist
  await lookup.fill(`${orderId}-missing`);
  await page.click("#read-direct");
  await expect(out).toContainText("No such order.");

  // sign out through the hosted logout, and come back signed out
  await page.click("#sign-out");
  await page.waitForURL("http://localhost:8765/");
  await expect(page.locator("#signed-out")).toBeVisible();
  await expect(page.locator("#who")).toBeHidden();

  expect(await page.evaluate(() => window.__csp), "Content Security Policy violations").toEqual([]);
  expect(problems, "console errors and uncaught exceptions").toEqual([]);
});
