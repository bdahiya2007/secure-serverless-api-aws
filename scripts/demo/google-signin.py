#!/usr/bin/env python3
"""Sign in with Google through the Cognito hosted pages and save the resulting ID token locally (authorization code + PKCE).

  scripts/demo/google-signin.py [--region us-east-1]     sign in in a browser, save the tokens
  scripts/demo/google-signin.py --refresh [--region R]   get new tokens from the saved refresh token (this runs the
                                                          sign-in guard again, so a user removed from the allow-list is refused)
  scripts/demo/google-signin.py --forget [--region R]    delete the saved tokens

Needs the federated sign-in switch on (terraform output federated_signin) and a browser on this machine: the script listens on
http://localhost:8765/callback, which must be one of the app client's callback URLs (it is by default). Standard library only.

Tokens are CREDENTIALS. They are written to ~/.cache/orders-api/ with mode 0600, never printed, never logged and never inside the
repository. The ID token lasts about an hour; the refresh token about 7 days. Use --forget when you are done.
"""
import argparse, base64, hashlib, http.server, json, os, secrets, subprocess, sys, threading, urllib.parse, urllib.request, urllib.error, webbrowser

PORT = 8765
CALLBACK = f"http://localhost:{PORT}/callback"
CACHE = os.path.expanduser("~/.cache/orders-api")


def repo_dev_dir():
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True).stdout.strip()
    return os.path.join(top, "terraform", "environments", "dev")


def regional_config(region):
    out = subprocess.run(["terraform", "output", "-json", "federated_signin"], cwd=repo_dev_dir(), capture_output=True, text=True)
    cfg = json.loads(out.stdout or "null") if out.returncode == 0 else None
    if not cfg or region not in cfg:
        sys.exit(f"No federated sign-in for {region}. Is enable_federated_signin on (and, for the second region, enable_multi_region)?")
    return cfg[region]["host"], cfg[region]["client_id"]


def token_request(host, fields):
    req = urllib.request.Request(
        f"https://{host}/oauth2/token", data=urllib.parse.urlencode(fields).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        # Cognito's error body names the problem (for example invalid_grant) and holds no token.
        sys.exit(f"Token request refused: HTTP {e.code} {e.read().decode(errors='replace')[:200]}")


def save(region, tokens):
    os.makedirs(CACHE, mode=0o700, exist_ok=True)
    for name in ("id_token", "refresh_token"):
        if name in tokens:
            path = os.path.join(CACHE, f"{name}-{region}")
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(tokens[name])
    claims = json.loads(base64.urlsafe_b64decode(tokens["id_token"].split(".")[1] + "=="))
    print(f"Saved tokens for {region} in {CACHE} (ID token expires in about {(claims['exp'] - claims['iat']) // 60} minutes).")
    print(f"Issuer pool: {claims['iss'].rsplit('/', 1)[-1].split('_')[0]}; email verified: {claims.get('email_verified')}; "
          f"federated: {'identities' in claims}.")


def browser_sign_in(region):
    host, client_id = regional_config(region)
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    url = f"https://{host}/oauth2/authorize?" + urllib.parse.urlencode({
        "response_type": "code", "client_id": client_id, "redirect_uri": CALLBACK, "scope": "openid email profile",
        "identity_provider": "Google", "code_challenge": challenge, "code_challenge_method": "S256", "state": state})
    result = {}
    done = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if urllib.parse.urlparse(self.path).path != "/callback":
                self.send_response(404); self.end_headers(); return
            result["code"], result["state"], result["error"] = (q.get(k, [""])[0] for k in ("code", "state", "error_description"))
            self.send_response(200); self.send_header("Content-Type", "text/plain"); self.end_headers()
            self.wfile.write(b"Signed in. You can close this tab and return to the terminal.")
            done.set()

        def log_message(self, *args):  # no request logging: the URL holds a one-time code
            pass

    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"Open this URL in a browser and sign in with Google ({region}):\n\n{url}\n")
    try:
        webbrowser.open(url)
    except Exception:
        pass
    if not done.wait(300):
        sys.exit("Timed out after 5 minutes.")
    server.shutdown()
    if result["error"] or not result["code"]:
        sys.exit(f"Sign-in was refused: {result['error'] or 'no code returned'}")
    if result["state"] != state:
        sys.exit("State mismatch; aborting.")
    save(region, token_request(host, {"grant_type": "authorization_code", "client_id": client_id, "code": result["code"],
                                      "redirect_uri": CALLBACK, "code_verifier": verifier}))


def refresh(region):
    host, client_id = regional_config(region)
    path = os.path.join(CACHE, f"refresh_token-{region}")
    if not os.path.exists(path):
        sys.exit(f"No saved refresh token for {region}; sign in first.")
    with open(path) as f:
        tokens = token_request(host, {"grant_type": "refresh_token", "client_id": client_id, "refresh_token": f.read().strip()})
    save(region, tokens)


def forget(region):
    for name in ("id_token", "refresh_token"):
        try:
            os.remove(os.path.join(CACHE, f"{name}-{region}"))
        except FileNotFoundError:
            pass
    print(f"Deleted saved tokens for {region}.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--refresh", action="store_true")
    mode.add_argument("--forget", action="store_true")
    a = ap.parse_args()
    (refresh if a.refresh else forget if a.forget else browser_sign_in)(a.region)
