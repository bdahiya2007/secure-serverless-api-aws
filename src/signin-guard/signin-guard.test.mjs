import { test } from "node:test";
import assert from "node:assert/strict";
import { createHandler, decide, parseAllowList, DENIED } from "./signin-guard.mjs";

const allow = parseAllowList("Owner@example.com, second@example.org ,");
const silent = () => {};

const external = (attrs) => ({ triggerSource: "PreSignUp_ExternalProvider", request: { userAttributes: attrs } });
const token = (attrs, source = "TokenGeneration_HostedAuth") => ({ triggerSource: source, request: { userAttributes: attrs } });
const federatedAttrs = (email, extra = {}) => ({ email, email_verified: "true", identities: '[{"providerName":"Google"}]', ...extra });

test("parseAllowList trims, lower-cases and drops empty entries", () => {
  assert.deepEqual([...allow].sort(), ["owner@example.com", "second@example.org"]);
  assert.equal(parseAllowList(undefined).size, 0);
  assert.equal(parseAllowList("").size, 0);
});

test("pre sign-up: an allowed Google address is let in, ignoring case and spaces", () => {
  assert.equal(decide(external({ email: "OWNER@example.com " }), allow), "allow");
});

test("pre sign-up: an address that is not on the list is denied", () => {
  assert.equal(decide(external({ email: "stranger@example.com" }), allow), "deny");
});

test("pre sign-up: a missing or empty email is denied", () => {
  assert.equal(decide(external({}), allow), "deny");
  assert.equal(decide(external({ email: "" }), allow), "deny");
  assert.equal(decide({ triggerSource: "PreSignUp_ExternalProvider" }, allow), "deny");
});

test("pre sign-up: an allowed address that Google says is not verified is denied", () => {
  assert.equal(decide(external({ email: "owner@example.com", email_verified: "false" }), allow), "deny");
});

test("pre sign-up: an empty allow-list denies everyone (fail closed)", () => {
  assert.equal(decide(external({ email: "owner@example.com" }), new Set()), "deny");
});

test("pre sign-up by an administrator (CLI test users) is allowed", () => {
  assert.equal(decide({ triggerSource: "PreSignUp_AdminCreateUser", request: { userAttributes: { email: "t@example.com" } } }, allow), "allow");
});

test("self sign-up and unknown triggers are denied", () => {
  assert.equal(decide({ triggerSource: "PreSignUp_SignUp", request: { userAttributes: { email: "owner@example.com" } } }, allow), "deny");
  assert.equal(decide({ triggerSource: "Something_Else" }, allow), "deny");
  assert.equal(decide({}, allow), "deny");
  assert.equal(decide(null, allow), "deny");
});

test("token generation: a federated user on the list gets tokens, on every trigger variant", () => {
  for (const source of ["TokenGeneration_HostedAuth", "TokenGeneration_Authentication", "TokenGeneration_RefreshTokens"]) {
    assert.equal(decide(token(federatedAttrs("owner@example.com"), source), allow), "allow", source);
  }
});

test("token generation: a federated user who is no longer on the list is denied, even on refresh", () => {
  const gone = parseAllowList("someone-else@example.com");
  assert.equal(decide(token(federatedAttrs("owner@example.com")), gone), "deny");
  assert.equal(decide(token(federatedAttrs("owner@example.com"), "TokenGeneration_RefreshTokens"), gone), "deny");
});

test("token generation: the EXTERNAL_PROVIDER status alone marks a user as federated", () => {
  const attrs = { email: "stranger@example.com", "cognito:user_status": "EXTERNAL_PROVIDER" };
  assert.equal(decide(token(attrs), allow), "deny");
});

test("token generation: a native (administrator-created) user is not subject to the list", () => {
  assert.equal(decide(token({ email: "cli-test@example.com" }), allow), "allow");
});

test("handler returns the event unchanged when allowed", async () => {
  const handler = createHandler({ allowedEmails: "owner@example.com", log: silent });
  const event = external({ email: "owner@example.com" });
  assert.equal(await handler(event), event);
});

test("handler throws a generic error when denied, without echoing the email", async () => {
  const handler = createHandler({ allowedEmails: "owner@example.com", log: silent });
  await assert.rejects(handler(external({ email: "stranger@example.com" })), (err) => {
    assert.equal(err.message, DENIED);
    assert.ok(!err.message.includes("stranger"));
    return true;
  });
});

test("the log line has the decision and trigger but no email", async () => {
  const lines = [];
  const handler = createHandler({ allowedEmails: "owner@example.com", log: (l) => lines.push(l) });
  await handler(external({ email: "owner@example.com" }));
  await assert.rejects(handler(external({ email: "stranger@example.com" })));
  assert.equal(lines.length, 2);
  for (const line of lines) {
    assert.ok(!/example\.com|@/.test(line), line);
    const parsed = JSON.parse(line);
    assert.equal(parsed.triggerSource, "PreSignUp_ExternalProvider");
  }
  assert.equal(JSON.parse(lines[0]).decision, "allow");
  assert.equal(JSON.parse(lines[1]).decision, "deny");
});

test("handler with no allow-list configured denies a federated sign-in", async () => {
  const handler = createHandler({ allowedEmails: undefined, log: silent });
  await assert.rejects(handler(external({ email: "owner@example.com" })));
});
