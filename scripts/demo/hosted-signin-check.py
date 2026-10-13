#!/usr/bin/env python3
"""Checks Cognito's hosted sign-in for the browser client with NO browser: the authorization code flow with PKCE, exactly as a
front end does it, signing in a temporary password user on the hosted pages.

  scripts/demo/hosted-signin-check.py

What it does: creates a temporary admin-created user, opens /oauth2/authorize, signs in on the hosted login page, takes the
authorization code from the redirect (it never contacts the redirect URL), exchanges it for tokens with the PKCE verifier,
checks the ID token (issuer, audience, email) and calls the API with it (a 404 for a missing order means "accepted"; 401 means
refused), checks that a wrong password and a redirect URL that is not registered are refused, and ALWAYS deletes the user.
Needs: the hosted UI and browser client applied (terraform output browser_signin), AWS credentials, terraform, python3.
Tokens are never printed. Standard library only.
"""
import base64, hashlib, html, http.cookiejar, json, os, re, secrets, subprocess, sys, urllib.error, urllib.parse, urllib.request


def sh(*args, cwd=None):
    return subprocess.run(args, capture_output=True, text=True, check=True, cwd=cwd).stdout.strip()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def open_url(opener, url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        r = opener.open(req, timeout=25)
        return r.status, dict(r.headers), r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode("utf-8", "replace")


def main():
    top = sh("git", "rev-parse", "--show-toplevel")
    dev = os.path.join(top, "terraform", "environments", "dev")
    out = subprocess.run(["terraform", "output", "-json", "browser_signin"], capture_output=True, text=True, cwd=dev)
    cfg = json.loads(out.stdout or "null") if out.returncode == 0 else None
    if not cfg:
        sys.exit("The browser client is not applied (terraform output browser_signin is empty). Set cognito_domain_prefix and browser_callback_urls first.")
    host, client_id = cfg["host"], cfg["client_id"]
    pool = sh("terraform", "output", "-raw", "user_pool_id", cwd=dev)
    api = sh("terraform", "output", "-raw", "create_order_url", cwd=dev).rsplit("/orders", 1)[0]
    callbacks = json.loads(sh("aws", "cognito-idp", "describe-user-pool-client", "--user-pool-id", pool, "--client-id", client_id,
                              "--query", "UserPoolClient.CallbackURLs", "--output", "json"))
    redirect = callbacks[0]
    run = secrets.token_hex(3)
    email, password = f"hosted-{run}@example.com", "Aa1!" + secrets.token_hex(12)
    passed = failed = 0

    def check(label, ok, detail=""):
        nonlocal passed, failed
        passed, failed = (passed + 1, failed) if ok else (passed, failed + 1)
        print(f"  {'ok  ' if ok else 'FAIL'} {label}{(' -> ' + detail) if detail else ''}")

    sh("aws", "cognito-idp", "admin-create-user", "--user-pool-id", pool, "--username", email, "--message-action", "SUPPRESS",
       "--user-attributes", f"Name=email,Value={email}", "Name=email_verified,Value=true")
    sh("aws", "cognito-idp", "admin-set-user-password", "--user-pool-id", pool, "--username", email, "--password", password, "--permanent")
    try:
        verifier = secrets.token_urlsafe(64)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        state = secrets.token_urlsafe(12)
        q = urllib.parse.urlencode({"response_type": "code", "client_id": client_id, "redirect_uri": redirect, "scope": "openid email",
                                    "code_challenge": challenge, "code_challenge_method": "S256", "state": state})
        jar = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect)

        print("hosted host and browser client found; the redirect URL tested is the first registered one")
        print("== 1 the authorize endpoint and the login page")
        status, headers, _ = open_url(opener, f"https://{host}/oauth2/authorize?{q}")
        loc = headers.get("Location", "")
        check("authorize redirects to the hosted login page", status in (301, 302) and "/login" in loc, f"HTTP {status}")
        login_url = urllib.parse.urljoin(f"https://{host}/", loc)
        status, _, page = open_url(opener, login_url)
        # Attribute order varies (the live page writes action before name), so read the form tag first, then its action.
        tag = re.search(r'<form\b[^>]*\bname="cognitoSignInForm"[^>]*>', page)
        form = re.search(r'\baction="([^"]+)"', tag.group(0)) if tag else None
        csrf = re.search(r'<input\b[^>]*\bname="_csrf"[^>]*\bvalue="([^"]+)"', page)
        check("login page has the sign-in form with a CSRF token", status == 200 and bool(form) and bool(csrf), f"HTTP {status}")
        if not (form and csrf):
            return 1
        action = urllib.parse.urljoin(f"https://{host}/", html.unescape(form.group(1)))
        fields = lambda pw: urllib.parse.urlencode({"_csrf": csrf.group(1), "username": email, "password": pw, "signInSubmitButton": "Sign in"}).encode()
        hdr = {"Content-Type": "application/x-www-form-urlencoded", "Referer": login_url}

        print("== 2 a wrong password is refused")
        status, headers, _ = open_url(opener, action, fields("Wrong1!password"), hdr)
        check("wrong password does not redirect with a code", "code=" not in headers.get("Location", ""), f"HTTP {status}")

        print("== 3 sign in with the right password")
        status, headers, _ = open_url(opener, action, fields(password), hdr)
        loc = headers.get("Location", "")
        got = urllib.parse.parse_qs(urllib.parse.urlparse(loc).query)
        check("sign-in redirects to the registered URL with a code", status in (301, 302) and loc.startswith(redirect) and "code" in got, f"HTTP {status}")
        check("the state value is returned unchanged", got.get("state", [""])[0] == state)
        if "code" not in got:
            return 1

        print("== 4 exchange the code (PKCE) for tokens")
        body = urllib.parse.urlencode({"grant_type": "authorization_code", "client_id": client_id, "code": got["code"][0],
                                       "redirect_uri": redirect, "code_verifier": verifier}).encode()
        status, _, raw = open_url(urllib.request.build_opener(), f"https://{host}/oauth2/token", body, {"Content-Type": "application/x-www-form-urlencoded"})
        tokens = json.loads(raw) if status == 200 else {}
        check("token endpoint returns an ID token and a refresh token", status == 200 and "id_token" in tokens and "refresh_token" in tokens, f"HTTP {status}")
        if "id_token" not in tokens:
            return 1
        claims = json.loads(base64.urlsafe_b64decode(tokens["id_token"].split(".")[1] + "=="))
        check("ID token: issuer is this pool and audience is the browser client", claims.get("iss", "").endswith("/" + pool) and claims.get("aud") == client_id)
        check("ID token: token_use id, email present and verified", claims.get("token_use") == "id" and claims.get("email") == email and claims.get("email_verified") is True)
        # the same code cannot be used twice
        status2, _, _ = open_url(urllib.request.build_opener(), f"https://{host}/oauth2/token", body, {"Content-Type": "application/x-www-form-urlencoded"})
        check("an authorization code works only once", status2 == 400, f"HTTP {status2}")

        print("== 5 the API accepts the token")
        s_ok, _, _ = open_url(urllib.request.build_opener(), f"{api}/orders-via-lambda/{run}-missing", None, {"Authorization": tokens["id_token"]})
        s_no, _, _ = open_url(urllib.request.build_opener(), f"{api}/orders-via-lambda/{run}-missing")
        check("API with the token: 404 (accepted, order not found)", s_ok == 404, f"HTTP {s_ok}")
        check("API without a token: 401", s_no == 401, f"HTTP {s_no}")

        print("== 6 a redirect URL that is not registered is refused")
        bad_q = urllib.parse.urlencode({"response_type": "code", "client_id": client_id, "redirect_uri": "https://not-registered.example.test/",
                                        "scope": "openid email", "code_challenge": challenge, "code_challenge_method": "S256"})
        status, headers, _ = open_url(urllib.request.build_opener(NoRedirect), f"https://{host}/oauth2/authorize?{bad_q}")
        check("authorize with an unregistered redirect_uri does not redirect there", "not-registered" not in headers.get("Location", ""), f"HTTP {status}")
        return 0 if failed == 0 else 1
    finally:
        subprocess.run(["aws", "cognito-idp", "admin-delete-user", "--user-pool-id", pool, "--username", email], capture_output=True)
        left = sh("aws", "cognito-idp", "list-users", "--user-pool-id", pool, "--query", "length(Users)", "--output", "text")
        print(f"\nresult: {passed} passed, {failed} failed\ncleanup: temporary user deleted, users left={left}")


if __name__ == "__main__":
    sys.exit(main())
