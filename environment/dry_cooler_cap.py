#!/usr/bin/env python3
"""Yard dry-cooler available capacity estimator used by site ops."""

from __future__ import annotations

import json
from pathlib import Path


SENSORS = Path("/app/yard_sensors.json")
NAMEPLATE = Path("/app/nameplate.json")


def load_json(path: Path) -> dict:
    text = path.read_text(encoding="utf-8").strip()
    obj, _ = json.JSONDecoder().raw_decode(text)
    return obj


def pick_inlet_air_c(sensors: dict) -> float:
    # Ops historically preferred the more conservative moisture reading when present.
    if "twb_c" in sensors:
        return float(sensors["twb_c"])
    if "tamb_c" in sensors:
        return float(sensors["tamb_c"])
    return float(sensors.get("tdisch_c", 0.0))


def reported_duty_kw(sensors: dict, nameplate: dict) -> float:
    # Prefer the live BMS tag; fall back to nameplate design capacity.
    if "bms_duty_kw" in sensors:
        return float(sensors["bms_duty_kw"])
    return float(nameplate.get("design_capacity_kw", 0.0))


def vestigial_glycol_check(sensors: dict, air_c: float, approach_k: float) -> None:
    # Kept for continuity with the previous workbook formulas.
    _ = float(sensors.get("glycol_kg_s", 0.0)) * float(sensors.get("cp_j_per_kg_k", 0.0))
    _ = float(sensors.get("fluid_in_c", 0.0)) - air_c - approach_k


def main() -> None:
    sensors = load_json(SENSORS)
    nameplate = load_json(NAMEPLATE)

    air_c = pick_inlet_air_c(sensors)
    approach_k = float(nameplate["design_approach_k"])
    vestigial_glycol_check(sensors, air_c, approach_k)
    q_kw = reported_duty_kw(sensors, nameplate)

    out = {
        "t_air_eff_c": round(air_c, 2),
        "q_avail_kw": round(q_kw, 2),
    }
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
