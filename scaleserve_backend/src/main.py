from __future__ import annotations

import hashlib
import json
import os
import random
import re
import smtplib
from datetime import UTC, datetime, timedelta
from email.message import EmailMessage
from pathlib import Path
from typing import Any, Literal

import bcrypt
import jwt
import psycopg
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from psycopg.rows import dict_row

load_dotenv()

PROJECT_ROOT = Path(__file__).resolve().parents[1]

PORT = int(os.getenv("PORT", "8080"))
DATABASE_URL = os.getenv("DATABASE_URL", "").strip()
JWT_SECRET = os.getenv("JWT_SECRET", "").strip()
JWT_EXPIRES_IN = os.getenv("JWT_EXPIRES_IN", "12h").strip()
OTP_TTL_MINUTES = int(os.getenv("OTP_TTL_MINUTES", "10"))
OTP_MAX_ATTEMPTS = int(os.getenv("OTP_MAX_ATTEMPTS", "5"))
DEFAULT_WORKSPACE_ID = (
    os.getenv("DEFAULT_WORKSPACE_ID", "00000000-0000-0000-0000-000000000001").strip()
)
DEFAULT_WORKSPACE_SLUG = os.getenv("DEFAULT_WORKSPACE_SLUG", "default").strip().lower()
SMTP_GMAIL_USER = os.getenv("SMTP_GMAIL_USER", "").strip()
SMTP_GMAIL_APP_PASSWORD = os.getenv("SMTP_GMAIL_APP_PASSWORD", "").strip()
SMTP_FROM_NAME = os.getenv("SMTP_FROM_NAME", "ScaleServe").strip()
CORS_ORIGINS = os.getenv("CORS_ORIGINS", "").strip()
AUTO_MIGRATE = os.getenv("AUTO_MIGRATE", "true").strip().lower() == "true"

if not DATABASE_URL:
    raise RuntimeError("DATABASE_URL is required.")
if not JWT_SECRET:
    raise RuntimeError("JWT_SECRET is required.")

SMTP_CONFIGURED = bool(SMTP_GMAIL_USER and SMTP_GMAIL_APP_PASSWORD)


class OtpPurpose:
    LOGIN_MFA = "login_mfa"
    PASSWORD_RESET = "password_reset"


class BootstrapRequest(BaseModel):
    email: str
    password: str
    mfaEnabled: bool = False
    username: str | None = None


class LoginRequest(BaseModel):
    email: str | None = None
    username: str | None = None
    password: str


class EmailRequest(BaseModel):
    email: str | None = None
    username: str | None = None


class VerifyOtpRequest(BaseModel):
    email: str | None = None
    username: str | None = None
    otp: str


class ResetPasswordRequest(BaseModel):
    email: str | None = None
    username: str | None = None
    otp: str
    newPassword: str


class SyncSettingsRequest(BaseModel):
    settings: dict[str, Any] = Field(default_factory=dict)
    workspaceSlug: str | None = None
    initiatedByUsername: str | None = None


class SyncMachinePeerRequest(BaseModel):
    dnsName: str
    name: str = ""
    ipAddress: str = ""
    os: str = ""
    online: bool = False


class SyncMachineSnapshotRequest(BaseModel):
    capturedAtIso: str | None = None
    workspaceSlug: str | None = None
    initiatedByUsername: str | None = None
    selfDnsName: str
    selfName: str = ""
    selfIpAddress: str = ""
    isConnected: bool = False
    tailnetName: str = ""
    loginName: str = ""
    backendState: str = ""
    magicDnsSuffix: str = ""
    peers: list[SyncMachinePeerRequest] = Field(default_factory=list)


class SyncCommandLogRequest(BaseModel):
    workspaceSlug: str | None = None
    commandText: str
    safeCommandText: str
    exitCode: int
    success: bool | None = None
    stdout: str = ""
    stderr: str = ""
    source: str = "app"
    initiatedByUsername: str | None = None
    createdAtIso: str | None = None


class SyncRemoteProfileRequest(BaseModel):
    dnsName: str
    remoteUser: str
    keyPath: str = ""
    bootstrapKeyPath: str = ""
    defaultCommand: str = ""
    ownerUsername: str | None = None
    updatedAtIso: str | None = None


class SyncRemoteRunRequest(BaseModel):
    startedAtIso: str
    finishedAtIso: str | None = None
    deviceDnsName: str
    remoteUser: str
    command: str
    safeCommandText: str | None = None
    exitCode: int
    success: bool
    runType: str = "remote_command"
    localFilePath: str | None = None
    stdout: str = ""
    stderr: str = ""
    metadataJson: str | None = None
    initiatedByUsername: str | None = None


