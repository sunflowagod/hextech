
#!/usr/bin/env bash
# ============================================================
#  setup.sh — clawtank split
#
#  Home page at /
#  Studio at /studio
#  API reference at /api/docs  (SEO-targeted)
#  Auto-save files, delete user files, new-file button at
#  bottom of scripts panel.
#  Shared top nav (home / studio / api) via templates/_header.html
# ============================================================
set -e

[ -e clawtank ] && { echo "!! clawtank/ exists"; exit 1; }
[ -e worker ]   && { echo "!! worker/ exists"; exit 1; }

mkdir -p clawtank/scripts clawtank/templates worker/scripts

# ============================================================
#  clawtank/
# ============================================================
cd clawtank

cat > .gitignore <<'EOF'
venv/
__pycache__/
*.pyc
.env
.DS_Store
clawtank/
clawtank-*/
*.apk
*.zip
.gradle/
build/
workspaces/
projects/
data/
*.db
EOF

cat > requirements.txt <<'EOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
jinja2==3.1.4
python-multipart==0.0.9
websockets==12.0
EOF

cat > Procfile <<'EOF'
web: uvicorn main:app --host 0.0.0.0 --port $PORT
EOF

cat > railway.toml <<'EOF'
[build]
builder = "nixpacks"

[deploy]
startCommand = "uvicorn main:app --host 0.0.0.0 --port $PORT"
healthcheckPath = "/api/health"
healthcheckTimeout = 30
restartPolicyType = "on_failure"
EOF

cat > README.md <<'EOF'
# clawtank coordinator

    /           home (landing page)
    /studio     editor + live emulator
    /api/docs   API reference (SEO page)

MODE=remote by default. Workers bring devices into the pool.
    ../worker/start.sh

Auto-saves edited files into a per-page workspace (not a shared
folder). Every new studio page load is seeded from immutable
defaults/ (hello-world). Default file names cannot be deleted.
When a live session ends, the worker force-stops the app on the
emulator so the next lease starts clean.
EOF

cat > config.py <<'EOF'
import os
from pathlib import Path

HERE          = Path(__file__).resolve().parent
SCRIPTS_DIR   = HERE / "scripts"          # legacy / shared (unused for studio)
DEFAULTS_DIR  = HERE / "defaults"         # immutable hello-world seed
WORKSPACES_DIR = HERE / "workspaces"      # per-page isolated copies
PROJECTS_DIR  = HERE / "projects"         # shared snapshots (/project/<id>)
TEMPLATES_DIR = HERE / "templates"

MODE            = os.getenv("MODE", "remote")
PUBLIC_URL      = os.getenv("PUBLIC_URL", "http://127.0.0.1:8000")
SESSION_SECONDS = int(os.getenv("SESSION_SECONDS", "15"))
BUILD_MAX       = int(os.getenv("BUILD_MAX", "480"))
BUILD_IDLE      = int(os.getenv("BUILD_IDLE", "120"))

# Accounts / credits (1 credit = $0.01; a successful paid build costs BUILD_COST_CENTS)
DATABASE_PATH   = HERE / "data" / "clawtank.db"
SESSION_COOKIE  = "ct_session"
SESSION_DAYS    = int(os.getenv("SESSION_DAYS", "30"))
BUILD_COST_CENTS = int(os.getenv("BUILD_COST_CENTS", "5"))   # $0.05
STARTING_CREDITS = int(os.getenv("STARTING_CREDITS", "25"))  # free on signup
SECRET_KEY      = os.getenv("SECRET_KEY", "clawtank-dev-secret-change-me")

# Google OAuth (optional — enables "Continue with Google")
GOOGLE_CLIENT_ID     = os.getenv("GOOGLE_CLIENT_ID", "120801736446-t8dl3oa1mh8kks7e8v66skfs2j4nhbnc.apps.googleusercontent.com")
GOOGLE_CLIENT_SECRET = os.getenv("GOOGLE_CLIENT_SECRET", "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")
GOOGLE_REDIRECT_URI  = os.getenv("GOOGLE_REDIRECT_URI", "")  # default: {PUBLIC_URL}/auth/google/callback

# x402 payments (USDC via facilitator — see https://docs.x402.org)
X402_ENABLED       = os.getenv("X402_ENABLED", "1") not in ("0", "false", "False")
X402_PAY_TO        = os.getenv("X402_PAY_TO", "0x0000000000000000000000000000000000000000")
X402_NETWORK       = os.getenv("X402_NETWORK", "base-sepolia")  # or base
X402_FACILITATOR   = os.getenv("X402_FACILITATOR", "https://x402.org/facilitator")
# USDC (6 decimals): $0.05 = 50000 atomic units
X402_PRICE_ATOMIC  = os.getenv("X402_PRICE_ATOMIC", "50000")
X402_ASSET_SEPOLIA = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
X402_ASSET_BASE    = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
WORKSPACE_TTL   = int(os.getenv("WORKSPACE_TTL", "3600"))  # seconds

# Files seeded by setup.sh — cannot be deleted via the UI.
DEFAULT_FILES = {
    "MainActivity.kt",
    "colors.xml",
    "strings.xml",
    "AndroidManifest.xml",
    "themes.xml",
    "network_security_config.xml",
    "dimens.xml",
    "arrays.xml",
    "ic_launcher_foreground.xml",
    "ic_launcher_background.xml",
    "ic_vector_example.xml",
    "font_family.xml",
    "app/build.gradle.kts",
}

MAX_SIZE  = os.getenv("MAX_SIZE", "540")
MAX_FPS   = os.getenv("MAX_FPS", "60")
BIT_RATE  = os.getenv("BIT_RATE", "8000000")

SCRIPTS_DIR.mkdir(parents=True, exist_ok=True)
DEFAULTS_DIR.mkdir(parents=True, exist_ok=True)
WORKSPACES_DIR.mkdir(parents=True, exist_ok=True)
PROJECTS_DIR.mkdir(parents=True, exist_ok=True)
(DATABASE_PATH.parent).mkdir(parents=True, exist_ok=True)
EOF

cat > accounts.py <<'EOF'
"""User accounts, sessions, API keys, and credit ledger."""
from __future__ import annotations

import hashlib
import secrets
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from config import (
    DATABASE_PATH, SESSION_COOKIE, SESSION_DAYS,
    BUILD_COST_CENTS, STARTING_CREDITS, SECRET_KEY,
)

# ---------------------------------------------------------------------------
#  Schema
# ---------------------------------------------------------------------------

def _conn() -> sqlite3.Connection:
    DATABASE_PATH.parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(str(DATABASE_PATH), check_same_thread=False)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA foreign_keys = ON")
    return c


def init_db() -> None:
    with _conn() as db:
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                email TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL DEFAULT '',
                display_name TEXT,
                credits INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL,
                google_sub TEXT UNIQUE
            );
            CREATE TABLE IF NOT EXISTS sessions (
                token TEXT PRIMARY KEY,
                user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                created_at REAL NOT NULL,
                expires_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS api_keys (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                key_hash TEXT NOT NULL UNIQUE,
                key_prefix TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_used_at REAL,
                revoked INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS credit_ledger (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                delta INTEGER NOT NULL,
                balance_after INTEGER NOT NULL,
                reason TEXT NOT NULL,
                meta TEXT,
                created_at REAL NOT NULL
            );
            """
        )
        db.commit()
        # migrate google_sub column if upgrading older DBs
        try:
            cols = [r[1] for r in db.execute("PRAGMA table_info(users)").fetchall()]
            if "google_sub" not in cols:
                db.execute("ALTER TABLE users ADD COLUMN google_sub TEXT")
                db.commit()
        except Exception:
            pass
    _seed_test_accounts()


def _hash_password(password: str, salt: Optional[str] = None) -> str:
    salt = salt or secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt.encode("utf-8"), 120_000
    )
    return f"pbkdf2_sha256${salt}${dk.hex()}"


def _verify_password(password: str, stored: str) -> bool:
    try:
        algo, salt, hexdigest = stored.split("$", 2)
        if algo != "pbkdf2_sha256":
            return False
        dk = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), salt.encode("utf-8"), 120_000
        )
        return secrets.compare_digest(dk.hex(), hexdigest)
    except Exception:
        return False


def _hash_api_key(raw: str) -> str:
    return hashlib.sha256(f"{SECRET_KEY}:{raw}".encode("utf-8")).hexdigest()


@dataclass
class User:
    id: int
    email: str
    display_name: str
    credits: int
    created_at: float

    def public(self) -> dict:
        return {
            "id": self.id,
            "email": self.email,
            "display_name": self.display_name,
            "credits": self.credits,
            "credits_dollars": f"${self.credits / 100:.2f}",
            "build_cost_cents": BUILD_COST_CENTS,
        }


def _row_user(r: sqlite3.Row) -> User:
    return User(
        id=r["id"],
        email=r["email"],
        display_name=r["display_name"] or r["email"].split("@")[0],
        credits=int(r["credits"]),
        created_at=float(r["created_at"]),
    )


def create_user(email: str, password: str, display_name: str = "") -> User:
    email = email.strip().lower()
    if not email or "@" not in email:
        raise ValueError("valid email required")
    if len(password) < 6:
        raise ValueError("password must be at least 6 characters")
    now = time.time()
    ph = _hash_password(password)
    with _conn() as db:
        try:
            cur = db.execute(
                "INSERT INTO users (email, password_hash, display_name, credits, created_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (email, ph, display_name.strip() or email.split("@")[0],
                 STARTING_CREDITS, now),
            )
            uid = cur.lastrowid
            db.execute(
                "INSERT INTO credit_ledger (user_id, delta, balance_after, reason, meta, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (uid, STARTING_CREDITS, STARTING_CREDITS, "signup_bonus", None, now),
            )
            db.commit()
        except sqlite3.IntegrityError:
            raise ValueError("email already registered")
    return get_user_by_id(uid)  # type: ignore


def authenticate(email: str, password: str) -> Optional[User]:
    email = email.strip().lower()
    with _conn() as db:
        r = db.execute("SELECT * FROM users WHERE email = ?", (email,)).fetchone()
    if not r:
        return None
    if not _verify_password(password, r["password_hash"]):
        return None
    return _row_user(r)


def get_user_by_id(uid: int) -> Optional[User]:
    with _conn() as db:
        r = db.execute("SELECT * FROM users WHERE id = ?", (uid,)).fetchone()
    return _row_user(r) if r else None


def create_session(user_id: int) -> str:
    token = secrets.token_urlsafe(32)
    now = time.time()
    exp = now + SESSION_DAYS * 86400
    with _conn() as db:
        db.execute(
            "INSERT INTO sessions (token, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)",
            (token, user_id, now, exp),
        )
        db.commit()
    return token


def destroy_session(token: str) -> None:
    if not token:
        return
    with _conn() as db:
        db.execute("DELETE FROM sessions WHERE token = ?", (token,))
        db.commit()


def user_from_session(token: Optional[str]) -> Optional[User]:
    if not token:
        return None
    now = time.time()
    with _conn() as db:
        r = db.execute(
            "SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id "
            "WHERE s.token = ? AND s.expires_at > ?",
            (token, now),
        ).fetchone()
    return _row_user(r) if r else None


def user_from_api_key(raw_key: Optional[str]) -> Optional[User]:
    if not raw_key:
        return None
    raw_key = raw_key.strip()
    if raw_key.lower().startswith("bearer "):
        raw_key = raw_key[7:].strip()
    h = _hash_api_key(raw_key)
    now = time.time()
    with _conn() as db:
        r = db.execute(
            "SELECT u.*, k.id AS key_id FROM api_keys k "
            "JOIN users u ON u.id = k.user_id "
            "WHERE k.key_hash = ? AND k.revoked = 0",
            (h,),
        ).fetchone()
        if not r:
            return None
        db.execute(
            "UPDATE api_keys SET last_used_at = ? WHERE id = ?",
            (now, r["key_id"]),
        )
        db.commit()
    return _row_user(r)


def create_api_key(user_id: int, name: str = "default") -> tuple[str, dict]:
    raw = "ct_" + secrets.token_urlsafe(32)
    h = _hash_api_key(raw)
    prefix = raw[:10]
    now = time.time()
    with _conn() as db:
        cur = db.execute(
            "INSERT INTO api_keys (user_id, name, key_hash, key_prefix, created_at) "
            "VALUES (?, ?, ?, ?, ?)",
            (user_id, (name or "default")[:64], h, prefix, now),
        )
        kid = cur.lastrowid
        db.commit()
    return raw, {
        "id": kid,
        "name": (name or "default")[:64],
        "prefix": prefix,
        "created_at": now,
        "key": raw,  # only returned once
    }


def list_api_keys(user_id: int) -> list[dict]:
    with _conn() as db:
        rows = db.execute(
            "SELECT id, name, key_prefix, created_at, last_used_at, revoked "
            "FROM api_keys WHERE user_id = ? ORDER BY created_at DESC",
            (user_id,),
        ).fetchall()
    return [
        {
            "id": r["id"],
            "name": r["name"],
            "prefix": r["key_prefix"],
            "created_at": r["created_at"],
            "last_used_at": r["last_used_at"],
            "revoked": bool(r["revoked"]),
        }
        for r in rows
    ]


def revoke_api_key(user_id: int, key_id: int) -> bool:
    with _conn() as db:
        cur = db.execute(
            "UPDATE api_keys SET revoked = 1 WHERE id = ? AND user_id = ?",
            (key_id, user_id),
        )
        db.commit()
        return cur.rowcount > 0


def adjust_credits(user_id: int, delta: int, reason: str, meta: str = "") -> int:
    """Atomically change balance. Raises ValueError if insufficient funds on debit."""
    with _conn() as db:
        r = db.execute(
            "SELECT credits FROM users WHERE id = ?", (user_id,)
        ).fetchone()
        if not r:
            raise ValueError("user not found")
        bal = int(r["credits"])
        new_bal = bal + delta
        if new_bal < 0:
            raise ValueError("insufficient credits")
        db.execute("UPDATE users SET credits = ? WHERE id = ?", (new_bal, user_id))
        db.execute(
            "INSERT INTO credit_ledger (user_id, delta, balance_after, reason, meta, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (user_id, delta, new_bal, reason, meta or None, time.time()),
        )
        db.commit()
        return new_bal


def add_credits_dummy(user_id: int, cents: int) -> int:
    if cents <= 0 or cents > 100_000:
        raise ValueError("invalid amount")
    return adjust_credits(user_id, cents, "dummy_topup", f"test_add_{cents}")


def charge_build(user_id: int) -> int:
    return adjust_credits(
        user_id, -BUILD_COST_CENTS, "paid_build", f"cost={BUILD_COST_CENTS}"
    )


def refund_build(user_id: int) -> int:
    return adjust_credits(
        user_id, BUILD_COST_CENTS, "build_refund", f"cost={BUILD_COST_CENTS}"
    )


def ledger(user_id: int, limit: int = 50) -> list[dict]:
    with _conn() as db:
        rows = db.execute(
            "SELECT delta, balance_after, reason, meta, created_at "
            "FROM credit_ledger WHERE user_id = ? ORDER BY id DESC LIMIT ?",
            (user_id, limit),
        ).fetchall()
    return [dict(r) for r in rows]


def _seed_test_accounts() -> None:
    """Idempotent demo users for local testing."""
    tests = [
        ("test@clawtank.app", "test1234", "Test User", 1000),
        ("demo@clawtank.app", "demo1234", "Demo User", 50),
    ]
    for email, pw, name, credits in tests:
        with _conn() as db:
            r = db.execute("SELECT id FROM users WHERE email = ?", (email,)).fetchone()
            if r:
                continue
        try:
            u = create_user(email, pw, name)
            # top up to desired test balance (signup already gave STARTING_CREDITS)
            extra = credits - STARTING_CREDITS
            if extra > 0:
                adjust_credits(u.id, extra, "test_seed", "bootstrap")
        except ValueError:
            pass


def get_or_create_google_user(email: str, google_sub: str, display_name: str = "") -> User:
    """Link or create a user from Google OAuth profile."""
    email = (email or "").strip().lower()
    if not email or not google_sub:
        raise ValueError("email and google_sub required")
    now = time.time()
    with _conn() as db:
        r = db.execute(
            "SELECT * FROM users WHERE google_sub = ? OR email = ?",
            (google_sub, email),
        ).fetchone()
        if r:
            if not r["google_sub"]:
                db.execute(
                    "UPDATE users SET google_sub = ? WHERE id = ?",
                    (google_sub, r["id"]),
                )
                db.commit()
            return _row_user(
                db.execute("SELECT * FROM users WHERE id = ?", (r["id"],)).fetchone()
            )
        cur = db.execute(
            "INSERT INTO users (email, password_hash, display_name, credits, created_at, google_sub) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (email, "", display_name or email.split("@")[0], STARTING_CREDITS, now, google_sub),
        )
        uid = cur.lastrowid
        db.execute(
            "INSERT INTO credit_ledger (user_id, delta, balance_after, reason, meta, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (uid, STARTING_CREDITS, STARTING_CREDITS, "signup_bonus", "google", now),
        )
        db.commit()
    return get_user_by_id(uid)  # type: ignore


# Init on import
init_db()
EOF

cat > x402_pay.py <<'EOF'
"""x402 payment protocol helpers (HTTP 402 + facilitator verify/settle).

Spec-oriented implementation aligned with https://docs.x402.org
Headers: PAYMENT-REQUIRED, PAYMENT-SIGNATURE (also accepts legacy X-PAYMENT).
"""
from __future__ import annotations

import base64
import json
import urllib.request
import urllib.error
from typing import Any, Optional

from config import (
    X402_ENABLED, X402_PAY_TO, X402_NETWORK, X402_FACILITATOR,
    X402_PRICE_ATOMIC, X402_ASSET_SEPOLIA, X402_ASSET_BASE, PUBLIC_URL,
)


def _asset_for_network(network: str) -> str:
    n = (network or "").lower()
    if "8453" in n or n == "base":
        return X402_ASSET_BASE
    return X402_ASSET_SEPOLIA


def _network_caip(network: str) -> str:
    n = (network or "base-sepolia").lower()
    if n in ("base", "eip155:8453"):
        return "eip155:8453"
    if n in ("base-sepolia", "eip155:84532"):
        return "eip155:84532"
    return network


def payment_requirements(resource: str, description: str = "clawtank paid build") -> dict:
    network = _network_caip(X402_NETWORK)
    asset = _asset_for_network(X402_NETWORK)
    return {
        "x402Version": 1,
        "error": "Payment required",
        "accepts": [
            {
                "scheme": "exact",
                "network": network if network.startswith("eip155:") else X402_NETWORK,
                "maxAmountRequired": str(X402_PRICE_ATOMIC),
                "resource": resource,
                "description": description,
                "mimeType": "application/json",
                "payTo": X402_PAY_TO,
                "maxTimeoutSeconds": 120,
                "asset": asset,
                "extra": {"name": "USDC", "version": "2"},
            }
        ],
    }


def encode_payment_required(req: dict) -> str:
    raw = json.dumps(req).encode("utf-8")
    return base64.b64encode(raw).decode("ascii")


def decode_payment_header(value: str) -> Optional[dict]:
    if not value:
        return None
    try:
        # may already be JSON
        if value.strip().startswith("{"):
            return json.loads(value)
        pad = "=" * (-len(value) % 4)
        return json.loads(base64.b64decode(value + pad).decode("utf-8"))
    except Exception:
        return None


def extract_payment_header(headers) -> Optional[str]:
    """Accept PAYMENT-SIGNATURE (v2) or X-PAYMENT (v1 legacy)."""
    for key in ("payment-signature", "PAYMENT-SIGNATURE", "x-payment", "X-PAYMENT"):
        v = headers.get(key)
        if v:
            return v
    return None


def _post_json(url: str, body: dict, timeout: float = 30.0) -> dict:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode("utf-8") or "{}")
        except Exception:
            return {"error": str(e), "status": e.code}
    except Exception as e:
        return {"error": str(e)}


def verify_and_settle(payment_header: str, requirements: dict) -> tuple[bool, dict]:
    """Verify + settle via the configured facilitator. Returns (ok, detail)."""
    if not X402_ENABLED:
        return False, {"error": "x402 disabled"}
    if not X402_PAY_TO or X402_PAY_TO.endswith("000000000000"):
        return False, {"error": "X402_PAY_TO not configured"}

    payment = decode_payment_header(payment_header)
    if not payment:
        return False, {"error": "invalid payment header"}

    accepts = requirements.get("accepts") or []
    req0 = accepts[0] if accepts else {}

    # Facilitator verify
    verify_body = {
        "x402Version": payment.get("x402Version", requirements.get("x402Version", 1)),
        "paymentHeader": payment if isinstance(payment, dict) else payment_header,
        "paymentRequirements": req0,
    }
    # Some facilitators expect the raw header string
    alt_body = {
        "x402Version": verify_body["x402Version"],
        "paymentPayload": payment,
        "paymentRequirements": req0,
    }

    base = X402_FACILITATOR.rstrip("/")
    v = _post_json(f"{base}/verify", verify_body)
    if v.get("error") and "paymentPayload" not in str(v):
        v = _post_json(f"{base}/verify", alt_body)

    is_valid = bool(
        v.get("isValid")
        or v.get("is_valid")
        or v.get("valid")
        or (v.get("success") is True)
    )
    if not is_valid and v.get("error"):
        # Dev/test fallback: if facilitator unreachable, reject
        return False, {"phase": "verify", "detail": v}

    s = _post_json(f"{base}/settle", verify_body)
    if s.get("error"):
        s = _post_json(f"{base}/settle", alt_body)

    settled = bool(
        s.get("success")
        or s.get("settled")
        or (s.get("transaction") or s.get("txHash") or s.get("tx_hash"))
    )
    if settled or is_valid:
        # Prefer settle success; some test facilitators only verify
        return True, {"verify": v, "settle": s}
    return False, {"phase": "settle", "detail": s}


def payment_required_response(resource: str, description: str = "clawtank paid build"):
    """Build JSON body + headers for HTTP 402."""
    req = payment_requirements(resource, description)
    header_val = encode_payment_required(req)
    headers = {
        "PAYMENT-REQUIRED": header_val,
        "X-PAYMENT-REQUIRED": header_val,  # compatibility
        "Content-Type": "application/json",
    }
    return req, headers
EOF



cat > workspace.py <<'EOF'
"""Per-browser-page isolated script workspaces.

Every studio page load gets a fresh workspace id and is seeded from
immutable DEFAULTS_DIR (hello-world). Concurrent tabs never share edits.
"""
from __future__ import annotations

import re
import shutil
import time
import uuid
from pathlib import Path, PurePosixPath

from config import DEFAULTS_DIR, WORKSPACES_DIR, DEFAULT_FILES, WORKSPACE_TTL

_WS_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")


def _valid_id(ws_id: str | None) -> str | None:
    if not ws_id or not _WS_RE.match(ws_id):
        return None
    return ws_id


def workspace_path(ws_id: str) -> Path:
    return (WORKSPACES_DIR / ws_id).resolve()


def ensure_defaults_present() -> None:
    """If defaults/ is empty, copy from scripts/ (first boot after setup)."""
    DEFAULTS_DIR.mkdir(parents=True, exist_ok=True)
    if any(DEFAULTS_DIR.rglob("*")):
        return
    scripts = Path(__file__).resolve().parent / "scripts"
    if not scripts.is_dir():
        return
    for p in scripts.rglob("*"):
        if p.is_file():
            rel = p.relative_to(scripts)
            dest = DEFAULTS_DIR / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, dest)


def seed_workspace(ws_id: str) -> Path:
    """Create workspace dir and copy immutable defaults into it."""
    ensure_defaults_present()
    root = workspace_path(ws_id)
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True, exist_ok=True)
    for p in DEFAULTS_DIR.rglob("*"):
        if p.is_file():
            rel = p.relative_to(DEFAULTS_DIR)
            dest = root / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, dest)
    # touch marker for TTL cleanup
    (root / ".created").write_text(str(time.time()))
    return root


def get_or_create(ws_id: str | None) -> tuple[str, Path]:
    """Return (id, path). Invalid/missing id → new seeded workspace."""
    ensure_defaults_present()
    wid = _valid_id(ws_id)
    if wid:
        root = workspace_path(wid)
        if root.is_dir() and any(root.rglob("*")):
            return wid, root
        return wid, seed_workspace(wid)
    wid = "w_" + uuid.uuid4().hex[:16]
    return wid, seed_workspace(wid)


def reset_workspace(ws_id: str | None) -> tuple[str, Path]:
    """Always re-seed (used when client asks for a clean slate)."""
    wid = _valid_id(ws_id) or ("w_" + uuid.uuid4().hex[:16])
    return wid, seed_workspace(wid)


def safe_path(ws_id: str, name: str) -> Path:
    root = workspace_path(ws_id).resolve()
    if not root.is_dir():
        raise FileNotFoundError("workspace missing")
    p = (root / name).resolve()
    try:
        p.relative_to(root)
    except ValueError:
        raise ValueError("invalid path")
    return p


def list_files(ws_id: str) -> list[dict]:
    root = workspace_path(ws_id)
    out = []
    if not root.is_dir():
        return out
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        if p.name.startswith("."):
            continue
        rel = str(p.relative_to(root))
        out.append({
            "name": rel,
            "size": p.stat().st_size,
            "is_default": rel in DEFAULT_FILES,
        })
    return out


def collect_scripts(ws_id: str) -> dict:
    root = workspace_path(ws_id)
    out = {}
    if not root.is_dir():
        return out
    for p in sorted(root.rglob("*")):
        if p.is_file() and not p.name.startswith("."):
            out[str(p.relative_to(root))] = p.read_text(errors="replace")
    return out


def is_default_name(name: str) -> bool:
    norm = str(PurePosixPath(name))
    if norm.startswith("./"):
        norm = norm[2:]
    return norm in DEFAULT_FILES


def cleanup_stale(ttl: int | None = None) -> int:
    ttl = WORKSPACE_TTL if ttl is None else ttl
    now = time.time()
    removed = 0
    if not WORKSPACES_DIR.is_dir():
        return 0
    for child in list(WORKSPACES_DIR.iterdir()):
        if not child.is_dir():
            continue
        marker = child / ".created"
        try:
            created = float(marker.read_text()) if marker.is_file() else child.stat().st_mtime
        except Exception:
            created = 0
        if now - created > ttl:
            try:
                shutil.rmtree(child)
                removed += 1
            except Exception:
                pass
    return removed


# ---------------------------------------------------------------------------
#  Shared projects (JSFiddle-style permanent snapshots)
# ---------------------------------------------------------------------------
from config import PROJECTS_DIR

_PROJ_RE = re.compile(r"^[A-Za-z0-9_-]{6,32}$")


def project_path(project_id: str) -> Path:
    return (PROJECTS_DIR / project_id).resolve()


def _valid_project_id(pid: str | None) -> str | None:
    if not pid or not _PROJ_RE.match(pid):
        return None
    return pid


def save_project_from_workspace(ws_id: str) -> str:
    """Snapshot a workspace into projects/<id>/ and return the id."""
    src = workspace_path(ws_id)
    if not src.is_dir():
        raise FileNotFoundError("workspace missing")
    PROJECTS_DIR.mkdir(parents=True, exist_ok=True)
    # Short, URL-friendly id (like jsfiddle)
    for _ in range(8):
        pid = uuid.uuid4().hex[:10]
        dest = project_path(pid)
        if not dest.exists():
            break
    else:
        pid = uuid.uuid4().hex
        dest = project_path(pid)
    dest.mkdir(parents=True, exist_ok=False)
    for p in src.rglob("*"):
        if not p.is_file() or p.name.startswith("."):
            continue
        rel = p.relative_to(src)
        out = dest / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, out)
    (dest / ".meta").write_text(
        f'{{"created": {time.time()}, "from_workspace": "{ws_id}"}}\n'
    )
    return pid


def project_exists(project_id: str) -> bool:
    pid = _valid_project_id(project_id)
    if not pid:
        return False
    root = project_path(pid)
    if not root.is_dir():
        return False
    return any(p.is_file() and not p.name.startswith(".") for p in root.rglob("*"))


def seed_workspace_from_project(project_id: str, ws_id: str | None = None) -> tuple[str, Path]:
    """Create a fresh workspace filled from a saved project snapshot."""
    pid = _valid_project_id(project_id)
    if not pid or not project_exists(pid):
        raise FileNotFoundError("project not found")
    src = project_path(pid)
    wid = _valid_id(ws_id) or ("w_" + uuid.uuid4().hex[:16])
    root = workspace_path(wid)
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True, exist_ok=True)
    for p in src.rglob("*"):
        if not p.is_file() or p.name.startswith("."):
            continue
        # APK is bound via build_ws, not shown as an editable source file
        if p.name.endswith(".apk"):
            continue
        rel = p.relative_to(src)
        out = root / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, out)
    (root / ".created").write_text(str(time.time()))
    (root / ".from_project").write_text(pid)
    return wid, root


def list_project_files(project_id: str) -> list[dict]:
    pid = _valid_project_id(project_id)
    if not pid:
        return []
    root = project_path(pid)
    out = []
    if not root.is_dir():
        return out
    for p in sorted(root.rglob("*")):
        if not p.is_file() or p.name.startswith("."):
            continue
        rel = str(p.relative_to(root))
        out.append({
            "name": rel,
            "size": p.stat().st_size,
            "is_default": rel in DEFAULT_FILES,
        })
    return out
EOF

cat > scrcpy_protocol.py <<'EOF'
import struct

def encode_touch(x, y, w, h, action):
    p = 0 if action == 1 else 0xFFFF
    b = bytearray(32)
    b[0] = 2; b[1] = action
    struct.pack_into(">Q", b, 2, 0)
    struct.pack_into(">i", b, 10, int(x))
    struct.pack_into(">i", b, 14, int(y))
    struct.pack_into(">H", b, 18, int(w))
    struct.pack_into(">H", b, 20, int(h))
    struct.pack_into(">H", b, 22, p)
    struct.pack_into(">I", b, 24, 1)
    struct.pack_into(">I", b, 28, 0 if action == 1 else 1)
    return bytes(b)

def encode_key(code, action):
    b = bytearray(14); b[0] = 0; b[1] = action
    struct.pack_into(">i", b, 2, int(code)); return bytes(b)

def encode_text(t):
    p = t.encode("utf-8")
    b = bytearray(5 + len(p)); b[0] = 1
    struct.pack_into(">I", b, 1, len(p)); b[5:] = p
    return bytes(b)

def find_sps(a):
    i, n = 0, len(a)
    while i < n - 3:
        if a[i:i+4] == b"\x00\x00\x00\x01": off = i + 4
        elif a[i:i+3] == b"\x00\x00\x01":   off = i + 3
        else: i += 1; continue
        if off >= n: break
        if (a[off] & 0x1F) == 7 and off + 4 <= n:
            return a[off+1], a[off+2], a[off+3]
        i = off
    return None
EOF

cat > scrcpy_session.py <<'EOF'
import asyncio, os, random, struct
from pathlib import Path
from scrcpy_protocol import find_sps

ADB        = "adb"
JAR_PATH   = Path("/tmp/scrcpy-server.jar")
SERVER_VER = os.getenv("SERVER_VER", "3.1")
JAR_URL    = (f"https://github.com/Genymobile/scrcpy/releases/download/"
              f"v{SERVER_VER}/scrcpy-server-v{SERVER_VER}")
MAX_SIZE   = os.getenv("MAX_SIZE", "540")
MAX_FPS    = os.getenv("MAX_FPS", "60")
BIT_RATE   = os.getenv("BIT_RATE", "8000000")


async def list_devices():
    p = await asyncio.create_subprocess_exec(
        ADB, "devices",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, _ = await p.communicate()
    serials = []
    for line in out.decode("utf-8", "ignore").splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            serials.append(parts[0])
    emus = [s for s in serials if s.startswith("emulator-")]
    rest = [s for s in serials if s not in emus]
    return emus + rest


class ScrcpySession:
    def __init__(self, device_id):
        self.device_id    = device_id
        self.scid         = random.randint(1, 0x7FFFFFFF)
        self.forward_port = random.randint(27183, 27399)
        self.proc = self.video_rd = self.video_wr = None
        self.control_wr   = None
        self.device_name  = device_id
        self.width        = 0
        self.height       = 0
        self.codec_string = "avc1.42E01E"
        self._clock       = asyncio.Lock()
        self._subscribers = set()
        self._reader_task = None
        self._running     = False
        self._cached_config   = None
        self._cached_keyframe = None

    def alive(self):
        return bool(self._running and self._reader_task
                    and not self._reader_task.done())

    async def _adb(self, *args, timeout=30):
        p = await asyncio.create_subprocess_exec(
            ADB, "-s", self.device_id, *args,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            out, err = await asyncio.wait_for(p.communicate(), timeout=timeout)
            return (p.returncode, out.decode("utf-8", "ignore"),
                    err.decode("utf-8", "ignore"))
        except asyncio.TimeoutError:
            p.kill(); return -1, "", "timeout"

    async def _setup(self):
        rc, out, _ = await self._adb("shell", "echo", "ok", timeout=8)
        if "ok" not in out: raise RuntimeError(f"{self.device_id} not responding")
        await self._adb("shell", "input", "keyevent", "KEYCODE_WAKEUP", timeout=5)
        await self._adb("shell", "wm", "dismiss-keyguard", timeout=5)
        await self._adb("shell", "pkill", "-f", "com.genymobile.scrcpy.Server", timeout=5)
        await asyncio.sleep(0.5)
        if not (JAR_PATH.exists() and JAR_PATH.stat().st_size > 10000):
            p = await asyncio.create_subprocess_exec(
                "curl", "-L", "-s", "-o", str(JAR_PATH), JAR_URL,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL)
            await p.wait()
        rc, _, err = await self._adb("push", str(JAR_PATH),
                                     "/data/local/tmp/scrcpy-server.jar")
        if rc != 0: raise RuntimeError(f"push failed: {err.strip()}")
        abstract = f"scrcpy_{self.scid:08x}"
        await self._adb("forward", "--remove", f"tcp:{self.forward_port}", timeout=3)
        rc, _, err = await self._adb(
            "forward", f"tcp:{self.forward_port}", f"localabstract:{abstract}")
        if rc != 0: raise RuntimeError(f"forward failed: {err.strip()}")
        args = [SERVER_VER, f"scid={self.scid:08x}", "log_level=info",
                f"max_size={MAX_SIZE}", f"max_fps={MAX_FPS}",
                f"video_bit_rate={BIT_RATE}", "tunnel_forward=true",
                "audio=false", "control=true", "cleanup=true"]
        cmd = ("CLASSPATH=/data/local/tmp/scrcpy-server.jar "
               "app_process / com.genymobile.scrcpy.Server " + " ".join(args))
        self.proc = await asyncio.create_subprocess_exec(
            ADB, "-s", self.device_id, "shell", cmd,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        asyncio.create_task(self._drain(self.proc.stderr))
        await asyncio.sleep(2.5)

    async def _drain(self, stream):
        try:
            while True:
                line = await stream.readline()
                if not line: break
        except BaseException: pass

    async def _connect(self):
        for _ in range(50):
            try:
                self.video_rd, self.video_wr = await asyncio.open_connection(
                    "127.0.0.1", self.forward_port); break
            except (ConnectionRefusedError, OSError):
                await asyncio.sleep(0.3)
        else: raise RuntimeError("video connect failed")
        for _ in range(50):
            try:
                _, self.control_wr = await asyncio.open_connection(
                    "127.0.0.1", self.forward_port); break
            except (ConnectionRefusedError, OSError):
                await asyncio.sleep(0.3)
        else: raise RuntimeError("control connect failed")

    @staticmethod
    async def _read_exact(r, n, timeout=None):
        async def _do():
            buf = bytearray()
            while len(buf) < n:
                chunk = await r.read(n - len(buf))
                if not chunk: raise EOFError(f"EOF {len(buf)}/{n}")
                buf.extend(chunk)
            return bytes(buf)
        if timeout is None: return await _do()
        return await asyncio.wait_for(_do(), timeout=timeout)

    async def _read_metadata(self):
        await self._read_exact(self.video_rd, 1, timeout=25)
        raw = await self._read_exact(self.video_rd, 64, timeout=25)
        self.device_name = (raw.rstrip(b"\x00").decode("utf-8", "ignore")
                            or self.device_id)
        meta = await self._read_exact(self.video_rd, 12, timeout=10)
        codec_id, w, h = struct.unpack(">III", meta)
        if w < 0: w = -w
        if h < 0: h = -h
        self.width, self.height = w, h

    async def _next_packet(self):
        header = await self._read_exact(self.video_rd, 12, timeout=None)
        pts_flags, size = struct.unpack(">QI", header)
        is_config = bool(pts_flags & (1 << 63))
        is_key    = bool(pts_flags & (1 << 62))
        if size == 0:
            return {"config": is_config, "key": is_key,
                    "payload": b"", "skip": True}
        payload = await self._read_exact(self.video_rd, size, timeout=None)
        return {"config": is_config, "key": is_key,
                "payload": payload, "skip": False}

    async def send_control(self, data):
        async with self._clock:
            if not self.control_wr: return
            try:
                self.control_wr.write(data)
                await self.control_wr.drain()
            except Exception: pass

    def subscribe(self):
        q = asyncio.Queue(maxsize=512)
        self._subscribers.add(q)
        if self._cached_config:
            try: q.put_nowait(self._cached_config)
            except Exception: pass
        if self._cached_keyframe:
            try: q.put_nowait(self._cached_keyframe)
            except Exception: pass
        return q

    def unsubscribe(self, q): self._subscribers.discard(q)

    async def _reader_loop(self):
        while self._running:
            try:
                pkt = await self._next_packet()
            except asyncio.CancelledError: break
            except Exception: break
            if pkt.get("skip"): continue
            if pkt["config"]:
                sps = find_sps(pkt["payload"])
                if sps:
                    p, c, l = sps
                    self.codec_string = f"avc1.{p:02X}{c:02X}{l:02X}"
            flags = 0
            if pkt["key"]:    flags |= 0x01
            if pkt["config"]: flags |= 0x02
            data = bytes([flags]) + pkt["payload"]
            if pkt["config"]: self._cached_config = data
            elif pkt["key"]:  self._cached_keyframe = data
            for q in list(self._subscribers):
                try: q.put_nowait(data)
                except asyncio.QueueFull:
                    try: q.get_nowait()
                    except Exception: pass
                    try: q.put_nowait(data)
                    except Exception: pass

    async def start(self):
        await self._setup()
        await self._connect()
        await self._read_metadata()
        self._running = True
        self._reader_task = asyncio.create_task(self._reader_loop())

    async def stop(self):
        if not self._running and self._reader_task is None:
            return
        self._running = False
        for q in list(self._subscribers):
            try: q.put_nowait(None)
            except Exception: pass
        self._subscribers.clear()
        if self._reader_task:
            self._reader_task.cancel()
            try:
                await asyncio.wait_for(self._reader_task, timeout=2)
            except BaseException:
                pass
            self._reader_task = None
        for w in (self.video_wr, self.control_wr):
            if w:
                try: w.close()
                except Exception: pass
        if self.proc:
            try: self.proc.kill()
            except Exception: pass
        try:
            await self._adb("forward", "--remove", f"tcp:{self.forward_port}")
        except BaseException:
            pass
EOF

cat > pool.py <<'EOF'
import asyncio, time, uuid
from config import MODE


class CapacityFull(Exception):
    pass


_workers: dict = {}
_sessions: dict = {}
_pending: dict = {}
_rlock = asyncio.Lock()


async def add_worker(worker_id, ws, devices):
    async with _rlock:
        _workers[worker_id] = {"ws": ws, "devices": list(devices),
                               "busy": set(), "since": time.time()}
    print(f"  worker online: {worker_id}  devices={devices}")
    await wake_queue()


async def remove_worker(worker_id):
    async with _rlock:
        _workers.pop(worker_id, None)
        dead = [sid for sid, s in _sessions.items()
                if getattr(s, "worker_id", None) == worker_id]
        for sid in dead: _sessions.pop(sid, None)
    print(f"  worker offline: {worker_id}")
    for sid in dead:
        fut = _pending.pop(sid, None)
        if fut and not fut.done():
            fut.set_exception(CapacityFull("worker gone"))


async def update_devices(worker_id, devices):
    changed = False
    async with _rlock:
        if worker_id in _workers:
            if set(_workers[worker_id]["devices"]) != set(devices):
                _workers[worker_id]["devices"] = list(devices)
                changed = True
    if changed: await wake_queue()


async def _remote_pick():
    for wid, info in _workers.items():
        for dev in info["devices"]:
            if dev not in info["busy"]:
                info["busy"].add(dev)
                return wid, dev
    return None


async def _remote_release(worker_id, device_id):
    async with _rlock:
        if worker_id in _workers:
            _workers[worker_id]["busy"].discard(device_id)


async def _remote_acquire():
    async with _rlock:
        pick = await _remote_pick()
        if not pick: raise CapacityFull()
        worker_id, device_id = pick
        info = _workers.get(worker_id)
        if not info: raise CapacityFull()
        control_ws = info["ws"]

    session_id = "s_" + uuid.uuid4().hex[:10]
    fut = asyncio.get_event_loop().create_future()
    _pending[session_id] = fut

    try:
        await control_ws.send_json({"type": "open_session",
                                    "session_id": session_id,
                                    "device_id": device_id})
    except Exception as e:
        _pending.pop(session_id, None)
        await _remote_release(worker_id, device_id)
        raise CapacityFull(f"worker unreachable: {e}")

    try:
        session = await asyncio.wait_for(fut, timeout=25)
        session.worker_id = worker_id
        session.device_id = device_id
        _sessions[session_id] = session
        return session
    except asyncio.TimeoutError:
        _pending.pop(session_id, None)
        await _remote_release(worker_id, device_id)
        raise CapacityFull("worker did not open session in time")


def resolve_pending(session_id, session):
    fut = _pending.pop(session_id, None)
    if fut and not fut.done(): fut.set_result(session)


def get_session(session_id): return _sessions.get(session_id)
def forget_session(session_id): return _sessions.pop(session_id, None)


async def _remote_release_session(session):
    wid = getattr(session, "worker_id", None)
    did = getattr(session, "device_id", None)
    sid = getattr(session, "session_id", None)
    if sid: forget_session(sid)
    if wid and did: await _remote_release(wid, did)
    await wake_queue()


_local_sessions: dict = {}
_local_busy: set = set()
_llock = asyncio.Lock()


async def _local_devices():
    try:
        from scrcpy_session import list_devices
        return await list_devices()
    except Exception:
        return []


async def _local_acquire():
    async with _llock:
        devices = await _local_devices()
        free = [d for d in devices if d not in _local_busy]
        if not free:
            raise CapacityFull(f"all {len(devices)} busy")
        picked = free[0]
        _local_busy.add(picked)
        existing = _local_sessions.get(picked)

    if existing is not None and existing.alive():
        return existing

    if existing is not None:
        try: await existing.stop()
        except BaseException: pass
        async with _llock: _local_sessions.pop(picked, None)

    from scrcpy_session import ScrcpySession
    sess = ScrcpySession(picked)
    try:
        await sess.start()
    except Exception:
        async with _llock: _local_busy.discard(picked)
        raise

    async with _llock: _local_sessions[picked] = sess
    return sess


async def _local_release(session):
    dev = getattr(session, "device_id", None)
    if dev:
        async with _llock: _local_busy.discard(dev)
    await wake_queue()


async def acquire():
    if MODE == "local": return await _local_acquire()
    return await _remote_acquire()


async def release(session):
    if MODE == "local": await _local_release(session)
    else: await _remote_release_session(session)


async def stats():
    if MODE == "local":
        pool = len(await _local_devices())
        inuse = len(_local_busy)
        return {"pool_size": pool, "inuse": inuse, "workers": [],
                "leases": {d: "local" for d in _local_busy}}
    async with _rlock:
        pool = sum(len(w["devices"]) for w in _workers.values())
        inuse = sum(len(w["busy"]) for w in _workers.values())
        return {
            "pool_size": pool, "inuse": inuse,
            "workers": [{"worker_id": wid,
                         "devices": list(w["devices"]),
                         "busy": list(w["busy"]),
                         "connected_at": w["since"]}
                        for wid, w in _workers.items()],
            "leases": {d: wid for wid, w in _workers.items()
                       for d in w["busy"]},
        }


async def wake_queue():
    from queue_manager import QUEUE
    await QUEUE.wake()
EOF

cat > queue_manager.py <<'EOF'
import asyncio
from dataclasses import dataclass
from typing import Optional
from pool import acquire, release, CapacityFull, stats as pool_stats


@dataclass
class Entry:
    client_id: str
    ws: object
    future: asyncio.Future


class QueueManager:
    def __init__(self):
        self._waiting: list[Entry] = []
        self._lock = asyncio.Lock()
        self._notify = asyncio.Event()
        self._worker_task: Optional[asyncio.Task] = None
        self._tick = 0

    async def start(self):
        if self._worker_task is None or self._worker_task.done():
            self._worker_task = asyncio.create_task(
                self._worker(), name="queue-worker")

    async def stop(self):
        if self._worker_task:
            self._worker_task.cancel()
            try: await self._worker_task
            except BaseException: pass
            self._worker_task = None

    async def enqueue(self, client_id: str, ws):
        async with self._lock:
            self._waiting = [e for e in self._waiting
                             if e.client_id != client_id]
            fut = asyncio.get_event_loop().create_future()
            self._waiting.append(Entry(client_id, ws, fut))
            pos = len(self._waiting)
        await self.start()
        await self._broadcast()
        self._notify.set()
        return pos, fut

    async def remove(self, client_id: str) -> int:
        async with self._lock:
            for e in self._waiting:
                if e.client_id == client_id and not e.future.done():
                    e.future.cancel()
            self._waiting = [e for e in self._waiting
                             if e.client_id != client_id]
            size = len(self._waiting)
        await self._broadcast()
        return size

    def size(self) -> int:
        return len(self._waiting)

    async def wake(self):
        await self.start()
        self._notify.set()

    async def _worker(self):
        while True:
            try:
                await self._notify.wait()
                self._notify.clear()
                while await self._try_serve_one(): pass
            except asyncio.CancelledError:
                return
            except Exception as e:
                print(f"  queue worker error: {type(e).__name__}: {e}")
                await asyncio.sleep(0.5)

    async def _try_serve_one(self) -> bool:
        async with self._lock:
            if not self._waiting: return False
            head = self._waiting[0]
            if head.future.cancelled():
                self._waiting.pop(0); return True

        try:
            session = await acquire()
        except CapacityFull:
            return False
        except Exception as e:
            async with self._lock:
                if self._waiting and self._waiting[0] is head:
                    self._waiting.pop(0)
            if not head.future.done(): head.future.set_exception(e)
            await self._broadcast()
            return True

        async with self._lock:
            if self._waiting and self._waiting[0] is head:
                self._waiting.pop(0); popped = True
            else:
                popped = False

        if not popped:
            try: await release(session)
            except BaseException: pass
            return True

        if not head.future.done(): head.future.set_result(session)
        await self._broadcast()
        return True

    async def _broadcast(self):
        async with self._lock:
            self._tick += 1
            tick = self._tick
            snapshot = [(e.client_id, e.ws, i + 1)
                        for i, e in enumerate(self._waiting)]
            size = len(snapshot)

        try:
            st = await pool_stats()
        except Exception:
            st = {"pool_size": 0, "inuse": 0}

        async def send(cid, ws, pos):
            try:
                await ws.send_json({
                    "type": "queued", "tick": tick, "position": pos,
                    "queue_size": size,
                    "pool_size": st.get("pool_size", 0),
                    "inuse": st.get("inuse", 0),
                })
            except Exception:
                pass

        if snapshot:
            await asyncio.gather(*(send(c, w, p) for c, w, p in snapshot),
                                 return_exceptions=True)


QUEUE = QueueManager()
EOF

cat > session_manager.py <<'EOF'
import asyncio, time


class RemoteSession:
    def __init__(self, session_id: str, meta: dict, control_ws):
        self.session_id   = session_id
        self.device_name  = meta.get("device_name") or meta.get("device_id", "?")
        self.width        = int(meta.get("width")  or 0)
        self.height       = int(meta.get("height") or 0)
        self.codec_string = meta.get("codec") or "avc1.42E01E"
        self._control_ws  = control_ws
        self._subscribers = set()
        self._running     = True
        self._cached_config   = None
        self._cached_keyframe = None
        self.created_at   = time.time()
        self.last_ping    = time.time()
        self.worker_id    = None
        self.device_id    = meta.get("device_id")

    def subscribe(self):
        q = asyncio.Queue(maxsize=512)
        self._subscribers.add(q)
        if self._cached_config:
            try: q.put_nowait(self._cached_config)
            except Exception: pass
        if self._cached_keyframe:
            try: q.put_nowait(self._cached_keyframe)
            except Exception: pass
        return q

    def unsubscribe(self, q): self._subscribers.discard(q)

    def fanout(self, data: bytes):
        if not data: return
        self.last_ping = time.time()
        flags = data[0]
        if flags & 0x02: self._cached_config = data
        elif flags & 0x01: self._cached_keyframe = data
        for q in list(self._subscribers):
            try: q.put_nowait(data)
            except asyncio.QueueFull:
                try: q.get_nowait()
                except Exception: pass
                try: q.put_nowait(data)
                except Exception: pass

    def ping(self): self.last_ping = time.time()

    def alive(self) -> bool:
        return self._running and (time.time() - self.last_ping) < 8.0

    async def send_control(self, data: bytes):
        try: await self._control_ws.send_bytes(data)
        except Exception: pass

    async def stop(self):
        if not self._running: return
        self._running = False
        for q in list(self._subscribers):
            try: q.put_nowait(None)
            except Exception: pass
        self._subscribers.clear()
        try: await self._control_ws.close()
        except BaseException: pass
EOF

# http_api.py — home / studio / api reference routes + hardened delete endpoint
cat > http_api.py <<'EOF'
import asyncio, os, time, uuid
from pathlib import Path, PurePosixPath
from fastapi import APIRouter, Request, HTTPException, Response, Form
from fastapi.responses import HTMLResponse, RedirectResponse, JSONResponse
from fastapi.templating import Jinja2Templates
from config import (SCRIPTS_DIR, TEMPLATES_DIR, MODE, SESSION_SECONDS,
                    DEFAULT_FILES, BUILD_IDLE, SESSION_COOKIE, BUILD_COST_CENTS,
                    PUBLIC_URL, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET,
                    GOOGLE_REDIRECT_URI, X402_ENABLED, X402_PAY_TO)
from queue_manager import QUEUE
from pool import stats as pool_stats, _workers, _rlock
import workspace as wsmod
import accounts
import x402_pay

router = APIRouter()
templates = Jinja2Templates(directory=str(TEMPLATES_DIR))


def _current_user(request: Request):
    tok = request.cookies.get(SESSION_COOKIE)
    return accounts.user_from_session(tok)


def _tpl(request: Request, name: str, **extra):
    ctx = {"request": request, "user": _current_user(request),
           "build_cost_cents": BUILD_COST_CENTS}
    ctx.update(extra)
    return templates.TemplateResponse(name, ctx)


def _set_session_cookie(response: Response, token: str):
    response.set_cookie(
        SESSION_COOKIE, token,
        httponly=True, samesite="lax", max_age=30 * 86400, path="/",
    )


def _clear_session_cookie(response: Response):
    response.delete_cookie(SESSION_COOKIE, path="/")


@router.get("/", response_class=HTMLResponse)
async def home(request: Request):
    return _tpl(request, "home.html", active="home")


@router.get("/studio", response_class=HTMLResponse)
async def studio(request: Request):
    return _tpl(request, "index.html", active="studio", project_id=None)


@router.get("/project/{project_id}", response_class=HTMLResponse)
async def project_page(project_id: str, request: Request):
    """Open studio preloaded from a shared project snapshot."""
    if not wsmod.project_exists(project_id):
        raise HTTPException(404, "project not found")
    return _tpl(request, "index.html", active="studio", project_id=project_id)


@router.get("/api/docs", response_class=HTMLResponse)
async def api_docs(request: Request):
    return _tpl(request, "api.html", active="api")


# ---------------------------------------------------------------------------
#  Auth pages + API
# ---------------------------------------------------------------------------

@router.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    if _current_user(request):
        return RedirectResponse("/account", status_code=303)
    return _tpl(request, "login.html", active="account", error=None)


@router.post("/login")
async def login_submit(request: Request,
                       email: str = Form(...),
                       password: str = Form(...)):
    user = accounts.authenticate(email, password)
    if not user:
        return _tpl(request, "login.html", active="account",
                    error="Invalid email or password")
    token = accounts.create_session(user.id)
    resp = RedirectResponse("/account", status_code=303)
    _set_session_cookie(resp, token)
    return resp


@router.get("/register", response_class=HTMLResponse)
async def register_page(request: Request):
    if _current_user(request):
        return RedirectResponse("/account", status_code=303)
    return _tpl(request, "register.html", active="account", error=None)


@router.post("/register")
async def register_submit(request: Request,
                          email: str = Form(...),
                          password: str = Form(...),
                          display_name: str = Form("")):
    try:
        user = accounts.create_user(email, password, display_name)
    except ValueError as e:
        return _tpl(request, "register.html", active="account", error=str(e))
    token = accounts.create_session(user.id)
    resp = RedirectResponse("/account", status_code=303)
    _set_session_cookie(resp, token)
    return resp


@router.post("/logout")
async def logout(request: Request):
    tok = request.cookies.get(SESSION_COOKIE)
    accounts.destroy_session(tok or "")
    resp = RedirectResponse("/", status_code=303)
    _clear_session_cookie(resp)
    return resp


def _google_redirect_uri(request: Request) -> str:
    if GOOGLE_REDIRECT_URI:
        return GOOGLE_REDIRECT_URI
    base = str(request.base_url).rstrip("/")
    return base + "/auth/google/callback"


@router.get("/auth/google")
async def auth_google_start(request: Request):
    if not GOOGLE_CLIENT_ID:
        raise HTTPException(
            501,
            "Google sign-in not configured. Set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET.",
        )
    import urllib.parse
    params = {
        "client_id": GOOGLE_CLIENT_ID,
        "redirect_uri": _google_redirect_uri(request),
        "response_type": "code",
        "scope": "openid email profile",
        "access_type": "online",
        "prompt": "select_account",
    }
    url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode(params)
    return RedirectResponse(url, status_code=302)


@router.get("/auth/google/callback")
async def auth_google_callback(request: Request, code: str = "", error: str = ""):
    if error:
        return _tpl(request, "login.html", active="account",
                    error=f"Google auth error: {error}")
    if not code or not GOOGLE_CLIENT_ID or not GOOGLE_CLIENT_SECRET:
        return _tpl(request, "login.html", active="account",
                    error="Google sign-in failed (missing code or config)")
    import urllib.parse, urllib.request, json as _json
    token_body = urllib.parse.urlencode({
        "code": code,
        "client_id": GOOGLE_CLIENT_ID,
        "client_secret": GOOGLE_CLIENT_SECRET,
        "redirect_uri": _google_redirect_uri(request),
        "grant_type": "authorization_code",
    }).encode()
    try:
        req = urllib.request.Request(
            "https://oauth2.googleapis.com/token",
            data=token_body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            tok = _json.loads(resp.read().decode())
        access = tok.get("access_token")
        if not access:
            raise RuntimeError("no access_token")
        req2 = urllib.request.Request(
            "https://www.googleapis.com/oauth2/v2/userinfo",
            headers={"Authorization": f"Bearer {access}"},
        )
        with urllib.request.urlopen(req2, timeout=15) as resp:
            profile = _json.loads(resp.read().decode())
        email = profile.get("email") or ""
        sub = profile.get("id") or profile.get("sub") or ""
        name = profile.get("name") or profile.get("given_name") or ""
        if not email:
            raise RuntimeError("Google account has no email")
        user = accounts.get_or_create_google_user(email, str(sub), name)
        session = accounts.create_session(user.id)
        resp = RedirectResponse("/account", status_code=303)
        _set_session_cookie(resp, session)
        return resp
    except Exception as e:
        return _tpl(request, "login.html", active="account",
                    error=f"Google sign-in failed: {e}")


@router.get("/account", response_class=HTMLResponse)
async def account_page(request: Request):
    user = _current_user(request)
    if not user:
        return RedirectResponse("/login", status_code=303)
    keys = accounts.list_api_keys(user.id)
    hist = accounts.ledger(user.id, 30)
    return _tpl(request, "account.html", active="account",
                keys=keys, ledger=hist, flash=None)


@router.get("/api/me")
async def api_me(request: Request):
    user = _current_user(request)
    if not user:
        raise HTTPException(401, "not logged in")
    return user.public()


@router.post("/api/credits/dummy-topup")
async def dummy_topup(request: Request):
    """Test-only: add credits without Stripe."""
    user = _current_user(request)
    if not user:
        raise HTTPException(401, "login required")
    try:
        body = await request.json()
    except Exception:
        body = {}
    cents = int(body.get("cents", 500))  # default $5.00
    try:
        bal = accounts.add_credits_dummy(user.id, cents)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"ok": True, "credits": bal, "added": cents}


@router.post("/api/credits/charge")
async def credits_charge(request: Request):
    """Charge credits upfront for a studio Pay Build (non-refundable)."""
    user = _current_user(request)
    if not user:
        raise HTTPException(401, "login required")
    try:
        bal = accounts.charge_build(user.id)
    except ValueError as e:
        raise HTTPException(402, str(e))
    return {
        "ok": True,
        "credits": bal,
        "charged": BUILD_COST_CENTS,
        "refundable": False,
    }


@router.post("/api/credits/refund")
async def credits_refund(request: Request):
    user = _current_user(request)
    if not user:
        raise HTTPException(401, "login required")
    bal = accounts.refund_build(user.id)
    return {"ok": True, "credits": bal, "refunded": BUILD_COST_CENTS}


@router.post("/api/keys")
async def create_key(request: Request):
    user = _current_user(request)
    if not user:
        raise HTTPException(401, "login required")
    try:
        body = await request.json()
    except Exception:
        body = {}
    name = (body.get("name") or "default")[:64]
    raw, meta = accounts.create_api_key(user.id, name)
    return {"ok": True, "key": raw, **{k: meta[k] for k in meta if k != "key"}}


@router.get("/api/keys")
async def get_keys(request: Request):
    user = _current_user(request)
    if not user:
        raise HTTPException(401, "login required")
    return {"keys": accounts.list_api_keys(user.id)}


@router.delete("/api/keys/{key_id}")
async def delete_key(key_id: int, request: Request):
    user = _current_user(request)
    if not user:
        raise HTTPException(401, "login required")
    ok = accounts.revoke_api_key(user.id, key_id)
    if not ok:
        raise HTTPException(404, "key not found")
    return {"ok": True}


@router.get("/api/health")
async def health():
    st = await pool_stats()
    return {"ok": True, "mode": MODE,
            "queue_size": QUEUE.size(),
            "session_seconds": SESSION_SECONDS, **st}


@router.get("/api/debug")
async def debug():
    st = await pool_stats()
    return {"mode": MODE, "env_MODE": os.getenv("MODE"),
            "queue_size": QUEUE.size(),
            "session_seconds": SESSION_SECONDS,
            "scripts_exists": SCRIPTS_DIR.exists(),
            "default_files": sorted(DEFAULT_FILES),
            "pool": st}


def _ws_id(request: Request) -> str:
    """Workspace id from header or query. Creates+seeds if missing."""
    raw = request.headers.get("x-workspace-id") or request.query_params.get("ws")
    wid, _ = wsmod.get_or_create(raw)
    return wid


@router.post("/api/workspace")
async def create_workspace(request: Request):
    """Create a workspace.

    - Default: seed from immutable defaults (hello-world).
    - ?project=<id> or body {"project_id"}: seed from a shared project.
    """
    try:
        wsmod.cleanup_stale()
    except Exception:
        pass
    project_id = request.query_params.get("project")
    if not project_id:
        try:
            body = await request.json()
            if isinstance(body, dict):
                project_id = body.get("project_id")
        except Exception:
            project_id = None
    if project_id:
        try:
            wid, _ = wsmod.seed_workspace_from_project(project_id)
        except FileNotFoundError:
            raise HTTPException(404, "project not found")
        has_apk = False
        try:
            import build_ws
            has_apk = bool(build_ws.attach_project_apk_to_workspace(project_id, wid))
        except Exception:
            pass
        return {"workspace_id": wid, "project_id": project_id,
                "files": wsmod.list_files(wid), "has_apk": has_apk}
    wid, _ = wsmod.reset_workspace(None)
    return {"workspace_id": wid, "files": wsmod.list_files(wid)}


@router.post("/api/workspace/reset")
async def reset_workspace(request: Request):
    """Re-seed an existing (or new) workspace from defaults."""
    raw = request.headers.get("x-workspace-id") or request.query_params.get("ws")
    wid, _ = wsmod.reset_workspace(raw)
    return {"workspace_id": wid, "files": wsmod.list_files(wid)}


@router.post("/api/project")
async def save_project(request: Request):
    """Snapshot the caller's workspace into a shareable /project/<id> link."""
    raw = request.headers.get("x-workspace-id") or request.query_params.get("ws")
    wid, path = wsmod.get_or_create(raw)
    if not any(p.is_file() and not p.name.startswith(".") for p in path.rglob("*")):
        raise HTTPException(400, "workspace is empty")
    try:
        pid = wsmod.save_project_from_workspace(wid)
    except FileNotFoundError:
        raise HTTPException(400, "workspace missing")
    except Exception as e:
        raise HTTPException(500, f"save failed: {e}")
    # Bundle last successful APK so recipients can download it without rebuilding
    has_apk = False
    try:
        import build_ws
        item = build_ws.get_apk_for_workspace(wid)
        if item and item.get("data"):
            apk_path = wsmod.project_path(pid) / "app-debug.apk"
            apk_path.write_bytes(item["data"])
            has_apk = True
    except Exception:
        pass
    return {
        "project_id": pid,
        "url": f"/project/{pid}",
        "share_url": f"/project/{pid}",
        "has_apk": has_apk,
    }


@router.get("/api/project/{project_id}")
async def get_project(project_id: str):
    if not wsmod.project_exists(project_id):
        raise HTTPException(404, "project not found")
    return {
        "project_id": project_id,
        "url": f"/project/{project_id}",
        "files": wsmod.list_project_files(project_id),
    }


@router.get("/api/download/project")
async def download_project(request: Request):
    """Zip the current workspace (studio sources) for download."""
    import io, zipfile
    from fastapi.responses import StreamingResponse
    wid = _ws_id(request)
    root = wsmod.workspace_path(wid)
    if not root.is_dir():
        raise HTTPException(404, "workspace not found")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(root.rglob("*")):
            if not path.is_file() or path.name.startswith("."):
                continue
            zf.write(path, arcname=str(path.relative_to(root)))
    buf.seek(0)
    headers = {
        "Content-Disposition": f'attachment; filename="clawtank-{wid[:10]}.zip"'
    }
    return StreamingResponse(buf, media_type="application/zip", headers=headers)


@router.get("/api/download/apk")
async def download_apk(request: Request):
    """Download the last successful debug APK for this workspace."""
    from fastapi.responses import Response
    import build_ws
    wid = _ws_id(request)
    item = build_ws.get_apk_for_workspace(wid)
    if not item:
        raise HTTPException(
            404,
            "no APK yet — run BUILD & RUN successfully first",
        )
    data = item["data"]
    name = item.get("filename") or "app-debug.apk"
    return Response(
        content=data,
        media_type="application/vnd.android.package-archive",
        headers={
            "Content-Disposition": f'attachment; filename="{name}"',
            "Content-Length": str(len(data)),
        },
    )


@router.get("/api/download/apk/status")
async def apk_status(request: Request):
    import build_ws
    wid = _ws_id(request)
    item = build_ws.get_apk_for_workspace(wid)
    if not item:
        return {"ready": False, "workspace_id": wid}
    return {
        "ready": True,
        "workspace_id": wid,
        "size": len(item["data"]),
        "filename": item.get("filename") or "app-debug.apk",
    }


@router.get("/api/files")
async def files(request: Request):
    wid = _ws_id(request)
    return {"workspace_id": wid, "files": wsmod.list_files(wid)}


@router.get("/api/files/{name:path}")
async def read_file(name: str, request: Request):
    wid = _ws_id(request)
    try:
        p = wsmod.safe_path(wid, name)
    except (ValueError, FileNotFoundError):
        raise HTTPException(400, "invalid path")
    if not p.is_file():
        raise HTTPException(404, "not found")
    return {"name": name, "content": p.read_text(errors="replace"),
            "workspace_id": wid}


@router.put("/api/files/{name:path}")
async def write_file(name: str, body: dict, request: Request):
    wid = _ws_id(request)
    try:
        p = wsmod.safe_path(wid, name)
    except (ValueError, FileNotFoundError):
        raise HTTPException(400, "invalid path")
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(body.get("content", ""))
    return {"ok": True, "workspace_id": wid}


@router.delete("/api/files/{name:path}")
async def delete_file(name: str, request: Request):
    if wsmod.is_default_name(name):
        raise HTTPException(403, "cannot delete default file")
    wid = _ws_id(request)
    try:
        p = wsmod.safe_path(wid, name)
    except (ValueError, FileNotFoundError):
        raise HTTPException(400, "invalid path")
    try:
        rel = str(p.relative_to(wsmod.workspace_path(wid)))
    except ValueError:
        raise HTTPException(400, "invalid path")
    if rel in DEFAULT_FILES:
        raise HTTPException(403, "cannot delete default file")
    if not p.is_file():
        raise HTTPException(404, "not found")
    p.unlink()
    return {"ok": True, "workspace_id": wid}


# ---------------------------------------------------------------------------
#  POST /v1/build  — fire-and-forget + scripted interactions
# ---------------------------------------------------------------------------
async def _pick_free_device():
    """Pick a free device from any connected worker and mark it busy."""
    async with _rlock:
        for wid, info in _workers.items():
            for dev in info["devices"]:
                if dev not in info["busy"]:
                    info["busy"].add(dev)
                    return wid, dev, info["ws"]
    return None, None, None


async def _release_device(worker_id, device_id):
    async with _rlock:
        if worker_id in _workers:
            _workers[worker_id]["busy"].discard(device_id)


@router.get("/api/default-files")
async def default_files():
    """List hard-coded default scripts that cannot be deleted via the UI/API."""
    from config import DEFAULTS_DIR
    out = []
    for name in sorted(DEFAULT_FILES):
        p = DEFAULTS_DIR / name
        item = {"name": name, "deletable": False}
        if p.is_file():
            item["size"] = p.stat().st_size
            item["exists"] = True
        else:
            item["exists"] = False
        out.append(item)
    return {"default_files": out, "names": sorted(DEFAULT_FILES)}


@router.post("/v1/build")
async def v1_build(body: dict):
    """
    PUBLIC (free) cloud Android build API — uses the shared emulator pool.

    Body:
      files         (required)  { "MainActivity.kt": "...", "colors.xml": "...", ... }
      run           (optional)  bool, default true — install & launch on emulator
      script        (optional)  list of timed actions
      logcat_lines  (optional)  int 1–1000, default 200

    For paid / credit-backed builds use POST /v1/private/build with an API key.
    """
    return await _run_v1_build(body, paid=False, user=None)


@router.post("/v1/private/build")
async def v1_private_build(request: Request, body: dict = None):
    """
    PRIVATE (paid) cloud Android build API.

    Pay with either:
      1) Account credits — Authorization: Bearer ct_... (API key)
      2) x402 USDC — retry after 402 with PAYMENT-SIGNATURE / X-PAYMENT

    Charge is upfront and non-refundable. Same body as POST /v1/build.
    """
    if body is None:
        try:
            body = await request.json()
        except Exception:
            body = {}

    resource = str(request.url)
    pay_hdr = x402_pay.extract_payment_header(request.headers)
    auth = request.headers.get("authorization") or request.headers.get("x-api-key")
    user = accounts.user_from_api_key(auth)

    paid_via = None
    if user:
        if user.credits < BUILD_COST_CENTS:
            # Fall through to x402 if enabled
            user = None
        else:
            try:
                accounts.charge_build(user.id)
                paid_via = "credits"
            except ValueError:
                user = None

    if paid_via is None and X402_ENABLED:
        if not pay_hdr:
            req, hdrs = x402_pay.payment_required_response(
                resource,
                description="clawtank private build ($0.05 USDC or account credits)",
            )
            return JSONResponse(status_code=402, content=req, headers=hdrs)
        ok, detail = x402_pay.verify_and_settle(
            pay_hdr,
            x402_pay.payment_requirements(resource),
        )
        if not ok:
            req, hdrs = x402_pay.payment_required_response(resource, "payment verification failed")
            req["error"] = "Payment verification failed"
            req["detail"] = detail
            return JSONResponse(status_code=402, content=req, headers=hdrs)
        paid_via = "x402"
    elif paid_via is None:
        raise HTTPException(
            401,
            "valid API key required, or enable x402 (X402_ENABLED + X402_PAY_TO)",
        )

    result = await _run_v1_build(body, paid=True, user=user)
    if isinstance(result, dict):
        result["paid_via"] = paid_via
        result["credits_refundable"] = False
        if paid_via == "credits" and user:
            u2 = accounts.get_user_by_id(user.id)
            result["credits_charged"] = BUILD_COST_CENTS
            result["credits_remaining"] = u2.credits if u2 else None
        if paid_via == "x402":
            result["credits_charged"] = 0
            result["x402"] = True
    return result


@router.post("/api/pay/x402/challenge")
async def x402_challenge(request: Request):
    """Return x402 payment requirements for a studio Pay Build (USDC)."""
    resource = str(request.base_url).rstrip("/") + "/api/pay/x402/settle"
    req, hdrs = x402_pay.payment_required_response(
        resource, "clawtank studio pay build ($0.05 USDC)",
    )
    return JSONResponse(status_code=402, content=req, headers=hdrs)


@router.post("/api/pay/x402/settle")
async def x402_settle_and_credit(request: Request):
    """Verify x402 payment and credit the logged-in user's balance ($0.05)."""
    user = _current_user(request)
    if not user:
        raise HTTPException(401, "login required to deposit x402 payment into credits")
    pay_hdr = x402_pay.extract_payment_header(request.headers)
    if not pay_hdr:
        resource = str(request.url)
        req, hdrs = x402_pay.payment_required_response(resource)
        return JSONResponse(status_code=402, content=req, headers=hdrs)
    ok, detail = x402_pay.verify_and_settle(
        pay_hdr, x402_pay.payment_requirements(str(request.url)),
    )
    if not ok:
        raise HTTPException(402, f"x402 payment failed: {detail}")
    # Credit user for one paid build (5 cents)
    bal = accounts.adjust_credits(user.id, BUILD_COST_CENTS, "x402_deposit", "usdc")
    return {"ok": True, "credits": bal, "added": BUILD_COST_CENTS, "x402": detail}


async def _run_v1_build(body: dict, paid: bool = False, user=None):
    if MODE != "remote":
        raise HTTPException(501, "POST /v1/build requires MODE=remote and a connected worker")

    files = body.get("files")
    if not isinstance(files, dict) or not files:
        raise HTTPException(400, "files required (object mapping filename → source)")

    run = body.get("run", True)
    script = body.get("script") or []
    try:
        logcat_lines = int(body.get("logcat_lines", 200))
    except (TypeError, ValueError):
        logcat_lines = 200
    logcat_lines = max(1, min(1000, logcat_lines))

    import build_ws
    control = build_ws._any_worker_ws()
    if not control:
        raise HTTPException(503, "no worker connected")

    # Grab any free device so loot (screenshots + logcat) can run.
    worker_id, device_id, control = await _pick_free_device()
    if not device_id:
        raise HTTPException(503, "no free emulator available")
    picked = True

    build_id = "b_" + uuid.uuid4().hex[:10]
    build_ws.register_build(build_id)
    t0 = time.time()

    try:
        await control.send_json({
            "type": "build",
            "build_id": build_id,
            "files": files,
            "device_id": device_id,
            "script": script if script else None,
            "run": bool(run),
            "logcat_lines": logcat_lines,
        })
    except Exception as e:
        build_ws.drop_build(build_id)
        if picked and worker_id:
            await _release_device(worker_id, device_id)
        raise HTTPException(502, f"cannot start build: {e}")

    logs = []
    code = -1
    q = build_ws._builds.get(build_id)
    try:
        while True:
            try:
                kind, payload = await asyncio.wait_for(q.get(), timeout=int(BUILD_IDLE) if BUILD_IDLE else 180)
            except asyncio.TimeoutError:
                logs.append("[clawtank] build stalled\n")
                code = -1
                break
            if kind == "log":
                logs.append(payload if payload.endswith("\n") else payload + "\n")
            elif kind == "done":
                code = int(payload)
                break
    except Exception as e:
        logs.append(f"[clawtank] wait error: {e}\n")
        code = -1

    screenshots = []
    loot_logs = []
    steps = []
    if code == 0 and run:
        loot_q = build_ws._loot.get(build_id)
        if loot_q:
            try:
                while True:
                    item = await asyncio.wait_for(loot_q.get(), timeout=90)
                    if item is None:
                        break
                    if item.get("kind") == "screenshot":
                        screenshots.append(item.get("data", ""))
                        steps.append({"at": item.get("at"), "action": "screenshot",
                                      "idx": item.get("idx")})
                    elif item.get("kind") == "log":
                        loot_logs.append(item.get("line", ""))
                    elif item.get("kind") == "logcat":
                        # Full logcat blob from worker (preferred)
                        blob = item.get("text") or ""
                        if blob:
                            loot_logs = blob.splitlines()
                    elif item.get("kind") == "step":
                        steps.append(item)
            except asyncio.TimeoutError:
                pass
            except Exception:
                pass

    build_ws.drop_build(build_id)
    if picked and worker_id and device_id:
        await _release_device(worker_id, device_id)

    build_ms = int((time.time() - t0) * 1000)
    build_log = "".join(logs)
    logcat_text = "\n".join(loot_logs) if loot_logs else ""

    if code != 0:
        return {
            "status": "error",
            "message": "build failed",
            "code": code,
            "build_ms": build_ms,
            "device": device_id,
            "build_log": build_log,
            "logcat": logcat_text or build_log,
            "screenshots": [],
            "steps": steps,
        }

    return {
        "status": "ok",
        "tier": "private" if paid else "public",
        "device": device_id or "auto",
        "platform": "android-34",
        "build_ms": build_ms,
        "screenshots": screenshots,
        "build_log": build_log,
        "logcat": logcat_text,
        "logcat_lines": logcat_lines,
        "steps": steps,
        "stream": None,
    }
EOF

cat > build_runner.py <<'EOF'
from pathlib import Path
from config import SCRIPTS_DIR
import workspace as wsmod

HERE = Path(__file__).resolve().parent


def collect_scripts(workspace_id: str | None = None) -> dict:
    """Collect sources for a build.

    Prefer the per-page workspace when provided; fall back to the
    shared scripts/ tree (legacy / API callers that POST files inline).
    """
    if workspace_id:
        try:
            return wsmod.collect_scripts(workspace_id)
        except Exception:
            pass
    out = {}
    for p in sorted(SCRIPTS_DIR.rglob("*")):
        if p.is_file():
            out[str(p.relative_to(SCRIPTS_DIR))] = p.read_text(errors="replace")
    return out
EOF

cat > build_ws.py <<'EOF'
import asyncio, json, uuid
from fastapi import APIRouter, WebSocket
from config import MODE
from build_runner import collect_scripts
from pool import _workers

router = APIRouter()
_builds: dict = {}
_loot:   dict = {}


def _any_worker_ws():
    for info in _workers.values():
        return info["ws"]
    return None


def register_build(build_id):
    _builds[build_id] = asyncio.Queue()
    _loot[build_id]   = asyncio.Queue()


def drop_build(build_id):
    _builds.pop(build_id, None)
    _loot.pop(build_id, None)


def push_build_log(build_id, line):
    q = _builds.get(build_id)
    if q:
        try: q.put_nowait(("log", line))
        except Exception: pass


def push_screenshot(build_id, idx, data):
    q = _loot.get(build_id)
    if q:
        try: q.put_nowait({"kind": "screenshot", "idx": idx, "data": data})
        except Exception: pass


def push_app_log(build_id, line):
    q = _loot.get(build_id)
    if q:
        try: q.put_nowait({"kind": "log", "line": line})
        except Exception: pass


def push_logcat_blob(build_id, text):
    q = _loot.get(build_id)
    if q:
        try: q.put_nowait({"kind": "logcat", "text": text or ""})
        except Exception: pass


def finish_build(build_id, code):
    q = _builds.get(build_id)
    if q:
        try: q.put_nowait(("done", code))
        except Exception: pass


def finish_loot(build_id):
    q = _loot.get(build_id)
    if q:
        try: q.put_nowait(None)
        except Exception: pass


# Last successful APK bytes, keyed by build_id and workspace_id
_apks: dict = {}
_ws_apks: dict = {}


def push_apk(build_id, data_b64, workspace_id=None, filename="app-debug.apk"):
    import base64
    try:
        raw = base64.b64decode(data_b64 or "")
    except Exception:
        return
    if not raw or len(raw) < 32:
        return
    store_apk_bytes(raw, build_id=build_id, workspace_id=workspace_id,
                    filename=filename or "app-debug.apk")


def store_apk_bytes(raw: bytes, build_id=None, workspace_id=None,
                    filename="app-debug.apk"):
    """Keep APK in memory and optionally on disk under the workspace."""
    item = {"data": raw, "filename": filename or "app-debug.apk"}
    if build_id:
        _apks[build_id] = item
    if workspace_id:
        _ws_apks[workspace_id] = item
        try:
            import workspace as wsmod
            root = wsmod.workspace_path(workspace_id)
            if root.is_dir():
                art = root / ".artifacts"
                art.mkdir(parents=True, exist_ok=True)
                (art / (filename or "app-debug.apk")).write_bytes(raw)
        except Exception:
            pass


def get_apk_for_workspace(workspace_id):
    item = _ws_apks.get(workspace_id)
    if item:
        return item
    # Fall back to on-disk artifact (e.g. after coordinator restart)
    try:
        import workspace as wsmod
        root = wsmod.workspace_path(workspace_id)
        for name in ("app-debug.apk",):
            p = root / ".artifacts" / name
            if p.is_file() and p.stat().st_size > 32:
                item = {"data": p.read_bytes(), "filename": name}
                _ws_apks[workspace_id] = item
                return item
    except Exception:
        pass
    return None


def get_apk_for_build(build_id):
    return _apks.get(build_id)


def attach_project_apk_to_workspace(project_id, workspace_id):
    """If a shared project has a saved APK, bind it to the new workspace."""
    try:
        import workspace as wsmod
        apk = wsmod.project_path(project_id) / "app-debug.apk"
        if apk.is_file() and apk.stat().st_size > 32:
            store_apk_bytes(apk.read_bytes(), workspace_id=workspace_id,
                            filename="app-debug.apk")
            return True
    except Exception:
        pass
    return False


@router.websocket("/ws/build")
async def ws_build(ws: WebSocket):
    await ws.accept()
    if MODE != "remote":
        await ws.send_text("[clawtank] local builds run via /ws/stream\n")
        await ws.send_text(json.dumps({"done": True, "code": 1}) + "\n")
        try: await ws.close()
        except Exception: pass
        return

    control = _any_worker_ws()
    if not control:
        await ws.send_text("[clawtank] no worker connected\n")
        await ws.send_text(json.dumps({"done": True, "code": 1}) + "\n")
        try: await ws.close()
        except Exception: pass
        return

    files = collect_scripts()
    build_id = "b_" + uuid.uuid4().hex[:10]
    register_build(build_id)

    try:
        await control.send_json({"type": "build", "build_id": build_id,
                                 "files": files, "device_id": None})
    except Exception as e:
        drop_build(build_id)
        await ws.send_text(f"[clawtank] cannot start build: {e}\n")
        await ws.send_text(json.dumps({"done": True, "code": 1}) + "\n")
        try: await ws.close()
        except Exception: pass
        return

    code = -1
    try:
        q = _builds[build_id]
        while True:
            try:
                kind, payload = await asyncio.wait_for(q.get(), timeout=120)
            except asyncio.TimeoutError:
                await ws.send_text("[clawtank] build stalled\n")
                code = -1; break
            if kind == "log":
                try:
                    await ws.send_text(payload if payload.endswith("\n")
                                       else payload + "\n")
                except Exception: break
            elif kind == "done":
                code = int(payload); break
        try: await ws.send_text(json.dumps({"done": True, "code": code}) + "\n")
        except Exception: pass
    finally:
        loot_q = _loot.get(build_id)
        if loot_q:
            try:
                while True:
                    item = await asyncio.wait_for(loot_q.get(), timeout=15)
                    if item is None: break
                    if item["kind"] == "screenshot":
                        await ws.send_json({"type": "loot_screenshot",
                                            "idx": item["idx"],
                                            "data": item["data"]})
                    elif item["kind"] == "log":
                        await ws.send_json({"type": "loot_log",
                                            "line": item["line"]})
            except Exception:
                pass
        drop_build(build_id)
        try: await ws.close()
        except Exception: pass
EOF

cat > stream_ws.py <<'EOF'
import asyncio, json, secrets, time
from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from config import MODE, SESSION_SECONDS, BUILD_IDLE
from queue_manager import QUEUE
from pool import acquire, release, CapacityFull
from scrcpy_protocol import encode_touch, encode_key, encode_text
from build_runner import collect_scripts

router = APIRouter()


async def _acquire_or_queue(ws, client_id):
    try:
        return await acquire()
    except CapacityFull:
        pass
    except asyncio.CancelledError:
        raise
    except Exception as e:
        raise RuntimeError(str(e))

    pos, fut = await QUEUE.enqueue(client_id, ws)

    try:
        import pool as _pool
        st = await _pool.stats()
        await ws.send_json({
            "type": "queued", "tick": 0, "position": pos,
            "queue_size": QUEUE.size(),
            "pool_size": st.get("pool_size", 0),
            "inuse": st.get("inuse", 0),
        })
    except Exception: pass

    try:
        session = await asyncio.wait_for(fut, timeout=1800)
        return session
    except asyncio.TimeoutError:
        await QUEUE.remove(client_id)
        raise RuntimeError("queue timed out")
    except asyncio.CancelledError:
        await QUEUE.remove(client_id)
        raise
    except Exception as e:
        await QUEUE.remove(client_id)
        raise RuntimeError(str(e))


async def _run_build(ws, session, workspace_id=None):
    files = collect_scripts(workspace_id)
    if not files:
        await ws.send_text("[clawtank] no files to build\n")
        return 1, None

    device_id = getattr(session, "device_id", None)

    try:
        await ws.send_json({"type": "building",
                            "device": getattr(session, "device_name", "?"),
                            "device_id": device_id})
    except Exception: pass

    if MODE == "local":
        return await _local_build(ws, device_id), None

    import build_ws, uuid
    control = build_ws._any_worker_ws()
    if not control:
        await ws.send_text("[clawtank] no worker connected\n")
        return 1, None

    build_id = "b_" + uuid.uuid4().hex[:10]
    build_ws.register_build(build_id)

    try:
        await control.send_json({"type": "build", "build_id": build_id,
                                 "files": files, "device_id": device_id,
                                 "workspace_id": workspace_id})
    except Exception as e:
        build_ws.drop_build(build_id)
        await ws.send_text(f"[clawtank] cannot start build: {e}\n")
        return 1, None

    code = -1
    q = build_ws._builds[build_id]
    while True:
        try:
            kind, payload = await asyncio.wait_for(q.get(),
                                                  timeout=BUILD_IDLE)
        except asyncio.TimeoutError:
            await ws.send_text(
                f"[clawtank] build idle for {BUILD_IDLE}s — aborting\n")
            code = -1; break
        if kind == "log":
            try:
                await ws.send_text(payload if payload.endswith("\n")
                                   else payload + "\n")
            except Exception:
                return -1, build_id
        elif kind == "done":
            code = int(payload); break
    return code, build_id


async def _local_build(ws, device_id) -> int:
    import os
    from pathlib import Path
    from config import BUILD_MAX
    HERE = Path(__file__).resolve().parent
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    env["TERM"] = "dumb"
    if device_id: env["TARGET_DEVICE"] = device_id

    try:
        proc = await asyncio.create_subprocess_exec(
            "bash", str(HERE / "hello.sh"),
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=str(HERE), env=env)
    except Exception as e:
        await ws.send_text(f"[clawtank] spawn failed: {e}\n")
        return 1

    async def pump():
        buffer = b""
        while True:
            chunk = await proc.stdout.read(512)
            if not chunk: break
            buffer += chunk.replace(b"\r", b"\n")
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                text = line.decode("utf-8", "replace")
                if text.strip():
                    try: await ws.send_text(text + "\n")
                    except Exception: pass
        if buffer.strip():
            try: await ws.send_text(buffer.decode("utf-8", "replace") + "\n")
            except Exception: pass

    try:
        await asyncio.wait_for(pump(), timeout=BUILD_MAX)
        code = await asyncio.wait_for(proc.wait(), timeout=30)
    except asyncio.TimeoutError:
        proc.kill()
        try: await proc.wait()
        except Exception: pass
        await ws.send_text(f"[clawtank] build exceeded {BUILD_MAX}s — killed\n")
        code = -1
    return code


async def _relay_loot(ws, build_id):
    import build_ws
    q = build_ws._loot.get(build_id)
    if q is None:
        return
    try:
        while True:
            try:
                item = await asyncio.wait_for(q.get(), timeout=60)
            except asyncio.TimeoutError:
                return
            if item is None:
                return
            if item["kind"] == "screenshot":
                try:
                    await ws.send_json({"type": "loot_screenshot",
                                        "idx": item["idx"],
                                        "data": item["data"]})
                except Exception:
                    return
            elif item["kind"] == "log":
                try:
                    await ws.send_json({"type": "loot_log",
                                        "line": item["line"]})
                    await ws.send_text(f"[app] {item['line']}\n")
                except Exception:
                    pass
    except asyncio.CancelledError:
        return


async def _stream_live(ws, session):
    await ws.send_json({
        "type": "ready", "duration": SESSION_SECONDS,
        "device": session.device_name,
        "device_id": getattr(session, "device_id", None),
        "android": "14",
        "api": 34,
        "width": session.width, "height": session.height,
        "codec": session.codec_string,
    })

    try:
        while True:
            msg = await asyncio.wait_for(ws.receive_text(), timeout=10)
            if '"ready"' in msg: break
    except Exception:
        return

    q = session.subscribe()

    async def frame_pump():
        try:
            while True:
                data = await q.get()
                if data is None: return
                await ws.send_bytes(data)
        except (asyncio.CancelledError, Exception):
            return

    async def deadline():
        end = time.time() + SESSION_SECONDS
        try:
            while True:
                remaining = int(round(end - time.time()))
                if remaining <= 0:
                    try: await ws.send_json({"type": "expired"})
                    except Exception: pass
                    return
                try: await ws.send_json({"type": "tick", "remaining": remaining})
                except Exception: return
                await asyncio.sleep(1)
        except asyncio.CancelledError:
            return

    async def health():
        try:
            while True:
                await asyncio.sleep(1)
                alive_fn = getattr(session, "alive", None)
                if alive_fn is None: continue
                if not alive_fn():
                    try: await ws.send_json({"type": "emulator_offline"})
                    except Exception: pass
                    return
        except asyncio.CancelledError:
            return

    async def control():
        try:
            while True:
                raw = await ws.receive_text()
                try: d = json.loads(raw)
                except Exception: continue
                t = d.get("type")
                if t == "tap":
                    await session.send_control(encode_touch(
                        d["x"], d["y"], session.width, session.height, 0))
                    await session.send_control(encode_touch(
                        d["x"], d["y"], session.width, session.height, 1))
                elif t == "swipe":
                    x1, y1, x2, y2 = d["x1"], d["y1"], d["x2"], d["y2"]
                    await session.send_control(encode_touch(
                        x1, y1, session.width, session.height, 0))
                    for i in range(1, 8):
                        await session.send_control(encode_touch(
                            x1 + (x2-x1)*i/8, y1 + (y2-y1)*i/8,
                            session.width, session.height, 2))
                    await session.send_control(encode_touch(
                        x2, y2, session.width, session.height, 1))
                elif t == "key":
                    await session.send_control(encode_key(int(d.get("code", 4)), 0))
                    await session.send_control(encode_key(int(d.get("code", 4)), 1))
                elif t == "text":
                    await session.send_control(encode_text(str(d.get("text", ""))))
        except WebSocketDisconnect:
            return
        except asyncio.CancelledError:
            return
        except Exception:
            return

    tasks = [asyncio.create_task(frame_pump()),
             asyncio.create_task(deadline()),
             asyncio.create_task(health()),
             asyncio.create_task(control())]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for t in tasks:
            if not t.done(): t.cancel()
        for t in tasks:
            try: await asyncio.wait_for(t, timeout=2)
            except BaseException: pass
        try: session.unsubscribe(q)
        except Exception: pass


async def _request_force_stop(session):
    """Tell the worker that owns this session to force-stop the app package."""
    from config import MODE
    if MODE != "remote":
        # local: stop via adb directly when possible
        device_id = getattr(session, "device_id", None)
        if not device_id:
            return
        try:
            import asyncio
            p = await asyncio.create_subprocess_exec(
                "adb", "-s", device_id, "shell", "am", "force-stop",
                "com.clawtank.app",
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL)
            await asyncio.wait_for(p.wait(), timeout=8)
        except Exception:
            pass
        return
    worker_id = getattr(session, "worker_id", None)
    device_id = getattr(session, "device_id", None)
    if not worker_id or not device_id:
        return
    try:
        from pool import _workers, _rlock
        async with _rlock:
            info = _workers.get(worker_id)
            control = info["ws"] if info else None
        if control:
            await control.send_json({
                "type": "force_stop",
                "device_id": device_id,
                "package": "com.clawtank.app",
            })
    except Exception:
        pass


@router.websocket("/ws/stream")
async def ws_stream(ws: WebSocket):
    await ws.accept()
    client_id = ws.query_params.get("client") or secrets.token_hex(8)
    workspace_id = ws.query_params.get("ws") or None
    session = None
    build_id = None

    try:
        try:
            session = await _acquire_or_queue(ws, client_id)
        except asyncio.CancelledError:
            raise
        except Exception as e:
            try: await ws.send_json({"type": "error", "message": str(e)})
            except Exception: pass
            return

        try: await ws.send_json({"type": "assigned"})
        except Exception: return

        code, build_id = await _run_build(ws, session, workspace_id=workspace_id)
        if code != 0:
            try: await ws.send_json({"type": "build_failed", "code": code})
            except Exception: pass
            return

        loot_task = None
        if build_id:
            loot_task = asyncio.create_task(_relay_loot(ws, build_id))

        try:
            await _stream_live(ws, session)
        except asyncio.CancelledError:
            raise
        except Exception:
            pass
        finally:
            if loot_task:
                loot_task.cancel()
                try: await loot_task
                except BaseException: pass

    except WebSocketDisconnect:
        pass
    except asyncio.CancelledError:
        pass
    except Exception as e:
        print(f"  ws_stream error: {type(e).__name__}: {e}")
    finally:
        await QUEUE.remove(client_id)
        if session is not None:
            # Ask worker to force-stop the app so the next lease starts clean.
            try:
                await _request_force_stop(session)
            except BaseException:
                pass
            try: await release(session)
            except BaseException: pass
        if build_id:
            try:
                import build_ws
                build_ws.drop_build(build_id)
            except Exception: pass
        try: await ws.close()
        except Exception: pass
EOF

cat > worker_ws.py <<'EOF'
import asyncio, json
from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from pool import add_worker, remove_worker, update_devices, get_session
from build_ws import (push_build_log, push_screenshot,
                      push_app_log, push_logcat_blob, push_apk,
                      finish_build, finish_loot)

router = APIRouter()


@router.websocket("/ws/worker")
async def ws_worker(ws: WebSocket):
    await ws.accept()
    worker_id = None
    try:
        raw = await asyncio.wait_for(ws.receive_text(), timeout=10)
        hello = json.loads(raw)
    except Exception:
        await ws.close(code=4400); return
    if hello.get("type") != "hello":
        await ws.close(code=4400); return

    worker_id = hello.get("worker_id") or "anon"
    devices   = hello.get("devices") or []
    await add_worker(worker_id, ws, devices)
    print(f"  + worker {worker_id}  devices={devices}")

    try:
        await ws.send_json({"type": "hello_ack"})
        while True:
            raw = await ws.receive_text()
            try: msg = json.loads(raw)
            except Exception: continue
            t = msg.get("type")
            if t == "devices":
                await update_devices(worker_id, msg.get("devices") or [])
            elif t == "build_log":
                push_build_log(msg.get("build_id", ""), msg.get("line", ""))
            elif t == "loot_screenshot":
                push_screenshot(msg.get("build_id", ""),
                                msg.get("idx"),
                                msg.get("data", ""))
            elif t == "loot_log":
                push_app_log(msg.get("build_id", ""), msg.get("line", ""))
            elif t == "loot_logcat":
                push_logcat_blob(msg.get("build_id", ""), msg.get("text", ""))
            elif t == "loot_done":
                finish_loot(msg.get("build_id", ""))
            elif t == "loot_apk":
                push_apk(msg.get("build_id", ""),
                         msg.get("data", ""),
                         workspace_id=msg.get("workspace_id"),
                         filename=msg.get("filename") or "app-debug.apk")
            elif t == "build_done":
                finish_build(msg.get("build_id", ""), int(msg.get("code", -1)))
            elif t == "session_ping":
                s = get_session(msg.get("session_id"))
                if s: s.ping()
    except WebSocketDisconnect:
        pass
    except Exception as e:
        print(f"  worker {worker_id} error: {e}")
    finally:
        if worker_id:
            await remove_worker(worker_id)
            print(f"  - worker {worker_id}")
EOF

cat > worker_session_ws.py <<'EOF'
import asyncio, json
from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from pool import resolve_pending
from session_manager import RemoteSession

router = APIRouter()


@router.websocket("/ws/worker-session/{session_id}")
async def ws_worker_session(ws: WebSocket, session_id: str):
    await ws.accept()
    session = None
    try:
        raw = await ws.receive_text()
        meta = json.loads(raw)
        if meta.get("type") != "meta":
            await ws.close(code=4000); return
        session = RemoteSession(session_id, meta, ws)
        resolve_pending(session_id, session)
        while True:
            msg = await ws.receive()
            if msg.get("type") == "websocket.disconnect": break
            data = msg.get("bytes")
            if data is not None:
                session.fanout(data)
    except WebSocketDisconnect:
        pass
    except Exception as e:
        print(f"  worker-session error: {e}")
    finally:
        if session: await session.stop()
EOF

cat > main.py <<'EOF'
#!/usr/bin/env python3
from contextlib import asynccontextmanager
from fastapi import FastAPI
import accounts  # initializes SQLite + test users
import http_api, stream_ws, build_ws, worker_ws, worker_session_ws
from queue_manager import QUEUE


@asynccontextmanager
async def lifespan(app: FastAPI):
    accounts.init_db()
    await QUEUE.start()
    try:
        yield
    finally:
        await QUEUE.stop()


app = FastAPI(title="clawtank coordinator", lifespan=lifespan)
app.include_router(http_api.router)
app.include_router(stream_ws.router)
app.include_router(build_ws.router)
app.include_router(worker_ws.router)
app.include_router(worker_session_ws.router)

if __name__ == "__main__":
    import os, uvicorn
    uvicorn.run(app, host=os.getenv("HOST", "0.0.0.0"),
                port=int(os.getenv("PORT", "8000")))
EOF

cat > start.sh <<'EOF'
#!/usr/bin/env bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
if [ ! -d venv ]; then python3 -m venv venv; fi
source venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
export HOST PORT
export MODE="${MODE:-remote}"
export MAX_SIZE="${MAX_SIZE:-540}"
export MAX_FPS="${MAX_FPS:-60}"
export BIT_RATE="${BIT_RATE:-8000000}"
export SESSION_SECONDS="${SESSION_SECONDS:-15}"
export BUILD_MAX="${BUILD_MAX:-480}"
export BUILD_IDLE="${BUILD_IDLE:-120}"

if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "!! port $PORT in use"
  echo "   lsof -ti:$PORT | xargs kill -9"
  exit 1
fi

echo ""
echo "  clawtank coordinator   MODE=$MODE  LEASE=${SESSION_SECONDS}s"
echo "  http://$HOST:$PORT"
echo ""
exec uvicorn main:app --host "$HOST" --port "$PORT" --reload
EOF

cat > hello.sh <<'HELLO'
#!/usr/bin/env bash
set -e
PACKAGE="com.clawtank.app"
ACTIVITY="MainActivity"
GRADLE_VERSION="8.9"
ANDROID_API="34"
BUILD_TOOLS="34.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_DEVICE="${TARGET_DEVICE:-}"
if [ -n "$TARGET_DEVICE" ]; then
  SAFE_DEV=$(echo "$TARGET_DEVICE" | tr ':/.' '___')
  PROJECT_DIR="clawtank-$SAFE_DEV"
else
  PROJECT_DIR="clawtank"
fi

FRESH=0; EMU_INDEX=1; SOURCE_FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) FRESH=1; shift ;;
    [0-9]*)  EMU_INDEX="$1"; shift ;;
    *)       SOURCE_FILES+=("$1"); shift ;;
  esac
done

if [ ${#SOURCE_FILES[@]} -eq 0 ]; then
  SRC="$SCRIPT_DIR/scripts"
  if [ -d "$SRC" ]; then
    while IFS= read -r -d '' f; do SOURCE_FILES+=("$f"); done \
      < <(find "$SRC" -type f -print0 | sort -z)
  fi
fi

echo ""
echo "  Project   : $PROJECT_DIR"
if [ -n "$TARGET_DEVICE" ]; then
  echo "  Target    : $TARGET_DEVICE"
fi

if ! command -v java >/dev/null 2>&1; then
  sudo apt-get update -qq
  if apt-cache show openjdk-17-jdk >/dev/null 2>&1; then
    sudo apt-get install -y -qq openjdk-17-jdk
  elif apt-cache show openjdk-21-jdk >/dev/null 2>&1; then
    sudo apt-get install -y -qq openjdk-21-jdk
  else
    sudo apt-get install -y -qq default-jdk
  fi
fi
[ -z "${JAVA_HOME:-}" ] && {
  JAVA_BIN=$(readlink -f "$(command -v java)")
  JAVA_HOME=$(dirname "$(dirname "$JAVA_BIN")")
  export JAVA_HOME
}
JAVA_MAJOR=$(java -version 2>&1 | head -1 | grep -oE '"[0-9]+' | tr -d '"')

SDK_ROOT="${ANDROID_HOME:-$HOME/Android/Sdk}"
CMDLINE_TOOLS="$SDK_ROOT/cmdline-tools/latest"
if [ ! -d "$CMDLINE_TOOLS/bin" ]; then
  mkdir -p "$SDK_ROOT/cmdline-tools"
  TMP_ZIP=$(mktemp /tmp/cmdline-tools-XXXX.zip)
  curl -fL -o "$TMP_ZIP" \
    "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  unzip -q -o "$TMP_ZIP" -d "$SDK_ROOT/cmdline-tools"
  [ -d "$SDK_ROOT/cmdline-tools/cmdline-tools" ] && \
    mv "$SDK_ROOT/cmdline-tools/cmdline-tools" "$CMDLINE_TOOLS"
  rm -f "$TMP_ZIP"
fi
export ANDROID_HOME="$SDK_ROOT"
export PATH="$CMDLINE_TOOLS/bin:$SDK_ROOT/platform-tools:$PATH"

if [ ! -d "$SDK_ROOT/platforms/android-${ANDROID_API}" ] || \
   [ ! -d "$SDK_ROOT/build-tools/${BUILD_TOOLS}" ]; then
  yes | sdkmanager --sdk_root="$SDK_ROOT" \
    "platforms;android-${ANDROID_API}" \
    "build-tools;${BUILD_TOOLS}" "platform-tools" >/dev/null || true
fi

GRADLE_CACHE_DIR="$HOME/.local/share/clawtank-gradle"
GRADLE_HOME="$GRADLE_CACHE_DIR/gradle-${GRADLE_VERSION}"
GRADLE_BIN="$GRADLE_HOME/bin/gradle"
if [ ! -x "$GRADLE_BIN" ]; then
  mkdir -p "$GRADLE_CACHE_DIR"
  ZIP_PATH="$GRADLE_CACHE_DIR/gradle-${GRADLE_VERSION}-bin.zip"
  curl -fL -o "$ZIP_PATH" \
    "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"
  unzip -q -o "$ZIP_PATH" -d "$GRADLE_CACHE_DIR"
fi

if [ -d "$PROJECT_DIR" ] && [ "$FRESH" = "0" ]; then
  cd "$PROJECT_DIR"
else
  rm -rf "$PROJECT_DIR"
  mkdir -p "$PROJECT_DIR"/app/src/main/{java/com/clawtank/app,res/values}
  cd "$PROJECT_DIR"
  cat > settings.gradle.kts << 'EOF'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "clawtank"
include(":app")
EOF
  cat > build.gradle.kts << 'EOF'
plugins {
    id("com.android.application") version "8.7.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
}
EOF
  cat > app/build.gradle.kts << EOF
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "com.clawtank.app"
    compileSdk = ${ANDROID_API}
    defaultConfig {
        applicationId = "com.clawtank.app"
        minSdk = 24
        targetSdk = ${ANDROID_API}
        versionCode = 1
        versionName = "1.0"
    }
    buildTypes { release { isMinifyEnabled = false } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_${JAVA_MAJOR}
        targetCompatibility = JavaVersion.VERSION_${JAVA_MAJOR}
    }
    kotlinOptions { jvmTarget = "${JAVA_MAJOR}" }
}
dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
}
EOF
  cat > app/src/main/AndroidManifest.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:allowBackup="true" android:label="@string/app_name"
        android:supportsRtl="true"
        android:theme="@style/Theme.AppCompat.Light.NoActionBar">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF
  cat > app/src/main/res/values/strings.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">clawtank</string>
    <string name="main_title">clawtank</string>
</resources>
EOF
  cat > app/src/main/res/values/colors.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="black">#FF000000</color>
    <color name="white">#FFFFFFFF</color>
    <color name="rainbow_red">#FFFF0000</color>
    <color name="rainbow_orange">#FFFF7F00</color>
    <color name="rainbow_yellow">#FFFFFF00</color>
    <color name="rainbow_green">#FF00FF00</color>
    <color name="rainbow_blue">#FF0000FF</color>
    <color name="rainbow_indigo">#FF4B0082</color>
    <color name="rainbow_violet">#FF8B00FF</color>
</resources>
EOF
  cat > gradle.properties << 'EOF'
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.useAndroidX=true
kotlin.code.style=official
EOF
fi

mkdir -p app/src/main/java/com/clawtank/app \
         app/src/main/res/values \
         app/src/main/res/xml \
         app/src/main/res/drawable \
         app/src/main/res/font
for SRC in "${SOURCE_FILES[@]}"; do
  [ -f "$SRC" ] || continue
  # Preserve relative path under scripts/ when present
  REL="${SRC#"$SCRIPT_DIR/scripts/"}"
  BASE=$(basename "$SRC")
  case "$REL" in
    app/build.gradle.kts|build.gradle.kts)
      cp "$SRC" app/build.gradle.kts ;;
    AndroidManifest.xml)
      cp "$SRC" app/src/main/AndroidManifest.xml ;;
    *.kt)
      # Preserve editor line numbers: only prepend package when the file
      # does not already declare one (avoids shifting error line:col).
      if grep -qE '^[[:space:]]*package[[:space:]]' "$SRC"; then
        cp "$SRC" app/src/main/java/com/clawtank/app/"$BASE"
      else
        { echo "package com.clawtank.app"; echo ""
          cat "$SRC"
        } > app/src/main/java/com/clawtank/app/"$BASE"
      fi ;;
    strings.xml|colors.xml|themes.xml|styles.xml|dimens.xml|arrays.xml)
      cp "$SRC" app/src/main/res/values/"$BASE" ;;
    network_security_config.xml)
      cp "$SRC" app/src/main/res/xml/network_security_config.xml ;;
    font_family.xml)
      cp "$SRC" app/src/main/res/values/font_family.xml ;;
    *.font.xml)
      cp "$SRC" app/src/main/res/font/"$BASE" ;;
    ic_launcher_foreground.xml|ic_launcher_background.xml|ic_vector_example.xml|*.xml)
      # drawable / adaptive-icon vectors
      case "$BASE" in
        network_security_config.xml) continue ;;
        strings.xml|colors.xml|themes.xml|styles.xml|dimens.xml|arrays.xml) continue ;;
        AndroidManifest.xml) continue ;;
        *) cp "$SRC" app/src/main/res/drawable/"$BASE" ;;
      esac ;;
    *)
      # Fallback: if path contains res/ keep structure, else skip unknown
      if [[ "$REL" == res/* ]]; then
        mkdir -p "app/src/main/$(dirname "$REL")"
        cp "$SRC" "app/src/main/$REL"
      fi
      ;;
  esac
done

[ -f app/src/main/java/com/clawtank/app/MainActivity.kt ] || {
  cat > app/src/main/java/com/clawtank/app/MainActivity.kt << 'EOF'
package com.clawtank.app
import android.graphics.Typeface
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
class MainActivity : AppCompatActivity() {
    override fun onCreate(s: Bundle?) {
        super.onCreate(s)
        val root = FrameLayout(this).apply {
            setBackgroundColor(ContextCompat.getColor(this@MainActivity, R.color.black))
        }
        val title = getString(R.string.main_title)
        val colors = intArrayOf(
            ContextCompat.getColor(this, R.color.rainbow_red),
            ContextCompat.getColor(this, R.color.rainbow_orange),
            ContextCompat.getColor(this, R.color.rainbow_yellow),
            ContextCompat.getColor(this, R.color.rainbow_green),
            ContextCompat.getColor(this, R.color.rainbow_blue),
            ContextCompat.getColor(this, R.color.rainbow_indigo),
            ContextCompat.getColor(this, R.color.rainbow_violet))
        val sp = SpannableString(title)
        for (i in title.indices) sp.setSpan(
            ForegroundColorSpan(colors[i % colors.size]), i, i+1,
            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val tv = TextView(this).apply {
            text = sp; textSize = 48f
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            gravity = Gravity.CENTER; setPadding(32,32,32,32) }
        root.addView(tv, FrameLayout.LayoutParams(-2,-2, Gravity.CENTER))
        setContentView(root)
    }
}
EOF
}

echo "sdk.dir=$SDK_ROOT" > local.properties
if [ ! -x gradlew ]; then
  mkdir -p gradle/wrapper
  "$GRADLE_BIN" wrapper --gradle-version "$GRADLE_VERSION" --quiet
  chmod +x gradlew
fi

echo ""
echo "  Building debug APK…"
set +e
./gradlew assembleDebug --console=plain --parallel --build-cache \
  -Dorg.gradle.daemon=true
GRADLE_RC=$?
set -e
if [ "$GRADLE_RC" -ne 0 ]; then
  echo "ERROR: gradle assembleDebug failed (exit $GRADLE_RC)"
  exit "$GRADLE_RC"
fi

APK="app/build/outputs/apk/debug/app-debug.apk"
[ -f "$APK" ] || { echo "ERROR: APK not produced"; exit 1; }

if [ -n "$TARGET_DEVICE" ]; then
  DEVICE="$TARGET_DEVICE"
  echo "  Using device: $DEVICE (pinned)"
else
  mapfile -t DEVICES < <(adb devices | awk '/device$/{print $1}')
  [ ${#DEVICES[@]} -gt 0 ] || { echo "ERROR: no emulators"; exit 1; }
  [ "$EMU_INDEX" -ge 1 ] && [ "$EMU_INDEX" -le ${#DEVICES[@]} ] || EMU_INDEX=1
  DEVICE="${DEVICES[$((EMU_INDEX-1))]}"
  echo "  Using device: $DEVICE (index $EMU_INDEX)"
fi

adb -s "$DEVICE" install -r "$APK"
echo "  Launching…"
adb -s "$DEVICE" shell am start -n "${PACKAGE}/.${ACTIVITY}"
echo "  Done!"
HELLO

cat > scripts/MainActivity.kt <<'KT'
package com.clawtank.app

import android.graphics.Typeface
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.util.Log
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d("clawtank", "Cats")
        val root = FrameLayout(this).apply {
            setBackgroundColor(ContextCompat.getColor(this@MainActivity, R.color.black))
        }
        val title = getString(R.string.main_title)
        val rainbowColors = intArrayOf(
            ContextCompat.getColor(this, R.color.rainbow_red),
            ContextCompat.getColor(this, R.color.rainbow_orange),
            ContextCompat.getColor(this, R.color.rainbow_yellow),
            ContextCompat.getColor(this, R.color.rainbow_green),
            ContextCompat.getColor(this, R.color.rainbow_blue),
            ContextCompat.getColor(this, R.color.rainbow_indigo),
            ContextCompat.getColor(this, R.color.rainbow_violet))
        val spannable = SpannableString(title)
        for (i in title.indices) {
            spannable.setSpan(
                ForegroundColorSpan(rainbowColors[i % rainbowColors.size]),
                i, i + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val textView = TextView(this).apply {
            text = spannable; textSize = 48f
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            gravity = Gravity.CENTER; setPadding(32, 32, 32, 32) }
        root.addView(textView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        setContentView(root)
    }
}
KT

cat > scripts/colors.xml <<'COL'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="black">#FF000000</color>
    <color name="white">#FFFFFFFF</color>
    <color name="rainbow_red">#FFFF0000</color>
    <color name="rainbow_orange">#FFFF7F00</color>
    <color name="rainbow_yellow">#FFFFFF00</color>
    <color name="rainbow_green">#FF00FF00</color>
    <color name="rainbow_blue">#FF0000FF</color>
    <color name="rainbow_indigo">#FF4B0082</color>
    <color name="rainbow_violet">#FF8B00FF</color>
</resources>
COL

cat > scripts/strings.xml <<'STR'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">clawtank</string>
    <string name="main_title">clawtank</string>
</resources>
STR

cat > scripts/AndroidManifest.xml <<'MAN'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <application
        android:allowBackup="true"
        android:label="@string/app_name"
        android:supportsRtl="true"
        android:theme="@style/Theme.Clawtank"
        android:networkSecurityConfig="@xml/network_security_config"
        android:icon="@drawable/ic_launcher_foreground">
        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
MAN

cat > scripts/themes.xml <<'THM'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="Theme.Clawtank" parent="Theme.AppCompat.Light.NoActionBar">
        <item name="colorPrimary">@color/rainbow_blue</item>
        <item name="colorPrimaryDark">@color/black</item>
        <item name="colorAccent">@color/rainbow_orange</item>
        <item name="android:statusBarColor">@color/black</item>
        <item name="android:navigationBarColor">@color/black</item>
        <item name="android:windowBackground">@color/black</item>
    </style>
</resources>
THM

cat > scripts/network_security_config.xml <<'NSC'
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="false">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>
    <!-- Allow cleartext to localhost for debug / emulator -->
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="true">localhost</domain>
        <domain includeSubdomains="true">10.0.2.2</domain>
    </domain-config>
</network-security-config>
NSC

cat > scripts/dimens.xml <<'DIM'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <dimen name="padding_small">8dp</dimen>
    <dimen name="padding_medium">16dp</dimen>
    <dimen name="padding_large">32dp</dimen>
    <dimen name="text_title">48sp</dimen>
    <dimen name="text_body">16sp</dimen>
    <dimen name="icon_size">48dp</dimen>
</resources>
DIM

cat > scripts/arrays.xml <<'ARR'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string-array name="rainbow_names">
        <item>red</item>
        <item>orange</item>
        <item>yellow</item>
        <item>green</item>
        <item>blue</item>
        <item>indigo</item>
        <item>violet</item>
    </string-array>
    <!-- Color hex values as strings (integer-array cannot reference @color) -->
    <string-array name="rainbow_color_hex">
        <item>#FFFF0000</item>
        <item>#FFFF7F00</item>
        <item>#FFFFFF00</item>
        <item>#FF00FF00</item>
        <item>#FF0000FF</item>
        <item>#FF4B0082</item>
        <item>#FF8B00FF</item>
    </string-array>
</resources>
ARR

cat > scripts/ic_vector_example.xml <<'VEC'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FF6B00"
        android:pathData="M12,2L2,7l10,5 10,-5 -10,-5zM2,17l10,5 10,-5M2,12l10,5 10,-5" />
</vector>
VEC

cat > scripts/ic_launcher_foreground.xml <<'FG'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#FF6B00"
        android:pathData="M54,30c-13.2,0 -24,10.8 -24,24s10.8,24 24,24 24,-10.8 24,-24 -10.8,-24 -24,-24zM54,66c-6.6,0 -12,-5.4 -12,-12s5.4,-12 12,-12 12,5.4 12,12 -5.4,12 -12,12z" />
    <path
        android:fillColor="#FFFFFF"
        android:pathData="M48,48h12v12h-12z" />
</vector>
FG

cat > scripts/ic_launcher_background.xml <<'BG'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#0B0D10"
        android:pathData="M0,0h108v108h-108z" />
</vector>
BG

cat > scripts/font_family.xml <<'FNT'
<?xml version="1.0" encoding="utf-8"?>
<!-- Placeholder for custom fonts.
     To use a real font: put a .ttf/.otf under res/font/ and either
     (1) reference it from a theme, or (2) replace this file with a
     <font-family> that lists <font android:font="@font/your_file" .../>.
     Kept as a plain resources file so the default project always compiles. -->
<resources>
    <string name="font_family_placeholder">sans-serif</string>
</resources>
FNT

mkdir -p scripts/app
cat > scripts/app/build.gradle.kts <<'BGK'
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "com.clawtank.app"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.clawtank.app"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }
    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}
dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
}
BGK


# ============================================================
#  templates/_header.html — shared top nav
# ============================================================
cat > templates/_header.html <<'HTML'
{# clawtank shared top nav. Include from every page:
     {% set active = 'home' %}  ...or 'studio' / 'api'
     {% include "_header.html" %}
#}
<header class="ct-nav">
  <style>
    .ct-nav{
      border-bottom:1px solid var(--border,#1e232c);
      font-family:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
    }
    .ct-nav__inner{
      display:grid;grid-template-columns:1fr auto 1fr;
      align-items:center;gap:16px;padding:12px 20px;
    }
    .ct-nav__left{display:flex;align-items:center;gap:26px;min-width:0}
    .ct-nav__center{
      display:flex;align-items:center;justify-content:center;
      min-width:0;pointer-events:none;
    }
    .ct-nav__kotlin{
      font-family:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
      font-size:.62rem;font-weight:500;letter-spacing:.06em;
      text-transform:uppercase;color:var(--muted,#8b93a7);
      white-space:nowrap;
    }
    .ct-nav__kotlin b{
      font-weight:600;color:var(--text,#e8eaed);letter-spacing:0;
      text-transform:none;margin-left:4px;
    }
    .ct-nav__brand{
      font-family:"Inter",system-ui,-apple-system,"Segoe UI",sans-serif;
      font-size:1.05rem;font-weight:700;letter-spacing:-.01em;
      color:var(--text,#e8eaed);text-decoration:none;white-space:nowrap;
    }
    .ct-nav__brand span{color:var(--accent,#ff6b00)}
    .ct-nav__links{display:flex;gap:22px}
    .ct-nav__link{
      font-size:.82rem;font-weight:500;letter-spacing:-.01em;
      color:var(--muted,#8b93a7);text-decoration:none;
      transition:color .15s;padding:2px 0;
    }
    .ct-nav__link:hover{color:var(--text,#e8eaed)}
    .ct-nav__link[aria-current="page"]{color:var(--text,#e8eaed)}
    .ct-nav__link[aria-current="page"]::before{
      content:"\203A";color:var(--accent,#ff6b00);margin-right:6px;opacity:.9;
    }
    .ct-nav__extra{display:flex;align-items:center;justify-content:flex-end;gap:8px;min-width:0}
    .ct-nav__auth{display:flex;align-items:center;gap:14px;margin-left:8px}
    .ct-nav__auth form{display:inline;margin:0}
  </style>
  <div class="ct-nav__inner">
    <div class="ct-nav__left">
      <a class="ct-nav__brand" href="/">claw<span>tank</span></a>
      <nav class="ct-nav__links" aria-label="Primary">
        <a class="ct-nav__link" href="/"{% if active == 'home' %} aria-current="page"{% endif %}>home</a>
        <a class="ct-nav__link" href="/studio"{% if active == 'studio' %} aria-current="page"{% endif %}>studio</a>
        <a class="ct-nav__link" href="/api/docs"{% if active == 'api' %} aria-current="page"{% endif %}>api</a>
      </nav>
    </div>
    <div class="ct-nav__center">
      {% if header_center %}{{ header_center|safe }}{% endif %}
    </div>
    <div class="ct-nav__extra">
      {% if header_extra %}{{ header_extra|safe }}{% endif %}
      <span class="ct-nav__auth">
        {% if user %}
          <a class="ct-nav__link" href="/account"{% if active == 'account' %} aria-current="page"{% endif %}>
            <span class="ct-nav__user-name">{{ user.display_name }}</span>
            · <span class="ct-nav__credits" id="navCredits" data-credits="{{ user.credits }}">{{ user.credits }}¢</span>
          </a>
          <form action="/logout" method="post" style="display:inline;margin:0">
            <button type="submit" class="ct-nav__link" style="background:none;border:none;cursor:pointer;font:inherit;color:inherit;padding:2px 0">logout</button>
          </form>
        {% else %}
          <a class="ct-nav__link" href="/login"{% if active == 'account' %} aria-current="page"{% endif %}>login</a>
          <a class="ct-nav__link" href="/register">create</a>
        {% endif %}
      </span>
    </div>
  </div>
</header>

<script>
(function(){
  function setCredits(cents){
    if(cents === undefined || cents === null || isNaN(cents)) return;
    cents = Math.max(0, parseInt(cents, 10));
    document.querySelectorAll("#navCredits, .ct-nav__credits, [data-credits-display]").forEach(function(el){
      el.textContent = cents + "¢";
      el.setAttribute("data-credits", String(cents));
    });
    var bal = document.getElementById("accountBalance");
    if(bal){
      bal.textContent = cents + "¢";
      var sub = document.getElementById("accountBalanceUsd");
      if(sub) sub.textContent = "($" + (cents/100).toFixed(2) + ")";
    }
    window.__ctCredits = cents;
  }
  window.updateCreditsDisplay = setCredits;
  window.refreshCredits = async function(){
    try{
      var r = await fetch("/api/me", {credentials:"same-origin"});
      if(!r.ok) return null;
      var d = await r.json();
      if(typeof d.credits === "number") setCredits(d.credits);
      return d.credits;
    }catch(e){ return null; }
  };
  // Light poll so other tabs / pay-build stay in sync
  if(document.getElementById("navCredits")){
    setInterval(function(){ window.refreshCredits(); }, 8000);
  }
})();
</script>

HTML

# ============================================================
#  home.html — landing page
# ============================================================

cat > templates/login.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Login · clawtank</title>
<link rel="preconnect" href="https://fonts.googleapis.com"/>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet"/>
<style>
:root{--bg:#0b0d10;--panel:#0e1116;--border:#1e232c;--text:#e8eaed;--muted:#7b8494;--accent:#ff6b00;--font:"Inter",system-ui,sans-serif;--mono:"JetBrains Mono",monospace}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--font);background:var(--bg);color:var(--text);min-height:100vh}
.page{max-width:420px;margin:0 auto;padding:40px 20px}
h1{font-size:1.4rem;margin:28px 0 8px}
.sub{color:var(--muted);font-size:.9rem;margin-bottom:24px}
label{display:block;font-size:.75rem;color:var(--muted);margin:14px 0 6px;font-family:var(--mono)}
input{width:100%;padding:10px 12px;border-radius:8px;border:1px solid var(--border);background:#0a0d12;color:var(--text);font-size:.9rem}
button,.btn{margin-top:20px;width:100%;padding:11px;border-radius:8px;border:none;background:var(--accent);color:#000;font-weight:600;cursor:pointer;font-size:.9rem}
.err{background:rgba(255,80,80,.12);border:1px solid rgba(255,80,80,.35);color:#ff8a8a;padding:10px 12px;border-radius:8px;font-size:.85rem;margin-bottom:14px}
.hint{margin-top:18px;font-size:.8rem;color:var(--muted);line-height:1.5}
.hint code{font-family:var(--mono);color:var(--text)}
a{color:var(--accent)}
</style>
</head>
<body>
{% set active = 'account' %}{% include "_header.html" %}
<div class="page">
  <h1>Log in</h1>
  <p class="sub">Use your clawtank account to access credits and API keys.</p>
  {% if error %}<div class="err">{{ error }}</div>{% endif %}
  <a href="/auth/google" class="btn-google" style="display:flex;align-items:center;justify-content:center;gap:10px;width:100%;padding:11px;border-radius:8px;border:1px solid var(--border);background:#fff;color:#222;font-weight:600;font-size:.9rem;margin-bottom:16px;text-decoration:none">
    <svg width="18" height="18" viewBox="0 0 48 48"><path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/><path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/><path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/><path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/></svg>
    Continue with Google
  </a>
  <p style="text-align:center;color:var(--muted);font-size:.75rem;margin-bottom:12px">or</p>
  <form method="post" action="/login">
    <label>email</label>
    <input type="email" name="email" required autocomplete="username"/>
    <label>password</label>
    <input type="password" name="password" required autocomplete="current-password"/>
    <button type="submit">Log in</button>
  </form>
  <p class="hint">No account? <a href="/register">Create one</a>.<br/>
  Test: <code>test@clawtank.app</code> / <code>test1234</code></p>
</div>
</body>
</html>
HTML

cat > templates/register.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Create account · clawtank</title>
<link rel="preconnect" href="https://fonts.googleapis.com"/>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet"/>
<style>
:root{--bg:#0b0d10;--panel:#0e1116;--border:#1e232c;--text:#e8eaed;--muted:#7b8494;--accent:#ff6b00;--font:"Inter",system-ui,sans-serif;--mono:"JetBrains Mono",monospace}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--font);background:var(--bg);color:var(--text);min-height:100vh}
.page{max-width:420px;margin:0 auto;padding:40px 20px}
h1{font-size:1.4rem;margin:28px 0 8px}
.sub{color:var(--muted);font-size:.9rem;margin-bottom:24px}
label{display:block;font-size:.75rem;color:var(--muted);margin:14px 0 6px;font-family:var(--mono)}
input{width:100%;padding:10px 12px;border-radius:8px;border:1px solid var(--border);background:#0a0d12;color:var(--text);font-size:.9rem}
button{margin-top:20px;width:100%;padding:11px;border-radius:8px;border:none;background:var(--accent);color:#000;font-weight:600;cursor:pointer;font-size:.9rem}
.err{background:rgba(255,80,80,.12);border:1px solid rgba(255,80,80,.35);color:#ff8a8a;padding:10px 12px;border-radius:8px;font-size:.85rem;margin-bottom:14px}
.hint{margin-top:18px;font-size:.8rem;color:var(--muted)}
a{color:var(--accent)}
</style>
</head>
<body>
{% set active = 'account' %}{% include "_header.html" %}
<div class="page">
  <h1>Create account</h1>
  <p class="sub">Get starting credits for paid builds. Studio free builds stay free.</p>
  {% if error %}<div class="err">{{ error }}</div>{% endif %}
  <a href="/auth/google" class="btn-google" style="display:flex;align-items:center;justify-content:center;gap:10px;width:100%;padding:11px;border-radius:8px;border:1px solid var(--border);background:#fff;color:#222;font-weight:600;font-size:.9rem;margin-bottom:16px;text-decoration:none">
    <svg width="18" height="18" viewBox="0 0 48 48"><path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z"/><path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z"/><path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z"/><path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z"/></svg>
    Continue with Google
  </a>
  <p style="text-align:center;color:var(--muted);font-size:.75rem;margin-bottom:12px">or</p>
  <form method="post" action="/register">
    <label>display name</label>
    <input type="text" name="display_name" autocomplete="nickname"/>
    <label>email</label>
    <input type="email" name="email" required autocomplete="username"/>
    <label>password (min 6)</label>
    <input type="password" name="password" required minlength="6" autocomplete="new-password"/>
    <button type="submit">Create account</button>
  </form>
  <p class="hint">Already have an account? <a href="/login">Log in</a></p>
</div>
</body>
</html>
HTML

cat > templates/account.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Account · clawtank</title>
<link rel="preconnect" href="https://fonts.googleapis.com"/>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet"/>
<style>
:root{--bg:#0b0d10;--panel:#0e1116;--panel2:#141821;--border:#1e232c;--text:#e8eaed;--muted:#7b8494;--accent:#ff6b00;--green:#3dd68c;--font:"Inter",system-ui,sans-serif;--mono:"JetBrains Mono",monospace}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--font);background:var(--bg);color:var(--text);min-height:100vh;font-size:14px}
.page{max-width:720px;margin:0 auto;padding:32px 20px 64px}
h1{font-size:1.35rem;margin:24px 0 6px}
.sub{color:var(--muted);margin-bottom:28px}
.card{border:1px solid var(--border);background:var(--panel);border-radius:12px;padding:20px;margin-bottom:18px}
.card h2{font-size:.95rem;margin-bottom:12px}
.bal{font-size:2rem;font-weight:600;font-family:var(--mono);color:var(--green)}
.bal span{font-size:.85rem;color:var(--muted);font-weight:400}
.row{display:flex;gap:10px;flex-wrap:wrap;margin-top:14px}
button,.btn{font-family:var(--font);font-size:.8rem;font-weight:600;padding:8px 14px;border-radius:7px;border:1px solid var(--border);background:var(--panel2);color:var(--text);cursor:pointer}
button.primary{background:var(--accent);border-color:var(--accent);color:#000}
button:disabled{opacity:.4;cursor:not-allowed}
table{width:100%;border-collapse:collapse;font-size:.8rem}
th,td{text-align:left;padding:8px 6px;border-bottom:1px solid var(--border);font-family:var(--mono)}
th{color:var(--muted);font-weight:500}
code{font-family:var(--mono);background:var(--panel2);padding:2px 6px;border-radius:4px;font-size:.75rem}
.flash{background:rgba(61,214,140,.12);border:1px solid rgba(61,214,140,.35);color:var(--green);padding:10px;border-radius:8px;margin-bottom:14px;font-size:.85rem;word-break:break-all}
.muted{color:var(--muted);font-size:.8rem}
</style>
</head>
<body>
{% set active = 'account' %}{% include "_header.html" %}
<div class="page">
  <h1>{{ user.display_name }}</h1>
  <p class="sub">{{ user.email }} · member since {{ user.created_at|int }}</p>

  <div class="card">
    <h2>Credits</h2>
    <div class="bal"><span id="accountBalance" data-credits-display>{{ user.credits }}¢</span> <span id="accountBalanceUsd">(${{ '%.2f'|format(user.credits/100) }})</span></div>
    <p class="muted" style="margin-top:8px">Paid build cost: {{ build_cost_cents }}¢ upfront (non-refundable) · Free BUILD &amp; RUN does not use credits.</p>
    <div class="row">
      <button type="button" class="primary" id="btnAdd100">+ $1.00 (test)</button>
      <button type="button" class="primary" id="btnAdd500">+ $5.00 (test)</button>
      <button type="button" id="btnAdd1000">+ $10.00 (test)</button>
    </div>
    <div id="topupFlash" class="flash" style="display:none;margin-top:12px"></div>
    <p class="muted" style="margin-top:10px">Dummy top-up for testing (no real Stripe charge yet).</p>
  </div>

  <div class="card">
    <h2>API keys</h2>
    <p class="muted" style="margin-bottom:12px">Use with <code>Authorization: Bearer ct_…</code> on <code>POST /v1/private/build</code>.</p>
    <div class="row">
      <input id="keyName" placeholder="key name" value="default" style="flex:1;min-width:120px;padding:8px 10px;border-radius:7px;border:1px solid var(--border);background:#0a0d12;color:var(--text)"/>
      <button type="button" class="primary" id="btnNewKey">Create key</button>
    </div>
    <div id="keyFlash" class="flash" style="display:none;margin-top:12px"></div>
    <table style="margin-top:16px">
      <thead><tr><th>name</th><th>prefix</th><th></th></tr></thead>
      <tbody>
      {% for k in keys %}
        <tr>
          <td>{{ k.name }}{% if k.revoked %} <span class="muted">(revoked)</span>{% endif %}</td>
          <td><code>{{ k.prefix }}…</code></td>
          <td>{% if not k.revoked %}<button type="button" data-revoke="{{ k.id }}">revoke</button>{% endif %}</td>
        </tr>
      {% else %}
        <tr><td colspan="3" class="muted">No keys yet</td></tr>
      {% endfor %}
      </tbody>
    </table>
  </div>

  <div class="card">
    <h2>Credit history</h2>
    <table>
      <thead><tr><th>when</th><th>delta</th><th>balance</th><th>reason</th></tr></thead>
      <tbody>
      {% for e in ledger %}
        <tr>
          <td class="muted">{{ e.created_at|int }}</td>
          <td>{{ e.delta }}¢</td>
          <td>{{ e.balance_after }}¢</td>
          <td>{{ e.reason }}</td>
        </tr>
      {% else %}
        <tr><td colspan="4" class="muted">No transactions</td></tr>
      {% endfor %}
      </tbody>
    </table>
  </div>
</div>
<script>
async function topup(cents){
  const r = await fetch("/api/credits/dummy-topup", {
    method:"POST", headers:{"Content-Type":"application/json"},
    credentials:"same-origin",
    body: JSON.stringify({cents})
  });
  if(r.ok){
    const d = await r.json();
    if(typeof d.credits === "number" && window.updateCreditsDisplay){
      window.updateCreditsDisplay(d.credits);
    }
    // Prepend a ledger row hint without full reload
    const flash = document.getElementById("topupFlash");
    if(flash){
      flash.style.display = "block";
      flash.textContent = "Added " + cents + "¢ · balance " + d.credits + "¢";
    }
  } else {
    alert((await r.json().catch(()=>({}))).detail || "top-up failed");
  }
}
document.getElementById("btnAdd100").onclick = () => topup(100);
document.getElementById("btnAdd500").onclick = () => topup(500);
document.getElementById("btnAdd1000").onclick = () => topup(1000);

document.getElementById("btnNewKey").onclick = async () => {
  const name = document.getElementById("keyName").value || "default";
  const r = await fetch("/api/keys", {
    method:"POST", headers:{"Content-Type":"application/json"},
    body: JSON.stringify({name})
  });
  const d = await r.json().catch(()=>({}));
  if(!r.ok){ alert(d.detail || "failed"); return; }
  const el = document.getElementById("keyFlash");
  el.style.display = "block";
  el.textContent = "Copy now (shown once): " + d.key;
  setTimeout(() => location.reload(), 8000);
};
document.querySelectorAll("[data-revoke]").forEach(btn => {
  btn.onclick = async () => {
    if(!confirm("Revoke this key?")) return;
    await fetch("/api/keys/" + btn.dataset.revoke, {method:"DELETE"});
    location.reload();
  };
});
</script>
</body>
</html>
HTML

cat > templates/home.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="format-detection" content="telephone=no">
<!-- ═══════════════════════════════════════════════════════════
     PRIMARY SEO
     ═══════════════════════════════════════════════════════════ -->
<title>Cloud Android Compiler API — Send Kotlin, Get a Running App | clawtank</title>
<meta name="description" content="clawtank is a cloud Android compiler API. POST Kotlin and XML source — get a compiled APK running on a pooled emulator, plus screenshots, logcat, and a live stream.">
<meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1">
<meta name="googlebot" content="index, follow, max-snippet:-1, max-image-preview:large">
<link rel="canonical" href="https://clawtank.app/">
<link rel="sitemap" type="application/xml" title="Sitemap" href="/sitemap.xml">
<!-- ═══════════════════════════════════════════════════════════
     THEME / PWA
     ═══════════════════════════════════════════════════════════ -->
<meta name="theme-color" content="#0b0d10">
<meta name="color-scheme" content="dark">
<link rel="icon" type="image/svg+xml" href="/static/favicon.svg">
<link rel="apple-touch-icon" sizes="180x180" href="/static/apple-touch-icon.png">
<link rel="manifest" href="/static/manifest.webmanifest">
<!-- ═══════════════════════════════════════════════════════════
     OPEN GRAPH
     ═══════════════════════════════════════════════════════════ -->
<meta property="og:type" content="website">
<meta property="og:site_name" content="clawtank">
<meta property="og:locale" content="en_US">
<meta property="og:title" content="clawtank — Cloud Android Compiler API">
<meta property="og:description" content="POST Kotlin and XML. Get a compiled APK running on a cloud emulator with screenshots, logcat, and a live WebSocket stream back.">
<meta property="og:url" content="https://clawtank.app/">
<meta property="og:image" content="https://clawtank.app/static/og-image.png">
<meta property="og:image:secure_url" content="https://clawtank.app/static/og-image.png">
<meta property="og:image:type" content="image/png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="clawtank — cloud Android compiler API">
<!-- ═══════════════════════════════════════════════════════════
     TWITTER / X
     ═══════════════════════════════════════════════════════════ -->
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="clawtank — Cloud Android Compiler API">
<meta name="twitter:description" content="POST Kotlin and XML. Get a running Android app back — screenshots, logcat, live stream.">
<meta name="twitter:image" content="https://clawtank.app/static/og-image.png">
<meta name="twitter:image:alt" content="clawtank — cloud Android compiler API">
<!-- ═══════════════════════════════════════════════════════════
     FONTS
     ═══════════════════════════════════════════════════════════ -->
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
<!-- ═══════════════════════════════════════════════════════════
     STRUCTURED DATA
     Organization · WebSite · WebPage · SoftwareApplication
     · FAQPage · HowTo
     ═══════════════════════════════════════════════════════════ -->
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "Organization",
      "@id": "https://clawtank.app/#org",
      "name": "clawtank",
      "url": "https://clawtank.app/",
      "logo": {
        "@type": "ImageObject",
        "@id": "https://clawtank.app/#logo",
        "url": "https://clawtank.app/static/apple-touch-icon.png",
        "width": 180,
        "height": 180
      },
      "image": { "@id": "https://clawtank.app/#logo" },
      "description": "Cloud Android compiler API. Compiles Kotlin and XML, runs the APK on a pooled emulator, and returns screenshots, logcat, and a live stream."
    },
    {
      "@type": "WebSite",
      "@id": "https://clawtank.app/#site",
      "url": "https://clawtank.app/",
      "name": "clawtank",
      "publisher": { "@id": "https://clawtank.app/#org" },
      "inLanguage": "en"
    },
    {
      "@type": "WebPage",
      "@id": "https://clawtank.app/#page",
      "url": "https://clawtank.app/",
      "name": "clawtank — Cloud Android Compiler API",
      "isPartOf": { "@id": "https://clawtank.app/#site" },
      "about": { "@id": "https://clawtank.app/#app" },
      "primaryImageOfPage": {
        "@type": "ImageObject",
        "url": "https://clawtank.app/static/og-image.png",
        "width": 1200,
        "height": 630
      },
      "speakable": {
        "@type": "SpeakableSpecification",
        "cssSelector": [".hero-lede", "#faq"]
      },
      "inLanguage": "en"
    },
    {
      "@type": "SoftwareApplication",
      "@id": "https://clawtank.app/#app",
      "name": "clawtank",
      "applicationCategory": "DeveloperApplication",
      "applicationSubCategory": "Android Build Tool",
      "operatingSystem": "Web, Linux, macOS, Windows",
      "softwareVersion": "1.0",
      "description": "Cloud Android compiler API that compiles Kotlin and XML, installs the APK on a pooled emulator, and returns screenshots, logcat, and a live WebSocket stream.",
      "url": "https://clawtank.app/",
      "publisher": { "@id": "https://clawtank.app/#org" },
      "offers": {
        "@type": "Offer",
        "price": "0.05",
        "priceCurrency": "USD",
        "description": "Per successful build. Failed compiles are refunded."
      },
      "featureList": [
        "Cloud Android APK compilation",
        "Pooled Android emulator",
        "Live WebSocket screen stream",
        "Automated screenshots",
        "Remote logcat capture",
        "Programmatic build API",
        "Kotlin and XML source input"
      ]
    },
    {
      "@type": "FAQPage",
      "@id": "https://clawtank.app/#faq",
      "mainEntity": [
        {
          "@type": "Question",
          "name": "How do I compile an Android app in the cloud without installing an SDK?",
          "acceptedAnswer": {
            "@type": "Answer",
            "text": "Send your Kotlin and XML source to clawtank's POST /v1/build endpoint. The service compiles the APK on managed infrastructure, installs it on a pooled Android emulator, launches it, and returns screenshots, logcat, and a live WebSocket stream. No Android SDK, no Gradle, and no local emulator are required."
          }
        },
        {
          "@type": "Question",
          "name": "Is there an API for compiling and running Android apps programmatically?",
          "acceptedAnswer": {
            "@type": "Answer",
            "text": "Yes. clawtank exposes a single HTTP endpoint, POST /v1/build, that accepts a JSON bundle of Kotlin and XML source files and returns a compiled, running Android app with screenshots and logcat. It is designed for CI pipelines, autonomous agents, and test automation."
          }
        },
        {
          "@type": "Question",
          "name": "Can I run Android builds in CI/CD without a device farm?",
          "acceptedAnswer": {
            "@type": "Answer",
            "text": "Yes. clawtank replaces dedicated Android build runners and self-hosted emulator farms with one HTTPS endpoint. Your pipeline POSTs source files and receives a running app, screenshots, and logcat back in a single response."
          }
        },
        {
          "@type": "Question",
          "name": "How do I get screenshots and logcat from a remote Android emulator?",
          "acceptedAnswer": {
            "@type": "Answer",
            "text": "clawtank returns three PNG screenshots taken at t+2s, t+3s, and t+4s after launch, plus up to 200 lines of logcat attributed to the app process. Both are included in the JSON response from POST /v1/build, no extra calls needed."
          }
        },
        {
          "@type": "Question",
          "name": "Can AI agents use clawtank to compile and test Android apps?",
          "acceptedAnswer": {
            "@type": "Answer",
            "text": "Yes. clawtank's API is designed for machine consumption. Agents can POST source files, receive screenshots and logcat as structured data, and iterate in a closed feedback loop. Every response is deterministic JSON with no browser or UI requirement."
          }
        },
        {
          "@type": "Question",
          "name": "Is clawtank free to use?",
          "acceptedAnswer": {
            "@type": "Answer",
            "text": "The clawtank studio is free to use in a browser with no signup. Programmatic API access costs $0.05 per successful build, and failed compiles are refunded automatically. There is no subscription and no minimum commit."
          }
        }
      ]
    },
    {
      "@type": "HowTo",
      "@id": "https://clawtank.app/#howto",
      "name": "How to compile an Android app in the cloud",
      "description": "Compile Kotlin and XML source into a running Android app on a pooled emulator without installing an SDK.",
      "totalTime": "PT1M",
      "tool": [
        { "@type": "HowToTool", "name": "clawtank API" }
      ],
      "step": [
        {
          "@type": "HowToStep",
          "position": 1,
          "name": "Send source",
          "text": "POST a JSON bundle of Kotlin and XML files to /v1/build."
        },
        {
          "@type": "HowToStep",
          "position": 2,
          "name": "Wait for the build",
          "text": "clawtank compiles the APK on managed infrastructure — no SDK, no local Gradle."
        },
        {
          "@type": "HowToStep",
          "position": 3,
          "name": "Get the results",
          "text": "Receive screenshots, logcat, and a live WebSocket URL in the JSON response."
        }
      ]
    }
  ]
}
</script>
<style>
  :root{
    --bg:#0b0d10;
    --panel:#0e1116;
    --panel-2:#141821;
    --border:#1e232c;
    --border-hi:#2a3140;
    --text:#e8eaed;
    --muted:#7b8494;
    --dim:#545c6b;
    --accent:#ff6b00;
    --accent-soft:rgba(255,107,0,.1);
    --green:#3dd68c;
    --amber:#febc2e;
    --blue:#6ea8ff;
    --font:"Inter",system-ui,sans-serif;
    --mono:"JetBrains Mono",ui-monospace,monospace;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{height:100%}
  body{
    font-family:var(--font);
    background:var(--bg);
    color:var(--text);
    -webkit-font-smoothing:antialiased;
    font-size:15px;
    line-height:1.65;
  }
  a{color:inherit;text-decoration:none}
  .page{
    max-width:860px;
    margin:0 auto;
    padding:48px 32px 64px;
    min-height:100vh;
    display:flex;
    flex-direction:column;
  }
  header{margin-bottom:80px}
  .hero{margin-bottom:56px}
  .hero-kicker{
    display:flex;
    align-items:center;
    gap:10px;
    font-family:var(--mono);
    font-size:11.5px;
    letter-spacing:.16em;
    text-transform:uppercase;
    color:var(--accent);
    margin-bottom:22px;
  }
  .hero-kicker .dash{
    width:28px;height:1px;background:var(--accent);display:inline-block;
  }
  .hero h1{
    font-size:44px;
    font-weight:600;
    line-height:1.1;
    letter-spacing:-.03em;
    color:var(--text);
    margin-bottom:24px;
    max-width:680px;
  }
  .hero h1 .line-1{display:block;color:var(--text)}
  .hero h1 .line-2{display:block;color:var(--muted)}
  .hero h1 .line-3{display:block;color:var(--text);margin-top:6px}
  .hero h1 .grab{color:var(--accent)}
  .hero-rule{
    display:flex;
    align-items:center;
    gap:6px;
    margin-bottom:26px;
    max-width:640px;
  }
  .hero-rule .tick{
    height:1px;flex:0 0 36px;background:var(--accent);opacity:.35;
  }
  .hero-rule .tick:nth-child(2){opacity:.55}
  .hero-rule .tick:nth-child(3){opacity:.75}
  .hero-rule .tick:nth-child(4){opacity:.9}
  .hero-rule .tick:nth-child(5){opacity:1}
  .hero-rule .label{
    margin-left:12px;
    font-family:var(--mono);
    font-size:11px;
    letter-spacing:.14em;
    text-transform:uppercase;
    color:var(--dim);
    white-space:nowrap;
  }
  .hero-lede{
    color:var(--muted);
    max-width:620px;
    font-size:15.5px;
    line-height:1.7;
    margin-bottom:30px;
  }
  .hero-lede strong{color:var(--text);font-weight:500}
  .actions{display:flex;gap:12px;flex-wrap:wrap}
  .btn{
    display:inline-flex;
    align-items:center;
    gap:8px;
    padding:9px 16px;
    border-radius:7px;
    font-size:13.5px;
    font-weight:500;
    border:1px solid transparent;
    transition:background .15s,border-color .15s,color .15s,transform .15s;
  }
  .btn.primary{background:var(--text);color:#0b0d10}
  .btn.primary:hover{background:#fff;transform:translateY(-1px)}
  .btn.ghost{border-color:var(--border);color:var(--muted)}
  .btn.ghost:hover{border-color:var(--border-hi);color:var(--text)}
  .btn .arr{font-family:var(--mono);opacity:.6;transition:transform .15s}
  .btn:hover .arr{transform:translateX(2px)}
  .showcase{
    display:grid;
    grid-template-columns:minmax(0,1fr) 220px;
    gap:36px;
    align-items:start;
    margin-bottom:80px;
  }
  .showcase > .term{grid-column:1}
  .showcase > .phone-wrap{grid-column:2}
  .showcase > figcaption{
    grid-column:1 / -1;
    font-family:var(--mono);
    font-size:11.5px;
    color:var(--dim);
    text-align:center;
    letter-spacing:.04em;
    margin-top:-20px;
  }
  .showcase figure{display:contents;margin:0}
  .term{
    border:1px solid var(--border);
    border-radius:10px;
    background:var(--panel);
    overflow:hidden;
    min-width:0;
  }
  .term-head{
    display:flex;align-items:center;gap:7px;
    padding:11px 14px;
    border-bottom:1px solid var(--border);
  }
  .term-head .dot{width:11px;height:11px;border-radius:50%;flex-shrink:0}
  .dot.r{background:#ff5f57}
  .dot.y{background:#febc2e}
  .dot.g{background:#28c840}
  .term-head .title{
    margin-left:8px;
    font-family:var(--mono);
    font-size:11px;
    color:var(--dim);
    letter-spacing:.04em;
  }
  .term pre{
    margin:0;
    padding:18px 20px;
    font-family:var(--mono);
    font-size:12px;
    line-height:1.75;
    color:#c8d0dd;
    overflow-x:auto;
    white-space:pre;
  }
  .c{color:var(--dim);font-style:italic}
  .k{color:#e8eaed}
  .s{color:var(--green)}
  .p{color:var(--dim)}
  .u{color:var(--blue)}
  .ok{color:var(--green);font-weight:500}
  .warn{color:var(--amber);font-weight:500}
  .key{color:#c586c0}
  .phone-wrap{
    display:flex;
    flex-direction:column;
    align-items:center;
    gap:14px;
    justify-self:end;
  }
  .phone{
    position:relative;
    width:220px;
    aspect-ratio:220/460;
    padding:4px;
    border-radius:34px;
    background:linear-gradient(160deg,
      #f8f7f4 0%,#d6d2c8 14%,#b8b3a7 45%,
      #a09a8d 62%,#cfcabe 86%,#f0eee9 100%);
    box-shadow:
      0 0 0 1.5px #8a8377,
      0 0 0 3px #b8b3a7,
      0 16px 32px rgba(0,0,0,.5);
    flex-shrink:0;
  }
  .bezel{
    position:relative;width:100%;height:100%;
    border-radius:30px;background:#08060a;padding:9px;
  }
  .island{
    position:absolute;top:14px;left:50%;transform:translateX(-50%);
    width:60px;height:18px;background:#000;border-radius:999px;z-index:10;
  }
  .island::after{
    content:"";position:absolute;top:50%;right:11px;transform:translateY(-50%);
    width:6px;height:6px;border-radius:50%;background:#04040a;
  }
  .screen{
    position:relative;width:100%;height:100%;
    border-radius:22px;background:#0a0d12;overflow:hidden;
  }
  .scene{
    position:absolute;inset:0;
    padding:44px 20px 40px;
    font-family:var(--mono);
    color:var(--text);
    opacity:0;
    transition:opacity .5s ease;
    pointer-events:none;
    display:flex;
    flex-direction:column;
    align-items:center;
    justify-content:center;
    text-align:center;
    gap:16px;
  }
  .scene.active{opacity:1}
  .s-step{
    font-size:10px;
    letter-spacing:.24em;
    color:var(--dim);
    text-transform:uppercase;
  }
  .s-icon{
    width:52px;
    height:52px;
    border-radius:50%;
    border:2px solid var(--border);
    display:flex;
    align-items:center;
    justify-content:center;
    font-size:22px;
    line-height:1;
    color:var(--muted);
    flex-shrink:0;
  }
  .s-icon.spin{
    border-color:rgba(254,188,46,.35);
    border-top-color:var(--amber);
    color:transparent;
    animation:spin 1s linear infinite;
  }
  .s-icon.ok{
    border-color:rgba(61,214,140,.5);
    color:var(--green);
    font-size:26px;
    font-weight:600;
  }
  @keyframes spin{to{transform:rotate(360deg)}}
  .s-title{
    font-size:26px;
    font-weight:600;
    letter-spacing:.02em;
    line-height:1.05;
    color:var(--text);
  }
  .s-title.amber{color:var(--amber)}
  .s-title.green{color:var(--green)}
  .s-detail{
    font-size:12.5px;
    color:var(--muted);
    line-height:1.5;
    max-width:170px;
  }
  .s-caption{
    position:absolute;
    bottom:22px;
    left:0;
    right:0;
    text-align:center;
    font-size:9.5px;
    letter-spacing:.08em;
    color:var(--dim);
    text-transform:lowercase;
  }
  .progress{display:flex;gap:6px}
  .progress span{
    width:28px;height:2px;background:#1e232c;border-radius:2px;
    transition:background .3s;
  }
  .progress span.active{background:var(--accent)}
  section{margin-bottom:64px}
  section h2{
    font-size:22px;
    font-weight:600;
    color:var(--text);
    letter-spacing:-.02em;
    margin-bottom:10px;
    line-height:1.3;
  }
  section h2 .num{
    font-family:var(--mono);
    font-size:12px;
    color:var(--dim);
    font-weight:400;
    margin-right:10px;
    letter-spacing:.06em;
  }
  .section-sub{
    color:var(--muted);
    font-size:14.5px;
    margin-bottom:26px;
    max-width:600px;
    line-height:1.7;
  }
  .section-sub strong{color:var(--text);font-weight:500}
  .rows{border-top:1px solid var(--border)}
  .row{
    display:grid;
    grid-template-columns:120px 1fr;
    gap:24px;
    padding:18px 0;
    border-bottom:1px solid var(--border);
    align-items:baseline;
  }
  .row dt{
    font-size:12.5px;
    color:var(--dim);
    font-family:var(--mono);
    letter-spacing:.02em;
  }
  .row dd{font-size:14px;color:var(--text);line-height:1.6}
  .row dd small{
    display:block;
    color:var(--muted);
    font-size:13px;
    margin-top:5px;
    line-height:1.65;
  }
  .row dd code{
    font-family:var(--mono);
    font-size:12.5px;
    color:var(--text);
    background:var(--panel-2);
    padding:1px 6px;
    border-radius:4px;
    border:1px solid var(--border);
  }
  .use-cases{
    list-style:none;
    display:grid;
    grid-template-columns:repeat(2,1fr);
    gap:14px;
  }
  .use-case{
    border:1px solid var(--border);
    background:var(--panel);
    border-radius:10px;
    padding:18px 20px;
    transition:border-color .2s;
  }
  .use-case:hover{border-color:var(--border-hi)}
  .use-case h3{
    font-size:14px;
    font-weight:600;
    color:var(--text);
    margin-bottom:6px;
  }
  .use-case p{font-size:13px;color:var(--muted);line-height:1.6}
  .faq{display:flex;flex-direction:column;gap:0;border-top:1px solid var(--border)}
  .faq details{
    border-bottom:1px solid var(--border);
    padding:0;
  }
  .faq summary{
    list-style:none;
    cursor:pointer;
    padding:18px 0;
    display:flex;
    align-items:flex-start;
    gap:14px;
    font-size:15px;
    font-weight:600;
    color:var(--text);
    letter-spacing:-.01em;
    line-height:1.4;
  }
  .faq summary::-webkit-details-marker{display:none}
  .faq summary::before{
    content:"+";
    font-family:var(--mono);
    font-size:14px;
    color:var(--accent);
    flex:0 0 auto;
    width:14px;
    display:inline-block;
    transition:transform .2s;
  }
  .faq details[open] summary::before{content:"–"}
  .faq summary:hover{color:var(--accent)}
  .faq .faq-a{
    padding:0 0 20px 28px;
    color:var(--muted);
    font-size:14px;
    line-height:1.7;
    max-width:640px;
  }
  .faq .faq-a strong{color:var(--text);font-weight:500}
  .faq .faq-a code{
    font-family:var(--mono);
    font-size:12.5px;
    color:var(--text);
    background:var(--panel-2);
    padding:1px 6px;
    border-radius:4px;
    border:1px solid var(--border);
  }
  .cta{
    border:1px solid var(--border);
    border-radius:14px;
    padding:32px 30px;
    background:
      radial-gradient(500px 200px at 15% 0%, rgba(255,107,0,.08), transparent 70%),
      var(--panel);
    display:flex;
    justify-content:space-between;
    align-items:center;
    gap:24px;
    flex-wrap:wrap;
  }
  .cta h2{margin-bottom:6px}
  .cta p{color:var(--muted);font-size:14px;max-width:460px;line-height:1.6}
  footer{
    margin-top:auto;
    padding-top:32px;
    border-top:1px solid var(--border);
    display:flex;
    justify-content:space-between;
    align-items:center;
    font-size:12.5px;
    color:var(--dim);
    font-family:var(--mono);
    flex-wrap:wrap;
    gap:14px;
  }
  footer .links{display:flex;gap:20px}
  footer a{transition:color .15s}
  footer a:hover{color:var(--muted)}
  .js .reveal{
    opacity:0;
    filter:blur(16px);
    transform:translateY(30px) scale(.985);
    transition:
      opacity .9s cubic-bezier(.22,.68,.28,1),
      filter .9s cubic-bezier(.22,.68,.28,1),
      transform .9s cubic-bezier(.22,.68,.28,1);
    transition-delay:var(--d,0ms);
  }
  .js .reveal.is-in{
    opacity:1;
    filter:blur(0);
    transform:none;
  }
  @keyframes riseIn{
    to{opacity:1;transform:none;filter:blur(0)}
  }
  .js .hero > *{
    opacity:0;
    transform:translateY(16px);
    filter:blur(10px);
    animation:riseIn .95s cubic-bezier(.22,.68,.28,1) forwards;
  }
  .js .hero > .hero-kicker{animation-delay:.05s}
  .js .hero > h1{animation-delay:.13s}
  .js .hero > .hero-rule{animation-delay:.22s}
  .js .hero > .hero-lede{animation-delay:.30s}
  .js .hero > .actions{animation-delay:.38s}
  .js .ct-nav{
    opacity:0;
    animation:riseIn .7s cubic-bezier(.22,.68,.28,1) .02s forwards;
  }
  @media(max-width:720px){
    .showcase{grid-template-columns:1fr;gap:32px}
    .showcase > .term{grid-column:1}
    .showcase > .phone-wrap{grid-column:1;justify-self:center}
    .showcase > figcaption{margin-top:0}
    .use-cases{grid-template-columns:1fr}
  }
  @media(max-width:600px){
    .page{padding:32px 20px 48px}
    header{margin-bottom:48px}
    .hero h1{font-size:30px}
    .hero-rule .tick{flex-basis:20px}
    .hero-rule .label{display:none}
    .hero{margin-bottom:40px}
    .showcase{margin-bottom:56px}
    .row{grid-template-columns:1fr;gap:4px;padding:14px 0}
    .cta{padding:24px 22px;flex-direction:column;align-items:flex-start}
    footer{flex-direction:column;align-items:flex-start}
  }
  @media(prefers-reduced-motion:reduce){
    *{animation-duration:.001ms !important;transition-duration:.001ms !important}
  }
</style>
</head>
<body>
<div class="page">
  <header class="ct-nav">
    <style>
      .ct-nav{
        border-bottom:1px solid var(--border,#1e232c);
        font-family:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
      }
      .ct-nav__inner{
        display:flex;align-items:center;justify-content:space-between;
        gap:16px;padding:12px 20px;
      }
      .ct-nav__left{display:flex;align-items:center;gap:26px;min-width:0}
      .ct-nav__brand{
        display:inline-flex;align-items:center;gap:9px;
        font-family:"Inter",system-ui,-apple-system,"Segoe UI",sans-serif;
        font-size:1.05rem;font-weight:700;letter-spacing:-.01em;
        color:var(--text,#e8eaed);text-decoration:none;white-space:nowrap;
      }
      .ct-nav__brand .brand-word span{color:var(--accent,#ff6b00)}
      .brand-mark{
        width:22px;height:22px;flex:0 0 auto;display:block;
        color:var(--accent,#ff6b00);
      }
      .brand-mark svg{width:100%;height:100%;display:block}
      @keyframes markSwap{
        from{opacity:0;transform:scale(.6) rotate(-14deg);filter:blur(5px)}
        to{opacity:1;transform:none;filter:blur(0)}
      }
      .brand-mark.swap{animation:markSwap .55s cubic-bezier(.22,.68,.28,1)}
      .ct-nav__links{display:flex;gap:22px}
      .ct-nav__link{
        font-size:.82rem;font-weight:500;letter-spacing:-.01em;
        color:var(--muted,#8b93a7);text-decoration:none;
        transition:color .15s;padding:2px 0;
      }
      .ct-nav__link:hover{color:var(--text,#e8eaed)}
      .ct-nav__link[aria-current="page"]{color:var(--text,#e8eaed)}
      .ct-nav__link[aria-current="page"]::before{
        content:"\203A";color:var(--accent,#ff6b00);margin-right:6px;opacity:.9;
      }
      .ct-nav__extra{display:flex;align-items:center;gap:8px;min-width:0}
    </style>
    <div class="ct-nav__inner">
      <div class="ct-nav__left">
        <a class="ct-nav__brand" href="/" aria-label="clawtank home">
          <span class="brand-mark swap" id="brand-mark" aria-hidden="true"></span>
          <span class="brand-word">claw<span>tank</span></span>
        </a>
        <nav class="ct-nav__links" aria-label="Primary">
          <a class="ct-nav__link" href="/" aria-current="page">home</a>
          <a class="ct-nav__link" href="/studio">studio</a>
          <a class="ct-nav__link" href="/api/docs">api</a>
        </nav>
      </div>
      <div class="ct-nav__extra" style="display:flex;gap:14px;align-items:center">
        {% if user %}
          <a class="ct-nav__link" href="/account">
            <span class="ct-nav__user-name">{{ user.display_name }}</span>
            · <span class="ct-nav__credits" id="navCredits" data-credits="{{ user.credits }}">{{ user.credits }}¢</span>
          </a>
          <form action="/logout" method="post" style="display:inline;margin:0">
            <button type="submit" class="ct-nav__link" style="background:none;border:none;cursor:pointer;font:inherit;color:inherit;padding:2px 0">logout</button>
          </form>
        {% else %}
          <a class="ct-nav__link" href="/login">login</a>
          <a class="ct-nav__link" href="/register">create</a>
        {% endif %}
      </div>
    </div>
  </header>
  <main>
    <section class="hero">
      <div class="hero-kicker">
        <span class="dash"></span>
        <span>cloud android compiler api</span>
      </div>
      <h1>
        <span class="line-1">Send Android Code.</span>
        <span class="line-2">Get a running app in cloud.</span>
        <span class="line-3"><span class="grab">No SDK. No setup.</span></span>
      </h1>
      <div class="hero-rule">
        <span class="tick"></span>
        <span class="tick"></span>
        <span class="tick"></span>
        <span class="tick"></span>
        <span class="tick"></span>
        <span class="label">send · build · run · grab</span>
      </div>
      <p class="hero-lede">
        <strong>clawtank is a cloud Android compiler API.</strong>
        POST your Kotlin and XML source. It compiles the APK on managed
        infrastructure, installs it on a pooled Android emulator, and
        returns the running app, three screenshots, logcat, and a live
        WebSocket stream — all in a single HTTP request. No local
        toolchain. No device farm.
      </p>
      <div class="actions">
        <a href="/studio" class="btn primary">Open the studio <span class="arr">→</span></a>
        <a href="/api/docs" class="btn ghost">Read the API <span class="arr">→</span></a>
      </div>
    </section>
    <section class="showcase">
      <figure>
        <div class="term">
          <div class="term-head">
            <span class="dot r"></span>
            <span class="dot y"></span>
            <span class="dot g"></span>
            <span class="title">clawtank — one request, one running app</span>
          </div>
<pre><span class="c"># send source to the cloud</span>
<span class="k">$</span> curl -X POST <span class="u">https://clawtank.app/v1/build</span> \
    -H <span class="s">"Content-Type: application/json"</span> \
    -d <span class="s">'{"files":{"MainActivity.kt":"…"}}'</span>
<span class="c"># → compiled · installed · launched</span>
<span class="p">{</span>
  <span class="key">"status"</span><span class="p">:</span>       <span class="s">"ok"</span><span class="p">,</span>
  <span class="key">"device"</span><span class="p">:</span>       <span class="s">"emulator-5554"</span><span class="p">,</span>
  <span class="key">"platform"</span><span class="p">:</span>     <span class="s">"android-34"</span><span class="p">,</span>
  <span class="key">"build_ms"</span><span class="p">:</span>     <span class="warn">41203</span><span class="p">,</span>
  <span class="key">"screenshots"</span><span class="p">: [</span>
    <span class="s">"…/s1.png"</span><span class="p">,</span> <span class="s">"…/s2.png"</span><span class="p">,</span> <span class="s">"…/s3.png"</span>
  <span class="p">],</span>
  <span class="key">"logcat"</span><span class="p">:</span>      <span class="s">"…"</span><span class="p">,</span>
  <span class="key">"stream"</span><span class="p">:</span>      <span class="s">"wss://clawtank.app/ws/stream"</span>
<span class="p">}</span></pre>
        </div>
      </figure>
      <div class="phone-wrap">
        <div class="phone">
          <div class="bezel">
            <div class="island"></div>
            <div class="screen">
              <div class="scene active" data-scene="send">
                <div class="s-step">Step 01</div>
                <div class="s-icon">→</div>
                <div class="s-title">SEND</div>
                <div class="s-detail">POST /v1/build</div>
                <div class="s-caption">kotlin + xml → cloud</div>
              </div>
              <div class="scene" data-scene="build">
                <div class="s-step">Step 02</div>
                <div class="s-icon spin"></div>
                <div class="s-title amber">BUILD</div>
                <div class="s-detail">compiling APK…</div>
                <div class="s-caption">gradle · kotlin 2.0</div>
              </div>
              <div class="scene" data-scene="run">
                <div class="s-step">Step 03</div>
                <div class="s-icon ok">✓</div>
                <div class="s-title green">RUN</div>
                <div class="s-detail">live on emulator</div>
                <div class="s-caption">shots · logcat · stream</div>
              </div>
            </div>
          </div>
        </div>
        <div class="progress">
          <span class="active"></span><span></span><span></span>
        </div>
      </div>
    </section>
    <section>
      <h2><span class="num">01 /</span>How it works</h2>
      <p class="section-sub">
        Four steps from a folder of source files to a running app you can
        see and touch.
      </p>
      <dl class="rows">
        <div class="row">
          <dt>SEND</dt>
          <dd>POST a JSON bundle of Kotlin sources and XML resources.
            <small>Every file is validated, then written into a fresh Gradle project. No prior workspace, no session state.</small>
          </dd>
        </div>
        <div class="row">
          <dt>BUILD</dt>
          <dd>clawtank compiles the APK on managed infrastructure.
            <small>Kotlin 2.0.21, Gradle 8.9, Android API 34. Your machine only sends files — the heavy lifting happens in the cloud.</small>
          </dd>
        </div>
        <div class="row">
          <dt>RUN</dt>
          <dd>The APK is installed on a pooled Android emulator and launched.
            <small>A virtual device is spun up on demand, the app is installed, and the emulator waits for it to reach a stable state.</small>
          </dd>
        </div>
        <div class="row">
          <dt>GRAB</dt>
          <dd>You get back a live screen stream, three screenshots, logcat, and timing.
            <small>Everything you need to see what the app did — in a single response, ready for a pipeline or an agent to read.</small>
          </dd>
        </div>
      </dl>
    </section>
    <section>
      <h2><span class="num">02 /</span>What you pull out</h2>
      <p class="section-sub">
        Every successful run returns the same structured payload — designed
        for machines to read and humans to skim.
      </p>
      <dl class="rows">
        <div class="row">
          <dt>live screen</dt>
          <dd>A WebSocket stream of the running emulator.
            <small>Tap, swipe, type — drive the app from your browser exactly like a real device. Sessions are time-boxed and pooled fairly.</small>
          </dd>
        </div>
        <div class="row">
          <dt>screenshots</dt>
          <dd>Three PNGs captured at t+2s, t+3s, and t+4s after launch.
            <small>Signed, short-lived URLs at native emulator resolution. Perfect for visual diffs, agent feedback loops, or just proving the app rendered.</small>
          </dd>
        </div>
        <div class="row">
          <dt>logcat</dt>
          <dd>The app process's full log stream, capped at 200 lines.
            <small>Enough to catch crashes, intent filters, ANRs, and your own debug prints. Attributed to the correct PID.</small>
          </dd>
        </div>
        <div class="row">
          <dt>timing</dt>
          <dd>Total wall-clock for the whole pipeline, in milliseconds.
            <small>Returned as <code>build_ms</code> so pipelines and agents can budget, retry, or escalate on slow runs.</small>
          </dd>
        </div>
      </dl>
    </section>
    <section>
      <h2><span class="num">03 /</span>Who grabs from clawtank</h2>
      <p class="section-sub">
        Anywhere you need a real Android app running somewhere you don't
        want to own.
      </p>
      <ul class="use-cases">
        <li class="use-case">
          <h3>Developers prototyping</h3>
          <p>Write Kotlin in your browser, hit BUILD &amp; RUN, and watch your idea come to life on an emulator. No SDK install, no Gradle bootstrap, no AVD image download.</p>
        </li>
        <li class="use-case">
          <h3>AI agents &amp; autonomous workflows</h3>
          <p>Let agents write source, ship it to clawtank, and read screenshots + logcat back as part of a closed feedback loop. Fully machine-readable responses.</p>
        </li>
        <li class="use-case">
          <h3>CI/CD pipelines</h3>
          <p>Replace dedicated Android build runners and self-hosted emulator farms with a single HTTP endpoint that returns artifacts and logs.</p>
        </li>
        <li class="use-case">
          <h3>Mobile QA automation</h3>
          <p>Trigger real Android builds from test frameworks and assert on real screenshots and logcat — instead of mocking a device or faking a renderer.</p>
        </li>
      </ul>
    </section>
    <section>
      <h2><span class="num">04 /</span>Pricing</h2>
      <p class="section-sub">
        Pay only for successful runs. No subscription, no seats, no minimum
        commit.
      </p>
      <dl class="rows">
        <div class="row">
          <dt>per run</dt>
          <dd>$0.05 <span style="color:var(--muted);font-size:13px">· only when the build succeeds</span>
            <small>Failed compiles are refunded automatically. You never pay for a build that didn't return artifacts.</small>
          </dd>
        </div>
        <div class="row">
          <dt>included</dt>
          <dd>Cloud build · pooled emulator · install · launch · live stream · 3 screenshots · logcat · timing</dd>
        </div>
        <div class="row">
          <dt>access</dt>
          <dd>No API key. No signup. No rate limit.
            <small>Humans use the same pipeline through the browser studio at <a href="/studio" style="color:var(--accent)">/studio</a>.</small>
          </dd>
        </div>
      </dl>
    </section>
    <section id="faq">
      <h2><span class="num">05 /</span>FAQ</h2>
      <p class="section-sub">
        Quick answers to the questions we get most.
      </p>
      <div class="faq">
        <details open>
          <summary>How do I compile an Android app in the cloud without installing an SDK?</summary>
          <div class="faq-a">
            Send your Kotlin and XML source to clawtank's <code>POST /v1/build</code>
            endpoint. The service compiles the APK on managed infrastructure,
            installs it on a pooled Android emulator, launches it, and returns
            screenshots, logcat, and a live WebSocket stream. No Android SDK,
            no Gradle, and no local emulator are required on your machine.
          </div>
        </details>
        <details>
          <summary>Is there an API for compiling and running Android apps programmatically?</summary>
          <div class="faq-a">
            Yes. clawtank exposes a single HTTP endpoint, <code>POST /v1/build</code>,
            that accepts a JSON bundle of Kotlin and XML source files and returns a
            compiled, running Android app with screenshots and logcat. It is
            designed for CI pipelines, autonomous agents, and test automation.
          </div>
        </details>
        <details>
          <summary>Can I run Android builds in CI/CD without a device farm?</summary>
          <div class="faq-a">
            Yes. clawtank replaces dedicated Android build runners and self-hosted
            emulator farms with one HTTPS endpoint. Your pipeline POSTs source
            files and receives a running app, screenshots, and logcat back in a
            single response — no shared runners, no AVD images, no maintenance.
          </div>
        </details>
        <details>
          <summary>How do I get screenshots and logcat from a remote Android emulator?</summary>
          <div class="faq-a">
            clawtank returns three PNG screenshots taken at t+2s, t+3s, and t+4s
            after launch, plus up to 200 lines of logcat attributed to the app
            process. Both are included in the JSON response from
            <code>POST /v1/build</code>, so no extra calls are needed.
          </div>
        </details>
        <details>
          <summary>Can AI agents use clawtank to compile and test Android apps?</summary>
          <div class="faq-a">
            Yes. clawtank's API is designed for machine consumption. Agents can
            POST source files, receive screenshots and logcat as structured data,
            and iterate in a closed feedback loop. Every response is deterministic
            JSON with no browser or UI requirement.
          </div>
        </details>
        <details>
          <summary>Is clawtank free to use?</summary>
          <div class="faq-a">
            The clawtank studio is free to use in a browser with no signup.
            Programmatic API access costs $0.05 per successful build, and failed
            compiles are refunded automatically. There is no subscription and no
            minimum commit.
          </div>
        </details>
      </div>
    </section>
    <section class="cta">
      <div>
        <h2>Try it in your browser.</h2>
        <p>The studio is a full editor with a live emulator, build log, and screenshot loot. No install, no account.</p>
      </div>
      <div class="actions">
        <a href="/studio" class="btn primary">Open the studio <span class="arr">→</span></a>
        <a href="/api/docs" class="btn ghost">Read the API <span class="arr">→</span></a>
      </div>
    </section>
  </main>
  <footer>
    <span>clawtank · v1 · © 2025</span>
    <div class="links">
      <a href="/studio">studio</a>
      <a href="/api/docs">api</a>
      <a href="/api/health">status</a>
    </div>
  </footer>
</div>
<script>
  document.documentElement.classList.add('js');
  (function(){
    const scenes = document.querySelectorAll('.scene');
    const dots   = document.querySelectorAll('.progress span');
    const DURATION = 2800;
    let i = 0;
    function show(n){
      scenes.forEach((s, k) => s.classList.toggle('active', k === n));
      dots.forEach((d, k)   => d.classList.toggle('active', k === n));
    }
    show(0);
    setInterval(() => {
      i = (i + 1) % scenes.length;
      show(i);
    }, DURATION);
  })();
  (function(){
    const SELECTOR = [
      'section:not(.cta) > h2',
      'section:not(.cta) > .section-sub',
      '.showcase .term',
      '.showcase .phone-wrap',
      '.showcase figcaption',
      '.rows .row',
      '.use-case',
      '.faq details',
      '.cta',
      'footer'
    ].join(',');
    const targets = Array.from(document.querySelectorAll(SELECTOR));
    if(!targets.length) return;
    targets.forEach(el => el.classList.add('reveal'));
    const byParent = new Map();
    targets.forEach(el => {
      const p = el.parentElement;
      if(!byParent.has(p)) byParent.set(p, []);
      byParent.get(p).push(el);
    });
    byParent.forEach(list => {
      list.forEach((el, i) => {
        el.style.setProperty('--d', Math.min(i, 8) * 70 + 'ms');
      });
    });
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if(reduce || !('IntersectionObserver' in window)){
      targets.forEach(el => el.classList.add('is-in'));
      return;
    }
    const io = new IntersectionObserver(entries => {
      entries.forEach(entry => {
        if(entry.isIntersecting){
          entry.target.classList.add('is-in');
          io.unobserve(entry.target);
        }
      });
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    targets.forEach(el => io.observe(el));
  })();
  (function(){
    const host = document.getElementById('brand-mark');
    if(!host) return;
    host.innerHTML = `
      <svg viewBox="0 0 32 32" fill="none" aria-hidden="true">
        <path d="M7.5 5C11.6 8.6 14.4 13.6 15.6 20" stroke="currentColor" stroke-width="3.4" stroke-linecap="round"/>
        <path d="M15 4.4C18.6 8.2 21.2 13.2 22.2 19" stroke="currentColor" stroke-width="3.4" stroke-linecap="round"/>
        <path d="M22.4 5C25.2 8.4 27 12.4 27.6 16.6" stroke="currentColor" stroke-width="3.4" stroke-linecap="round"/>
      </svg>`;
  })();
</script>
<script>
(function(){
  if(window.updateCreditsDisplay) return;
  function setCredits(cents){
    if(cents === undefined || cents === null || isNaN(cents)) return;
    cents = Math.max(0, parseInt(cents, 10));
    document.querySelectorAll("#navCredits, .ct-nav__credits, [data-credits-display]").forEach(function(el){
      el.textContent = cents + "¢";
      el.setAttribute("data-credits", String(cents));
    });
    window.__ctCredits = cents;
  }
  window.updateCreditsDisplay = setCredits;
  window.refreshCredits = async function(){
    try{
      var r = await fetch("/api/me", {credentials:"same-origin"});
      if(!r.ok) return null;
      var d = await r.json();
      if(typeof d.credits === "number") setCredits(d.credits);
      return d.credits;
    }catch(e){ return null; }
  };
  if(document.getElementById("navCredits")){
    setInterval(function(){ window.refreshCredits(); }, 8000);
  }
})();
</script>
</body>
</html>

HTML

# ============================================================
#  api.html — API reference (SEO-targeted, styled like home)
#
#  Targets search terms:
#    "android build api", "cloud android emulator",
#    "remote android build", "apk build api",
#    "android screenshot api", "headless android".
#
#  Structure:
#    hero → showcase → 3 calling patterns → request/response
#    → websocket → errors → cta
#
#  No /docs promotion. No internal endpoints. No swagger.
# ============================================================
cat > templates/api.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>Android Build API — Compile &amp; Run APKs in the Cloud | clawtank</title>
<meta name="description" content="clawtank is a cloud Android build API. POST Kotlin and XML, get back compiled APKs, PNG screenshots, logcat, and a live emulator WebSocket. No SDK, no API keys, no signup." />
<meta name="keywords" content="android build api, cloud android emulator, remote android build, apk build api, kotlin build api, android screenshot api, headless android, android ci api, android emulator api, android automation api" />
<meta name="robots" content="index, follow" />
<meta name="theme-color" content="#0b0d10" />
<meta name="color-scheme" content="dark" />
<link rel="canonical" href="https://clawtank.app/api/docs" />
<meta property="og:type" content="website" />
<meta property="og:site_name" content="clawtank" />
<meta property="og:title" content="Android Build API — clawtank" />
<meta property="og:description" content="POST Kotlin and XML. Get screenshots, logcat, and a live emulator WebSocket back." />
<meta property="og:url" content="https://clawtank.app/api/docs" />
<meta name="twitter:card" content="summary_large_image" />
<meta name="twitter:title" content="Android Build API — clawtank" />
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet" />
<style>
  :root {
    --bg: #080a0d;
    --panel: #0e1116;
    --panel-2: #141821;
    --panel-3: #1a1f2a;
    --border: #1e232c;
    --border-hi: #2a3140;
    --text: #e8eaed;
    --muted: #7b8494;
    --dim: #545c6b;
    --accent: #ff6b00;
    --accent-soft: rgba(255,107,0,.12);
    --green: #3dd68c;
    --green-soft: rgba(61,214,140,.12);
    --amber: #febc2e;
    --blue: #6ea8ff;
    --blue-soft: rgba(110,168,255,.12);
    --red: #ff5c5c;
    --font: "Inter", system-ui, sans-serif;
    --mono: "JetBrains Mono", ui-monospace, monospace;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html { scroll-behavior: smooth; }
  body {
    font-family: var(--font);
    background: var(--bg);
    color: var(--text);
    -webkit-font-smoothing: antialiased;
    font-size: 15px;
    line-height: 1.65;
  }
  a { color: inherit; text-decoration: none; }
  code, pre { font-family: var(--mono); }

  .page {
    max-width: 920px;
    margin: 0 auto;
    padding: 0 28px 80px;
    min-height: 100vh;
  }

  /* ---- hero ---- */
  .hero {
    padding: 48px 0 40px;
    border-bottom: 1px solid var(--border);
    margin-bottom: 48px;
  }
  .hero-kicker {
    display: flex; align-items: center; gap: 10px;
    font-family: var(--mono); font-size: 11.5px;
    letter-spacing: .16em; text-transform: uppercase;
    color: var(--accent); margin-bottom: 18px;
  }
  .hero-kicker .dash { width: 24px; height: 1px; background: var(--accent); }
  .hero h1 {
    font-size: 36px; font-weight: 700; letter-spacing: -.03em;
    line-height: 1.15; margin-bottom: 14px;
  }
  .hero h1 span { color: var(--accent); }
  .hero-lede {
    color: var(--muted); font-size: 16px; max-width: 620px;
    margin-bottom: 28px; line-height: 1.7;
  }
  .hero-lede strong { color: var(--text); font-weight: 500; }

  /* base url pill */
  .base-url {
    display: inline-flex; align-items: center; gap: 12px;
    background: var(--panel); border: 1px solid var(--border);
    border-radius: 10px; padding: 10px 14px 10px 16px;
    font-family: var(--mono); font-size: 13.5px;
  }
  .base-url .label {
    font-size: 10.5px; text-transform: uppercase; letter-spacing: .1em;
    color: var(--dim); font-weight: 500;
  }
  .base-url .url { color: var(--green); font-weight: 500; }
  .base-url .copy-btn {
    margin-left: 4px;
  }

  /* ---- section ---- */
  section { margin-bottom: 56px; }
  section h2 {
    font-size: 22px; font-weight: 650; letter-spacing: -.02em;
    margin-bottom: 8px; display: flex; align-items: center; gap: 12px;
  }
  section h2 .num {
    font-family: var(--mono); font-size: 12px; color: var(--dim);
    font-weight: 400; letter-spacing: .06em;
  }
  .section-sub {
    color: var(--muted); font-size: 14.5px; margin-bottom: 24px;
    max-width: 640px; line-height: 1.7;
  }

  /* ---- endpoint card ---- */
  .endpoint {
    background: var(--panel);
    border: 1px solid var(--border);
    border-radius: 14px;
    overflow: hidden;
    margin-bottom: 28px;
  }
  .endpoint-head {
    display: flex; align-items: center; gap: 12px;
    padding: 16px 20px;
    border-bottom: 1px solid var(--border);
    background: var(--panel-2);
  }
  .method {
    font-family: var(--mono); font-size: 11px; font-weight: 600;
    letter-spacing: .06em; padding: 4px 10px; border-radius: 6px;
    text-transform: uppercase;
  }
  .method.post { background: var(--green-soft); color: var(--green); }
  .method.ws { background: var(--blue-soft); color: var(--blue); }
  .path {
    font-family: var(--mono); font-size: 14.5px; font-weight: 500;
    color: var(--text);
  }
  .endpoint-body { padding: 20px 22px 24px; }
  .endpoint-desc {
    color: var(--muted); font-size: 14px; margin-bottom: 18px;
    line-height: 1.65;
  }

  /* request url row */
  .req-url {
    display: flex; align-items: center; gap: 10px; flex-wrap: wrap;
    background: var(--bg); border: 1px solid var(--border);
    border-radius: 8px; padding: 10px 14px; margin-bottom: 20px;
    font-family: var(--mono); font-size: 13px;
  }
  .req-url .verb {
    font-size: 11px; font-weight: 600; letter-spacing: .04em;
    color: var(--green); background: var(--green-soft);
    padding: 3px 8px; border-radius: 4px;
  }
  .req-url .verb.ws { color: var(--blue); background: var(--blue-soft); }
  .req-url .full { color: var(--text); word-break: break-all; flex: 1; min-width: 0; }

  /* params table */
  .params { margin-bottom: 22px; }
  .params h4 {
    font-size: 11.5px; text-transform: uppercase; letter-spacing: .1em;
    color: var(--dim); font-weight: 600; margin-bottom: 10px;
  }
  .param {
    display: grid; grid-template-columns: 140px 1fr;
    gap: 8px 16px; padding: 10px 0;
    border-bottom: 1px solid var(--border);
    align-items: baseline;
  }
  .param:last-child { border-bottom: none; }
  .param .name {
    font-family: var(--mono); font-size: 13px; color: var(--text);
  }
  .param .name em {
    font-style: normal; font-size: 10.5px; color: var(--accent);
    margin-left: 6px; font-weight: 500;
  }
  .param .desc { font-size: 13.5px; color: var(--muted); line-height: 1.55; }
  .param .desc code {
    font-size: 12px; background: var(--panel-3); padding: 1px 5px;
    border-radius: 3px; border: 1px solid var(--border); color: var(--text);
  }

  /* code block with copy */
  .code-block {
    position: relative;
    background: #06080b;
    border: 1px solid var(--border);
    border-radius: 10px;
    margin-bottom: 16px;
    overflow: hidden;
  }
  .code-block-bar {
    display: flex; align-items: center; justify-content: space-between;
    padding: 8px 12px 8px 14px;
    border-bottom: 1px solid var(--border);
    background: var(--panel-2);
  }
  .code-block-bar .lang {
    font-family: var(--mono); font-size: 11px;
    color: var(--dim); letter-spacing: .04em;
  }
  .code-block-bar .tabs {
    display: flex; gap: 4px;
  }
  .code-block-bar .tab {
    font-family: var(--mono); font-size: 11px; padding: 3px 10px;
    border-radius: 5px; border: 1px solid transparent;
    background: transparent; color: var(--muted); cursor: pointer;
    transition: all .15s;
  }
  .code-block-bar .tab:hover { color: var(--text); }
  .code-block-bar .tab.active {
    background: var(--panel-3); color: var(--text);
    border-color: var(--border-hi);
  }
  .copy-btn {
    font-family: var(--mono); font-size: 11px; font-weight: 500;
    padding: 5px 12px; border-radius: 6px; cursor: pointer;
    background: var(--panel-3); border: 1px solid var(--border);
    color: var(--muted); transition: all .15s;
    display: inline-flex; align-items: center; gap: 5px;
  }
  .copy-btn:hover { color: var(--text); border-color: var(--border-hi); }
  .copy-btn.copied {
    color: var(--green); border-color: rgba(61,214,140,.35);
    background: var(--green-soft);
  }
  .code-block pre {
    margin: 0; padding: 16px 18px;
    font-size: 12.5px; line-height: 1.7; color: #c8d0dd;
    overflow-x: auto; white-space: pre;
  }
  .code-block pre .c { color: var(--dim); font-style: italic; }
  .code-block pre .k { color: #e8eaed; }
  .code-block pre .s { color: var(--green); }
  .code-block pre .p { color: var(--dim); }
  .code-block pre .u { color: var(--blue); }
  .code-block pre .key { color: #c586c0; }
  .code-block pre .warn { color: var(--amber); }
  .code-pane { display: none; }
  .code-pane.active { display: block; }

  /* response example */
  .response-label {
    font-size: 11.5px; text-transform: uppercase; letter-spacing: .1em;
    color: var(--dim); font-weight: 600; margin: 18px 0 10px;
  }

  /* toc / quick nav */
  .toc {
    display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 40px;
  }
  .toc a {
    font-family: var(--mono); font-size: 12px;
    padding: 6px 14px; border-radius: 8px;
    border: 1px solid var(--border); background: var(--panel);
    color: var(--muted); transition: all .15s;
  }
  .toc a:hover { color: var(--text); border-color: var(--border-hi); }
  .toc a .m {
    font-size: 10px; margin-right: 6px; opacity: .7;
  }

  /* footer */
  footer {
    margin-top: 48px; padding-top: 28px;
    border-top: 1px solid var(--border);
    display: flex; justify-content: space-between; align-items: center;
    font-size: 12.5px; color: var(--dim); font-family: var(--mono);
    flex-wrap: wrap; gap: 14px;
  }
  footer .links { display: flex; gap: 20px; }
  footer a:hover { color: var(--muted); }

  @media (max-width: 640px) {
    .page { padding: 0 16px 56px; }
    .hero h1 { font-size: 28px; }
    .param { grid-template-columns: 1fr; gap: 4px; }
    .endpoint-head { flex-wrap: wrap; }
  }
</style>
</head>
<body>

<div class="page">

  {% set active = 'api' %}{% include "_header.html" %}

  <div class="hero">
    <div class="hero-kicker">
      <span class="dash"></span>
      <span>android build api</span>
    </div>
    <h1>Compile &amp; run APKs<br>in the <span>cloud</span>.</h1>
    <p class="hero-lede">
      POST Kotlin and XML. Get back screenshots, logcat, and a live emulator
      WebSocket. <strong>No SDK. No API keys. No signup.</strong>
    </p>
    <div class="base-url">
      <span class="label">base</span>
      <span class="url" id="baseUrl">https://clawtank.app</span>
      <button class="copy-btn" data-copy="https://clawtank.app" type="button">copy</button>
    </div>
  </div>

  <nav class="toc" aria-label="Endpoints">
    <a href="#build"><span class="m">POST</span>/v1/build</a>
    <a href="#scripted"><span class="m">POST</span>/v1/build + script</a>
    <a href="#stream"><span class="m">WS</span>/ws/stream</a>
    <a href="#files"><span class="m">GET</span>/api/default-files</a>
  </nav>

  <!-- ========== 00 Public vs private ========== -->
  <section id="tiers">
    <h2><span class="num">00 /</span>Public vs private</h2>
    <p class="section-sub">
      <strong>Public</strong> <code>POST /v1/build</code> — free shared pool, no auth.<br/>
      <strong>Private</strong> <code>POST /v1/private/build</code> — requires
      <code>Authorization: Bearer ct_…</code> from your <a href="/account">account</a>,
      charges 5¢ upfront via account credits <code>Authorization: Bearer ct_…</code> or <strong>x402</strong> USDC (<code>PAYMENT-SIGNATURE</code> after HTTP 402). Non-refundable.
    </p>
  </section>

  <!-- ========== 01 POST /v1/build ========== -->
  <section id="build">
    <h2><span class="num">01 /</span>Fire and forget (public)</h2>
    <p class="section-sub">
      Send source, get three screenshots back. Enough to prove the app
      compiled, launched, and rendered. Free — uses the shared emulator pool.
    </p>

    <div class="endpoint">
      <div class="endpoint-head">
        <span class="method post">POST</span>
        <span class="path">/v1/build</span>
      </div>
      <div class="endpoint-body">
        <p class="endpoint-desc">
          Compiles the APK on managed infrastructure, installs it on a pooled
          emulator, launches it, and returns three PNGs (t+2s, t+3s, t+4s)
          plus logcat.
        </p>

        <div class="req-url">
          <span class="verb">POST</span>
          <span class="full" id="url-build">https://clawtank.app/v1/build</span>
          <button class="copy-btn" data-copy="https://clawtank.app/v1/build" type="button">copy</button>
        </div>

        <div class="params">
          <h4>Body (JSON)</h4>
          <div class="param">
            <div class="name">files <em>required</em></div>
            <div class="desc">Object mapping filename → source string. Include at least <code>MainActivity.kt</code>. Optional: <code>colors.xml</code>, <code>strings.xml</code>.</div>
          </div>
          <div class="param">
            <div class="name">run</div>
            <div class="desc">Boolean. Default <code>true</code>. Install &amp; launch on emulator. When <code>false</code>, compile only.</div>
          </div>
          <div class="param">
            <div class="name">logcat_lines</div>
            <div class="desc">Integer 1–1000. Default <code>200</code>. Max app logcat lines returned in the response.</div>
          </div>
        </div>

        <div class="code-block" data-group="build">
          <div class="code-block-bar">
            <div class="tabs">
              <button class="tab active" data-pane="py">Python</button>
              <button class="tab" data-pane="sh">curl / shell</button>
            </div>
            <button class="copy-btn" type="button" data-copy-target="build-py">copy</button>
          </div>
          <div class="code-pane active" data-pane="py" id="build-py">
<pre><span class="c">#!/usr/bin/env python3</span>
<span class="k">import</span> json, urllib.request, base64

URL = <span class="s">"https://clawtank.app/v1/build"</span>

MAIN = <span class="s">"""package com.clawtank.app
import android.os.Bundle
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {
    override fun onCreate(s: Bundle?) {
        super.onCreate(s)
        val root = FrameLayout(this)
        root.setBackgroundColor(0xFF000000.toInt())
        val tv = TextView(this).apply {
            text = "wow"; textSize = 48f
            setTextColor(0xFFFFFFFF.toInt()); gravity = Gravity.CENTER
        }
        root.addView(tv, FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))
        setContentView(root)
    }
}
"""</span>

payload = {
    <span class="s">"files"</span>: {
        <span class="s">"MainActivity.kt"</span>: MAIN,
        <span class="s">"strings.xml"</span>: <span class="s">'&lt;resources&gt;&lt;string name="app_name"&gt;wow&lt;/string&gt;&lt;/resources&gt;'</span>,
        <span class="s">"colors.xml"</span>: <span class="s">'&lt;resources&gt;&lt;color name="black"&gt;#FF000000&lt;/color&gt;&lt;/resources&gt;'</span>,
    },
    <span class="s">"run"</span>: True,
    <span class="s">"logcat_lines"</span>: 200,
}

req = urllib.request.Request(
    URL, data=json.dumps(payload).encode(),
    headers={<span class="s">"Content-Type"</span>: <span class="s">"application/json"</span>}, method=<span class="s">"POST"</span>)
with urllib.request.urlopen(req, timeout=300) as r:
    body = json.loads(r.read())

print(body[<span class="s">"status"</span>], body.get(<span class="s">"build_ms"</span>), <span class="s">"ms"</span>)
for i, b64 in enumerate(body.get(<span class="s">"screenshots"</span>) or []):
    open(f<span class="s">"shot_{i+1}.png"</span>, <span class="s">"wb"</span>).write(base64.b64decode(b64))
    print(f<span class="s">"  wrote shot_{i+1}.png"</span>)
logcat = body.get(<span class="s">"logcat"</span>) or <span class="s">""</span>
print(<span class="s">"--- logcat ---"</span>)
print(logcat if logcat else <span class="s">"(empty)"</span>)
if body.get(<span class="s">"build_log"</span>):
    print(<span class="s">"--- build_log (tail) ---"</span>)
    print(<span class="s">"\n"</span>.join((body[<span class="s">"build_log"</span>] or <span class="s">""</span>).splitlines()[-20:]))</pre>
          </div>
          <div class="code-pane" data-pane="sh" id="build-sh">
<pre><span class="c">#!/usr/bin/env bash</span>
<span class="c"># Fire-and-forget build — returns 3 screenshots + logcat</span>

URL=<span class="s">"https://clawtank.app/v1/build"</span>

curl -sS -X POST <span class="s">"$URL"</span> \
  -H <span class="s">'Content-Type: application/json'</span> \
  -d @- <<EOF | tee response.json
{
  "files": {
    "MainActivity.kt": "package com.clawtank.app\\nimport android.os.Bundle\\nimport android.view.Gravity\\nimport android.widget.FrameLayout\\nimport android.widget.TextView\\nimport androidx.appcompat.app.AppCompatActivity\\n\\nclass MainActivity : AppCompatActivity() {\\n    override fun onCreate(s: Bundle?) {\\n        super.onCreate(s)\\n        val root = FrameLayout(this)\\n        root.setBackgroundColor(0xFF000000.toInt())\\n        val tv = TextView(this).apply { text = \\"wow\\"; textSize = 48f; setTextColor(0xFFFFFFFF.toInt()); gravity = Gravity.CENTER }\\n        root.addView(tv, FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))\\n        setContentView(root)\\n    }\\n}\\n",
    "strings.xml": "&lt;resources&gt;&lt;string name=\\"app_name\\"&gt;wow&lt;/string&gt;&lt;/resources&gt;",
    "colors.xml": "&lt;resources&gt;&lt;color name=\\"black\\"&gt;#FF000000&lt;/color&gt;&lt;/resources&gt;"
  },
  "run": true
}
EOF

<span class="c"># extract screenshots with jq (optional)</span>
<span class="c"># jq -r '.screenshots[0]' response.json | base64 -d > shot_1.png</span></pre>
          </div>
        </div>

        <div class="response-label">Example response</div>
        <div class="code-block">
          <div class="code-block-bar">
            <span class="lang">json</span>
            <button class="copy-btn" type="button" data-copy-target="build-resp">copy</button>
          </div>
          <pre id="build-resp">{
  <span class="key">"status"</span><span class="p">:</span>       <span class="s">"ok"</span><span class="p">,</span>
  <span class="key">"device"</span><span class="p">:</span>       <span class="s">"emulator-5554"</span><span class="p">,</span>
  <span class="key">"platform"</span><span class="p">:</span>     <span class="s">"android-34"</span><span class="p">,</span>
  <span class="key">"build_ms"</span><span class="p">:</span>     <span class="warn">41203</span><span class="p">,</span>
  <span class="key">"screenshots"</span><span class="p">:</span> [<span class="s">"iVBORw0KGgo…"</span><span class="p">,</span> <span class="s">"…"</span><span class="p">,</span> <span class="s">"…"</span>]<span class="p">,</span>
  <span class="key">"logcat"</span><span class="p">:</span>       <span class="s">"05-01 12:34:56.789 D/clawtank: Cats\n…"</span><span class="p">,</span>
  <span class="key">"logcat_lines"</span><span class="p">:</span> <span class="warn">200</span><span class="p">,</span>
  <span class="key">"build_log"</span><span class="p">:</span>    <span class="s">"Building debug APK…\n…"</span><span class="p">,</span>
  <span class="key">"steps"</span><span class="p">:</span>       []
}</pre>
        </div>
      </div>
    </div>
  </section>

  <!-- ========== 02 Scripted ========== -->
  <section id="scripted">
    <h2><span class="num">02 /</span>Scripted interactions</h2>
    <p class="section-sub">
      Same endpoint. Add a <code>script</code> array of timed actions — tap,
      swipe, key, screenshot — relative to app launch.
    </p>

    <div class="endpoint">
      <div class="endpoint-head">
        <span class="method post">POST</span>
        <span class="path">/v1/build</span>
        <span style="font-family:var(--mono);font-size:12px;color:var(--muted);margin-left:auto">+ script</span>
      </div>
      <div class="endpoint-body">
        <p class="endpoint-desc">
          Each step has an <code>at</code> time (seconds after launch) and an
          <code>action</code>. Supported: <code>screenshot</code>, <code>tap</code>,
          <code>swipe</code>, <code>key</code>, <code>wait</code>.
        </p>

        <div class="req-url">
          <span class="verb">POST</span>
          <span class="full">https://clawtank.app/v1/build</span>
          <button class="copy-btn" data-copy="https://clawtank.app/v1/build" type="button">copy</button>
        </div>

        <div class="params">
          <h4>Extra body field</h4>
          <div class="param">
            <div class="name">script</div>
            <div class="desc">Array of <code>{ "at": number, "action": string, … }</code>. Coordinates are in device pixel space.</div>
          </div>
        </div>

        <div class="code-block" data-group="scripted">
          <div class="code-block-bar">
            <div class="tabs">
              <button class="tab active" data-pane="py">Python</button>
              <button class="tab" data-pane="sh">curl / shell</button>
            </div>
            <button class="copy-btn" type="button" data-copy-target="scripted-py">copy</button>
          </div>
          <div class="code-pane active" data-pane="py" id="scripted-py">
<pre><span class="c">#!/usr/bin/env python3</span>
<span class="k">import</span> json, urllib.request, base64

URL = <span class="s">"https://clawtank.app/v1/build"</span>

MAIN = <span class="s">"""package com.clawtank.app

import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Root container
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.parseColor("#111111"))
        }

        // Initial "tap me" label (acts as our button)
        val tapMe = TextView(this).apply {
            text = "tap me"
            textSize = 36f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            isClickable = true
            isFocusable = true
        }

        // Make it fill the screen so the whole area is tappable
        root.addView(
            tapMe,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )

        // On tap: turn everything red and show "swag"
        tapMe.setOnClickListener {
            root.setBackgroundColor(Color.RED)
            tapMe.text = "TAPPED"
            tapMe.textSize = 72f
        }

        setContentView(root)
    }
}
"""</span>

payload = {
    <span class="s">"files"</span>: {
        <span class="s">"MainActivity.kt"</span>: MAIN,
        <span class="s">"strings.xml"</span>: <span class="s">'&lt;resources&gt;&lt;string name="app_name"&gt;demo&lt;/string&gt;&lt;/resources&gt;'</span>,
    },
    <span class="s">"run"</span>: True,
    <span class="s">"script"</span>: [
        {<span class="s">"at"</span>: 2.0, <span class="s">"action"</span>: <span class="s">"screenshot"</span>},
        {<span class="s">"at"</span>: 3.0, <span class="s">"action"</span>: <span class="s">"tap"</span>, <span class="s">"x"</span>: 360, <span class="s">"y"</span>: 800},
        {<span class="s">"at"</span>: 4.0, <span class="s">"action"</span>: <span class="s">"screenshot"</span>},
        {<span class="s">"at"</span>: 5.0, <span class="s">"action"</span>: <span class="s">"swipe"</span>,
         <span class="s">"x1"</span>: 360, <span class="s">"y1"</span>: 1200, <span class="s">"x2"</span>: 360, <span class="s">"y2"</span>: 400},
        {<span class="s">"at"</span>: 6.5, <span class="s">"action"</span>: <span class="s">"screenshot"</span>},
    ],
}

req = urllib.request.Request(
    URL, data=json.dumps(payload).encode(),
    headers={<span class="s">"Content-Type"</span>: <span class="s">"application/json"</span>}, method=<span class="s">"POST"</span>)
with urllib.request.urlopen(req, timeout=300) as r:
    body = json.loads(r.read())

print(body[<span class="s">"status"</span>], len(body.get(<span class="s">"screenshots"</span>) or []), <span class="s">"shots"</span>)
for i, b64 in enumerate(body.get(<span class="s">"screenshots"</span>) or []):
    open(f<span class="s">"shot_{i+1}.png"</span>, <span class="s">"wb"</span>).write(base64.b64decode(b64))
    print(f<span class="s">"  wrote shot_{i+1}.png"</span>)
print(<span class="s">"--- logcat ---"</span>)
print(body.get(<span class="s">"logcat"</span>) or <span class="s">"(empty)"</span>)
print(<span class="s">"--- steps ---"</span>)
print(body.get(<span class="s">"steps"</span>) or [])</pre>
          </div>
          <div class="code-pane" data-pane="sh" id="scripted-sh">
<pre><span class="c">#!/usr/bin/env bash</span>
URL=<span class="s">"https://clawtank.app/v1/build"</span>

curl -sS -X POST <span class="s">"$URL"</span> \
  -H <span class="s">'Content-Type: application/json'</span> \
  -d @- <<'EOF'
{
  "files": {
    "MainActivity.kt": "package com.clawtank.app\nimport android.os.Bundle\nimport android.view.Gravity\nimport android.widget.FrameLayout\nimport android.widget.TextView\nimport androidx.appcompat.app.AppCompatActivity\n\nclass MainActivity : AppCompatActivity() {\n    override fun onCreate(s: Bundle?) {\n        super.onCreate(s)\n        val root = FrameLayout(this)\n        root.setBackgroundColor(0xFF111111.toInt())\n        val tv = TextView(this).apply { text = \"tap me\"; textSize = 36f; setTextColor(0xFFFFFFFF.toInt()); gravity = Gravity.CENTER }\n        root.addView(tv, FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))\n        setContentView(root)\n    }\n}\n",
    "strings.xml": "<resources><string name=\"app_name\">demo</string></resources>"
  },
  "run": true,
  "script": [
    { "at": 2.0, "action": "screenshot" },
    { "at": 3.0, "action": "tap", "x": 360, "y": 800 },
    { "at": 4.0, "action": "screenshot" },
    { "at": 5.0, "action": "swipe", "x1": 360, "y1": 1200, "x2": 360, "y2": 400 },
    { "at": 6.5, "action": "screenshot" }
  ]
}
EOF</pre>
          </div>
        </div>

        <div class="response-label">Example response</div>
        <div class="code-block">
          <div class="code-block-bar">
            <span class="lang">json</span>
            <button class="copy-btn" type="button" data-copy-target="scripted-resp">copy</button>
          </div>
          <pre id="scripted-resp">{
  <span class="key">"status"</span><span class="p">:</span>       <span class="s">"ok"</span><span class="p">,</span>
  <span class="key">"device"</span><span class="p">:</span>       <span class="s">"emulator-5554"</span><span class="p">,</span>
  <span class="key">"platform"</span><span class="p">:</span>     <span class="s">"android-34"</span><span class="p">,</span>
  <span class="key">"build_ms"</span><span class="p">:</span>     <span class="warn">43890</span><span class="p">,</span>
  <span class="key">"screenshots"</span><span class="p">:</span> [<span class="s">"iVBORw0KGgo…"</span><span class="p">,</span> <span class="s">"…"</span><span class="p">,</span> <span class="s">"…"</span>]<span class="p">,</span>
  <span class="key">"logcat"</span><span class="p">:</span>       <span class="s">"05-01 12:34:56.789 D/clawtank: …\n…"</span><span class="p">,</span>
  <span class="key">"logcat_lines"</span><span class="p">:</span> <span class="warn">200</span><span class="p">,</span>
  <span class="key">"build_log"</span><span class="p">:</span>    <span class="s">"Building debug APK…\n…"</span><span class="p">,</span>
  <span class="key">"steps"</span><span class="p">:</span> [
    {<span class="key">"at"</span><span class="p">:</span> 2.0, <span class="key">"action"</span><span class="p">:</span> <span class="s">"screenshot"</span><span class="p">,</span> <span class="key">"idx"</span><span class="p">:</span> 0}<span class="p">,</span>
    {<span class="key">"at"</span><span class="p">:</span> 3.0, <span class="key">"action"</span><span class="p">:</span> <span class="s">"tap"</span>}<span class="p">,</span>
    {<span class="key">"at"</span><span class="p">:</span> 4.0, <span class="key">"action"</span><span class="p">:</span> <span class="s">"screenshot"</span><span class="p">,</span> <span class="key">"idx"</span><span class="p">:</span> 1}
  ]
}</pre>
        </div>
      </div>
    </div>
  </section>

  <!-- ========== 03 Live stream ========== -->
  <section id="stream">
    <h2><span class="num">03 /</span>Live session</h2>
    <p class="section-sub">
      Open a WebSocket. Receive H.264 frames of the running app. Send taps,
      swipes, keys, and text in real time.
    </p>

    <div class="endpoint">
      <div class="endpoint-head">
        <span class="method ws">WS</span>
        <span class="path">/ws/stream</span>
      </div>
      <div class="endpoint-body">
        <p class="endpoint-desc">
          Binary frames are raw H.264 (first byte = flags: bit0 keyframe,
          bit1 config). Control messages are JSON text frames.
          Upload sources first via <code>PUT /api/files/…</code> or use the
          studio UI.
        </p>

        <div class="req-url">
          <span class="verb ws">WS</span>
          <span class="full" id="url-stream">wss://clawtank.app/ws/stream</span>
          <button class="copy-btn" data-copy="wss://clawtank.app/ws/stream" type="button">copy</button>
        </div>

        <div class="params">
          <h4>Control messages (client → server)</h4>
          <div class="param">
            <div class="name">tap</div>
            <div class="desc"><code>{"type":"tap","x":540,"y":1180}</code> — device pixel coordinates</div>
          </div>
          <div class="param">
            <div class="name">swipe</div>
            <div class="desc"><code>{"type":"swipe","x1":…,"y1":…,"x2":…,"y2":…}</code></div>
          </div>
          <div class="param">
            <div class="name">key</div>
            <div class="desc"><code>{"type":"key","code":4}</code> — 3=HOME, 4=BACK, 24/25=volume</div>
          </div>
          <div class="param">
            <div class="name">text</div>
            <div class="desc"><code>{"type":"text","text":"hello"}</code> — inject into focused field</div>
          </div>
        </div>

        <div class="params" style="margin-top:14px">
          <h4>Server → client (JSON text frames)</h4>
          <div class="param">
            <div class="name">queued</div>
            <div class="desc"><code>{"type":"queued","position":N,"queue_size":N,"pool_size":N,"inuse":N}</code></div>
          </div>
          <div class="param">
            <div class="name">assigned / building / ready</div>
            <div class="desc"><code>ready</code> includes <code>width</code>, <code>height</code>, <code>codec</code>, <code>duration</code></div>
          </div>
          <div class="param">
            <div class="name">tick</div>
            <div class="desc"><code>{"type":"tick","remaining":N}</code> — session countdown</div>
          </div>
          <div class="param">
            <div class="name">loot_screenshot</div>
            <div class="desc"><code>{"type":"loot_screenshot","idx":0,"data":"&lt;base64 png&gt;"}</code></div>
          </div>
          <div class="param">
            <div class="name">expired / build_failed / error</div>
            <div class="desc">Session end or failure frames</div>
          </div>
          <div class="param">
            <div class="name">binary frames</div>
            <div class="desc">H.264 NAL units; first byte flags (bit0 keyframe, bit1 config)</div>
          </div>
        </div>

        <div class="code-block" data-group="stream">
          <div class="code-block-bar">
            <div class="tabs">
              <button class="tab active" data-pane="py">Python</button>
              <button class="tab" data-pane="sh">shell notes</button>
            </div>
            <button class="copy-btn" type="button" data-copy-target="stream-py">copy</button>
          </div>
          <div class="code-pane active" data-pane="py" id="stream-py">
<pre><span class="c">#!/usr/bin/env python3</span>
<span class="c"># pip install websockets</span>
<span class="k">import</span> asyncio, json, websockets

URL = <span class="s">"wss://clawtank.app/ws/stream"</span>

<span class="k">async def</span> main():
    <span class="k">async with</span> websockets.connect(URL, max_size=None) <span class="k">as</span> ws:
        <span class="c"># wait for assigned / building / ready</span>
        <span class="k">while True</span>:
            msg = <span class="k">await</span> ws.recv()
            <span class="k">if isinstance</span>(msg, bytes):
                <span class="c"># H.264 frame — first byte is flags</span>
                flags, payload = msg[0], msg[1:]
                print(f<span class="s">"frame flags={flags:#x} size={len(payload)}"</span>)
                <span class="k">continue</span>
            data = json.loads(msg)
            print(<span class="s">"&lt;"</span>, data.get(<span class="s">"type"</span>), data)
            <span class="k">if</span> data.get(<span class="s">"type"</span>) == <span class="s">"ready"</span>:
                <span class="k">await</span> ws.send(json.dumps({<span class="s">"type"</span>: <span class="s">"ready"</span>}))
                <span class="c"># tap center of screen after a moment</span>
                <span class="k">await</span> asyncio.sleep(2)
                <span class="k">await</span> ws.send(json.dumps({
                    <span class="s">"type"</span>: <span class="s">"tap"</span>,
                    <span class="s">"x"</span>: data.get(<span class="s">"width"</span>, 720) // 2,
                    <span class="s">"y"</span>: data.get(<span class="s">"height"</span>, 1280) // 2,
                }))
            <span class="k">if</span> data.get(<span class="s">"type"</span>) <span class="k">in</span> (<span class="s">"expired"</span>, <span class="s">"emulator_offline"</span>, <span class="s">"error"</span>):
                <span class="k">break</span>

asyncio.run(main())</pre>
          </div>
          <div class="code-pane" data-pane="sh" id="stream-sh">
<pre><span class="c"># WebSocket streaming is best done from Python / Node / a browser.</span>
<span class="c"># Quick test with websocat (https://github.com/vi/websocat):</span>

websocat -b wss://clawtank.app/ws/stream

<span class="c"># After the "ready" JSON frame arrives, send:</span>
<span class="c">#   {"type":"ready"}</span>
<span class="c"># then control messages, e.g.:</span>
<span class="c">#   {"type":"tap","x":360,"y":800}</span>
<span class="c">#   {"type":"key","code":4}</span>

<span class="c"># Binary H.264 frames will print as raw bytes.</span>
<span class="c"># Prefer the Python sample above for real use.</span></pre>
          </div>
        </div>
      </div>
    </div>
  </section>

  <!-- ========== Files ========== -->
  <section id="files">
    <h2><span class="num">04 /</span>Scripts &amp; default files</h2>
    <p class="section-sub">
      Manage source files the studio and <code>POST /v1/build</code> can use.
      Default files are seeded and cannot be deleted.
    </p>

    <div class="endpoint">
      <div class="endpoint-head">
        <span class="method get">GET</span>
        <span class="path">/api/default-files</span>
      </div>
      <div class="endpoint-body">
        <p class="endpoint-desc">
          Lists the hard-coded default scripts (shown under
          <code>scripts/ · default</code> in the studio). These cannot be
          deleted. More defaults may be added over time.
        </p>
        <div class="response-label">Example response</div>
        <div class="code-block">
          <div class="code-block-bar">
            <span class="lang">json</span>
          </div>
          <pre>{
  <span class="key">"names"</span><span class="p">:</span> [<span class="s">"MainActivity.kt"</span><span class="p">,</span> <span class="s">"colors.xml"</span><span class="p">,</span> <span class="s">"strings.xml"</span>]<span class="p">,</span>
  <span class="key">"default_files"</span><span class="p">:</span> [
    {<span class="key">"name"</span><span class="p">:</span> <span class="s">"MainActivity.kt"</span><span class="p">,</span> <span class="key">"deletable"</span><span class="p">:</span> false, <span class="key">"exists"</span><span class="p">:</span> true, <span class="key">"size"</span><span class="p">:</span> 1234}<span class="p">,</span>
    {<span class="key">"name"</span><span class="p">:</span> <span class="s">"colors.xml"</span><span class="p">,</span> <span class="key">"deletable"</span><span class="p">:</span> false, <span class="key">"exists"</span><span class="p">:</span> true, <span class="key">"size"</span><span class="p">:</span> 400}<span class="p">,</span>
    {<span class="key">"name"</span><span class="p">:</span> <span class="s">"strings.xml"</span><span class="p">,</span> <span class="key">"deletable"</span><span class="p">:</span> false, <span class="key">"exists"</span><span class="p">:</span> true, <span class="key">"size"</span><span class="p">:</span> 180}
  ]
}</pre>
        </div>
      </div>
    </div>

    <div class="endpoint" style="margin-top:18px">
      <div class="endpoint-head">
        <span class="method get">GET</span>
        <span class="path">/api/files</span>
      </div>
      <div class="endpoint-body">
        <p class="endpoint-desc">List all scripts under <code>scripts/</code> (defaults + user files).</p>
      </div>
    </div>

    <div class="endpoint" style="margin-top:12px">
      <div class="endpoint-head">
        <span class="method get">GET</span>
        <span class="path">/api/files/{name}</span>
      </div>
      <div class="endpoint-body">
        <p class="endpoint-desc">Read one file. Returns <code>{"name","content"}</code>.</p>
      </div>
    </div>

    <div class="endpoint" style="margin-top:12px">
      <div class="endpoint-head">
        <span class="method put">PUT</span>
        <span class="path">/api/files/{name}</span>
      </div>
      <div class="endpoint-body">
        <p class="endpoint-desc">
          Create or overwrite a file. Body: <code>{"content": "…"}</code>.
          Use this to add new sources before a live stream session.
        </p>
      </div>
    </div>

    <div class="endpoint" style="margin-top:12px">
      <div class="endpoint-head">
        <span class="method del">DELETE</span>
        <span class="path">/api/files/{name}</span>
      </div>
      <div class="endpoint-body">
        <p class="endpoint-desc">
          Delete a user file. Default files always return <code>403</code>.
        </p>
      </div>
    </div>
  </section>

  <!-- ========== Errors ========== -->
  <section>
    <h2><span class="num">05 /</span>Errors</h2>
    <p class="section-sub">HTTP uses standard status codes. WebSocket errors are JSON control frames.</p>
    <div class="endpoint">
      <div class="endpoint-body" style="padding-top:18px">
        <div class="params" style="margin:0">
          <div class="param">
            <div class="name">400</div>
            <div class="desc"><code>invalid path</code> / missing <code>files</code></div>
          </div>
          <div class="param">
            <div class="name">503</div>
            <div class="desc">No worker online, or no free emulator</div>
          </div>
          <div class="param">
            <div class="name">ws: error</div>
            <div class="desc"><code>{"type":"error","message":"…"}</code></div>
          </div>
          <div class="param">
            <div class="name">ws: build_failed</div>
            <div class="desc"><code>{"type":"build_failed","code":N}</code> — Gradle non-zero</div>
          </div>
          <div class="param">
            <div class="name">ws: expired</div>
            <div class="desc">Session timer reached zero; device returned to pool</div>
          </div>
        </div>
      </div>
    </div>
  </section>

  <footer>
    <span>clawtank · v1</span>
    <div class="links">
      <a href="/studio">studio</a>
      <a href="/api/docs">api</a>
      <a href="/api/health">status</a>
    </div>
  </footer>

</div>

<script>
(function () {
  // Tab switching inside code blocks
  document.querySelectorAll(".code-block[data-group]").forEach(function (block) {
    var tabs = block.querySelectorAll(".tab");
    var panes = block.querySelectorAll(".code-pane");
    var copyBtn = block.querySelector(".copy-btn[data-copy-target]");
    tabs.forEach(function (tab) {
      tab.addEventListener("click", function () {
        var pane = tab.getAttribute("data-pane");
        tabs.forEach(function (t) { t.classList.toggle("active", t === tab); });
        panes.forEach(function (p) {
          p.classList.toggle("active", p.getAttribute("data-pane") === pane);
        });
        if (copyBtn) {
          var active = block.querySelector(".code-pane.active");
          if (active && active.id) copyBtn.setAttribute("data-copy-target", active.id);
        }
      });
    });
  });

  function plainText(el) {
    return el.innerText || el.textContent || "";
  }

  function flash(btn) {
    var prev = btn.textContent;
    btn.textContent = "copied";
    btn.classList.add("copied");
    setTimeout(function () {
      btn.textContent = prev;
      btn.classList.remove("copied");
    }, 1400);
  }

  document.querySelectorAll(".copy-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var text = "";
      if (btn.dataset.copy) {
        text = btn.dataset.copy;
      } else if (btn.dataset.copyTarget) {
        var el = document.getElementById(btn.dataset.copyTarget);
        if (el) text = plainText(el.querySelector("pre") || el);
      }
      if (!text) return;
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { flash(btn); });
      } else {
        var ta = document.createElement("textarea");
        ta.value = text;
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand("copy"); flash(btn); } catch (e) {}
        document.body.removeChild(ta);
      }
    });
  });
})();
</script>
</body>
</html>
HTML

# ============================================================
#  index.html — studio
# ============================================================
cat > templates/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>clawtank — studio</title>
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet" />
<style>
  :root{
    --bg:#0b0d10; --surface:#12151a; --surface2:#1a1e26; --border:#2a3140;
    --text:#e8eaed; --muted:#8b93a7; --accent:#ff6b00; --green:#3dd68c;
    --red:#ff5c5c; --amber:#ffb84d;
    --font:"Inter",system-ui,sans-serif;
    --mono:"JetBrains Mono",ui-monospace,monospace;
    --tok-keyword:#ff7a3d; --tok-type:#5b9dff; --tok-string:#3dd68c;
    --tok-comment:#5f6677; --tok-number:#ffb86b; --tok-func:#ffd479;
    --tok-annotation:#c586c0; --tok-tag:#5b9dff; --tok-attr:#56d4dd;
    --tok-punct:#8b93a7; --tok-meta:#c586c0;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{height:100%}
  body{font-family:var(--font);background:var(--bg);color:var(--text);
       display:grid;grid-template-rows:auto 1fr;overflow:hidden}

  .stats{display:flex;align-items:stretch;background:#0a0d12;
    border:1px solid var(--border);border-radius:10px;overflow:hidden;
    font-family:var(--mono)}
  .stat{display:flex;flex-direction:column;align-items:center;justify-content:center;
    padding:6px 16px;min-width:72px;border-right:1px solid var(--border);
    transition:background .2s}
  .stat:last-child{border-right:none}
  .stat .label{font-size:.58rem;text-transform:uppercase;letter-spacing:.08em;
    color:var(--muted);line-height:1}
  .stat .value{font-size:1.05rem;font-weight:600;line-height:1.2;
    color:var(--text);margin-top:3px}
  .stat.pool .value{color:var(--green)}
  .stat.inuse .value{color:var(--muted)}
  .stat.inuse.busy .value{color:var(--amber)}
  .stat.inuse.hot .value{color:var(--accent)}
  .stat.inuse.hot{background:rgba(255,107,0,.05)}
  .stat.queue .value{color:var(--muted)}
  .stat.queue.busy .value{color:var(--amber)}
  .stat.queue.busy{background:rgba(255,184,77,.06)}

  .shell{display:grid;grid-template-columns:240px 1fr 400px;min-height:0;overflow:hidden}
  @media(max-width:900px){ .shell{grid-template-columns:1fr} aside{display:none} }
  aside.files{background:var(--surface);border-right:1px solid var(--border);
    display:flex;flex-direction:column;overflow:hidden}
  .aside-head{padding:14px 14px 8px}
  .aside-head h2{font-size:.7rem;text-transform:uppercase;letter-spacing:.08em;
    color:var(--muted);font-weight:600}
  .file-list{list-style:none;overflow-y:auto;flex:1;padding:0 8px 12px}

  .file-group{
    font-family:var(--mono);font-size:.58rem;font-weight:600;
    color:var(--muted);text-transform:uppercase;letter-spacing:.1em;
    padding:10px 10px 4px;list-style:none;
    display:flex;align-items:center;gap:6px;
  }
  .file-group.divider{
    margin-top:14px;padding-top:16px;
    border-top:1px solid var(--border);
  }
  .file-group .tag{
    font-size:.52rem;font-weight:500;padding:1px 5px;border-radius:3px;
    background:var(--surface2);color:var(--muted);
    text-transform:none;letter-spacing:0;
  }

  .file-item{display:flex;align-items:center;gap:8px;padding:7px 10px;
    border-radius:7px;cursor:pointer;font-size:.8rem;color:var(--muted);
    font-family:var(--mono);transition:background .12s;position:relative}
  .file-item:hover{background:var(--surface2);color:var(--text)}
  .file-item.active{background:var(--surface2);color:var(--text);
    box-shadow:inset 3px 0 0 var(--accent)}
  .file-item.locked{cursor:pointer}
  .file-name{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .file-lock{
    font-family:var(--mono);font-size:.62rem;color:var(--muted);
    opacity:.4;padding:0 4px;user-select:none;
  }
  .file-del{
    display:none;background:transparent;border:none;color:var(--muted);
    cursor:pointer;padding:2px 6px;border-radius:4px;font-family:var(--mono);
    font-size:.75rem;line-height:1;
  }
  .file-item:hover .file-del{display:inline-flex}
  .file-item:hover .file-del:hover{background:rgba(255,92,92,.15);color:var(--red)}

  .aside-foot{
    padding:10px 12px;border-top:1px solid var(--border);
    flex-shrink:0;display:flex;flex-direction:column;gap:8px;
  }
  .aside-foot button{
    width:100%;font-family:var(--font);font-size:.78rem;font-weight:560;
    padding:8px 12px;border-radius:7px;cursor:pointer;
    background:var(--surface2);border:1px solid var(--border);color:var(--text);
    transition:background .15s;
  }
  .aside-foot button:hover{background:#222833;border-color:#3a4458}
  .aside-foot button.share{
    background:transparent;border-color:var(--accent);color:var(--accent);
  }
  .aside-foot button.share:hover{background:rgba(255,107,0,.1)}
  .share-modal{
    display:none;position:fixed;inset:0;z-index:1000;
    background:rgba(0,0,0,.55);align-items:center;justify-content:center;
    padding:20px;
  }
  .share-modal.open{display:flex}
  .share-card{
    background:var(--surface);border:1px solid var(--border);border-radius:12px;
    padding:22px 24px;max-width:440px;width:100%;
    box-shadow:0 20px 50px rgba(0,0,0,.45);
  }
  .share-card h3{
    font-size:.95rem;font-weight:600;margin-bottom:6px;color:var(--text);
  }
  .share-card p{
    font-size:.8rem;color:var(--muted);margin-bottom:14px;line-height:1.5;
  }
  .share-row{
    display:flex;gap:8px;align-items:stretch;
  }
  .share-row input{
    flex:1;font-family:var(--mono);font-size:.72rem;
    background:#0a0d12;border:1px solid var(--border);border-radius:7px;
    color:var(--text);padding:10px 12px;outline:none;
  }
  .share-row button{
    font-family:var(--font);font-size:.75rem;font-weight:600;
    padding:0 14px;border-radius:7px;cursor:pointer;
    background:var(--accent);border:1px solid var(--accent);color:#000;
  }
  .share-row button:hover{background:#ff8533}
  .share-card .close-row{
    margin-top:14px;text-align:right;
  }
  .share-card .close-row button{
    background:transparent;border:1px solid var(--border);color:var(--muted);
    font-size:.72rem;padding:6px 12px;border-radius:6px;cursor:pointer;
  }
  .share-card .close-row button:hover{color:var(--text);border-color:var(--border)}

  main.editor{display:flex;flex-direction:column;min-width:0;min-height:0;
    border-right:1px solid var(--border)}
  .toolbar{display:flex;align-items:center;gap:12px;padding:8px 16px;
    border-bottom:1px solid var(--border);background:var(--surface)}
  .path{flex:1;font-family:var(--mono);font-size:.78rem;color:var(--muted);
    display:flex;align-items:center;gap:10px}
  .path strong{color:var(--text)}
  .path .lock-badge{
    font-size:.58rem;color:var(--muted);padding:2px 6px;
    border:1px solid var(--border);border-radius:4px;
    text-transform:uppercase;letter-spacing:.06em;
  }
  .save-status{
    font-family:var(--mono);font-size:.68rem;color:var(--muted);
    display:inline-flex;align-items:center;gap:5px;opacity:0;
    transition:opacity .2s;
  }
  .save-status.show{opacity:1}
  .save-status.saving{color:var(--amber)}
  .save-status.saved{color:var(--green)}
  .save-status .sd{width:6px;height:6px;border-radius:50%;background:currentColor}
  .toolbar button{font-family:var(--font);font-size:.75rem;padding:5px 11px;
    border-radius:6px;background:var(--surface2);color:var(--text);
    border:1px solid var(--border);cursor:pointer}
  .toolbar button:hover{background:#222833}
  .editor-wrap{flex:1;position:relative;min-height:0;overflow:hidden}
  #editor,.highlight{position:absolute;inset:0;margin:0;padding:18px 22px;border:0;
    font-family:var(--mono);font-size:.85rem;line-height:1.6;tab-size:4;
    white-space:pre;overflow:auto}
  #editor{background:transparent;color:transparent;caret-color:var(--text);
    resize:none;outline:none;z-index:2}
  #editor::selection{background:rgba(255,107,0,.35);color:transparent}
  .highlight{background:var(--bg);color:var(--text);z-index:1;pointer-events:none;overflow:hidden}
  .highlight code{font:inherit;white-space:inherit;display:block;min-height:100%}
  .tok-keyword{color:var(--tok-keyword);font-weight:600}
  .tok-type{color:var(--tok-type)} .tok-string{color:var(--tok-string)}
  .tok-comment{color:var(--tok-comment);font-style:italic}
  .tok-number{color:var(--tok-number)} .tok-func{color:var(--tok-func)}
  .tok-annotation{color:var(--tok-annotation)} .tok-tag{color:var(--tok-tag)}
  .tok-attr{color:var(--tok-attr)} .tok-punct{color:var(--tok-punct)}
  .tok-meta{color:var(--tok-meta)}

  .resize-handle{height:7px;background:transparent;flex-shrink:0;
    cursor:row-resize;position:relative;
    border-top:1px solid var(--border);border-bottom:1px solid var(--border)}
  .resize-handle::before{content:"";position:absolute;left:50%;top:50%;
    transform:translate(-50%,-50%);width:40px;height:2px;
    background:var(--muted);border-radius:2px;opacity:.5}
  .resize-handle:hover{background:rgba(255,107,0,.06)}
  .resize-handle:hover::before{opacity:1;background:var(--accent)}

  .log-panel{height:200px;flex-shrink:0;display:flex;flex-direction:column;
    background:#05070a;min-height:60px;max-height:70vh}
  .log-head{display:flex;align-items:center;justify-content:space-between;
    padding:6px 12px;border-bottom:1px solid var(--border);
    font-family:var(--mono);font-size:.66rem;text-transform:uppercase;
    color:var(--muted);letter-spacing:.08em;flex-shrink:0}
  .log-head .lh-actions{display:flex;gap:6px}
  .log-head button{background:transparent;border:1px solid var(--border);
    color:var(--muted);font-family:var(--mono);font-size:.62rem;
    padding:2px 8px;border-radius:4px;cursor:pointer}
  .log-head button:hover{background:var(--surface2);color:var(--text)}
  .log{flex:1;overflow-y:auto;padding:8px 12px;margin:0;
    font-family:var(--mono);font-size:.7rem;line-height:1.5;color:#c8d0dd;
    white-space:pre-wrap;word-break:break-all}

  aside.preview{background:var(--surface);display:flex;flex-direction:column;
    align-items:center;padding:16px 14px;gap:12px;overflow-y:auto}
  .preview-title{font-family:var(--mono);font-size:.72rem;color:var(--muted);
    text-transform:none;letter-spacing:.04em;min-height:1em;
    text-align:center}
  .preview-title:empty{visibility:hidden}

  .phone{position:relative;width:300px;aspect-ratio:300/620;padding:5px;
    border-radius:44px;flex-shrink:0;
    background:linear-gradient(160deg,
      #f8f7f4 0%,#d6d2c8 14%,#b8b3a7 45%,#a09a8d 62%,#cfcabe 86%,#f0eee9 100%);
    box-shadow:0 0 0 2px #8a8377,0 0 0 4px #b8b3a7,0 20px 40px rgba(0,0,0,.5)}
  .bezel{position:relative;width:100%;height:100%;border-radius:40px;
    background:#08060a;padding:11px}
  .island{position:absolute;top:18px;left:50%;transform:translateX(-50%);
    width:76px;height:24px;background:#000;border-radius:999px;z-index:10}
  .island::before{content:"";position:absolute;top:50%;right:13px;
    transform:translateY(-50%);width:8px;height:8px;border-radius:50%;background:#04040a}
  .island::after{content:"";position:absolute;top:50%;left:13px;
    transform:translateY(-50%);width:26px;height:4px;background:#0a0a12;border-radius:2px}
  .screen{position:relative;width:100%;height:100%;overflow:hidden;
    border-radius:28px;background:#0b0805;
    display:flex;align-items:center;justify-content:center}
  .screen canvas{display:block;width:100%;height:100%;
    cursor:crosshair;touch-action:none;transition:opacity .3s ease}
  .screen .screen-overlay{position:absolute;inset:0;display:none;
    flex-direction:column;align-items:center;justify-content:center;gap:14px;
    z-index:5;background:radial-gradient(ellipse at center,
      rgba(10,8,5,.92), rgba(10,8,5,.98));
    padding:24px;text-align:center}
  .screen.overlay .screen-overlay{display:flex}
  .screen.overlay canvas{opacity:.06}

  .so-title{font-family:var(--mono);font-size:.8rem;color:var(--muted);
    letter-spacing:.14em;text-transform:uppercase}
  .so-big{font-family:var(--mono);font-size:2.2rem;font-weight:600;
    color:var(--text);line-height:1.1}
  .so-sub{font-family:var(--mono);font-size:.72rem;color:var(--muted)}
  .so-spinner{width:34px;height:34px;border-radius:50%;
    border:3px solid rgba(255,107,0,.15);border-top-color:var(--accent);
    animation:spin 1s linear infinite}
  @keyframes spin{to{transform:rotate(360deg)}}
  .home-bar{position:absolute;bottom:6px;left:50%;transform:translateX(-50%);
    width:76px;height:4px;border-radius:3px;background:rgba(255,234,203,.55);
    z-index:8;pointer-events:none}

  .pill{display:inline-flex;align-items:center;gap:.5rem;font-family:var(--mono);
    font-size:.7rem;padding:.4rem .7rem;border:1px solid var(--border);
    background:var(--surface2);color:var(--muted);border-radius:7px}
  .pill .dot{width:7px;height:7px;border-radius:50%;background:#b03a2e}
  .pill.on .dot{background:var(--green)}
  .pill.on{color:var(--green);border-color:rgba(61,214,140,.4)}
  .pill.warn .dot{background:var(--amber)}
  .pill.warn{color:var(--amber);border-color:rgba(255,184,77,.4)}
  .pill.err .dot{background:var(--red)}
  .pill.err{color:var(--red);border-color:rgba(255,92,92,.4)}

  .session-bar{width:100%;height:42px;background:#05070a;
    border:1px solid var(--border);border-radius:8px;
    position:relative;overflow:hidden;display:flex;align-items:center}
  .session-bar-fill{position:absolute;left:0;top:0;bottom:0;width:0%;
    background:linear-gradient(90deg,var(--accent) 0%, #ff8533 100%);
    transition:width .9s linear;opacity:.22}
  .session-bar-text{position:relative;width:100%;text-align:center;
    font-family:var(--mono);font-size:.78rem;
    color:var(--text);letter-spacing:.05em;z-index:1;font-weight:500}
  .session-bar.live .session-bar-text{color:var(--accent);font-weight:600}
  .session-bar.live .session-bar-fill{opacity:.32}
  .session-bar.warn .session-bar-text{color:var(--amber)}
  .session-bar.warn .session-bar-fill{
    background:linear-gradient(90deg,var(--amber) 0%, #ffcc80 100%);opacity:.18}
  .session-bar.err .session-bar-text{color:var(--red)}
  .session-bar.err .session-bar-fill{
    background:linear-gradient(90deg,var(--red) 0%, #ff8888 100%);opacity:.15}
  .session-bar.idle .session-bar-text{color:var(--muted)}

  .preview-actions{display:flex;gap:8px;flex-wrap:wrap;justify-content:center;width:100%}
  .preview-actions button{font-family:var(--font);font-size:.75rem;font-weight:600;
    padding:9px 16px;border-radius:7px;cursor:pointer;background:var(--surface2);
    color:var(--text);border:1px solid var(--border);transition:background .15s}
  .preview-actions button:hover:not(:disabled){background:#222833}
  .preview-actions button.accent{background:var(--accent);border-color:var(--accent);color:#000}
  .preview-actions button.accent:hover:not(:disabled){background:#ff8533}
  .preview-actions button.pay{
    background:transparent;border-color:rgba(61,214,140,.55);color:var(--green);
  }
  .preview-actions button.pay:hover:not(:disabled){background:rgba(61,214,140,.12)}
  .preview-actions button:disabled{opacity:.85;cursor:not-allowed}
  .preview-actions button.timing{
    background:linear-gradient(90deg,#1a1e26 0%,#2a1a0a 100%);
    border-color:var(--accent);color:var(--accent);
    font-family:var(--mono);font-weight:600;letter-spacing:.05em;
    font-variant-numeric:tabular-nums;
  }

  .loot{width:100%;display:flex;flex-direction:column;gap:8px;
    border-top:1px solid var(--border);padding-top:12px;margin-top:4px}
  .loot-title{font-family:var(--mono);font-size:.72rem;color:var(--muted);
    text-transform:uppercase;letter-spacing:.08em;display:flex;
    align-items:center;justify-content:space-between}
  .loot-title .tag{font-size:.58rem;background:var(--surface2);
    padding:2px 6px;border-radius:4px;color:var(--muted)}
  .loot-row{display:flex;gap:6px;width:100%}
  .loot-shot{flex:1;aspect-ratio:9/19.5;background:#05070a;
    border:1px solid var(--border);border-radius:6px;overflow:hidden;
    display:flex;align-items:center;justify-content:center;
    position:relative;transition:border-color .3s}
  .loot-shot.has-img{border-color:rgba(61,214,140,.35)}
  .loot-shot img{display:block;width:100%;height:100%;object-fit:cover}
  .loot-shot .loot-empty{font-family:var(--mono);font-size:.55rem;
    color:var(--muted);padding:6px;text-align:center;line-height:1.3}
  .loot-shot .cap{position:absolute;bottom:2px;right:4px;
    font-family:var(--mono);font-size:.5rem;color:var(--muted);
    background:rgba(0,0,0,.55);padding:1px 4px;border-radius:3px}
  .loot-actions{
    display:flex;flex-direction:column;gap:6px;width:100%;margin-top:4px;
  }
  .loot-actions button{
    width:100%;font-family:var(--font);font-size:.72rem;font-weight:560;
    padding:8px 10px;border-radius:7px;cursor:pointer;
    background:var(--surface2);border:1px solid var(--border);color:var(--text);
    transition:background .15s,opacity .15s;
  }
  .loot-actions button:hover:not(:disabled){background:#222833;border-color:#3a4458}
  .loot-actions button:disabled{opacity:.4;cursor:not-allowed}
  .loot-actions button.ready{
    border-color:rgba(61,214,140,.45);color:var(--green);
  }

  ::-webkit-scrollbar{width:8px;height:8px}
  ::-webkit-scrollbar-thumb{background:#2a3140;border-radius:4px}
  ::-webkit-scrollbar-thumb:hover{background:#3a4458}
</style>
</head>
<body>

{% set active = 'studio' %}{% set header_center %}<span class="ct-nav__kotlin">kotlin<b>2.0.21</b></span>{% endset %}{% set header_extra %}<div class="stats" id="stats">
  <div class="stat pool">
    <span class="label">pool</span>
    <span class="value" id="statPool">0</span>
  </div>
  <div class="stat inuse" id="statInUseWrap">
    <span class="label">in use</span>
    <span class="value" id="statInUse">0</span>
  </div>
  <div class="stat queue" id="statQueueWrap">
    <span class="label">queued</span>
    <span class="value" id="statQueue">0</span>
  </div>
</div>{% endset %}{% include "_header.html" %}

<div class="shell">
  <aside class="files">
    <div class="aside-head"><h2>scripts/</h2></div>
    <ul class="file-list" id="fileList"></ul>
    <div class="aside-foot">
      <button id="btnNew">+ New file</button>
      <button id="btnShare" class="share" type="button">Save / Share</button>
    </div>
  </aside>

<div class="share-modal" id="shareModal" role="dialog" aria-modal="true" aria-labelledby="shareTitle">
  <div class="share-card">
    <h3 id="shareTitle">Project saved</h3>
    <p>Anyone with this link can open the same files in the studio. Their edits stay in their own workspace until they share again.</p>
    <div class="share-row">
      <input id="shareUrl" type="text" readonly />
      <button type="button" id="btnCopyShare">Copy</button>
    </div>
    <div class="close-row">
      <button type="button" id="btnCloseShare">Close</button>
    </div>
  </div>
</div>
  <main class="editor">
    <div class="toolbar">
      <div class="path">
        <span id="currentPath">Select a file…</span>
        <span class="save-status" id="saveStatus"><span class="sd"></span><span id="saveStatusTxt"></span></span>
      </div>
      <button id="btnCopy" disabled>Copy</button>
    </div>
    <div class="editor-wrap">
      <pre class="highlight" aria-hidden="true"><code id="hlCode"></code></pre>
      <textarea id="editor" wrap="off" spellcheck="false" style="display:none"></textarea>
    </div>
    <div class="resize-handle" id="logResize"></div>
    <div class="log-panel" id="logPanel">
      <div class="log-head">
        <span>build log</span>
        <div class="lh-actions">
          <button id="btnCopyLog">copy</button>
          <button id="btnClearLog">clear</button>
        </div>
      </div>
      <pre class="log" id="log"></pre>
    </div>
  </main>
  <aside class="preview">
    <div class="preview-title" id="previewTitle"></div>

    <div class="phone">
      <div class="bezel">
        <div class="island"></div>
        <div class="screen" id="screen">
          <canvas id="cv" width="720" height="1560"></canvas>
          <div class="screen-overlay" id="overlay">
            <div class="so-title" id="ovTitle">ready</div>
            <div id="ovBody"></div>
            <div class="so-sub" id="ovSub">click BUILD &amp; RUN to start</div>
          </div>
        </div>
      </div>
      <span class="home-bar"></span>
    </div>

    <span class="pill" id="pill"><span class="dot"></span><span id="pillTxt">idle</span></span>

    <div class="session-bar idle" id="sessionBar">
      <div class="session-bar-fill" id="sessionFill"></div>
      <div class="session-bar-text" id="sessionText">idle — click BUILD &amp; RUN</div>
    </div>

    <div class="preview-actions">
      <button id="btnHome">HOME</button>
      <button id="btnBack">BACK</button>
      <button id="btnBuild" class="accent">BUILD &amp; RUN</button>
      <button id="btnPayBuild" class="pay" type="button" title="Uses 5¢ credits ($0.05)">PAY BUILD</button>
    </div>

    <div class="loot">
      <div class="loot-title">
        <span>loot</span>
        <span class="tag" id="lootTag">0/3</span>
      </div>
      <div class="loot-actions">
        <button type="button" id="btnDlProject">Download project</button>
        <button type="button" id="btnDlApk" disabled title="Run BUILD & RUN first">Download .apk</button>
      </div>
      <div class="loot-row" id="lootRow">
        <div class="loot-shot" data-idx="0">
          <span class="loot-empty">shot 1<br>t+2s</span>
        </div>
        <div class="loot-shot" data-idx="1">
          <span class="loot-empty">shot 2<br>t+3s</span>
        </div>
        <div class="loot-shot" data-idx="2">
          <span class="loot-empty">shot 3<br>t+4s</span>
        </div>
      </div>
    </div>
  </aside>
</div>
<script>
function esc(s){return s.replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;")}
const KT_KW=["package","import","class","interface","object","fun","val","var",
  "override","open","abstract","final","private","public","protected","internal",
  "return","if","else","when","for","while","do","break","continue","this","super",
  "null","true","false","is","as","in","out","by","where","try","catch","finally",
  "throw","companion","init","constructor","get","set","lateinit","suspend",
  "inline","data","sealed","enum","annotation","const","operator","infix"].join("|");
const RULES={
  kt:[{cls:"comment",re:/\/\/[^\n]*/},{cls:"comment",re:/\/\*[\s\S]*?\*\//},
      {cls:"string",re:/"(?:[^"\\\n]|\\.)*"/},{cls:"string",re:/'(?:[^'\\\n]|\\.)*'/},
      {cls:"annotation",re:/@[A-Za-z_][A-Za-z0-9_]*/},
      {cls:"number",re:/\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?[fFlLdD]?)\b/},
      {cls:"keyword",re:new RegExp("\\b(?:"+KT_KW+")\\b")},
      {cls:"type",re:/\b[A-Z][A-Za-z0-9_]*\b/},
      {cls:"func",re:/\b[a-z_][A-Za-z0-9_]*(?=\s*\()/}],
  xml:[{cls:"comment",re:/<!--[\s\S]*?-->/},{cls:"meta",re:/<\?[\s\S]*?\?>/},
       {cls:"string",re:/"[^"\n]*"|'[^'\n]*'/},
       {cls:"attr",re:/[A-Za-z_][A-Za-z0-9_:.-]*(?=\s*=)/},
       {cls:"tag",re:/[A-Za-z_][A-Za-z0-9_:.-]*/},
       {cls:"punct",re:/<\/?|\/?>|=|\//}],
  plain:[]};
function highlight(code, lang){
  const rules=RULES[lang]||[];
  if(!rules.length) return esc(code);
  const src=rules.map(r=>"("+r.re.source+")").join("|");
  const re=new RegExp(src,"g");
  let out="", last=0, m;
  while((m=re.exec(code))!==null){
    if(m.index>last) out+=esc(code.slice(last,m.index));
    for(let i=1;i<=rules.length;i++){
      if(m[i]!==undefined){
        out+='<span class="tok-'+rules[i-1].cls+'">'+esc(m[i])+'</span>';
        break;
      }
    }
    last=m.index+m[0].length;
    if(m[0].length===0) re.lastIndex++;
  }
  if(last<code.length) out+=esc(code.slice(last));
  return out;
}
function pickLang(name){
  if(name.endsWith(".kt")||name.endsWith(".kts")) return "kt";
  if(name.endsWith(".xml")) return "xml";
  return "plain";
}

const editorEl=document.getElementById("editor");
const hlEl=document.getElementById("hlCode");
const listEl=document.getElementById("fileList");
const pathEl=document.getElementById("currentPath");
const gutterEl=document.getElementById("editorGutter");
const lintPanel=document.getElementById("lintPanel");

function updateGutter(){
  if(!gutterEl || !editorEl) return;
  const text = editorEl.value || "";
  const n = text.split("\n").length;
  const errors = window.__lintErrors || {};
  let html = "";
  for(let i=1;i<=n;i++){
    const err = errors[i];
    html += '<span class="ln'+(err?' err':'')+'" title="'+(err?String(err).replace(/"/g,'&quot;'):'')+'">'+i+'</span>';
  }
  gutterEl.innerHTML = html;
  gutterEl.scrollTop = editorEl.scrollTop;
}

function lintKotlin(src){
  const errors = {}; // line -> message
  if(!src) return errors;
  const lines = src.split("\n");
  let brace = 0, paren = 0, bracket = 0;
  let inBlockComment = false;
  for(let i=0;i<lines.length;i++){
    let line = lines[i];
    const ln = i+1;
    // strip strings roughly for balance check
    let cleaned = "";
    let inStr = false, strCh = "";
    for(let j=0;j<line.length;j++){
      const c = line[j], n = line[j+1];
      if(inBlockComment){
        if(c==='*' && n==='/'){ inBlockComment=false; j++; }
        continue;
      }
      if(!inStr && c==='/' && n==='/') break;
      if(!inStr && c==='/' && n==='*'){ inBlockComment=true; j++; continue; }
      if((c==='"' || c==="'") && (j===0 || line[j-1]!=='\\')){
        if(!inStr){ inStr=true; strCh=c; }
        else if(c===strCh) inStr=false;
        continue;
      }
      if(inStr) continue;
      cleaned += c;
    }
    // unclosed string on this line (heuristic)
    if(inStr) errors[ln] = errors[ln] || "Unclosed string literal";
    for(const c of cleaned){
      if(c==='{') brace++;
      else if(c==='}'){ brace--; if(brace<0){ errors[ln]="Unexpected closing '}'"; brace=0; } }
      else if(c==='(') paren++;
      else if(c===')'){ paren--; if(paren<0){ errors[ln]="Unexpected closing ')'"; paren=0; } }
      else if(c==='[') bracket++;
      else if(c===']'){ bracket--; if(bracket<0){ errors[ln]="Unexpected closing ']'"; bracket=0; } }
    }
    // common kotlin mistakes
    if(/\bLog\.(d|e|i|w|v)\s*\(\s*"[^"]*$/.test(line) || /\bLog\.(d|e|i|w|v)\s*\(\s*"[^"]*"[^)]*$/.test(line) && !line.includes(")")){
      if(line.includes('Log.') && (line.match(/"/g)||[]).length % 2 === 1)
        errors[ln] = errors[ln] || "Possible unclosed string in Log call";
    }
    if(/\bpackage\s+[^\s;]+\s+[^\s]/.test(line) && !line.trim().startsWith("//"))
      errors[ln] = errors[ln] || "package must be alone on the line";
  }
  if(brace>0) errors[lines.length] = (errors[lines.length]?errors[lines.length]+"; ":"") + brace+" unclosed '{'";
  if(paren>0) errors[lines.length] = (errors[lines.length]?errors[lines.length]+"; ":"") + paren+" unclosed '('";
  if(bracket>0) errors[lines.length] = (errors[lines.length]?errors[lines.length]+"; ":"") + bracket+" unclosed '['";
  return errors;
}

function runLint(){
  if(!editorEl) return;
  const path = (pathEl && pathEl.textContent) || "";
  const isKt = /\.kt\b/i.test(path) || /\.kts\b/i.test(path) || !path;
  const errs = isKt ? lintKotlin(editorEl.value) : {};
  window.__lintErrors = errs;
  updateGutter();
  if(lintPanel){
    const keys = Object.keys(errs).map(Number).sort((a,b)=>a-b);
    if(!keys.length){ lintPanel.hidden = true; lintPanel.innerHTML=""; return; }
    lintPanel.hidden = false;
    lintPanel.innerHTML = keys.slice(0,8).map(ln =>
      '<div data-line="'+ln+'">Line '+ln+': '+errs[ln]+'</div>'
    ).join("");
    lintPanel.querySelectorAll("[data-line]").forEach(el=>{
      el.onclick = ()=>{
        const ln = parseInt(el.getAttribute("data-line"),10);
        const lines = editorEl.value.split("\n");
        let pos = 0;
        for(let i=0;i<ln-1 && i<lines.length;i++) pos += lines[i].length+1;
        editorEl.focus();
        editorEl.setSelectionRange(pos, pos);
        editorEl.scrollTop = Math.max(0, (ln-3) * 1.6 * 13.6);
        updateGutter();
      };
    });
  }
}

if(editorEl){
  editorEl.addEventListener("scroll", ()=>{
    if(gutterEl) gutterEl.scrollTop = editorEl.scrollTop;
    if(hlEl && hlEl.parentElement) hlEl.parentElement.scrollTop = editorEl.scrollTop;
  });
  editorEl.addEventListener("input", ()=>{ runLint(); });
}
const logEl=document.getElementById("log");
const logPanel=document.getElementById("logPanel");
const logResize=document.getElementById("logResize");
const lootRow=document.getElementById("lootRow");
const lootTag=document.getElementById("lootTag");
const saveStatus=document.getElementById("saveStatus");
const saveStatusTxt=document.getElementById("saveStatusTxt");
let activeFile=null;
let activeIsDefault=false;
let autosaveTimer=null;
let saveStatusTimer=null;
let workspaceId=null;  // fresh per page load — isolates edits from other tabs
const embeddedProjectId = {{ project_id | tojson }};

function wsHeaders(extra){
  const h = Object.assign({}, extra || {});
  if(workspaceId) h["X-Workspace-Id"] = workspaceId;
  return h;
}
function wsUrl(path){
  if(!workspaceId) return path;
  const sep = path.indexOf("?") >= 0 ? "&" : "?";
  return path + sep + "ws=" + encodeURIComponent(workspaceId);
}

function refreshHighlight(){
  if(!activeFile) return;
  hlEl.innerHTML=highlight(editorEl.value, pickLang(activeFile))
                +(editorEl.value.endsWith("\n")?"\n":"");
  document.querySelector(".highlight").scrollTop=editorEl.scrollTop;
  document.querySelector(".highlight").scrollLeft=editorEl.scrollLeft;
}

function showSaveStatus(kind, text){
  saveStatusTxt.textContent = text;
  saveStatus.className = "save-status show " + kind;
  if(saveStatusTimer){ clearTimeout(saveStatusTimer); saveStatusTimer=null; }
  if(kind === "saved"){
    saveStatusTimer = setTimeout(()=>{
      saveStatus.classList.remove("show");
    }, 1400);
  }
}

function fileItemHtml(f){
  const name = f.name;
  if(f.is_default){
    return '<li class="file-item locked" data-name="'+name+'" data-default="1">'+
           '<span class="file-name">'+name+'</span></li>';
  }
  return '<li class="file-item" data-name="'+name+'" data-default="0">'+
         '<span class="file-name">'+name+'</span>'+
         '<button class="file-del" data-name="'+name+'" title="delete">×</button>'+
         '</li>';
}

async function ensureWorkspace(){
  // Every full page load gets a brand-new workspace.
  // /studio → seed from defaults; /project/<id> → seed from that snapshot.
  if(workspaceId) return workspaceId;
  const opts = {method:"POST", headers:{"Content-Type":"application/json"}};
  if(embeddedProjectId){
    opts.body = JSON.stringify({project_id: embeddedProjectId});
  }
  const r = await fetch("/api/workspace", opts);
  if(!r.ok) throw new Error("workspace create failed");
  const d = await r.json();
  workspaceId = d.workspace_id;
  if(d.has_apk) setApkReady(true);
  return workspaceId;
}

async function loadFiles(){
  try{
    await ensureWorkspace();
    const r=await fetch(wsUrl("/api/files"), {headers: wsHeaders()});
    if(!r.ok) throw 0;
    const payload=await r.json();
    const files = Array.isArray(payload) ? payload : (payload.files || []);
    if(payload.workspace_id) workspaceId = payload.workspace_id;
    const defaults = files.filter(f => f.is_default);
    const customs  = files.filter(f => !f.is_default);

    let html = "";
    if(defaults.length){
      html += '<li class="file-group">default <span class="tag">required</span></li>';
      html += defaults.map(fileItemHtml).join("");
    }
    if(customs.length){
      html += '<li class="file-group divider">your files <span class="tag">'+customs.length+'</span></li>';
      html += customs.map(fileItemHtml).join("");
    }
    if(!html){
      html = "<li style='padding:12px;color:var(--muted);font-size:.75rem'>no files</li>";
    }
    listEl.innerHTML = html;

    listEl.querySelectorAll(".file-item").forEach(el => {
      el.onclick = (e) => {
        if(e.target.classList.contains("file-del")) return;
        openFile(el.dataset.name);
      };
    });
    listEl.querySelectorAll(".file-del").forEach(b => {
      b.onclick = async (e) => {
        e.stopPropagation();
        const nm = b.dataset.name;
        if(!confirm("Delete " + nm + "?")) return;
        try{
          const r = await fetch(wsUrl("/api/files/" + encodeURIComponent(nm)),
                                {method:"DELETE", headers: wsHeaders()});
          if(!r.ok){
            const body = await r.json().catch(()=>({detail:"error"}));
            flashPill((body.detail||"delete failed").slice(0,40));
            return;
          }
        }catch(err){
          flashPill("delete failed");
          return;
        }
        if(activeFile === nm){
          activeFile = null;
          activeIsDefault = false;
          editorEl.value = "";
          editorEl.style.display = "none";
          pathEl.textContent = "Select a file…";
          hlEl.innerHTML = "";
          document.getElementById("btnCopy").disabled = true;
        }
        await loadFiles();
      };
    });

    if(!activeFile){
      const first = files.find(f => f.name === "MainActivity.kt") || files[0];
      if(first) openFile(first.name);
    } else {
      const still = files.find(f => f.name === activeFile);
      if(!still){
        const first = files.find(f => f.name === "MainActivity.kt") || files[0];
        if(first) openFile(first.name);
      } else {
        listEl.querySelectorAll(".file-item").forEach(el =>
          el.classList.toggle("active", el.dataset.name === activeFile));
      }
    }
  }catch(e){
    listEl.innerHTML="<li style='padding:12px;color:#ff8888;font-size:.75rem'>load failed</li>";
  }
}

async function openFile(name){
  const r=await fetch(wsUrl("/api/files/"+encodeURIComponent(name)), {headers: wsHeaders()});
  if(!r.ok) return;
  const d=await r.json();
  activeFile=name;
  activeIsDefault = !!(listEl.querySelector('.file-item[data-name="'+CSS.escape(name)+'"]')
                       ?.dataset.default === "1");
  editorEl.style.display="block";
  editorEl.value=d.content;
  try{runLint();}catch(e){}
  pathEl.innerHTML = "<strong>"+name+"</strong>"
    + (activeIsDefault ? ' <span class="lock-badge">default</span>' : "");
  document.getElementById("btnCopy").disabled=false;
  editorEl.scrollTop=0; editorEl.scrollLeft=0;
  refreshHighlight();
  saveStatus.classList.remove("show");
  listEl.querySelectorAll(".file-item").forEach(el=>
    el.classList.toggle("active", el.dataset.name===name));
}

function scheduleAutosave(){
  if(!activeFile) return;
  if(autosaveTimer) clearTimeout(autosaveTimer);
  showSaveStatus("saving", "saving…");
  autosaveTimer = setTimeout(async () => {
    autosaveTimer = null;
    if(!activeFile) return;
    try{
      const r = await fetch(wsUrl("/api/files/"+encodeURIComponent(activeFile)), {
        method:"PUT",
        headers: wsHeaders({"Content-Type":"application/json"}),
        body: JSON.stringify({content: editorEl.value})
      });
      if(r.ok) showSaveStatus("saved", "saved");
      else showSaveStatus("saving", "save failed");
    }catch(e){
      showSaveStatus("saving", "save failed");
    }
  }, 800);
}

editorEl.addEventListener("input", () => { refreshHighlight(); scheduleAutosave(); });
editorEl.addEventListener("scroll", ()=>{
  document.querySelector(".highlight").scrollTop=editorEl.scrollTop;
  document.querySelector(".highlight").scrollLeft=editorEl.scrollLeft;
});
editorEl.addEventListener("keydown", e=>{
  if(e.key==="Tab"){
    e.preventDefault();
    const s=editorEl.selectionStart, en=editorEl.selectionEnd;
    editorEl.value=editorEl.value.slice(0,s)+"    "+editorEl.value.slice(en);
    editorEl.selectionStart=editorEl.selectionEnd=s+4;
    editorEl.dispatchEvent(new Event("input"));
  }
});
document.getElementById("btnCopy").onclick=()=>{
  navigator.clipboard.writeText(editorEl.value); flashPill("copied");
};
document.getElementById("btnNew").onclick=async()=>{
  const name=prompt("New file name (e.g. Page3.kt or themes.xml):");
  if(!name) return;
  const clean = name.trim().replace(/^\/+/, "");
  if(!clean){ flashPill("invalid name"); return; }
  const r = await fetch(wsUrl("/api/files/"+encodeURIComponent(clean)),{
    method:"PUT", headers: wsHeaders({"Content-Type":"application/json"}),
    body:JSON.stringify({content:""})});
  if(!r.ok){ flashPill("create failed"); return; }
  await loadFiles(); openFile(clean);
};

const shareModal = document.getElementById("shareModal");
const shareUrlEl = document.getElementById("shareUrl");
document.getElementById("btnShare").onclick = async () => {
  try {
    await ensureWorkspace();
    // Flush current editor to workspace before snapshot
    if (activeFile) {
      await fetch(wsUrl("/api/files/" + encodeURIComponent(activeFile)), {
        method: "PUT",
        headers: wsHeaders({"Content-Type": "application/json"}),
        body: JSON.stringify({content: editorEl.value})
      });
    }
    const r = await fetch("/api/project", {
      method: "POST",
      headers: wsHeaders({"Content-Type": "application/json"})
    });
    if (!r.ok) {
      const body = await r.json().catch(() => ({}));
      flashPill((body.detail || "share failed").toString().slice(0, 40));
      return;
    }
    const d = await r.json();
    const abs = location.origin + (d.url || ("/project/" + d.project_id));
    shareUrlEl.value = abs;
    shareModal.classList.add("open");
    // Update address bar without reload so the link is the current project
    try {
      history.replaceState(null, "", d.url || ("/project/" + d.project_id));
    } catch (e) {}
    flashPill("link ready");
  } catch (e) {
    flashPill("share failed");
  }
};
document.getElementById("btnCopyShare").onclick = async () => {
  try {
    await navigator.clipboard.writeText(shareUrlEl.value);
    const b = document.getElementById("btnCopyShare");
    const old = b.textContent;
    b.textContent = "Copied";
    setTimeout(() => { b.textContent = old; }, 1200);
  } catch (e) {
    shareUrlEl.select();
    flashPill("copy failed");
  }
};
document.getElementById("btnCloseShare").onclick = () => {
  shareModal.classList.remove("open");
};
shareModal.addEventListener("click", (e) => {
  if (e.target === shareModal) shareModal.classList.remove("open");
});
document.getElementById("btnClearLog").onclick=()=>{ logEl.textContent=""; };
document.getElementById("btnCopyLog").onclick=async()=>{
  try{
    await navigator.clipboard.writeText(logEl.textContent);
    const b = document.getElementById("btnCopyLog");
    const old = b.textContent;
    b.textContent = "copied";
    setTimeout(()=>{ b.textContent = old; }, 1000);
  }catch(e){ flashPill("copy failed"); }
};

logResize.addEventListener("mousedown", e => {
  e.preventDefault();
  const startY = e.clientY;
  const startH = logPanel.offsetHeight;
  document.body.style.cursor = "row-resize";
  document.body.style.userSelect = "none";
  const move = ev => {
    const delta = startY - ev.clientY;
    const newH = Math.max(60, Math.min(window.innerHeight * 0.7, startH + delta));
    logPanel.style.height = newH + "px";
  };
  const up = () => {
    document.removeEventListener("mousemove", move);
    document.removeEventListener("mouseup", up);
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
  };
  document.addEventListener("mousemove", move);
  document.addEventListener("mouseup", up);
});

const previewTitle=document.getElementById("previewTitle");
const pill=document.getElementById("pill");
const pillT=document.getElementById("pillTxt");
const screen=document.getElementById("screen");
const overlay=document.getElementById("overlay");
const ovTitle=document.getElementById("ovTitle");
const ovBody=document.getElementById("ovBody");
const ovSub=document.getElementById("ovSub");
const cv=document.getElementById("cv");
const ctx=cv.getContext("2d");
const sessionBar=document.getElementById("sessionBar");
const sessionFill=document.getElementById("sessionFill");
const sessionText=document.getElementById("sessionText");
const btnBuild=document.getElementById("btnBuild");

const statPool=document.getElementById("statPool");
const statInUse=document.getElementById("statInUse");
const statQueue=document.getElementById("statQueue");
const statInUseWrap=document.getElementById("statInUseWrap");
const statQueueWrap=document.getElementById("statQueueWrap");

let state="idle";
let sessionEnded=false;
let lastTick=0;
let countdown=0;
let sessionTotal=15;
let streamWs=null;
let decoder=null, configured=false;
let nativeW=720, nativeH=1560, ts=0, lastCfg=null;
let pending=[];
let frames=0, fpsT=performance.now();
let idleTimer=null;
let buildWatchdog=null;

function flashPill(msg){
  const old=pillT.textContent;
  pillT.textContent=msg;
  setTimeout(()=>{ if(pillT.textContent===msg) pillT.textContent=old; },1200);
}
function setPillClass(cls){
  pill.classList.remove("on","warn","err");
  if(cls) pill.classList.add(cls);
}
function setOverlay(show, title, body, sub){
  if(!show){ screen.classList.remove("overlay"); ovBody.innerHTML=""; return; }
  screen.classList.add("overlay");
  if(title!=null) ovTitle.textContent=title;
  if(body!=null){
    if(typeof body==="string") ovBody.innerHTML=body;
    else { ovBody.innerHTML=""; ovBody.appendChild(body); }
  }
  if(sub!=null) ovSub.textContent=sub;
}
function setSessionBar(cls, text, fillPct){
  sessionBar.className="session-bar"+(cls?" "+cls:"");
  if(text!=null) sessionText.textContent=text;
  if(fillPct!=null) sessionFill.style.width=Math.max(0,Math.min(100,fillPct))+"%";
}
function appendLog(line){
  logEl.textContent += line;
  logEl.scrollTop = logEl.scrollHeight;
  if(buildWatchdog){
    clearTimeout(buildWatchdog);
    buildWatchdog = setTimeout(onBuildTimeout, 180000);
  }
}
function onBuildTimeout(){
  if(state === "building"){
    appendLog("\n[clawtank] build stalled (3 min no output) — aborting\n");
    if(streamWs) try{ streamWs.close(); }catch(e){}
    setState("error");
  }
}
function endSession(){
  sessionEnded=true;
  btnBuild.disabled=false;
  btnBuild.textContent="BUILD & RUN";
  btnBuild.classList.remove("timing");
  if(btnPayBuild){
    btnPayBuild.disabled=false;
    btnPayBuild.textContent="PAY BUILD";
  }
  if(buildWatchdog){ clearTimeout(buildWatchdog); buildWatchdog=null; }
}

function resetLoot(){
  lootRow.querySelectorAll(".loot-shot").forEach(el => {
    el.classList.remove("has-img");
    const idx = parseInt(el.dataset.idx,10);
    const t = ["t+2s","t+3s","t+4s"][idx] || "";
    el.innerHTML = '<span class="loot-empty">shot '+(idx+1)+
                   '<br>'+t+'</span>';
  });
  lootTag.textContent = "0/3";
  // Keep Download .apk enabled if a prior build (or shared project) produced one
}

let apkPollTimer = null;

function setApkReady(ready){
  const b = document.getElementById("btnDlApk");
  if(!b) return;
  b.disabled = !ready;
  b.classList.toggle("ready", !!ready);
  b.title = ready ? "Download the last successful debug APK" : "Run BUILD & RUN first";
}

async function checkApkStatus(){
  try{
    await ensureWorkspace();
    const r = await fetch(wsUrl("/api/download/apk/status"), {headers: wsHeaders()});
    if(!r.ok) return false;
    const d = await r.json();
    if(d.ready){
      setApkReady(true);
      return true;
    }
  }catch(e){}
  return false;
}

function startApkPoll(){
  if(apkPollTimer){ clearInterval(apkPollTimer); apkPollTimer = null; }
  let n = 0;
  // Immediate check, then every 500ms for up to ~30s
  checkApkStatus();
  apkPollTimer = setInterval(async () => {
    n++;
    const ok = await checkApkStatus();
    if(ok || n >= 60){
      clearInterval(apkPollTimer);
      apkPollTimer = null;
    }
  }, 500);
}

async function downloadWithWs(path, fallbackName){
  await ensureWorkspace();
  const url = wsUrl(path);
  const r = await fetch(url, {headers: wsHeaders()});
  if(!r.ok){
    let msg = "download failed";
    try{
      const j = await r.json();
      msg = (j.detail || msg).toString();
    }catch(e){}
    flashPill(msg.slice(0,48));
    return;
  }
  const blob = await r.blob();
  let name = fallbackName;
  const cd = r.headers.get("Content-Disposition") || "";
  const m = /filename="?([^";]+)"?/.exec(cd);
  if(m) name = m[1];
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}

document.getElementById("btnDlProject").onclick = () => {
  downloadWithWs("/api/download/project", "clawtank-project.zip");
};
document.getElementById("btnDlApk").onclick = () => {
  downloadWithWs("/api/download/apk", "app-debug.apk");
};
function setLootScreenshot(idx, b64){
  if(idx == null) return;
  const el = lootRow.querySelector('.loot-shot[data-idx="'+idx+'"]');
  if(!el) return;
  const t = ["t+2s","t+3s","t+4s"][idx] || "";
  el.innerHTML = "";
  const img = document.createElement("img");
  img.src = "data:image/png;base64," + b64;
  img.alt = "shot " + (idx+1);
  el.appendChild(img);
  const cap = document.createElement("span");
  cap.className = "cap";
  cap.textContent = t;
  el.appendChild(cap);
  el.classList.add("has-img");
  const have = lootRow.querySelectorAll(".loot-shot.has-img").length;
  lootTag.textContent = have + "/3";
}

function formatDeviceLabel(m){
  // e.g. "Android 14 · sdk_gphone64_arm64" or "Android 14 · emulator-5554"
  const android = (m && (m.android || (m.api ? ("API " + m.api) : null))) || "Android 14";
  let phone = (m && (m.device || m.device_name || m.device_id)) || "";
  phone = String(phone).trim();
  // Drop noisy "device" suffix / empty
  if(!phone || phone === "?" ) phone = "";
  // Prefer a short friendly form for common emulator names
  if(/^emulator-\d+$/i.test(phone)) phone = phone;
  else if(/sdk_gphone|google_sdk|generic/i.test(phone)) phone = "Emulator";
  if(phone) return android + " · " + phone;
  return android;
}

function setPreviewTitle(text){
  if(!previewTitle) return;
  previewTitle.textContent = text || "";
}

function setState(next){
  if(state===next) return;
  state=next;
  if(idleTimer){ clearTimeout(idleTimer); idleTimer=null; }

  switch(next){
    case "idle":
      setPillClass(""); pillT.textContent="idle";
      setOverlay(true,"ready","", "click BUILD & RUN to start");
      setSessionBar("idle","idle — click BUILD & RUN",0);
      setPreviewTitle("");
      endSession(); break;
    case "queued":
      setPillClass("warn"); pillT.textContent="waiting";
      setPreviewTitle("");
      setOverlay(true,"in queue","", "");
      setSessionBar("warn","waiting in queue",0);
      btnBuild.disabled=true; btnBuild.textContent="RUNNING…";
      btnBuild.classList.remove("timing");
      break;
    case "assigned":
      setPillClass("warn"); pillT.textContent="assigned";
      setPreviewTitle("");
      setOverlay(true,"device assigned",
        '<div class="so-spinner"></div>', "preparing emulator…");
      setSessionBar("warn","preparing emulator…",0); break;
    case "building":
      setPillClass("warn"); pillT.textContent="building";
      setPreviewTitle("");
      setOverlay(true,"building",
        '<div class="so-spinner"></div>', "see log below");
      setSessionBar("warn","building…",0);
      if(buildWatchdog){ clearTimeout(buildWatchdog); }
      buildWatchdog = setTimeout(onBuildTimeout, 180000);
      break;
    case "live":
      setPillClass("on"); pillT.textContent="live";
      setOverlay(false);
      setSessionBar("live",(countdown||sessionTotal)+"s remaining",100);
      btnBuild.disabled=true;
      btnBuild.classList.add("timing");
      btnBuild.textContent=(countdown||sessionTotal)+"s";
      if(buildWatchdog){ clearTimeout(buildWatchdog); buildWatchdog=null; }
      break;
    case "expired":
      setPillClass("warn"); pillT.textContent="session ended";
      setPreviewTitle("");
      setOverlay(true,"session ended","", "returning to idle…");
      setSessionBar("warn","session ended — timer expired",0);
      endSession();
      idleTimer=setTimeout(()=>{ if(state==="expired") setState("idle"); },2000);
      break;
    case "offline":
      setPillClass("err"); pillT.textContent="emulator offline";
      setPreviewTitle("");
      setOverlay(true,"emulator offline","", "returning to idle…");
      setSessionBar("err","emulator offline",0);
      endSession();
      idleTimer=setTimeout(()=>{ if(state==="offline") setState("idle"); },3000);
      break;
    case "error":
      setPillClass("err"); pillT.textContent="error";
      setPreviewTitle("");
      setOverlay(true,"error","", "returning to idle…");
      setSessionBar("err","error — see log",0);
      endSession();
      idleTimer=setTimeout(()=>{ if(state==="error") setState("idle"); },3000);
      break;
  }
}

function makeDecoder(){
  return new VideoDecoder({
    output(f){
      if(f.displayWidth!==nativeW||f.displayHeight!==nativeH){
        nativeW=f.displayWidth; nativeH=f.displayHeight;
        cv.width=nativeW; cv.height=nativeH;
      }
      ctx.drawImage(f,0,0,cv.width,cv.height);
      f.close(); frames++;
      const now=performance.now();
      if(now-fpsT>1000){
        if(state==="live"){
          pillT.textContent="live · "+frames+"fps";
          setSessionBar("live",
            (countdown||sessionTotal)+"s remaining · "+frames+"fps",
            (countdown/Math.max(sessionTotal,1))*100);
        }
        frames=0; fpsT=now;
      }
    },
    error(e){ console.error("decode", e); }
  });
}
async function configDecoder(preferred){
  const list=[preferred,"avc1.64001F","avc1.640028","avc1.4D401F",
              "avc1.4D401E","avc1.42E01F","avc1.42E01E","avc1.42C029"]
    .filter((v,i,a)=>v&&a.indexOf(v)===i);
  for(const codec of list){
    try{
      const s=await VideoDecoder.isConfigSupported({
        codec, codedWidth:nativeW, codedHeight:nativeH, optimizeForLatency:true});
      if(s.supported){
        decoder.configure({codec, codedWidth:nativeW, codedHeight:nativeH,
                           optimizeForLatency:true});
        configured=true; return codec;
      }
    }catch(e){}
  }
  return null;
}
function feed(buf){
  if(buf.length<2) return;
  const flags=buf[0];
  const isKey=(flags&1)!==0, isCfg=(flags&2)!==0;
  const payload=buf.subarray(1);
  if(isCfg){ lastCfg=payload; return; }
  let data=payload;
  if(isKey && lastCfg){
    data=new Uint8Array(lastCfg.length+payload.length);
    data.set(lastCfg,0); data.set(payload,lastCfg.length);
  }
  ts+=16667;
  try{
    decoder.decode(new EncodedVideoChunk({
      type:isKey?"key":"delta", timestamp:ts, data}));
  }catch(e){}
}

function connectStream(){
  if(streamWs) try{ streamWs.close(); }catch(e){}
  const proto=location.protocol==="https:"?"wss:":"ws:";
  const q = new URLSearchParams();
  if(workspaceId) q.set("ws", workspaceId);
  const qs = q.toString() ? ("?" + q.toString()) : "";
  streamWs=new WebSocket(proto+"//"+location.host+"/ws/stream"+qs);
  streamWs.binaryType="arraybuffer";
  streamWs.onopen=()=>{
    if(decoder) try{ decoder.close(); }catch(e){}
    decoder=makeDecoder(); configured=false;
    lastCfg=null; pending=[];
  };
  streamWs.onclose=()=>{
    if(!sessionEnded){
      if(state==="live"||state==="building"||state==="assigned"||state==="queued"){
        setState("offline");
      } else if(state!=="idle" && state!=="expired" && state!=="error"){
        setState("idle");
      }
    }
    streamWs=null;
  };
  streamWs.onerror=()=>{};

  streamWs.onmessage=async ev=>{
    if(typeof ev.data==="string"){
      let m = null;
      const trimmed = ev.data.trim();
      if(trimmed.startsWith("{")){
        try{ m = JSON.parse(trimmed); }catch(e){ m = null; }
      }
      if(!m){
        appendLog(ev.data.endsWith("\n") ? ev.data : ev.data + "\n");
        return;
      }
      if(m.type==="queued"){
        if(typeof m.tick==="number" && m.tick>0){
          if(m.tick<=lastTick) return;
          lastTick=m.tick;
        }
        const pos=m.position||0, qn=m.queue_size||0;
        const pool=m.pool_size||0, inuse=m.inuse||0;
        setState("queued");
        const poolLine="pool "+pool
          +(inuse?" · "+inuse+" in use":"")
          +(qn?" · "+qn+" waiting":"");
        if(pool===0){
          setOverlay(true,"waiting","", "no emulators online yet");
          setSessionBar("warn","waiting — no emulators online",0);
        }else if(pos>1){
          setOverlay(true,"in queue",
            '<div class="so-big">#'+pos+'</div>', poolLine);
          setSessionBar("warn","waiting · #"+pos+" in line · "+poolLine,0);
        }else{
          setOverlay(true,"in queue",
            '<div class="so-big">next</div>', poolLine);
          setSessionBar("warn","next up · "+poolLine,0);
        }
        return;
      }
      if(m.type==="assigned"){ setState("assigned"); return; }
      if(m.type==="building"){
        setState("building");
        // Compile is underway; APK will be uploaded as soon as gradle finishes.
        startApkPoll();
        return;
      }
      if(m.type==="loot_screenshot"){
        setLootScreenshot(m.idx, m.data);
        return;
      }
      if(m.type==="loot_log"){ return; }
      if(m.type==="ready"){
        countdown=m.duration||15; sessionTotal=countdown;
        nativeW=m.width||nativeW; nativeH=m.height||nativeH;
        cv.width=nativeW; cv.height=nativeH;
        const used=await configDecoder(m.codec);
        if(!used){ setState("error"); return; }
        setPreviewTitle(formatDeviceLabel(m));
        setState("live");
        // Successful paid build — keep the charge
        payBuildPending=false;
        if(btnPayBuild){ btnPayBuild.disabled=false; btnPayBuild.textContent="PAY BUILD"; }
        // APK upload can arrive slightly after compile — poll until ready.
        startApkPoll();
        try{ streamWs.send(JSON.stringify({type:"ready"})); }catch(e){}
        pending.forEach(feed); pending=[];
        return;
      }
      if(m.type==="tick"){
        countdown=m.remaining;
        const pct=(countdown/Math.max(sessionTotal,1))*100;
        if(state==="live"){
          setSessionBar("live", countdown+"s remaining", pct);
          btnBuild.textContent = countdown + "s";
        }
        return;
      }
      if(m.type==="expired"){ setState("expired"); return; }
      if(m.type==="emulator_offline"){ setState("offline"); return; }
      if(m.type==="build_failed"){
        setState("error"); flashPill("build failed"); return;
      }
      if(m.type==="error"){
        setState("error");
        flashPill((m.message||"error").slice(0,40));
        // Pay Build is non-refundable (charged upfront)
        payBuildPending=false;
        if(btnPayBuild){ btnPayBuild.disabled=false; btnPayBuild.textContent="PAY BUILD"; }
        return;
      }
      return;
    }

    const buf=new Uint8Array(ev.data);
    if(!configured){ pending.push(buf); if(pending.length>512) pending.shift(); return; }
    feed(buf);
  };
}

const btnPayBuild=document.getElementById("btnPayBuild");
let payBuildPending=false;

function startStudioBuild(){
  logEl.textContent="";
  resetLoot();
  btnBuild.disabled=true;
  btnBuild.textContent="RUNNING…";
  btnBuild.classList.remove("timing");
  if(btnPayBuild){
    btnPayBuild.disabled=true;
    if(payBuildPending) btnPayBuild.textContent="PAYING…";
  }

  if(autosaveTimer){ clearTimeout(autosaveTimer); autosaveTimer=null; }
  if(activeFile){
    fetch(wsUrl("/api/files/"+encodeURIComponent(activeFile)),{
      method:"PUT", headers: wsHeaders({"Content-Type":"application/json"}),
      body:JSON.stringify({content:editorEl.value})
    }).catch(()=>{});
  }
  sessionEnded=false; lastTick=0;
  setState("queued");
  connectStream();
}

btnBuild.onclick=()=>{
  payBuildPending=false;
  startStudioBuild();
};

if(btnPayBuild) btnPayBuild.onclick=async ()=>{
  // Charge 5¢ ($0.05) then run the same build pipeline as BUILD & RUN
  try{
    const r = await fetch("/api/credits/charge", {method:"POST", credentials:"same-origin"});
    if(r.status === 401){
      flashPill("login required");
      location.href="/login";
      return;
    }
    if(r.status === 402){
      flashPill("need 5¢ credits");
      return;
    }
    if(!r.ok){
      flashPill("charge failed");
      return;
    }
    const d = await r.json();
    if(typeof d.credits === "number" && window.updateCreditsDisplay){
      window.updateCreditsDisplay(d.credits);
    }
    flashPill("−5¢ · " + d.credits + "¢ left");
    payBuildPending=true;
    startStudioBuild();
  }catch(e){
    flashPill("charge failed");
  }
};

async function refundPayBuildIfNeeded(){
  // Intentionally no-op: Pay Build is charged upfront and non-refundable
  // so error-prone code cannot be iterated for free.
  payBuildPending=false;
};

function toDev(cx,cy){
  const r=cv.getBoundingClientRect();
  return{
    x:Math.max(0,Math.min(nativeW-1,(cx-r.left)/r.width*nativeW)),
    y:Math.max(0,Math.min(nativeH-1,(cy-r.top)/r.height*nativeH))};
}
function sendControl(o){
  if(state!=="live") return;
  if(streamWs && streamWs.readyState===1)
    streamWs.send(JSON.stringify(o));
}
let drag=null;
cv.addEventListener("mousedown", e=>{ if(state!=="live") return; drag=toDev(e.clientX,e.clientY); });
cv.addEventListener("mouseup", e=>{
  if(!drag) return;
  const p=toDev(e.clientX,e.clientY);
  if(Math.abs(p.x-drag.x)>25||Math.abs(p.y-drag.y)>25)
    sendControl({type:"swipe",x1:drag.x,y1:drag.y,x2:p.x,y2:p.y});
  else sendControl({type:"tap",x:drag.x,y:drag.y});
  drag=null;
});
cv.addEventListener("touchstart", e=>{
  if(state!=="live") return;
  e.preventDefault();
  const t=e.touches[0]; drag=toDev(t.clientX,t.clientY);
},{passive:false});
cv.addEventListener("touchend", e=>{
  if(!drag) return;
  e.preventDefault();
  const t=e.changedTouches[0]; const p=toDev(t.clientX,t.clientY);
  if(Math.abs(p.x-drag.x)>25||Math.abs(p.y-drag.y)>25)
    sendControl({type:"swipe",x1:drag.x,y1:drag.y,x2:p.x,y2:p.y});
  else sendControl({type:"tap",x:drag.x,y:drag.y});
  drag=null;
},{passive:false});
document.getElementById("btnHome").onclick=()=>sendControl({type:"key",code:3});
document.getElementById("btnBack").onclick=()=>sendControl({type:"key",code:4});

function updateStats(pool, inuse, queued){
  statPool.textContent  = (pool  == null ? 0 : pool);
  statInUse.textContent = (inuse == null ? 0 : inuse);
  statQueue.textContent = (queued== null ? 0 : queued);
  const u = inuse || 0;
  statInUseWrap.classList.toggle("busy", u > 0);
  statInUseWrap.classList.toggle("hot",  u >= 2);
  statQueueWrap.classList.toggle("busy", (queued || 0) > 0);
}
async function pollStats(){
  try{
    const r = await fetch("/api/health");
    if(!r.ok) return;
    const d = await r.json();
    updateStats(d.pool_size ?? 0, d.inuse ?? 0, d.queue_size ?? 0);
  }catch(e){}
}

(async function boot(){
  try { await ensureWorkspace(); }
  catch(e){ console.error("workspace", e); }
  await loadFiles();
  setState("idle");
  resetLoot();
  // Shared /project/<id> links may already include a saved APK
  await checkApkStatus();
  pollStats(); setInterval(pollStats, 2000);
})();
</script>
</body>
</html>
HTML

# Immutable hello-world seed (studio workspaces copy from here)
mkdir -p defaults
cp -a scripts/. defaults/
# keep workspaces empty at install time
mkdir -p workspaces projects data

cd ..
echo "  created clawtank/"

# ============================================================
#  worker/
# ============================================================
cd worker

cat > .gitignore <<'EOF'
venv/
__pycache__/
*.pyc
.env
clawtank/
clawtank-*/
*.png
EOF

cat > requirements.txt <<'EOF'
websockets==12.0
EOF

cat > .env.example <<'EOF'
COORDINATOR_URL=ws://127.0.0.1:8000
WORKER_ID=laptop-1
MAX_SIZE=540
MAX_FPS=60
BIT_RATE=8000000
EOF

cat > README.md <<'EOF'
# clawtank worker

Sends 3 screenshots (t+2s, t+3s, t+4s) after a successful build.
EOF

cat > config.py <<'EOF'
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent
COORDINATOR_URL = os.getenv("COORDINATOR_URL", "ws://127.0.0.1:8000").rstrip("/")
WORKER_ID       = os.getenv("WORKER_ID", "laptop-1")
MAX_SIZE        = os.getenv("MAX_SIZE", "540")
MAX_FPS         = os.getenv("MAX_FPS", "60")
BIT_RATE        = os.getenv("BIT_RATE", "8000000")
SERVER_VER      = os.getenv("SERVER_VER", "3.1")
BUILD_MAX       = int(os.getenv("BUILD_MAX", "480"))
APP_PACKAGE     = os.getenv("APP_PACKAGE", "com.clawtank.app")
LOOT_LOG_LINES  = int(os.getenv("LOOT_LOG_LINES", "200"))
LOOT_FIRST      = float(os.getenv("LOOT_FIRST", "2.0"))
LOOT_INTERVAL   = float(os.getenv("LOOT_INTERVAL", "1.0"))
LOOT_COUNT      = int(os.getenv("LOOT_COUNT", "3"))
JAR_PATH        = Path("/tmp/scrcpy-server.jar")
JAR_URL         = (f"https://github.com/Genymobile/scrcpy/releases/download/"
                   f"v{SERVER_VER}/scrcpy-server-v{SERVER_VER}")
ADB             = "adb"
DEBUG           = os.getenv("DEBUG", "") == "1"
EOF

cat > scrcpy_protocol.py <<'EOF'
import struct
def encode_touch(x,y,w,h,a):
    p = 0 if a == 1 else 0xFFFF
    b = bytearray(32)
    b[0]=2; b[1]=a
    struct.pack_into(">Q", b, 2, 0)
    struct.pack_into(">i", b, 10, int(x))
    struct.pack_into(">i", b, 14, int(y))
    struct.pack_into(">H", b, 18, int(w))
    struct.pack_into(">H", b, 20, int(h))
    struct.pack_into(">H", b, 22, p)
    struct.pack_into(">I", b, 24, 1)
    struct.pack_into(">I", b, 28, 0 if a == 1 else 1)
    return bytes(b)
def encode_key(code, action):
    b = bytearray(14); b[0]=0; b[1]=action
    struct.pack_into(">i", b, 2, int(code)); return bytes(b)
def encode_text(t):
    p = t.encode("utf-8"); b = bytearray(5+len(p)); b[0]=1
    struct.pack_into(">I", b, 1, len(p)); b[5:] = p; return bytes(b)
def find_sps(a):
    i, n = 0, len(a)
    while i < n-3:
        if a[i:i+4]==b"\x00\x00\x00\x01": off=i+4
        elif a[i:i+3]==b"\x00\x00\x01": off=i+3
        else: i+=1; continue
        if off >= n: break
        if (a[off]&0x1F)==7 and off+4<=n:
            return a[off+1], a[off+2], a[off+3]
        i = off
    return None
EOF

cat > scrcpy_session.py <<'EOF'
import asyncio, random, struct
from config import (ADB, JAR_PATH, SERVER_VER, JAR_URL,
                    MAX_SIZE, MAX_FPS, BIT_RATE)
from scrcpy_protocol import find_sps


async def list_devices():
    p = await asyncio.create_subprocess_exec(
        ADB, "devices",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, _ = await p.communicate()
    serials = []
    for line in out.decode("utf-8", "ignore").splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device":
            serials.append(parts[0])
    return serials


class ScrcpySession:
    def __init__(self, device_id, on_frame):
        self.device_id = device_id
        self.on_frame = on_frame
        self.scid = random.randint(1, 0x7FFFFFFF)
        self.forward_port = random.randint(27183, 27399)
        self.proc = self.video_rd = self.video_wr = None
        self.control_wr = None
        self.device_name = device_id
        self.width = self.height = 0
        self.codec_string = "avc1.42E01E"
        self._clock = asyncio.Lock()
        self._reader_task = None
        self._running = False

    async def _adb(self, *args, timeout=30):
        p = await asyncio.create_subprocess_exec(
            ADB, "-s", self.device_id, *args,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            out, err = await asyncio.wait_for(p.communicate(), timeout=timeout)
            return p.returncode, out.decode("utf-8","ignore"), err.decode("utf-8","ignore")
        except asyncio.TimeoutError:
            p.kill(); return -1, "", "timeout"

    async def _setup(self):
        rc, out, _ = await self._adb("shell", "echo", "ok", timeout=8)
        if "ok" not in out: raise RuntimeError(f"{self.device_id} not responding")
        await self._adb("shell", "input", "keyevent", "KEYCODE_WAKEUP", timeout=5)
        await self._adb("shell", "wm", "dismiss-keyguard", timeout=5)
        await self._adb("shell", "pkill", "-f", "com.genymobile.scrcpy.Server", timeout=5)
        await asyncio.sleep(0.5)
        if not (JAR_PATH.exists() and JAR_PATH.stat().st_size > 10000):
            p = await asyncio.create_subprocess_exec(
                "curl", "-L", "-s", "-o", str(JAR_PATH), JAR_URL,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL)
            await p.wait()
        rc, _, err = await self._adb("push", str(JAR_PATH),
                                     "/data/local/tmp/scrcpy-server.jar")
        if rc != 0: raise RuntimeError(f"push failed: {err.strip()}")
        abstract = f"scrcpy_{self.scid:08x}"
        await self._adb("forward", "--remove", f"tcp:{self.forward_port}", timeout=3)
        rc, _, err = await self._adb("forward",
            f"tcp:{self.forward_port}", f"localabstract:{abstract}")
        if rc != 0: raise RuntimeError(f"forward failed: {err.strip()}")
        args = [SERVER_VER, f"scid={self.scid:08x}", "log_level=info",
                f"max_size={MAX_SIZE}", f"max_fps={MAX_FPS}",
                f"video_bit_rate={BIT_RATE}", "tunnel_forward=true",
                "audio=false", "control=true", "cleanup=true"]
        cmd = ("CLASSPATH=/data/local/tmp/scrcpy-server.jar "
               "app_process / com.genymobile.scrcpy.Server " + " ".join(args))
        self.proc = await asyncio.create_subprocess_exec(
            ADB, "-s", self.device_id, "shell", cmd,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        asyncio.create_task(self._drain(self.proc.stderr))
        await asyncio.sleep(2.5)

    async def _drain(self, s):
        try:
            while True:
                line = await s.readline()
                if not line: break
        except Exception: pass

    async def _connect(self):
        for _ in range(50):
            try:
                self.video_rd, self.video_wr = await asyncio.open_connection(
                    "127.0.0.1", self.forward_port); break
            except (ConnectionRefusedError, OSError):
                await asyncio.sleep(0.3)
        else: raise RuntimeError("video connect failed")
        for _ in range(50):
            try:
                _, self.control_wr = await asyncio.open_connection(
                    "127.0.0.1", self.forward_port); break
            except (ConnectionRefusedError, OSError):
                await asyncio.sleep(0.3)
        else: raise RuntimeError("control connect failed")

    @staticmethod
    async def _read_exact(r, n):
        buf = bytearray()
        while len(buf) < n:
            c = await r.read(n - len(buf))
            if not c: raise EOFError(f"EOF {len(buf)}/{n}")
            buf.extend(c)
        return bytes(buf)

    async def _read_metadata(self):
        await self._read_exact(self.video_rd, 1)
        raw = await self._read_exact(self.video_rd, 64)
        self.device_name = raw.rstrip(b"\x00").decode("utf-8","ignore") or self.device_id
        meta = await self._read_exact(self.video_rd, 12)
        _, w, h = struct.unpack(">III", meta)
        if w < 0: w = -w
        if h < 0: h = -h
        self.width, self.height = w, h

    async def _next_packet(self):
        header = await self._read_exact(self.video_rd, 12)
        pts_flags, size = struct.unpack(">QI", header)
        is_config = bool(pts_flags & (1 << 63))
        is_key    = bool(pts_flags & (1 << 62))
        if size == 0:
            return {"config": is_config, "key": is_key, "payload": b"", "skip": True}
        payload = await self._read_exact(self.video_rd, size)
        return {"config": is_config, "key": is_key, "payload": payload, "skip": False}

    async def send_control(self, data):
        async with self._clock:
            if not self.control_wr: return
            try:
                self.control_wr.write(data)
                await self.control_wr.drain()
            except Exception: pass

    async def _reader_loop(self):
        while self._running:
            try:
                pkt = await self._next_packet()
            except asyncio.CancelledError: break
            except Exception: break
            if pkt.get("skip"): continue
            if pkt["config"]:
                sps = find_sps(pkt["payload"])
                if sps:
                    p, c, l = sps
                    self.codec_string = f"avc1.{p:02X}{c:02X}{l:02X}"
            flags = 0
            if pkt["key"]: flags |= 0x01
            if pkt["config"]: flags |= 0x02
            data = bytes([flags]) + pkt["payload"]
            try: await self.on_frame(data)
            except Exception: pass

    async def start(self):
        await self._setup()
        await self._connect()
        await self._read_metadata()
        self._running = True
        self._reader_task = asyncio.create_task(self._reader_loop())

    async def stop(self):
        self._running = False
        if self._reader_task:
            self._reader_task.cancel()
            try: await self._reader_task
            except BaseException: pass
        for w in (self.video_wr, self.control_wr):
            if w:
                try: w.close()
                except Exception: pass
        if self.proc:
            try: self.proc.kill()
            except Exception: pass
        try:
            await self._adb("forward", "--remove", f"tcp:{self.forward_port}")
        except Exception: pass
EOF

cat > hello.sh <<'HELLO'
#!/usr/bin/env bash
set -e
PACKAGE="com.clawtank.app"
ACTIVITY="MainActivity"
GRADLE_VERSION="8.9"
ANDROID_API="34"
BUILD_TOOLS="34.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_DEVICE="${TARGET_DEVICE:-}"
if [ -n "$TARGET_DEVICE" ]; then
  SAFE_DEV=$(echo "$TARGET_DEVICE" | tr ':/.' '___')
  PROJECT_DIR="clawtank-$SAFE_DEV"
else
  PROJECT_DIR="clawtank"
fi

FRESH=0; EMU_INDEX=1; SOURCE_FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fresh) FRESH=1; shift ;;
    [0-9]*)  EMU_INDEX="$1"; shift ;;
    *)       SOURCE_FILES+=("$1"); shift ;;
  esac
done

if [ ${#SOURCE_FILES[@]} -eq 0 ]; then
  SRC="$SCRIPT_DIR/scripts"
  if [ -d "$SRC" ]; then
    while IFS= read -r -d '' f; do SOURCE_FILES+=("$f"); done \
      < <(find "$SRC" -type f -print0 | sort -z)
  fi
fi

echo ""
echo "  Project   : $PROJECT_DIR"
if [ -n "$TARGET_DEVICE" ]; then
  echo "  Target    : $TARGET_DEVICE"
fi

if ! command -v java >/dev/null 2>&1; then
  sudo apt-get update -qq
  if apt-cache show openjdk-17-jdk >/dev/null 2>&1; then
    sudo apt-get install -y -qq openjdk-17-jdk
  elif apt-cache show openjdk-21-jdk >/dev/null 2>&1; then
    sudo apt-get install -y -qq openjdk-21-jdk
  else
    sudo apt-get install -y -qq default-jdk
  fi
fi
[ -z "${JAVA_HOME:-}" ] && {
  JAVA_BIN=$(readlink -f "$(command -v java)")
  JAVA_HOME=$(dirname "$(dirname "$JAVA_BIN")")
  export JAVA_HOME
}
JAVA_MAJOR=$(java -version 2>&1 | head -1 | grep -oE '"[0-9]+' | tr -d '"')

SDK_ROOT="${ANDROID_HOME:-$HOME/Android/Sdk}"
CMDLINE_TOOLS="$SDK_ROOT/cmdline-tools/latest"
if [ ! -d "$CMDLINE_TOOLS/bin" ]; then
  mkdir -p "$SDK_ROOT/cmdline-tools"
  TMP_ZIP=$(mktemp /tmp/cmdline-tools-XXXX.zip)
  curl -fL -o "$TMP_ZIP" \
    "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  unzip -q -o "$TMP_ZIP" -d "$SDK_ROOT/cmdline-tools"
  [ -d "$SDK_ROOT/cmdline-tools/cmdline-tools" ] && \
    mv "$SDK_ROOT/cmdline-tools/cmdline-tools" "$CMDLINE_TOOLS"
  rm -f "$TMP_ZIP"
fi
export ANDROID_HOME="$SDK_ROOT"
export PATH="$CMDLINE_TOOLS/bin:$SDK_ROOT/platform-tools:$PATH"

if [ ! -d "$SDK_ROOT/platforms/android-${ANDROID_API}" ] || \
   [ ! -d "$SDK_ROOT/build-tools/${BUILD_TOOLS}" ]; then
  yes | sdkmanager --sdk_root="$SDK_ROOT" \
    "platforms;android-${ANDROID_API}" \
    "build-tools;${BUILD_TOOLS}" "platform-tools" >/dev/null || true
fi

GRADLE_CACHE_DIR="$HOME/.local/share/clawtank-gradle"
GRADLE_HOME="$GRADLE_CACHE_DIR/gradle-${GRADLE_VERSION}"
GRADLE_BIN="$GRADLE_HOME/bin/gradle"
if [ ! -x "$GRADLE_BIN" ]; then
  mkdir -p "$GRADLE_CACHE_DIR"
  ZIP_PATH="$GRADLE_CACHE_DIR/gradle-${GRADLE_VERSION}-bin.zip"
  curl -fL -o "$ZIP_PATH" \
    "https://services.gradle.org/distributions/gradle-${GRADLE_VERSION}-bin.zip"
  unzip -q -o "$ZIP_PATH" -d "$GRADLE_CACHE_DIR"
fi

if [ -d "$PROJECT_DIR" ] && [ "$FRESH" = "0" ]; then
  cd "$PROJECT_DIR"
else
  rm -rf "$PROJECT_DIR"
  mkdir -p "$PROJECT_DIR"/app/src/main/{java/com/clawtank/app,res/values}
  cd "$PROJECT_DIR"
  cat > settings.gradle.kts << 'EOF'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "clawtank"
include(":app")
EOF
  cat > build.gradle.kts << 'EOF'
plugins {
    id("com.android.application") version "8.7.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
}
EOF
  cat > app/build.gradle.kts << EOF
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "com.clawtank.app"
    compileSdk = ${ANDROID_API}
    defaultConfig {
        applicationId = "com.clawtank.app"
        minSdk = 24
        targetSdk = ${ANDROID_API}
        versionCode = 1
        versionName = "1.0"
    }
    buildTypes { release { isMinifyEnabled = false } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_${JAVA_MAJOR}
        targetCompatibility = JavaVersion.VERSION_${JAVA_MAJOR}
    }
    kotlinOptions { jvmTarget = "${JAVA_MAJOR}" }
}
dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
}
EOF
  cat > app/src/main/AndroidManifest.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application android:allowBackup="true" android:label="@string/app_name"
        android:supportsRtl="true"
        android:theme="@style/Theme.AppCompat.Light.NoActionBar">
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF
  cat > app/src/main/res/values/strings.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">clawtank</string>
    <string name="main_title">clawtank</string>
</resources>
EOF
  cat > app/src/main/res/values/colors.xml << 'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="black">#FF000000</color>
    <color name="white">#FFFFFFFF</color>
    <color name="rainbow_red">#FFFF0000</color>
    <color name="rainbow_orange">#FFFF7F00</color>
    <color name="rainbow_yellow">#FFFFFF00</color>
    <color name="rainbow_green">#FF00FF00</color>
    <color name="rainbow_blue">#FF0000FF</color>
    <color name="rainbow_indigo">#FF4B0082</color>
    <color name="rainbow_violet">#FF8B00FF</color>
</resources>
EOF
  cat > gradle.properties << 'EOF'
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.useAndroidX=true
kotlin.code.style=official
EOF
fi

mkdir -p app/src/main/java/com/clawtank/app \
         app/src/main/res/values \
         app/src/main/res/xml \
         app/src/main/res/drawable \
         app/src/main/res/font
for SRC in "${SOURCE_FILES[@]}"; do
  [ -f "$SRC" ] || continue
  # Preserve relative path under scripts/ when present
  REL="${SRC#"$SCRIPT_DIR/scripts/"}"
  BASE=$(basename "$SRC")
  case "$REL" in
    app/build.gradle.kts|build.gradle.kts)
      cp "$SRC" app/build.gradle.kts ;;
    AndroidManifest.xml)
      cp "$SRC" app/src/main/AndroidManifest.xml ;;
    *.kt)
      # Preserve editor line numbers: only prepend package when the file
      # does not already declare one (avoids shifting error line:col).
      if grep -qE '^[[:space:]]*package[[:space:]]' "$SRC"; then
        cp "$SRC" app/src/main/java/com/clawtank/app/"$BASE"
      else
        { echo "package com.clawtank.app"; echo ""
          cat "$SRC"
        } > app/src/main/java/com/clawtank/app/"$BASE"
      fi ;;
    strings.xml|colors.xml|themes.xml|styles.xml|dimens.xml|arrays.xml)
      cp "$SRC" app/src/main/res/values/"$BASE" ;;
    network_security_config.xml)
      cp "$SRC" app/src/main/res/xml/network_security_config.xml ;;
    font_family.xml)
      cp "$SRC" app/src/main/res/values/font_family.xml ;;
    *.font.xml)
      cp "$SRC" app/src/main/res/font/"$BASE" ;;
    ic_launcher_foreground.xml|ic_launcher_background.xml|ic_vector_example.xml|*.xml)
      # drawable / adaptive-icon vectors
      case "$BASE" in
        network_security_config.xml) continue ;;
        strings.xml|colors.xml|themes.xml|styles.xml|dimens.xml|arrays.xml) continue ;;
        AndroidManifest.xml) continue ;;
        *) cp "$SRC" app/src/main/res/drawable/"$BASE" ;;
      esac ;;
    *)
      # Fallback: if path contains res/ keep structure, else skip unknown
      if [[ "$REL" == res/* ]]; then
        mkdir -p "app/src/main/$(dirname "$REL")"
        cp "$SRC" "app/src/main/$REL"
      fi
      ;;
  esac
done
[ -f app/src/main/java/com/clawtank/app/MainActivity.kt ] || {
  cat > app/src/main/java/com/clawtank/app/MainActivity.kt << 'EOF'
package com.clawtank.app
import android.graphics.Typeface
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
class MainActivity : AppCompatActivity() {
    override fun onCreate(s: Bundle?) {
        super.onCreate(s)
        val root = FrameLayout(this).apply {
            setBackgroundColor(ContextCompat.getColor(this@MainActivity, R.color.black))
        }
        val title = getString(R.string.main_title)
        val colors = intArrayOf(
            ContextCompat.getColor(this, R.color.rainbow_red),
            ContextCompat.getColor(this, R.color.rainbow_orange),
            ContextCompat.getColor(this, R.color.rainbow_yellow),
            ContextCompat.getColor(this, R.color.rainbow_green),
            ContextCompat.getColor(this, R.color.rainbow_blue),
            ContextCompat.getColor(this, R.color.rainbow_indigo),
            ContextCompat.getColor(this, R.color.rainbow_violet))
        val sp = SpannableString(title)
        for (i in title.indices) sp.setSpan(
            ForegroundColorSpan(colors[i % colors.size]), i, i+1,
            Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        val tv = TextView(this).apply {
            text = sp; textSize = 48f
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            gravity = Gravity.CENTER; setPadding(32,32,32,32) }
        root.addView(tv, FrameLayout.LayoutParams(-2,-2, Gravity.CENTER))
        setContentView(root)
    }
}
EOF
}

echo "sdk.dir=$SDK_ROOT" > local.properties
if [ ! -x gradlew ]; then
  mkdir -p gradle/wrapper
  "$GRADLE_BIN" wrapper --gradle-version "$GRADLE_VERSION" --quiet
  chmod +x gradlew
fi

echo ""
echo "  Building debug APK…"
set +e
./gradlew assembleDebug --console=plain --parallel --build-cache \
  -Dorg.gradle.daemon=true
GRADLE_RC=$?
set -e
if [ "$GRADLE_RC" -ne 0 ]; then
  echo "ERROR: gradle assembleDebug failed (exit $GRADLE_RC)"
  exit "$GRADLE_RC"
fi

APK="app/build/outputs/apk/debug/app-debug.apk"
[ -f "$APK" ] || { echo "ERROR: APK not produced"; exit 1; }

if [ -n "$TARGET_DEVICE" ]; then
  DEVICE="$TARGET_DEVICE"
  echo "  Using device: $DEVICE (pinned)"
else
  mapfile -t DEVICES < <(adb devices | awk '/device$/{print $1}')
  [ ${#DEVICES[@]} -gt 0 ] || { echo "ERROR: no emulators"; exit 1; }
  [ "$EMU_INDEX" -ge 1 ] && [ "$EMU_INDEX" -le ${#DEVICES[@]} ] || EMU_INDEX=1
  DEVICE="${DEVICES[$((EMU_INDEX-1))]}"
  echo "  Using device: $DEVICE (index $EMU_INDEX)"
fi

adb -s "$DEVICE" install -r "$APK"
echo "  Launching…"
adb -s "$DEVICE" shell am start -n "${PACKAGE}/.${ACTIVITY}"
echo "  Done!"
HELLO

cat > scripts/MainActivity.kt <<'KT'
package com.clawtank.app

import android.graphics.Typeface
import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.util.Log
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.d("clawtank", "Cats")
        val root = FrameLayout(this).apply {
            setBackgroundColor(ContextCompat.getColor(this@MainActivity, R.color.black))
        }
        val title = getString(R.string.main_title)
        val rainbowColors = intArrayOf(
            ContextCompat.getColor(this, R.color.rainbow_red),
            ContextCompat.getColor(this, R.color.rainbow_orange),
            ContextCompat.getColor(this, R.color.rainbow_yellow),
            ContextCompat.getColor(this, R.color.rainbow_green),
            ContextCompat.getColor(this, R.color.rainbow_blue),
            ContextCompat.getColor(this, R.color.rainbow_indigo),
            ContextCompat.getColor(this, R.color.rainbow_violet))
        val spannable = SpannableString(title)
        for (i in title.indices) {
            spannable.setSpan(
                ForegroundColorSpan(rainbowColors[i % rainbowColors.size]),
                i, i + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        val textView = TextView(this).apply {
            text = spannable; textSize = 48f
            typeface = Typeface.create(Typeface.SANS_SERIF, Typeface.BOLD)
            gravity = Gravity.CENTER; setPadding(32, 32, 32, 32) }
        root.addView(textView, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        setContentView(root)
    }
}
KT

cat > scripts/colors.xml <<'COL'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="black">#FF000000</color>
    <color name="white">#FFFFFFFF</color>
    <color name="rainbow_red">#FFFF0000</color>
    <color name="rainbow_orange">#FFFF7F00</color>
    <color name="rainbow_yellow">#FFFFFF00</color>
    <color name="rainbow_green">#FF00FF00</color>
    <color name="rainbow_blue">#FF0000FF</color>
    <color name="rainbow_indigo">#FF4B0082</color>
    <color name="rainbow_violet">#FF8B00FF</color>
</resources>
COL

cat > scripts/strings.xml <<'STR'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">clawtank</string>
    <string name="main_title">clawtank</string>
</resources>
STR

cat > scripts/AndroidManifest.xml <<'MAN'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.INTERNET" />
    <application
        android:allowBackup="true"
        android:label="@string/app_name"
        android:supportsRtl="true"
        android:theme="@style/Theme.Clawtank"
        android:networkSecurityConfig="@xml/network_security_config"
        android:icon="@drawable/ic_launcher_foreground">
        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
MAN

cat > scripts/themes.xml <<'THM'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="Theme.Clawtank" parent="Theme.AppCompat.Light.NoActionBar">
        <item name="colorPrimary">@color/rainbow_blue</item>
        <item name="colorPrimaryDark">@color/black</item>
        <item name="colorAccent">@color/rainbow_orange</item>
        <item name="android:statusBarColor">@color/black</item>
        <item name="android:navigationBarColor">@color/black</item>
        <item name="android:windowBackground">@color/black</item>
    </style>
</resources>
THM

cat > scripts/network_security_config.xml <<'NSC'
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <base-config cleartextTrafficPermitted="false">
        <trust-anchors>
            <certificates src="system" />
        </trust-anchors>
    </base-config>
    <!-- Allow cleartext to localhost for debug / emulator -->
    <domain-config cleartextTrafficPermitted="true">
        <domain includeSubdomains="true">localhost</domain>
        <domain includeSubdomains="true">10.0.2.2</domain>
    </domain-config>
</network-security-config>
NSC

cat > scripts/dimens.xml <<'DIM'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <dimen name="padding_small">8dp</dimen>
    <dimen name="padding_medium">16dp</dimen>
    <dimen name="padding_large">32dp</dimen>
    <dimen name="text_title">48sp</dimen>
    <dimen name="text_body">16sp</dimen>
    <dimen name="icon_size">48dp</dimen>
</resources>
DIM

cat > scripts/arrays.xml <<'ARR'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string-array name="rainbow_names">
        <item>red</item>
        <item>orange</item>
        <item>yellow</item>
        <item>green</item>
        <item>blue</item>
        <item>indigo</item>
        <item>violet</item>
    </string-array>
    <!-- Color hex values as strings (integer-array cannot reference @color) -->
    <string-array name="rainbow_color_hex">
        <item>#FFFF0000</item>
        <item>#FFFF7F00</item>
        <item>#FFFFFF00</item>
        <item>#FF00FF00</item>
        <item>#FF0000FF</item>
        <item>#FF4B0082</item>
        <item>#FF8B00FF</item>
    </string-array>
</resources>
ARR

cat > scripts/ic_vector_example.xml <<'VEC'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">
    <path
        android:fillColor="#FF6B00"
        android:pathData="M12,2L2,7l10,5 10,-5 -10,-5zM2,17l10,5 10,-5M2,12l10,5 10,-5" />
</vector>
VEC

cat > scripts/ic_launcher_foreground.xml <<'FG'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#FF6B00"
        android:pathData="M54,30c-13.2,0 -24,10.8 -24,24s10.8,24 24,24 24,-10.8 24,-24 -10.8,-24 -24,-24zM54,66c-6.6,0 -12,-5.4 -12,-12s5.4,-12 12,-12 12,5.4 12,12 -5.4,12 -12,12z" />
    <path
        android:fillColor="#FFFFFF"
        android:pathData="M48,48h12v12h-12z" />
</vector>
FG

cat > scripts/ic_launcher_background.xml <<'BG'
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#0B0D10"
        android:pathData="M0,0h108v108h-108z" />
</vector>
BG

cat > scripts/font_family.xml <<'FNT'
<?xml version="1.0" encoding="utf-8"?>
<!-- Placeholder for custom fonts.
     To use a real font: put a .ttf/.otf under res/font/ and either
     (1) reference it from a theme, or (2) replace this file with a
     <font-family> that lists <font android:font="@font/your_file" .../>.
     Kept as a plain resources file so the default project always compiles. -->
<resources>
    <string name="font_family_placeholder">sans-serif</string>
</resources>
FNT

mkdir -p scripts/app
cat > scripts/app/build.gradle.kts <<'BGK'
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "com.clawtank.app"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.clawtank.app"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }
    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}
dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
}
BGK


cat > start.sh <<'START'
#!/usr/bin/env bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
if [ ! -d venv ]; then python3 -m venv venv; fi
source venv/bin/activate
pip install --quiet --upgrade pip
pip install --quiet -r requirements.txt
if [ -f .env ]; then set -a; source .env; set +a; fi
export COORDINATOR_URL="${COORDINATOR_URL:-ws://127.0.0.1:8000}"
export WORKER_ID="${WORKER_ID:-laptop-1}"
export BUILD_MAX="${BUILD_MAX:-480}"
echo ""
echo "  clawtank worker"
echo "  id   : $WORKER_ID"
echo "  coord: $COORDINATOR_URL"
echo ""
exec python3 worker.py
START

cat > worker.py <<'WORKER'
#!/usr/bin/env python3
"""clawtank worker."""
import asyncio, base64, json, os, sys, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import websockets
from config import (COORDINATOR_URL, WORKER_ID, BUILD_MAX,
                    APP_PACKAGE, LOOT_LOG_LINES,
                    LOOT_FIRST, LOOT_INTERVAL, LOOT_COUNT)
from scrcpy_session import ScrcpySession, list_devices

SCRIPTS_DIR = HERE / "scripts"
HELLO_SH    = HERE / "hello.sh"
ACTIVE      = {}


def _ws_session_url(session_id: str) -> str:
    return f"{COORDINATOR_URL.rstrip('/')}/ws/worker-session/{session_id}"


async def _session_worker(session_id: str, device_id: str):
    print(f"  opening session {session_id} on {device_id}")
    data_ws = None
    sess = None

    async def on_frame(data: bytes):
        try: await data_ws.send(data)
        except Exception: pass

    try:
        data_ws = await websockets.connect(_ws_session_url(session_id),
                                           max_size=None)
        sess = ScrcpySession(device_id, on_frame)
        await sess.start()

        await data_ws.send(json.dumps({
            "type": "meta",
            "worker_id": WORKER_ID,
            "device_id": device_id,
            "device_name": sess.device_name,
            "width": sess.width,
            "height": sess.height,
            "codec": sess.codec_string,
        }))

        ACTIVE[session_id] = {"session": sess, "ws": data_ws}
        print(f"  [{session_id}] streaming {device_id} "
              f"({sess.width}x{sess.height})")

        async def control_loop():
            try:
                async for msg in data_ws:
                    if isinstance(msg, bytes):
                        await sess.send_control(msg)
            except Exception: pass

        ctrl = asyncio.create_task(control_loop())
        try:
            while session_id in ACTIVE and data_ws.state.name == "OPEN":
                await asyncio.sleep(1)
        finally:
            ctrl.cancel()
    except Exception as e:
        print(f"  [{session_id}] error: {e}")
    finally:
        if sess:
            try: await sess.stop()
            except Exception: pass
        # Kill the app so the next user does not see the previous session's UI.
        try:
            await _force_stop_pkg(device_id, APP_PACKAGE)
        except Exception:
            pass
        if data_ws:
            try: await data_ws.close()
            except Exception: pass
        ACTIVE.pop(session_id, None)
        print(f"  [{session_id}] closed")


import re as _re

# Map Gradle/Kotlin absolute paths back to studio script names so the
# build log lines match the editor (e.g. MainActivity.kt:19:31).
_PATH_PATTERNS = [
    # .../app/src/main/java/com/clawtank/app/Foo.kt
    _re.compile(
        r"(?:file://)?(?:/[^\s:]+?/)?app/src/main/java/com/clawtank/app/([A-Za-z0-9_.]+\.kt)"
    ),
    # .../app/src/main/res/values/foo.xml  (and xml/drawable/font)
    _re.compile(
        r"(?:file://)?(?:/[^\s:]+?/)?app/src/main/res/(?:values|xml|drawable|font|mipmap[^/]*)/([A-Za-z0-9_.]+\.xml)"
    ),
    # .../app/src/main/AndroidManifest.xml
    _re.compile(
        r"(?:file://)?(?:/[^\s:]+?/)?app/src/main/(AndroidManifest\.xml)"
    ),
    # .../app/build.gradle.kts
    _re.compile(
        r"(?:file://)?(?:/[^\s:]+?/)?app/(build\.gradle\.kts)"
    ),
    # generic e: file:///.../Something.kt:line:col
    _re.compile(
        r"e:\s*file://[^\s]+?/([^/\s]+\.(?:kt|kts|xml)):(\d+)(?::(\d+))?"
    ),
]


def _studio_path_log(line: str) -> str:
    """Rewrite compiler paths to studio-relative names + keep line:col."""
    s = line
    # Kotlin style: e: file:///abs/path/MainActivity.kt:19:31 Message
    s = _re.sub(
        r"e:\s*file://\S+/(?:java/com/clawtank/app/)?([A-Za-z0-9_.]+\.(?:kt|kts|xml)):(\d+)(?::(\d+))?",
        lambda m: (
            f"e: {m.group(1)}:{m.group(2)}"
            + (f":{m.group(3)}" if m.group(3) else "")
        ),
        s,
    )
    s = _re.sub(
        r"w:\s*file://\S+/(?:java/com/clawtank/app/)?([A-Za-z0-9_.]+\.(?:kt|kts|xml)):(\d+)(?::(\d+))?",
        lambda m: (
            f"w: {m.group(1)}:{m.group(2)}"
            + (f":{m.group(3)}" if m.group(3) else "")
        ),
        s,
    )
    # Any remaining absolute paths to known layout files
    for pat in _PATH_PATTERNS[:4]:
        s = pat.sub(r"\1", s)
    # Strip long file:// prefixes left over
    s = _re.sub(r"file://[^\s]+/", "", s)
    return s


async def _sh(*args, timeout=30):
    p = await asyncio.create_subprocess_exec(
        "adb", *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(p.communicate(), timeout=timeout)
        return p.returncode, out, err
    except asyncio.TimeoutError:
        p.kill()
        return -1, b"", b"timeout"


async def _force_stop_pkg(device_id: str, package: str):
    if not device_id or not package:
        return
    try:
        rc, out, err = await _sh("-s", device_id, "shell", "am", "force-stop",
                                 package, timeout=8)
        print(f"  force-stop {package} on {device_id}: rc={rc}")
    except Exception as e:
        print(f"  force-stop error: {e}")


async def _capture_loot(ctrl_ws, build_id, device_id, script=None, logcat_lines=None):
    """Default 3 timed screenshots, or execute a provided script of actions."""
    max_lines = int(logcat_lines) if logcat_lines else LOOT_LOG_LINES
    max_lines = max(1, min(1000, max_lines))
    pid = None
    try:
        rc, out, _ = await _sh("-s", device_id, "shell", "pidof", APP_PACKAGE,
                               timeout=10)
        text = out.decode("utf-8", "ignore").strip()
        if text: pid = text.split()[0]
    except Exception as e:
        print(f"  [{build_id}] pidof error: {e}")

    t0 = time.time()
    shot_idx = 0

    async def do_screenshot(at=None):
        nonlocal shot_idx
        try:
            rc, png, _ = await _sh("-s", device_id, "exec-out",
                                   "screencap", "-p", timeout=15)
            if png and len(png) > 32:
                b64 = base64.b64encode(png).decode("ascii")
                await ctrl_ws.send(json.dumps({
                    "type": "loot_screenshot",
                    "build_id": build_id,
                    "idx": shot_idx,
                    "at": at,
                    "data": b64,
                }))
                print(f"  [{build_id}] shot {shot_idx+1}: {len(png)} bytes")
                shot_idx += 1
                return True
        except Exception as e:
            print(f"  [{build_id}] shot error: {e}")
        return False

    async def do_tap(x, y):
        try:
            await _sh("-s", device_id, "shell", "input", "tap",
                      str(int(x)), str(int(y)), timeout=8)
            return True
        except Exception as e:
            print(f"  [{build_id}] tap error: {e}")
            return False

    async def do_swipe(x1, y1, x2, y2, duration_ms=300):
        try:
            await _sh("-s", device_id, "shell", "input", "swipe",
                      str(int(x1)), str(int(y1)),
                      str(int(x2)), str(int(y2)),
                      str(int(duration_ms)), timeout=10)
            return True
        except Exception as e:
            print(f"  [{build_id}] swipe error: {e}")
            return False

    async def do_key(code):
        try:
            await _sh("-s", device_id, "shell", "input", "keyevent",
                      str(int(code)), timeout=8)
            return True
        except Exception as e:
            print(f"  [{build_id}] key error: {e}")
            return False

    if script and isinstance(script, list) and len(script) > 0:
        # Scripted run: execute actions at relative times from launch
        sorted_steps = sorted(script, key=lambda s: float(s.get("at", 0)))
        for step in sorted_steps:
            at = float(step.get("at", 0))
            action = (step.get("action") or "").lower()
            delta = at - (time.time() - t0)
            if delta > 0:
                await asyncio.sleep(delta)
            ok = False
            if action == "screenshot":
                ok = await do_screenshot(at=at)
            elif action == "tap":
                ok = await do_tap(step.get("x", 0), step.get("y", 0))
            elif action == "swipe":
                ok = await do_swipe(step.get("x1", 0), step.get("y1", 0),
                                    step.get("x2", 0), step.get("y2", 0),
                                    step.get("duration_ms", 300))
            elif action == "key":
                ok = await do_key(step.get("code", 4))
            elif action == "wait":
                ok = True
            else:
                print(f"  [{build_id}] unknown action: {action}")
            try:
                await ctrl_ws.send(json.dumps({
                    "type": "loot_log",
                    "build_id": build_id,
                    "line": f"[script] at={at} action={action} ok={ok}",
                }))
            except Exception:
                pass
    else:
        # Default fire-and-forget: 3 screenshots at t+2/3/4s
        for idx in range(LOOT_COUNT):
            target = LOOT_FIRST + idx * LOOT_INTERVAL
            delta = target - (time.time() - t0)
            if delta > 0:
                await asyncio.sleep(delta)
            await do_screenshot(at=target)

    # Always collect logcat at the end (up to max_lines)
    lines_sent = 0
    collected = []
    try:
        if pid:
            rc, logs, _ = await _sh("-s", device_id, "logcat", "-d",
                                    "--pid", pid, "-t", str(max_lines),
                                    "-v", "brief", timeout=20)
        else:
            rc, logs, _ = await _sh("-s", device_id, "logcat", "-d",
                                    "-t", str(max_lines),
                                    "-v", "brief", timeout=20)
        for line in logs.decode("utf-8", "ignore").splitlines():
            line = line.rstrip()
            if not line: continue
            if not pid:
                if APP_PACKAGE not in line and "AndroidRuntime" not in line:
                    continue
            collected.append(line)
            lines_sent += 1
        if not collected and pid is None:
            collected.append(f"[loot] {APP_PACKAGE} is not running — check log above")
        # Send full blob first (preferred by coordinator), then individual lines
        if collected:
            await ctrl_ws.send(json.dumps({
                "type": "loot_logcat",
                "build_id": build_id,
                "text": "\n".join(collected),
            }))
            for line in collected:
                await ctrl_ws.send(json.dumps({
                    "type": "loot_log",
                    "build_id": build_id,
                    "line": line,
                }))
        print(f"  [{build_id}] logcat: {lines_sent} lines (pid={pid}, max={max_lines})")
    except Exception as e:
        print(f"  [{build_id}] logcat error: {e}")
        try:
            await ctrl_ws.send(json.dumps({
                "type": "loot_log",
                "build_id": build_id,
                "line": f"[loot] logcat error: {e}",
            }))
        except Exception: pass


async def _loot_task(ctrl_ws, build_id, device_id, script=None, logcat_lines=None):
    try:
        await _capture_loot(ctrl_ws, build_id, device_id, script=script,
                            logcat_lines=logcat_lines)
    except Exception as e:
        print(f"  [{build_id}] loot error: {e}")
    finally:
        try:
            await ctrl_ws.send(json.dumps({
                "type": "loot_done", "build_id": build_id}))
        except Exception: pass


async def _send_apk(ctrl_ws, build_id, device_id, workspace_id=None):
    """Upload the debug APK to the coordinator after a successful build."""
    candidates = []
    if device_id:
        safe = str(device_id).translate(str.maketrans(":/.", "___"))
        candidates.append(
            HERE / f"clawtank-{safe}" / "app/build/outputs/apk/debug/app-debug.apk")
    candidates.append(HERE / "clawtank/app/build/outputs/apk/debug/app-debug.apk")
    apk = None
    for c in candidates:
        if c.is_file() and c.stat().st_size > 32:
            apk = c
            break
    if not apk:
        print(f"  [{build_id}] no apk found to upload")
        return
    data = base64.b64encode(apk.read_bytes()).decode("ascii")
    await ctrl_ws.send(json.dumps({
        "type": "loot_apk",
        "build_id": build_id,
        "workspace_id": workspace_id,
        "filename": "app-debug.apk",
        "data": data,
        "size": apk.stat().st_size,
    }))
    print(f"  [{build_id}] apk uploaded ({apk.stat().st_size} bytes)")


async def _build_worker(ctrl_ws, build_id: str, files: dict, device_id: str,
                        script=None, run=True, logcat_lines=None,
                        workspace_id=None):
    print(f"  build {build_id} on {device_id or '(any)'} ({len(files)} files)"
          + (f" script={len(script)} steps" if script else ""))

    SCRIPTS_DIR.mkdir(parents=True, exist_ok=True)
    for old in list(SCRIPTS_DIR.rglob("*")):
        if old.is_file():
            try: old.unlink()
            except Exception: pass
    for name, content in files.items():
        dest = (SCRIPTS_DIR / name).resolve()
        if not str(dest).startswith(str(SCRIPTS_DIR.resolve())):
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(content, encoding="utf-8")

    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"; env["TERM"] = "dumb"
    if device_id: env["TARGET_DEVICE"] = device_id

    try:
        proc = await asyncio.create_subprocess_exec(
            "stdbuf", "-oL", "-eL", "bash", str(HELLO_SH),
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=str(HERE), env=env)
    except FileNotFoundError:
        proc = await asyncio.create_subprocess_exec(
            "bash", str(HELLO_SH),
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=str(HERE), env=env)

    async def send_log(line: str):
        try:
            await ctrl_ws.send(json.dumps({
                "type": "build_log", "build_id": build_id,
                "line": _studio_path_log(line)}))
        except Exception: pass

    async def pump():
        buffer = b""
        while True:
            chunk = await proc.stdout.read(512)
            if not chunk: break
            buffer += chunk.replace(b"\r", b"\n")
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                text = line.decode("utf-8", "replace")
                if text.strip():
                    await send_log(text + "\n")
        if buffer.strip():
            await send_log(buffer.decode("utf-8", "replace") + "\n")

    code = -1
    try:
        try:
            await asyncio.wait_for(pump(), timeout=BUILD_MAX)
            code = await asyncio.wait_for(proc.wait(), timeout=30)
        except asyncio.TimeoutError:
            proc.kill()
            try: await proc.wait()
            except Exception: pass
            await send_log(
                f"\n[worker] build exceeded {BUILD_MAX}s — killed\n")
            code = -1
    except Exception as e:
        await send_log(f"\n[worker] build error: {e}\n")
        code = -1

    try:
        await ctrl_ws.send(json.dumps({
            "type": "build_done", "build_id": build_id, "code": code}))
    except Exception: pass

    if code == 0:
        try:
            await _send_apk(ctrl_ws, build_id, device_id, workspace_id)
        except Exception as e:
            print(f"  [{build_id}] apk upload error: {e}")

    if code == 0 and device_id and run:
        asyncio.create_task(_loot_task(ctrl_ws, build_id, device_id,
                                       script=script, logcat_lines=logcat_lines))

    print(f"  build {build_id} finished code={code}")


async def _session_pinger(ctrl_ws):
    try:
        while True:
            await asyncio.sleep(2)
            for sid in list(ACTIVE.keys()):
                try:
                    await ctrl_ws.send(json.dumps({
                        "type": "session_ping",
                        "session_id": sid,
                        "ts": time.time(),
                    }))
                except Exception:
                    return
    except asyncio.CancelledError:
        return


async def main():
    devices = await list_devices()
    print(f"  worker id : {WORKER_ID}")
    print(f"  devices   : {devices}")
    print(f"  coord     : {COORDINATOR_URL}")
    if not devices:
        print("  !! no adb devices — start an emulator first")
        sys.exit(1)

    ctrl_url = f"{COORDINATOR_URL.rstrip('/')}/ws/worker"

    while True:
        try:
            async with websockets.connect(ctrl_url, max_size=None) as ctrl_ws:
                await ctrl_ws.send(json.dumps({
                    "type": "hello",
                    "worker_id": WORKER_ID,
                    "devices": devices}))
                ack = json.loads(await ctrl_ws.recv())
                print(f"  registered.")

                async def heartbeat():
                    while True:
                        await asyncio.sleep(15)
                        try:
                            devs = await list_devices()
                            await ctrl_ws.send(json.dumps({
                                "type": "devices", "devices": devs}))
                        except Exception: return

                hb = asyncio.create_task(heartbeat())
                pg = asyncio.create_task(_session_pinger(ctrl_ws))
                try:
                    async for raw in ctrl_ws:
                        try: msg = json.loads(raw)
                        except Exception: continue
                        t = msg.get("type")
                        if t == "open_session":
                            asyncio.create_task(_session_worker(
                                msg["session_id"], msg["device_id"]))
                        elif t == "force_stop":
                            asyncio.create_task(_force_stop_pkg(
                                msg.get("device_id"),
                                msg.get("package") or APP_PACKAGE))
                        elif t == "build":
                            asyncio.create_task(_build_worker(
                                ctrl_ws, msg.get("build_id", ""),
                                msg.get("files") or {},
                                msg.get("device_id"),
                                script=msg.get("script"),
                                run=msg.get("run", True),
                                logcat_lines=msg.get("logcat_lines"),
                                workspace_id=msg.get("workspace_id")))
                finally:
                    hb.cancel(); pg.cancel()
        except (websockets.ConnectionClosed, ConnectionRefusedError, OSError) as e:
            print(f"  control lost ({e}) — retry in 3 s")
            await asyncio.sleep(3)
        except Exception as e:
            print(f"  unexpected: {e} — retry in 5 s")
            await asyncio.sleep(5)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n  bye")
WORKER

chmod +x hello.sh start.sh worker.py
chmod +x ../clawtank/hello.sh ../clawtank/start.sh

cd ..
echo "  created worker/"

echo ""
echo "=================================================="
echo "  clawtank + worker created"
echo "=================================================="
echo ""
echo "  Coordinator:  cd clawtank && ./start.sh"
echo "    → home at   http://127.0.0.1:8000/          (landing page)"
echo "    → studio at http://127.0.0.1:8000/studio    (editor)"
echo "    → api at    http://127.0.0.1:8000/api/docs  (api reference)"
echo "  Worker:       cd worker  && ./start.sh"
echo ""
echo "  API page:"
echo "  • SEO-targeted at /api/docs (Android build API, cloud emulator)"
echo "  • same visual language as the home page"
echo "  • three calling patterns, then POST + WS reference"
echo "  • no swagger promotion, no internal endpoints"
echo ""
echo "  File rules:"
echo "  • default files (MainActivity.kt, colors.xml, strings.xml,"
echo "    AndroidManifest.xml, themes.xml, network_security_config.xml,"
echo "    dimens.xml, arrays.xml, ic_launcher_*, ic_vector_example.xml,"
echo "    font_family.xml, app/build.gradle.kts) show at the top under"
echo "    'default · required' with NO delete X."
echo "  • user files appear below the 'your files' divider with an"
echo "    × that appears on hover only."
echo "  • server refuses DELETE on any default file, even with"
echo "    crafted paths like ./MainActivity.kt."
echo ""
