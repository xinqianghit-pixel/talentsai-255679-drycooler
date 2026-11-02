#!/usr/bin/env python3
"""Reference fix: multi-unit dry-cooler with cross-recirc matrix + shared glycol active-set."""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path


SENSORS = Path("/app/yard_sensors.json")
NAMEPLATE = Path("/app/nameplate.json")
FLOW_TOL = 1e-9
MAX_FLOW_ITERS = 64


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


def allocate_flows(
    total: float,
    weights: list[float],
    caps: list[float],
) -> list[float]:
    n = len(weights)
    if n == 0:
        raise ValueError("no units")
    if total <= 0.0:
        raise ValueError("glycol_total_kg_s must be positive")
    remaining = float(total)
    out = [0.0] * n
    active = {i for i in range(n) if weights[i] > 0.0 and caps[i] > 0.0}
    for _ in range(MAX_FLOW_ITERS):
        if remaining <= FLOW_TOL or not active:
            break
        wsum = sum(weights[i] for i in active)
        if wsum <= 0.0:
            break
        provisional = {i: remaining * (weights[i] / wsum) for i in active}
        saturated = [
            i
            for i, share in provisional.items()
            if share >= (caps[i] - out[i]) - FLOW_TOL
        ]
        if saturated:
            for i in saturated:
                out[i] = caps[i]
                active.discard(i)
            remaining = total - sum(out)
            continue
        for i, share in provisional.items():
            out[i] += share
        remaining = 0.0
        break
    else:
        raise ValueError("flow allocation did not converge")
    # numerical cleanup
    for i in range(n):
        if out[i] < 0.0:
            raise ValueError("negative allocated flow")
        if out[i] > caps[i] + 1e-6:
            raise ValueError("allocated flow exceeds cap")
    if sum(out) - total > 1e-6:
        raise ValueError("allocated flow exceeds station total")
    return out


def compute(s: dict, np: dict) -> dict:
    for key in ("tamb_c", "glycol_total_kg_s", "cp_j_per_kg_k", "recirc_matrix", "units"):
        if key not in s:
            raise ValueError(f"missing sensor field: {key}")
    if "design_approach_k" not in np or "models" not in np:
        raise ValueError("missing nameplate field")

    tamb = require_finite("tamb_c", s["tamb_c"])
    total = require_finite("glycol_total_kg_s", s["glycol_total_kg_s"])
    cp = require_finite("cp_j_per_kg_k", s["cp_j_per_kg_k"])
    approach = require_finite("design_approach_k", np["design_approach_k"])
    if total <= 0.0:
        raise ValueError("glycol_total_kg_s must be positive")
    if cp <= 0.0:
        raise ValueError("cp_j_per_kg_k must be positive")

    models_raw = np["models"]
    if not isinstance(models_raw, dict) or not models_raw:
        raise ValueError("models must be non-empty object")
    models: dict[str, list[tuple[float, float]]] = {}
    for mid, mobj in models_raw.items():
        if not isinstance(mobj, dict) or "capacity_curve" not in mobj:
            raise ValueError(f"model {mid} missing capacity_curve")
        models[str(mid)] = parse_capacity_curve(mobj["capacity_curve"])

    units_raw = s["units"]
    if not isinstance(units_raw, list) or len(units_raw) < 2:
        raise ValueError("units must contain at least 2 entries")
    n = len(units_raw)
    ids: list[str] = []
    tdisch: list[float] = []
    fluid_in: list[float] = []
    weights: list[float] = []
    caps: list[float] = []
    model_ids: list[str] = []
    seen: set[str] = set()
    for i, u in enumerate(units_raw):
        if not isinstance(u, dict):
            raise ValueError(f"units[{i}] must be object")
        for k in ("id", "tdisch_c", "fluid_in_c", "valve_weight", "max_flow_kg_s", "model_id"):
            if k not in u:
                raise ValueError(f"units[{i}] missing {k}")
        uid = u["id"]
        if not isinstance(uid, str) or not uid:
            raise ValueError(f"units[{i}].id must be non-empty string")
        if uid in seen:
            raise ValueError(f"duplicate unit id: {uid}")
        seen.add(uid)
        mid = u["model_id"]
        if not isinstance(mid, str) or mid not in models:
            raise ValueError(f"units[{i}] unknown model_id")
        w = require_finite(f"units[{i}].valve_weight", u["valve_weight"])
        cap = require_finite(f"units[{i}].max_flow_kg_s", u["max_flow_kg_s"])
        if w < 0.0:
            raise ValueError(f"units[{i}].valve_weight must be >= 0")
        if cap <= 0.0:
            raise ValueError(f"units[{i}].max_flow_kg_s must be positive")
        ids.append(uid)
        tdisch.append(require_finite(f"units[{i}].tdisch_c", u["tdisch_c"]))
        fluid_in.append(require_finite(f"units[{i}].fluid_in_c", u["fluid_in_c"]))
        weights.append(w)
        caps.append(cap)
        model_ids.append(mid)

    matrix = s["recirc_matrix"]
    if not isinstance(matrix, list) or len(matrix) != n:
        raise ValueError("recirc_matrix must be square matching units length")
    rows: list[list[float]] = []
    for i, row in enumerate(matrix):
        if not isinstance(row, list) or len(row) != n:
            raise ValueError(f"recirc_matrix[{i}] length mismatch")
        vals = [require_finite(f"recirc_matrix[{i}][{j}]", row[j]) for j in range(n)]
        if any(v < 0.0 for v in vals):
            raise ValueError(f"recirc_matrix[{i}] has negative entry")
        row_sum = sum(vals)
        if not (row_sum < 1.0 - 1e-12):
            raise ValueError(f"recirc_matrix[{i}] row sum must be strictly < 1")
        rows.append(vals)

    flows = allocate_flows(total, weights, caps)

    unit_out = []
    q_site = 0.0
    for i in range(n):
        row_sum = sum(rows[i])
        t_eff = (1.0 - row_sum) * tamb + sum(rows[i][j] * tdisch[j] for j in range(n))
        dT = fluid_in[i] - t_eff - approach
        if dT <= 0.0:
            raise ValueError(f"unit {ids[i]} non-positive available temperature difference")
        q_gly = flows[i] * cp * dT / 1000.0
        q_curve = interpolate_capacity(models[model_ids[i]], t_eff)
        q_avail = min(q_gly, q_curve)
        if not all(math.isfinite(x) for x in (t_eff, flows[i], q_avail)):
            raise ValueError(f"unit {ids[i]} produced non-finite output")
        q_site += q_avail
        unit_out.append(
            {
                "id": ids[i],
                "t_air_eff_c": round(t_eff, 2),
                "flow_kg_s": round(flows[i], 2),
                "q_avail_kw": round(q_avail, 2),
            }
        )

    if not math.isfinite(q_site):
        raise ValueError("q_site_kw not finite")
    return {"q_site_kw": round(q_site, 2), "units": unit_out}


def main() -> None:
    try:
        out = compute(load_json(SENSORS), load_json(NAMEPLATE))
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(out, ensure_ascii=False, allow_nan=False))


if __name__ == "__main__":
    main()