class SyncRemoteStateRequest(BaseModel):
    workspaceSlug: str | None = None
    initiatedByUsername: str | None = None
    profiles: list[SyncRemoteProfileRequest] = Field(default_factory=list)
    recentRuns: list[SyncRemoteRunRequest] = Field(default_factory=list)


def db_connection() -> psycopg.Connection[Any]:
    return psycopg.connect(DATABASE_URL, row_factory=dict_row)


def normalize_username(username: str) -> str:
    return (username or "").strip().lower()


def username_from_email(email: str) -> str:
    local_part = (email.split("@", 1)[0] if "@" in email else email).strip().lower()
    sanitized = re.sub(r"[^a-z0-9._-]+", "_", local_part).strip("._-")
    return sanitized or "operator"


def normalize_email(email: str | None) -> str | None:
    value = (email or "").strip().lower()
    return value if value else None


def resolve_email(*, email: str | None = None, username: str | None = None) -> str | None:
    return normalize_email(email or username)


def is_valid_email(email: str) -> bool:
    return re.fullmatch(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", email) is not None


def is_valid_gmail(email: str) -> bool:
    normalized = (email or "").strip().lower()
    return is_valid_email(normalized) and normalized.endswith("@gmail.com")


def validate_password(password: str) -> None:
    if len(password or "") < 8:
        raise ValueError("Password must be at least 8 characters.")


def parse_jwt_expiry(expiry_text: str) -> timedelta:
    value = expiry_text.strip().lower()
    if value.endswith("h"):
        return timedelta(hours=int(value[:-1] or "0"))
    if value.endswith("m"):
        return timedelta(minutes=int(value[:-1] or "0"))
    if value.endswith("d"):
        return timedelta(days=int(value[:-1] or "0"))
    return timedelta(hours=12)


def parse_iso_datetime(value: str | None, *, default_now: bool = True) -> datetime:
    text = (value or "").strip()
    if not text:
        if default_now:
            return datetime.now(UTC)
        raise ValueError("Datetime text is required.")

    normalized = text.replace("Z", "+00:00")
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def normalize_optional_text(value: str | None) -> str | None:
    text = (value or "").strip()
    return text if text else None


def json_value_from_text(value: str | None) -> Any | None:
    text = (value or "").strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"raw": text}


def stable_event_hash(*parts: Any) -> str:
    joined = "||".join(str(part) for part in parts)
    return hashlib.sha256(joined.encode("utf-8")).hexdigest()


