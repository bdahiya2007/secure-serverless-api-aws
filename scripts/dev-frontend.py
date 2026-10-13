#!/usr/bin/env python3
"""Serves the front end on http://localhost:8765/ for development, against the REAL deployed API and Cognito sign-in.

  scripts/dev-frontend.py [--port 8765]

It serves src/frontend/ and generates /config.json from the deployed stack (terraform output, public values only) with the redirect
address http://localhost:8765/, which is registered as a sign-in callback and a CORS origin. It sends the same security headers as
the production site (including the Content Security Policy), so anything the CSP would block shows up here, in the browser console,
before you publish. Listens on 127.0.0.1 only. Needs: terraform and AWS credentials (to read the stack's outputs), python3.
Stop it with Ctrl+C.
"""
import argparse, http.server, json, mimetypes, os, re, subprocess, sys, urllib.parse

TOP = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
ROOT = os.path.join(TOP, "src", "frontend")
DEV = os.path.join(TOP, "terraform", "environments", "dev")


def output(name):
    r = subprocess.run(["terraform", "output", "-json", name], capture_output=True, text=True, cwd=DEV)
    return json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None


def build(port):
    signin = output("browser_signin")
    create_url = output("create_order_url")
    if not signin or not create_url:
        sys.exit("The deployed stack has no browser sign-in or API URL (terraform output). Apply the hosted sign-in first.")
    redirect = f"http://localhost:{port}/"
    if redirect not in (signin.get("callback_urls") or []):
        sys.exit(f"{redirect} is not a registered callback URL (BROWSER_CALLBACK_URLS). Use the registered port, or add this one.")
    api_base = re.match(r"^(.*)/orders$", create_url).group(1)
    api_origin = re.match(r"^(https://[^/]+)", create_url).group(1)
    config = {"apiBaseUrl": api_base, "redirectUri": redirect,
              "cognito": {"host": signin["host"], "clientId": signin["client_id"], "scopes": " ".join(signin.get("scopes", ["openid", "email"]))}}
    csp = "; ".join(["default-src 'none'", "script-src 'self'", "style-src 'self'", "img-src 'self' data:", "font-src 'self'",
                     f"connect-src 'self' {api_origin} https://{signin['host']}", "base-uri 'self'", "form-action 'self'", "frame-ancestors 'none'"])
    headers = {"Content-Security-Policy": csp, "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
               "Referrer-Policy": "strict-origin-when-cross-origin", "Cache-Control": "no-store",
               "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=(), usb=()"}
    return json.dumps(config).encode(), headers


class Handler(http.server.BaseHTTPRequestHandler):
    config = b"{}"
    headers_out = {}

    def send_all(self, status, body, ctype):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in self.headers_out.items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/config.json":
            return self.send_all(200, self.config, "application/json")
        rel = "index.html" if path == "/" else path.lstrip("/")
        full = os.path.realpath(os.path.join(ROOT, rel))
        # only the front end's own files, never the tests or the package file, and never outside the folder
        if not full.startswith(ROOT + os.sep) or rel.endswith(".test.mjs") or rel == "package.json" or not os.path.isfile(full):
            err = os.path.join(ROOT, "error.html")
            return self.send_all(404, open(err, "rb").read() if os.path.isfile(err) else b"not found", "text/html; charset=utf-8")
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if full.endswith(".js"):
            ctype = "text/javascript"
        self.send_all(200, open(full, "rb").read(), ctype + ("; charset=utf-8" if ctype.startswith("text/") else ""))

    do_HEAD = do_GET

    def log_message(self, fmt, *args):
        sys.stderr.write("  %s\n" % (fmt % args))


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8765)
    a = ap.parse_args()
    Handler.config, Handler.headers_out = build(a.port)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print(f"Serving src/frontend at http://localhost:{a.port}/  (real API and sign-in; Ctrl+C to stop)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
