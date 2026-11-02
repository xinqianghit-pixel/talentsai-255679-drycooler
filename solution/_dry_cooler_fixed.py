#!/usr/bin/env python3
"""Reference fix for dry-cooler recirculation capacity."""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path


SENSORS = Path("/app/yard_sensors.json")
NAMEPLATE = Path("/app/nameplate.json")

REQUIRED_SENSOR = (
    "recirc_ratio",
    "tamb_c",
    "tdisch_c",
    "fluid_in_c",
    "glycol_kg_s",
    "cp_j_per_kg_k",
)
REQUIRED_SPEC = ("design_approach_k",)


def load_json(path: Path) -> dict:
    text = path.read_text(encoding="utf-8").strip()
    obj, _ = json.JSONDecoder().raw_decode(text)
    if not isinstance(obj, dict):
        raise ValueError("json root must be object")
    return obj


def require_finite(name: str, value: float) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError(f"{name} must be a number")
    value = float(value)
    if not math.isfinite(value):
        raise ValueError(f"{name} must be finite")
    return value


def compute(s: dict, np: dict) -> dict:
    for key in REQUIRED_SENSOR:
        if key not in s:
            raise ValueError(f"missing sensor field: {key}")
    for key in REQUIRED_SPEC:
        if key not in np:
            raise ValueError(f"missing nameplate field: {key}")

    r = require_finite("recirc_ratio", s["recirc_ratio"])
    if not (0.0 <= r <= 1.0):
        raise ValueError("recirc_ratio out of range")

    tamb = require_finite("tamb_c", s["tamb_c"])
    tdisch = require_finite("tdisch_c", s["tdisch_c"])
    t_eff = (1.0 - r) * tamb + r * tdisch

    approach = require_finite("design_approach_k", np["design_approach_k"])
    m = require_finite("glycol_kg_s", s["glycol_kg_s"])
    cp = require_finite("cp_j_per_kg_k", s["cp_j_per_kg_k"])
    t_fin = require_finite("fluid_in_c", s["fluid_in_c"])

    if m <= 0.0:
        raise ValueError("glycol_kg_s must be positive")
    if cp <= 0.0:
        raise ValueError("cp_j_per_kg_k must be positive")

    dT = t_fin - t_eff - approach
    if dT <= 0.0:
        raise ValueError("non-positive available temperature difference")

    q_w = m * cp * dT
    out = {
        "t_air_eff_c": round(t_eff, 2),
        "q_avail_kw": round(q_w / 1000.0, 2),
    }
    for key, value in out.items():
        if not math.isfinite(value):
            raise ValueError(f"{key} not finite")
    return out


def main() -> None:
    try:
        out = compute(load_json(SENSORS), load_json(NAMEPLATE))
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(out, ensure_ascii=False, allow_nan=False))


if __name__ == "__main__":
    main()