def to_iso(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.astimezone(UTC).isoformat()
    return str(value)


def to_user_response(row: dict[str, Any] | None) -> dict[str, Any] | None:
    if row is None:
        return None
    return {
        "id": str(row["id"]),
        "username": row["username"],
        "email": row["email"],
        "role": row["role"],
        "isActive": bool(row["is_active"]),
        "mfaEnabled": bool(row["mfa_enabled"]),
        "activeWorkspaceId": (
            str(row["active_workspace_id"]) if row.get("active_workspace_id") else None
        ),
        "createdAtIso": to_iso(row["created_at"]),
        "updatedAtIso": to_iso(row["updated_at"]),
        "lastLoginAtIso": to_iso(row["last_login_at"]),
    }


def mask_email(email: str) -> str:
    value = (email or "").strip()
    at = value.find("@")
    if at <= 1:
        return "***"
    return f"{value[0]}***{value[at:]}"


def issue_token(user: dict[str, Any]) -> str:
    now = datetime.now(UTC)
    expires_in = parse_jwt_expiry(JWT_EXPIRES_IN)
    payload = {
        "sub": str(user["id"]),
        "username": user["username"],
        "role": user["role"],
        "iat": int(now.timestamp()),
        "exp": int((now + expires_in).timestamp()),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm="HS256")


def send_otp_email(
    recipient_email: str,
    otp: str,
    purpose: Literal["login_mfa", "password_reset"],
    expires_at: datetime,
) -> None:
    if not SMTP_CONFIGURED:
        raise RuntimeError(
            "SMTP sender is not configured. Set SMTP_GMAIL_USER and SMTP_GMAIL_APP_PASSWORD."
        )

    purpose_label = "MFA sign in" if purpose == OtpPurpose.LOGIN_MFA else "password reset"
    message = EmailMessage()
    message["From"] = f"{SMTP_FROM_NAME} <{SMTP_GMAIL_USER}>"
    message["To"] = recipient_email
    message["Subject"] = f"ScaleServe OTP for {purpose_label}"
    message.set_content(
        f"Your OTP is {otp}.\n\n"
        f"Purpose: {purpose_label}\n"
        f"Expires at (UTC): {expires_at.astimezone(UTC).isoformat()}\n\n"
        "If you did not request this code, ignore this email."
    )

    with smtplib.SMTP_SSL("smtp.gmail.com", 465, timeout=20) as smtp:
        smtp.login(SMTP_GMAIL_USER, SMTP_GMAIL_APP_PASSWORD)
        smtp.send_message(message)


def fetch_user_by_email(email: str) -> dict[str, Any] | None:
    with db_connection() as conn, conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, username, email, password_hash, role, is_active, mfa_enabled, active_workspace_id, created_at, updated_at, last_login_at
            FROM app_users
            WHERE LOWER(email) = %s
            LIMIT 1
            """,
            (email,),
        )
        return cur.fetchone()


def resolve_user_id_by_username(cur: Any, username: str | None) -> str | None:
    normalized = normalize_username(username or "")
    if not normalized:
        return None
    cur.execute(
        """
        SELECT id
        FROM app_users
        WHERE username = %s
        LIMIT 1
        """,
        (normalized,),
    )
    row = cur.fetchone()
    if row is None:
        return None
    return str(row["id"])


def resolve_workspace_id(
    cur: Any,
    *,
    workspace_slug: str | None = None,
    username: str | None = None,
) -> str:
    slug = (workspace_slug or "").strip().lower()
    if slug:
        cur.execute(
            """
            SELECT id
            FROM workspaces
            WHERE slug = %s
            LIMIT 1
            """,
            (slug,),
        )
        row = cur.fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail=f'Workspace "{slug}" not found.')
        return str(row["id"])

    normalized_username = normalize_username(username or "")
    if normalized_username:
        cur.execute(
            """
            SELECT active_workspace_id
            FROM app_users
            WHERE username = %s
            LIMIT 1
            """,
            (normalized_username,),
        )
        row = cur.fetchone()
        if row is not None and row.get("active_workspace_id"):
            return str(row["active_workspace_id"])

    return DEFAULT_WORKSPACE_ID


def update_last_login(user_id: str) -> None:
    with db_connection() as conn, conn.cursor() as cur:
        cur.execute(
            """
            UPDATE app_users
            SET last_login_at = NOW(), updated_at = NOW()
            WHERE id = %s
            """,
            (user_id,),
        )


def create_otp_challenge(user: dict[str, Any], purpose: str) -> tuple[str, datetime]:
    otp = str(random.randint(0, 999999)).zfill(6)
    otp_hash = bcrypt.hashpw(otp.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")
    expires_at = datetime.now(UTC) + timedelta(minutes=OTP_TTL_MINUTES)

    with db_connection() as conn:
        with conn.transaction():
            with conn.cursor() as cur:
                cur.execute(
                    """
                    UPDATE auth_otp_challenges
                    SET consumed_at = NOW()
                    WHERE user_id = %s
                      AND purpose = %s
                      AND consumed_at IS NULL
                    """,
                    (user["id"], purpose),
                )
                cur.execute(
                    """
                    INSERT INTO auth_otp_challenges (user_id, purpose, otp_hash, expires_at, max_attempts)
                    VALUES (%s, %s, %s, %s, %s)
                    """,
                    (user["id"], purpose, otp_hash, expires_at, OTP_MAX_ATTEMPTS),
                )

    return otp, expires_at


def verify_otp_challenge(email: str, purpose: str, otp: str) -> tuple[bool, dict[str, Any] | None]:
    with db_connection() as conn:
        with conn.transaction():
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT c.id, c.otp_hash, c.expires_at, c.attempts, c.max_attempts, c.consumed_at,
                           u.id AS user_id, u.username, u.email, u.role, u.is_active, u.mfa_enabled, u.active_workspace_id, u.created_at, u.updated_at, u.last_login_at
                    FROM auth_otp_challenges c
                    JOIN app_users u ON u.id = c.user_id
                    WHERE LOWER(u.email) = %s
                      AND c.purpose = %s
                      AND c.consumed_at IS NULL
                    ORDER BY c.created_at DESC
                    LIMIT 1
                    """,
                    (email, purpose),
                )
                row = cur.fetchone()
                if row is None:
                    return False, None

                now = datetime.now(UTC)
                if row["expires_at"] <= now:
                    cur.execute(
                        """
                        UPDATE auth_otp_challenges
                        SET consumed_at = NOW()
                        WHERE id = %s
                        """,
                        (row["id"],),
                    )
                    return False, None

                if row["attempts"] >= row["max_attempts"]:
                    cur.execute(
                        """
                        UPDATE auth_otp_challenges
                        SET consumed_at = NOW()
                        WHERE id = %s
                        """,
                        (row["id"],),
                    )
                    return False, None

                if not bcrypt.checkpw(otp.encode("utf-8"), row["otp_hash"].encode("utf-8")):
                    next_attempts = int(row["attempts"]) + 1
                    cur.execute(
                        """
                        UPDATE auth_otp_challenges
                        SET attempts = %s,
                            consumed_at = CASE WHEN %s >= max_attempts THEN NOW() ELSE consumed_at END
                        WHERE id = %s
                        """,
                        (next_attempts, next_attempts, row["id"]),
                    )
                    return False, None

                cur.execute(
                    """
                    UPDATE auth_otp_challenges
                    SET consumed_at = NOW()
                    WHERE id = %s
                    """,
                    (row["id"],),
                )

                user = {
                    "id": row["user_id"],
                    "username": row["username"],
                    "email": row["email"],
                    "role": row["role"],
                    "is_active": row["is_active"],
                    "mfa_enabled": row["mfa_enabled"],
                    "active_workspace_id": row["active_workspace_id"],
                    "created_at": row["created_at"],
                    "updated_at": row["updated_at"],
                    "last_login_at": row["last_login_at"],
                }
                return True, user


