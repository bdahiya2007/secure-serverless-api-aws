// Cognito trigger that decides who may sign in with a federated identity provider (Google). Pure logic with no
// dependencies, so it can be unit-tested with Node's built-in test runner.
//
// It is attached to two triggers:
//   * Pre sign-up: runs once, when a federated user would first be created. Denying here stops the profile being created.
//   * Pre token generation: runs on EVERY token (sign-in and refresh), so removing an email from the allow-list also locks
//     out a user who already has a profile. Pre sign-up alone would not (it never runs again for an existing user).
// Administrator-created users (the CLI test users) are not federated and are let through; self sign-up is disabled.
// Anything unexpected is denied (fail closed). Errors never say why, and emails are never logged.

export const DENIED = "Sign-in is not permitted for this account";

export function parseAllowList(raw) {
  return new Set(
    String(raw ?? "")
      .split(",")
      .map((e) => e.trim().toLowerCase())
      .filter(Boolean),
  );
}

// Federated users carry an `identities` attribute and the status EXTERNAL_PROVIDER; native users carry neither.
const isFederated = (attrs) => Boolean(attrs.identities) || attrs["cognito:user_status"] === "EXTERNAL_PROVIDER";

// Returns "allow" or "deny" for a federated identity.
function checkFederated(attrs, allowList) {
  const email = typeof attrs.email === "string" ? attrs.email.trim().toLowerCase() : "";
  if (!email || !allowList.has(email)) return "deny";
  if (attrs.email_verified === "false" || attrs.email_verified === false) return "deny"; // explicit "not verified" only
  return "allow";
}

export function decide(event, allowList) {
  const source = typeof event?.triggerSource === "string" ? event.triggerSource : "";
  const attrs = event?.request?.userAttributes ?? {};

  if (source === "PreSignUp_ExternalProvider") return checkFederated(attrs, allowList);
  if (source === "PreSignUp_AdminCreateUser") return "allow";
  if (source.startsWith("TokenGeneration_")) return isFederated(attrs) ? checkFederated(attrs, allowList) : "allow";
  return "deny"; // PreSignUp_SignUp (self sign-up is off) and anything unknown
}

export function createHandler({ allowedEmails, log = console.log }) {
  const allowList = parseAllowList(allowedEmails);

  return async (event) => {
    const decision = decide(event, allowList);
    // No email, name or token in the log: only the decision and where it was made.
    log(JSON.stringify({ message: "sign-in decision", decision, triggerSource: event?.triggerSource ?? null }));
    if (decision !== "allow") throw new Error(DENIED);
    return event;
  };
}
