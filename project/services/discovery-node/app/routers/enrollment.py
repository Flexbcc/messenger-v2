"""Enrollment poll + one-time node_token claim (ADR-0009)."""
from fastapi import APIRouter, HTTPException

from app.db import get_conn
from app.schemas import EnrollmentStatusRequest, EnrollmentStatusResponse
from app.security import generate_node_token, hash_value, verify_hash
from app.trust import now_iso

router = APIRouter()


@router.post("/registry/enrollment/status", response_model=EnrollmentStatusResponse)
def enrollment_status(payload: EnrollmentStatusRequest):
    """
    Node polls enrollment state while pending or claims node_token after approval.
    Requires enrollment_secret from the initial registration response.
    """
    with get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM node_capabilities WHERE node_id = ?", (payload.node_id,)
        ).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="Unknown node_id")

    if not verify_hash(payload.enrollment_secret, row["enrollment_secret_hash"]):
        raise HTTPException(status_code=403, detail="Invalid enrollment_secret")

    trust_status = row["trust_status"] or "unknown"

    if trust_status == "pending":
        return EnrollmentStatusResponse(
            node_id=payload.node_id,
            trust_status="pending",
            message="Awaiting operator approval",
        )

    if trust_status == "trusted" and not row["token_claimed_at"]:
        token_plain = generate_node_token()
        now = now_iso()
        with get_conn() as conn:
            conn.execute(
                """
                UPDATE node_capabilities SET
                    node_token_hash = ?,
                    token_claimed_at = ?,
                    token_issued_at = ?
                WHERE node_id = ?
                """,
                (hash_value(token_plain), now, now, payload.node_id),
            )
            conn.commit()
        return EnrollmentStatusResponse(
            node_id=payload.node_id,
            trust_status="trusted",
            node_token=token_plain,
            message="Store node_token securely — shown only once",
        )

    if trust_status == "trusted":
        return EnrollmentStatusResponse(
            node_id=payload.node_id,
            trust_status="trusted",
            message="Enrollment complete",
        )

    return EnrollmentStatusResponse(
        node_id=payload.node_id,
        trust_status=trust_status,
        message=f"Node trust_status is {trust_status}",
    )
