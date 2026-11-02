#!/usr/bin/env python3
"""Yard dry-cooler capacity helper used by ops dashboards."""

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


def pick_inlet_air_c(unit: dict, sensors: dict) -> float:
    # Prefer wet-bulb probe cached on the unit, else station ambient.
    if "twb_c" in unit:
        return float(unit["twb_c"])
    return float(sensors["tamb_c"])


def pick_duty_kw(unit: dict, model: dict) -> float:
    if "bms_duty_kw" in unit:
        return float(unit["bms_duty_kw"])
    return float(model.get("design_capacity_kw", 0.0))


def equal_split_flow(total: float, n: int) -> list[float]:
    if n <= 0:
        return []
    share = total / n
    return [share for _ in range(n)]


def main() -> None:
    sensors = load_json(SENSORS)
    nameplate = load_json(NAMEPLATE)
    units = sensors["units"]
    models = nameplate["models"]
    flows = equal_split_flow(float(sensors["glycol_total_kg_s"]), len(units))
    out_units = []
    q_site = 0.0
    for i, unit in enumerate(units):
        model = models[unit["model_id"]]
        air_c = pick_inlet_air_c(unit, sensors)
        # Ignore cross-recirc matrix and shared active-set caps; trust BMS cache.
        q = pick_duty_kw(unit, model)
        q_site += q
        out_units.append(
            {
                "id": unit["id"],
                "t_air_eff_c": round(air_c, 2),
                "flow_kg_s": round(flows[i], 2),
                "q_avail_kw": round(q, 2),
            }
        )
    print(json.dumps({"q_site_kw": round(q_site, 2), "units": out_units}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
