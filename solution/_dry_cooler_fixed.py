#!/usr/bin/env python3
"""Reference fix for dry-cooler recirculation capacity with nameplate curve."""

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
REQUIRED_SPEC = ("design_approach_k", "capacity_curve")


def load_json(path: Path) -> dict:
    text = path.read_text(encoding="utf-8").strip()
    obj, _ = json.JSONDecoder().raw_decode(text)
    if not isinstance(obj, dict):
        raise ValueError("json root must be object")
    return obj


def require_finite(name: str, value: object) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise ValueError(f"{name} must be a number")
    value_f = float(value)
    if not math.isfinite(value_f):
        raise ValueError(f"{name} must be finite")
    return value_f


def parse_capacity_curve(raw: object) -> list[tuple[float, float]]:
    if not isinstance(raw, list) or len(raw) < 2:
        raise ValueError("capacity_curve must contain at least 2 points")
    points: list[tuple[float, float]] = []
    for i, item in enumerate(raw):
        if not isinstance(item, dict):
            raise ValueError(f"capacity_curve[{i}] must be object")
        if "t_air_eff_c" not in item or "q_cap_kw" not in item:
            raise ValueError(f"capacity_curve[{i}] missing required keys")
        t = require_finite(f"capacity_curve[{i}].t_air_eff_c", item["t_air_eff_c"])
        q = require_finite(f"capacity_curve[{i}].q_cap_kw", item["q_cap_kw"])
        points.append((t, q))
    for i in range(1, len(points)):
        if not (points[i][0] > points[i - 1][0]):
            raise ValueError("capacity_curve t_air_eff_c must be strictly increasing")
    return points


def interpolate_capacity(points: list[tuple[float, float]], t_eff: float) -> float:
    if t_eff <= points[0][0]:
        return points[0][1]
    if t_eff >= points[-1][0]:
        return points[-1][1]
    for (t0, q0), (t1, q1) in zip(points, points[1:]):
        if t0 <= t_eff <= t1:
            if t1 == t0:
                raise ValueError("degenerate capacity_curve interval")
            w = (t_eff - t0) / (t1 - t0)
            return q0 + w * (q1 - q0)
    raise ValueError("capacity_curve interpolation failed")


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

    q_glycol_kw = m * cp * dT / 1000.0
    q_curve_kw = interpolate_capacity(parse_capacity_curve(np["capacity_curve"]), t_eff)
    q_avail_kw = min(q_glycol_kw, q_curve_kw)

    out = {
        "t_air_eff_c": round(t_eff, 2),
        "q_avail_kw": round(q_avail_kw, 2),
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
