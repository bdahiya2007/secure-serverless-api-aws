// A tiny static server for the MOCKED browser tests. It serves src/frontend with a fake /config.json and the same security headers
// as production (a Content Security Policy whose connect-src is exactly the fake API and sign-in host), so a CSP violation in the
// page fails a test. Nothing here talks to AWS.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { dirname, extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

import { FAKE, PORT, config } from "./fixtures.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "src", "frontend");
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8" };

const CSP = [
  "default-src 'none'", "script-src 'self'", "style-src 'self'", "img-src 'self' data:", "font-src 'self'",
  `connect-src 'self' ${FAKE.api} https://${FAKE.host}`, "base-uri 'self'", "form-action 'self'", "frame-ancestors 'none'",
].join("; ");
const HEADERS = {
  "Content-Security-Policy": CSP, "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
  "Referrer-Policy": "strict-origin-when-cross-origin", "Cache-Control": "no-store",
};

createServer(async (req, res) => {
  const path = new URL(req.url, "http://x").pathname;
  const send = (status, body, type) => { res.writeHead(status, { "Content-Type": type, ...HEADERS }); res.end(body); };
  if (path === "/config.json") return send(200, JSON.stringify(config()), "application/json");
  const rel = path === "/" ? "index.html" : normalize(path).replace(/^([/\\])+/, "");
  if (rel.includes("..") || rel.endsWith(".test.mjs") || rel === "package.json") return send(404, "not found", "text/plain");
  try {
    send(200, await readFile(join(ROOT, rel)), TYPES[extname(rel)] ?? "application/octet-stream");
  } catch {
    send(404, await readFile(join(ROOT, "error.html")), TYPES[".html"]);
  }
}).listen(PORT, "127.0.0.1", () => console.log(`serving the front end at http://localhost:${PORT}/ (mocked tests)`));
