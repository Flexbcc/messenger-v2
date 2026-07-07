from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.db import get_conn, init_db
from app.routers import admin_enrollment, enrollment, registry
from app.config import ENROLLMENT_MODE
from app.attestation import ATTESTATION_MODE, MTLS_MODE

app = FastAPI(title="Discovery Node", version="0.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # MVP only, see home-node/app/main.py for the same note
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
def on_startup():
    init_db()


@app.get("/health")
def health():
    with get_conn() as conn:
        nodes_count = conn.execute("SELECT COUNT(*) FROM node_capabilities").fetchone()[0]
        users_count = conn.execute("SELECT COUNT(*) FROM user_records").fetchone()[0]
    return {
        "status": "ok",
        "node_role": "discovery",
        "load": {
            "registered_nodes": nodes_count,
            "registered_users": users_count,
            "enrollment_mode": ENROLLMENT_MODE,
            "attestation_mode": ATTESTATION_MODE,
            "mtls_mode": MTLS_MODE,
        },
    }


app.include_router(registry.router)
app.include_router(enrollment.router)
app.include_router(admin_enrollment.router)