def ensure_schema() -> None:
    if not AUTO_MIGRATE:
        return
    sql_paths = sorted((PROJECT_ROOT / "sql").glob("*.sql"))
    if not sql_paths:
        raise RuntimeError("No SQL migration files found in backend/sql.")

    with db_connection() as conn, conn.cursor() as cur:
        for sql_path in sql_paths:
            sql_text = sql_path.read_text(encoding="utf-8")
            cur.execute(sql_text)


app = FastAPI(title="ScaleServe Backend", version="1.0.0")

if CORS_ORIGINS:
    allowed_origins = [item.strip() for item in CORS_ORIGINS.split(",") if item.strip()]
else:
    allowed_origins = ["*"]

app.add_middleware(
    CORSMiddleware,
    allow_origins=allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
def startup_event() -> None:
    ensure_schema()


@app.get("/health")
def health() -> dict[str, Any]:
    try:
        with db_connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchone()
        return {"ok": True, "service": "scaleserve-backend"}
    except Exception as error:
        raise HTTPException(status_code=500, detail=str(error)) from error


@app.get("/auth/status")
def auth_status() -> dict[str, Any]:
    with db_connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT COUNT(*)::int AS count FROM app_users")
        row = cur.fetchone()
        count = int(row["count"] if row else 0)
    return {"hasUsers": count > 0}


@app.post("/auth/bootstrap", status_code=201)
def auth_bootstrap(payload: BootstrapRequest) -> dict[str, Any]:
    email = normalize_email(payload.email)
    password = payload.password
    mfa_enabled = payload.mfaEnabled is True
    requested_username = normalize_username(payload.username or "")
    if not email or not is_valid_gmail(email):
        raise HTTPException(status_code=400, detail="Valid Gmail address is required.")
    if mfa_enabled and not SMTP_CONFIGURED:
        raise HTTPException(
            status_code=400,
            detail="MFA cannot be enabled until SMTP Gmail sender is configured on backend.",
        )

    try:
        validate_password(password)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    with db_connection() as conn:
        with conn.transaction():
            with conn.cursor() as cur:
                cur.execute("SELECT COUNT(*)::int AS count FROM app_users")
                count_row = cur.fetchone()
                count = int(count_row["count"] if count_row else 0)
                if count > 0:
                    raise HTTPException(
                        status_code=409,
                        detail="Bootstrap already completed. Users already exist.",
                    )

                cur.execute(
                    """
                    INSERT INTO workspaces (id, slug, name, description, is_system, created_at, updated_at)
                    VALUES (%s, %s, %s, %s, TRUE, NOW(), NOW())
                    ON CONFLICT (id) DO UPDATE SET
                      slug = EXCLUDED.slug,
                      name = EXCLUDED.name,
                      description = EXCLUDED.description,
                      updated_at = NOW()
                    """,
                    (
                        DEFAULT_WORKSPACE_ID,
                        DEFAULT_WORKSPACE_SLUG,
                        "Default Workspace",
                        "System default workspace",
                    ),
                )

                password_hash = bcrypt.hashpw(
                    password.encode("utf-8"), bcrypt.gensalt(rounds=12)
                ).decode("utf-8")
                username = requested_username or username_from_email(email)
                cur.execute(
                    """
                    INSERT INTO app_users (username, email, password_hash, role, is_active, mfa_enabled, active_workspace_id)
                    VALUES (%s, %s, %s, 'admin', TRUE, %s, %s)
                    RETURNING id, username, email, role, is_active, mfa_enabled, active_workspace_id, created_at, updated_at, last_login_at
                    """,
                    (username, email, password_hash, mfa_enabled, DEFAULT_WORKSPACE_ID),
                )
                user = cur.fetchone()

                if user is not None:
                    cur.execute(
                        """
                        INSERT INTO workspace_users (workspace_id, user_id, role, is_active, joined_at)
                        VALUES (%s, %s, 'owner', TRUE, NOW())
                        ON CONFLICT (workspace_id, user_id) DO UPDATE SET
                          role = EXCLUDED.role,
                          is_active = TRUE
                        """,
                        (DEFAULT_WORKSPACE_ID, user["id"]),
                    )

    if user is None:
        raise HTTPException(status_code=500, detail="Failed to create bootstrap user.")

    update_last_login(str(user["id"]))
    token = issue_token(user)
    return {"user": to_user_response(user), "token": token}


@app.post("/auth/login")
def auth_login(payload: LoginRequest) -> dict[str, Any]:
    email = resolve_email(email=payload.email, username=payload.username)
    password = payload.password

    if not email or not is_valid_gmail(email) or not password:
        raise HTTPException(status_code=400, detail="Gmail and password are required.")

    user = fetch_user_by_email(email)
    if user is None or not bool(user["is_active"]):
        raise HTTPException(status_code=401, detail="Invalid email or password.")

    password_matches = bcrypt.checkpw(
        password.encode("utf-8"), user["password_hash"].encode("utf-8")
    )
    if not password_matches:
        raise HTTPException(status_code=401, detail="Invalid email or password.")

    if bool(user["mfa_enabled"]):
        email = user["email"]
        if not email:
            raise HTTPException(
                status_code=400,
                detail="MFA is enabled but no email is configured for this user.",
            )

        otp, expires_at = create_otp_challenge(user, OtpPurpose.LOGIN_MFA)
        send_otp_email(
            recipient_email=email,
            otp=otp,
            purpose=OtpPurpose.LOGIN_MFA,
            expires_at=expires_at,
        )
        return {
            "mfaRequired": True,
            "maskedEmail": mask_email(email),
            "user": to_user_response(user),
        }

    update_last_login(str(user["id"]))
    token = issue_token(user)
    return {"mfaRequired": False, "token": token, "user": to_user_response(user)}


@app.post("/auth/login/mfa/request")
def auth_login_mfa_request(payload: EmailRequest) -> dict[str, Any]:
    email = resolve_email(email=payload.email, username=payload.username)
    if not email or not is_valid_gmail(email):
        raise HTTPException(status_code=400, detail="Valid Gmail address is required.")

    user = fetch_user_by_email(email)
    if (
        user is None
        or not bool(user["is_active"])
        or not bool(user["mfa_enabled"])
        or not user["email"]
    ):
        raise HTTPException(status_code=400, detail="User is unavailable for MFA OTP request.")

    otp, expires_at = create_otp_challenge(user, OtpPurpose.LOGIN_MFA)
    send_otp_email(
        recipient_email=user["email"],
        otp=otp,
        purpose=OtpPurpose.LOGIN_MFA,
        expires_at=expires_at,
    )
    return {
        "sent": True,
        "maskedEmail": mask_email(user["email"]),
        "message": "MFA OTP sent.",
    }


@app.post("/auth/login/mfa/verify")
def auth_login_mfa_verify(payload: VerifyOtpRequest) -> dict[str, Any]:
    email = resolve_email(email=payload.email, username=payload.username)
    otp = (payload.otp or "").strip()
    if not email or not is_valid_gmail(email) or not otp:
        raise HTTPException(status_code=400, detail="Gmail and OTP are required.")

    valid, user = verify_otp_challenge(email, OtpPurpose.LOGIN_MFA, otp)
    if not valid or user is None:
        raise HTTPException(status_code=401, detail="Invalid or expired OTP.")

    update_last_login(str(user["id"]))
    token = issue_token(user)
    return {"token": token, "user": to_user_response(user)}


@app.post("/auth/forgot-password/request")
def auth_forgot_password_request(payload: EmailRequest) -> dict[str, Any]:
    email = resolve_email(email=payload.email, username=payload.username)
    if not email or not is_valid_gmail(email):
        raise HTTPException(status_code=400, detail="Valid Gmail address is required.")

    user = fetch_user_by_email(email)
    if user is None or not bool(user["is_active"]) or not user["email"]:
        raise HTTPException(
            status_code=404, detail="User not found or recovery email is missing."
        )

    otp, expires_at = create_otp_challenge(user, OtpPurpose.PASSWORD_RESET)
    send_otp_email(
        recipient_email=user["email"],
        otp=otp,
        purpose=OtpPurpose.PASSWORD_RESET,
        expires_at=expires_at,
    )
    return {
        "sent": True,
        "maskedEmail": mask_email(user["email"]),
        "message": "Password reset OTP sent.",
    }


@app.post("/auth/forgot-password/reset")
def auth_forgot_password_reset(payload: ResetPasswordRequest) -> dict[str, Any]:
    email = resolve_email(email=payload.email, username=payload.username)
    otp = (payload.otp or "").strip()
    new_password = payload.newPassword

    if not email or not is_valid_gmail(email) or not otp or not new_password:
        raise HTTPException(
            status_code=400, detail="Gmail, OTP, and newPassword are required."
        )
    try:
        validate_password(new_password)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error

    valid, user = verify_otp_challenge(email, OtpPurpose.PASSWORD_RESET, otp)
    if not valid or user is None:
        raise HTTPException(status_code=401, detail="Invalid or expired OTP.")

    new_password_hash = bcrypt.hashpw(
        new_password.encode("utf-8"), bcrypt.gensalt(rounds=12)
    ).decode("utf-8")
    with db_connection() as conn, conn.cursor() as cur:
        cur.execute(
            """
            UPDATE app_users
            SET password_hash = %s, updated_at = NOW()
            WHERE id = %s
            """,
            (new_password_hash, user["id"]),
        )

    return {"reset": True, "message": "Password reset successful."}


@app.post("/sync/settings")
def sync_settings(payload: SyncSettingsRequest) -> dict[str, Any]:
    if not payload.settings:
        return {"synced": 0}

    synced = 0
    with db_connection() as conn:
        with conn.transaction():
            with conn.cursor() as cur:
                workspace_id = resolve_workspace_id(
                    cur,
                    workspace_slug=payload.workspaceSlug,
                    username=payload.initiatedByUsername,
                )
                for key, raw_value in payload.settings.items():
                    normalized_key = (key or "").strip()
                    if not normalized_key:
                        continue
                    value = "" if raw_value is None else str(raw_value)
                    cur.execute(
                        """
                        INSERT INTO workspace_settings (workspace_id, key, value, updated_at)
                        VALUES (%s, %s, %s, NOW())
                        ON CONFLICT (workspace_id, key)
                        DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()
                        """,
                        (workspace_id, normalized_key, value),
                    )
                    synced += 1

    return {"synced": synced, "workspaceId": workspace_id}


@app.post("/sync/machine-snapshot")
def sync_machine_snapshot(payload: SyncMachineSnapshotRequest) -> dict[str, Any]:
    self_dns_name = normalize_optional_text(payload.selfDnsName)
    if not self_dns_name:
        raise HTTPException(status_code=400, detail="selfDnsName is required.")

    captured_at = parse_iso_datetime(payload.capturedAtIso, default_now=True)
    synced_machines = 0

    with db_connection() as conn:
        with conn.transaction():
            with conn.cursor() as cur:
                workspace_id = resolve_workspace_id(
                    cur,
                    workspace_slug=payload.workspaceSlug,
                    username=payload.initiatedByUsername,
                )

                def upsert_machine(
                    *,
                    dns_name: str,
                    display_name: str,
                    ip_address: str,
                    operating_system: str,
                    is_online: bool,
                    is_self: bool,
                    metadata: dict[str, Any],
                ) -> None:
                    cur.execute(
                        """
                        INSERT INTO machine_inventory (
                          workspace_id,
                          dns_name,
                          display_name,
                          ip_address,
                          operating_system,
                          is_online,
                          is_self,
                          tailnet_name,
                          login_name,
                          backend_state,
                          first_seen_at,
                          last_seen_at,
                          metadata_json,
                          updated_at
                        )
                        VALUES (
                          %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb, NOW()
                        )
                        ON CONFLICT (workspace_id, dns_name)
                        DO UPDATE SET
                          display_name = EXCLUDED.display_name,
                          ip_address = EXCLUDED.ip_address,
                          operating_system = EXCLUDED.operating_system,
                          is_online = EXCLUDED.is_online,
                          is_self = EXCLUDED.is_self,
                          tailnet_name = EXCLUDED.tailnet_name,
                          login_name = EXCLUDED.login_name,
                          backend_state = EXCLUDED.backend_state,
                          last_seen_at = EXCLUDED.last_seen_at,
                          metadata_json = EXCLUDED.metadata_json,
                          updated_at = NOW()
                        """,
                        (
                            workspace_id,
                            dns_name,
                            display_name,
                            ip_address,
                            operating_system,
                            is_online,
                            is_self,
                            normalize_optional_text(payload.tailnetName),
                            normalize_optional_text(payload.loginName),
                            normalize_optional_text(payload.backendState),
                            captured_at,
                            captured_at,
                            json.dumps(metadata),
                        ),
                    )

                upsert_machine(
                    dns_name=self_dns_name,
                    display_name=normalize_optional_text(payload.selfName)
                    or self_dns_name,
                    ip_address=normalize_optional_text(payload.selfIpAddress) or "unknown",
                    operating_system="unknown",
                    is_online=payload.isConnected,
                    is_self=True,
                    metadata={
                        "source": "tailscale_status",
                        "kind": "self",
                        "magicDnsSuffix": normalize_optional_text(payload.magicDnsSuffix),
                    },
                )
                synced_machines += 1

                for peer in payload.peers:
                    peer_dns_name = normalize_optional_text(peer.dnsName)
                    if not peer_dns_name:
                        continue
                    upsert_machine(
                        dns_name=peer_dns_name,
                        display_name=normalize_optional_text(peer.name) or peer_dns_name,
                        ip_address=normalize_optional_text(peer.ipAddress) or "unknown",
                        operating_system=normalize_optional_text(peer.os) or "unknown",
                        is_online=peer.online,
                        is_self=False,
                        metadata={"source": "tailscale_status", "kind": "peer"},
                    )
                    synced_machines += 1

                cur.execute(
                    """
                    INSERT INTO tailscale_snapshot_logs (
                      workspace_id,
                      captured_at,
                      source_machine_dns_name,
                      snapshot_json
                    )
                    VALUES (%s, %s, %s, %s::jsonb)
                    """,
                    (
                        workspace_id,
                        captured_at,
                        self_dns_name,
                        json.dumps(payload.model_dump(mode="json")),
                    ),
                )

    return {
        "syncedMachines": synced_machines,
        "snapshotLogged": True,
        "workspaceId": workspace_id,
    }


@app.post("/sync/command-log")
def sync_command_log(payload: SyncCommandLogRequest) -> dict[str, Any]:
    command_text = (payload.commandText or "").strip()
    safe_command_text = (payload.safeCommandText or "").strip()
    if not command_text or not safe_command_text:
        raise HTTPException(
            status_code=400, detail="commandText and safeCommandText are required."
        )

    created_at = parse_iso_datetime(payload.createdAtIso, default_now=True)
    success = payload.success if payload.success is not None else payload.exitCode == 0
    event_hash = stable_event_hash(
        created_at.isoformat(),
        command_text,
        safe_command_text,
        payload.exitCode,
        payload.source,
    )

    with db_connection() as conn:
        with conn.transaction():
            with conn.cursor() as cur:
                user_id = resolve_user_id_by_username(cur, payload.initiatedByUsername)
                workspace_id = resolve_workspace_id(
                    cur,
                    workspace_slug=payload.workspaceSlug,
                    username=payload.initiatedByUsername,
                )
                cur.execute(
                    """
                    INSERT INTO command_logs (
                      workspace_id,
                      command_text,
                      safe_command_text,
                      event_hash,
                      exit_code,
                      success,
                      stdout,
                      stderr,
                      source,
                      initiated_by_user_id,
                      created_at
                    )
                    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                    ON CONFLICT (workspace_id, event_hash) DO NOTHING
                    """,
                    (
                        workspace_id,
                        command_text,
                        safe_command_text,
                        event_hash,
                        payload.exitCode,
                        success,
                        payload.stdout,
                        payload.stderr,
                        normalize_optional_text(payload.source) or "app",
                        user_id,
                        created_at,
                    ),
                )
                inserted = cur.rowcount > 0

    return {"inserted": inserted, "workspaceId": workspace_id}


@app.post("/sync/remote-state")
def sync_remote_state(payload: SyncRemoteStateRequest) -> dict[str, Any]:
    profiles_upserted = 0
    runs_inserted = 0
    allowed_run_types = {
        "remote_command",
        "stream_file",
        "stream_script",
        "ssh_setup",
        "diagnostic",
        "other",
    }

    with db_connection() as conn:
        with conn.transaction():
            with conn.cursor() as cur:
                workspace_id = resolve_workspace_id(
                    cur,
                    workspace_slug=payload.workspaceSlug,
                    username=payload.initiatedByUsername,
                )
                for profile in payload.profiles:
                    dns_name = normalize_optional_text(profile.dnsName)
                    remote_user = normalize_optional_text(profile.remoteUser)
                    if not dns_name or not remote_user:
                        continue

                    updated_at = parse_iso_datetime(profile.updatedAtIso, default_now=True)
                    owner_user_id = resolve_user_id_by_username(cur, profile.ownerUsername)

                    cur.execute(
                        """
                        INSERT INTO remote_device_profiles (
                          workspace_id,
                          dns_name,
                          remote_user,
                          key_path,
                          bootstrap_key_path,
                          default_command,
                          owner_user_id,
                          updated_at
                        )
                        VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                        ON CONFLICT (workspace_id, dns_name)
                        DO UPDATE SET
                          remote_user = EXCLUDED.remote_user,
                          key_path = EXCLUDED.key_path,
                          bootstrap_key_path = EXCLUDED.bootstrap_key_path,
                          default_command = EXCLUDED.default_command,
                          owner_user_id = EXCLUDED.owner_user_id,
                          updated_at = EXCLUDED.updated_at
                        """,
                        (
                            workspace_id,
                            dns_name,
                            remote_user,
                            normalize_optional_text(profile.keyPath) or "",
                            normalize_optional_text(profile.bootstrapKeyPath) or "",
                            normalize_optional_text(profile.defaultCommand) or "",
                            owner_user_id,
                            updated_at,
                        ),
                    )
                    profiles_upserted += 1

                for run in payload.recentRuns:
                    device_dns_name = normalize_optional_text(run.deviceDnsName)
                    remote_user = normalize_optional_text(run.remoteUser)
                    command_text = (run.command or "").strip()
                    if not device_dns_name or not remote_user or not command_text:
                        continue

                    try:
                        started_at = parse_iso_datetime(run.startedAtIso, default_now=False)
                    except ValueError:
                        continue

                    finished_at = (
                        parse_iso_datetime(run.finishedAtIso, default_now=True)
                        if normalize_optional_text(run.finishedAtIso)
                        else None
                    )
                    run_type = (run.runType or "remote_command").strip().lower()
                    if run_type not in allowed_run_types:
                        run_type = "other"
                    metadata_value = json_value_from_text(run.metadataJson)
                    initiated_by_user_id = resolve_user_id_by_username(
                        cur, run.initiatedByUsername or payload.initiatedByUsername
                    )
                    event_hash = stable_event_hash(
                        started_at.isoformat(),
                        device_dns_name,
                        remote_user,
                        command_text,
                        run.exitCode,
                        run_type,
                        normalize_optional_text(run.localFilePath) or "",
                    )

                    cur.execute(
                        """
                        INSERT INTO remote_run_logs (
                          workspace_id,
                          started_at,
                          finished_at,
                          device_dns_name,
                          remote_user,
                          command,
                          safe_command_text,
                          event_hash,
                          exit_code,
                          success,
                          run_type,
                          local_file_path,
                          stdout,
                          stderr,
                          metadata_json,
                          initiated_by_user_id,
                          created_at
                        )
                        VALUES (
                          %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s::jsonb, %s, NOW()
                        )
                        ON CONFLICT (workspace_id, event_hash) DO NOTHING
                        """,
                        (
                            workspace_id,
                            started_at,
                            finished_at,
                            device_dns_name,
                            remote_user,
                            command_text,
                            normalize_optional_text(run.safeCommandText),
                            event_hash,
                            run.exitCode,
                            bool(run.success),
                            run_type,
                            normalize_optional_text(run.localFilePath),
                            run.stdout,
                            run.stderr,
                            json.dumps(metadata_value) if metadata_value is not None else None,
                            initiated_by_user_id,
                        ),
                    )
                    if cur.rowcount > 0:
                        runs_inserted += 1

    return {
        "profilesUpserted": profiles_upserted,
        "runsInserted": runs_inserted,
        "workspaceId": workspace_id,
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=PORT, reload=False)
