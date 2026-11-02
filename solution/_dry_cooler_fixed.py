#!/usr/bin/env python3
"""Reference fix for dry-cooler recirculation capacity."""

from __future__ import annotations

import json
import sys
from pathlib import Path


SENSORS = Path("/app/yard_sensors.json")
NAMEPLATE = Path("/app/nameplate.json")


def load_json(path: Path) -> dict:
    text = path.read_text(encoding="utf-8").strip()
    obj, _ = json.JSONDecoder().raw_decode(text)
    return obj


def compute(s: dict, np: dict) -> dict:
    r = float(s["recirc_ratio"])
    if not (0.0 <= r <= 1.0):
        raise ValueError("recirc_ratio out of range")

    tamb = float(s["tamb_c"])
    tdisch = float(s["tdisch_c"])
    t_eff = (1.0 - r) * tamb + r * tdisch

    approach = float(np["design_approach_k"])
    m = float(s["glycol_kg_s"])
    cp = float(s["cp_j_per_kg_k"])
    t_fin = float(s["fluid_in_c"])

    dT = t_fin - t_eff - approach
    if dT <= 0:
        raise ValueError("non-positive available temperature difference")

    q_w = m * cp * dT
    return {
        "t_air_eff_c": round(t_eff, 2),
        "q_avail_kw": round(q_w / 1000.0, 2),
    }


def main() -> None:
    try:
        out = compute(load_json(SENSORS), load_json(NAMEPLATE))
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
