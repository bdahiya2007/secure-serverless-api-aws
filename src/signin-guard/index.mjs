import { createHandler } from "./signin-guard.mjs";

// ALLOWED_EMAILS: comma-separated Google addresses that may sign in. Empty means nobody (fail closed).
export const handler = createHandler({ allowedEmails: process.env.ALLOWED_EMAILS });
