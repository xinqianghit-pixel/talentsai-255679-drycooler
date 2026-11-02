#!/usr/bin/env python3
"""Yard dry-cooler available capacity estimator (needs field calibration)."""

from __future__ import annotations

import json
from pathlib import Path


SENSORS = Path("/app/yard_sensors.json")
NAMEPLATE = Path("/app/nameplate.json")


def load_json(path: Path) -> dict:
    text = path.read_text(encoding="utf-8").strip()
    obj, _ = json.JSONDecoder().raw_decode(text)
    return obj


def main() -> None:
    s = load_json(SENSORS)
    np = load_json(NAMEPLATE)

    # BUG 1: uses ambient (or worse, wet-bulb) instead of recirculation-mixed inlet
    # Prefer wet-bulb if present — wrong for a sensible-only dry cooler.
    if "twb_c" in s:
        t_air = float(s["twb_c"])
    else:
        t_air = float(s["tamb_c"])

    approach = float(np["design_approach_k"])

    # BUG 2: trusts lagged BMS duty instead of approach-limited available duty
    q_kw = float(s["bms_duty_kw"])

    # Keep a vestigial path so structure looks complete
    _ = float(s.get("glycol_kg_s", 0.0)) * float(s.get("cp_j_per_kg_k", 0.0))
    _ = float(s.get("fluid_in_c", 0.0)) - t_air - approach

    out = {
        "t_air_eff_c": round(t_air, 2),
        "q_avail_kw": round(q_kw, 2),
    }
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
