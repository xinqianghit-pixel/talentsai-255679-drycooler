#!/usr/bin/env python3
"""Reference fix: multi-unit dry-cooler with cross-recirc matrix + shared pump/branch hydraulic root."""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path


SENSORS = Path("/app/yard_sensors.json")
NAMEPLATE = Path("/app/nameplate.json")
FLOW_TOL = 1e-9
MAX_FLOW_ITERS = 160
MAX_COUPLED_ITERS = 200
COUPLED_TOL = 1e-8
COUPLED_DAMPING = 0.5


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
    zero_head_flow: float,
    shutoff_head: float,
    openings: list[float],
    resistances: list[float],
    caps: list[float],
) -> list[float]:
    """Solve common head H = H0*(1-(sum(q_i)/Q0)^2) by bisection.

    Each branch has q_i(H)=min(cap_i, opening_i*sqrt(H/K_i)).
    The residual is strictly increasing on [0,H0], hence the root is unique.
    """
    if zero_head_flow <= 0.0 or shutoff_head <= 0.0:
        raise ValueError("pump parameters must be positive")

    def branch_flows(head: float) -> list[float]:
        return [
            0.0 if openings[i] == 0.0 else min(caps[i], openings[i] * math.sqrt(head / resistances[i]))
            for i in range(len(openings))
        ]

    def residual(head: float) -> float:
        q_total = sum(branch_flows(head))
        return head - shutoff_head * (1.0 - (q_total / zero_head_flow) ** 2)

    lo, hi = 0.0, shutoff_head
    if residual(lo) > 0.0 or residual(hi) < 0.0:
        raise ValueError("pump/branch root is not bracketed")
    for _ in range(MAX_FLOW_ITERS):
        mid = (lo + hi) / 2.0
        if residual(mid) > 0.0:
            hi = mid
        else:
            lo = mid
        if hi - lo <= FLOW_TOL:
            break
    else:
        raise ValueError("pump/branch root did not converge")
    out = branch_flows((lo + hi) / 2.0)
    if not all(math.isfinite(q) and 0.0 <= q <= caps[i] + 1e-8 for i, q in enumerate(out)):
        raise ValueError("invalid branch flow")
    return out


def estimate_plume_gain(raw: object, rows: list[list[float]]) -> float:
    """Scalar least-squares fit: observed-tamb = gain * sum_j r_ij*(tdisch_j-tamb)."""
    n = len(rows)
    if not isinstance(raw, list) or len(raw) < 2:
        raise ValueError("plume_calibration must contain at least 2 samples")
    sum_xx = 0.0
    sum_xy = 0.0
    for k, sample in enumerate(raw):
        if not isinstance(sample, dict):
            raise ValueError(f"plume_calibration[{k}] must be object")
        for field in ("ambient_c", "discharge_c", "observed_inlet_c"):
            if field not in sample:
                raise ValueError(f"plume_calibration[{k}] missing {field}")
        ambient = require_finite(f"plume_calibration[{k}].ambient_c", sample["ambient_c"])
        discharge = sample["discharge_c"]
        observed = sample["observed_inlet_c"]
        if not isinstance(discharge, list) or not isinstance(observed, list) or len(discharge) != n or len(observed) != n:
            raise ValueError(f"plume_calibration[{k}] vector length mismatch")
        discharge = [require_finite(f"plume_calibration[{k}].discharge_c[{j}]", v) for j, v in enumerate(discharge)]
        observed = [require_finite(f"plume_calibration[{k}].observed_inlet_c[{i}]", v) for i, v in enumerate(observed)]
        for i, row in enumerate(rows):
            x = sum(row[j] * (discharge[j] - ambient) for j in range(n))
            y = observed[i] - ambient
            sum_xx += x * x
            sum_xy += x * y
    if not math.isfinite(sum_xx) or sum_xx <= 1e-12:
        raise ValueError("plume calibration is rank deficient")
    gain = sum_xy / sum_xx
    if not math.isfinite(gain) or gain <= 0.0:
        raise ValueError("estimated plume gain must be positive")
    return gain


def compute(s: dict, np: dict) -> dict:
    for key in ("tamb_c", "glycol_total_kg_s", "pump_shutoff_head_kpa", "cp_j_per_kg_k", "air_cp_j_per_kg_k", "recirc_matrix", "plume_calibration", "units"):
        if key not in s:
            raise ValueError(f"missing sensor field: {key}")
    if "design_approach_k" not in np or "models" not in np:
        raise ValueError("missing nameplate field")

    tamb = require_finite("tamb_c", s["tamb_c"])
    total = require_finite("glycol_total_kg_s", s["glycol_total_kg_s"])
    shutoff_head = require_finite("pump_shutoff_head_kpa", s["pump_shutoff_head_kpa"])
    cp = require_finite("cp_j_per_kg_k", s["cp_j_per_kg_k"])
    air_cp = require_finite("air_cp_j_per_kg_k", s["air_cp_j_per_kg_k"])
    approach = require_finite("design_approach_k", np["design_approach_k"])
    if total <= 0.0:
        raise ValueError("glycol_total_kg_s must be positive")
    if shutoff_head <= 0.0:
        raise ValueError("pump_shutoff_head_kpa must be positive")
    if cp <= 0.0:
        raise ValueError("cp_j_per_kg_k must be positive")
    if air_cp <= 0.0:
        raise ValueError("air_cp_j_per_kg_k must be positive")

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
    resistances: list[float] = []
    air_flows: list[float] = []
    seen: set[str] = set()
    for i, u in enumerate(units_raw):
        if not isinstance(u, dict):
            raise ValueError(f"units[{i}] must be object")
        for k in ("id", "tdisch_c", "air_mass_flow_kg_s", "fluid_in_c", "valve_weight", "max_flow_kg_s", "branch_resistance_kpa_per_kg_s2", "model_id"):
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
        resistance = require_finite(f"units[{i}].branch_resistance_kpa_per_kg_s2", u["branch_resistance_kpa_per_kg_s2"])
        if w < 0.0:
            raise ValueError(f"units[{i}].valve_weight must be >= 0")
        if resistance <= 0.0:
            raise ValueError(f"units[{i}].branch_resistance_kpa_per_kg_s2 must be positive")
        if cap <= 0.0:
            raise ValueError(f"units[{i}].max_flow_kg_s must be positive")
        ids.append(uid)
        tdisch.append(require_finite(f"units[{i}].tdisch_c", u["tdisch_c"]))
        fluid_in.append(require_finite(f"units[{i}].fluid_in_c", u["fluid_in_c"]))
        weights.append(w)
        caps.append(cap)
        model_ids.append(mid)
        resistances.append(resistance)
        air_flow = require_finite(f"units[{i}].air_mass_flow_kg_s", u["air_mass_flow_kg_s"])
        if air_flow <= 0.0:
            raise ValueError(f"units[{i}].air_mass_flow_kg_s must be positive")
        air_flows.append(air_flow)

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

    plume_gain = estimate_plume_gain(s["plume_calibration"], rows)
    if any(plume_gain * sum(row) >= 1.0 - 1e-12 for row in rows):
        raise ValueError("estimated plume gain makes effective recirculation row sum >= 1")

    flows = allocate_flows(total, shutoff_head, weights, resistances, caps)

    # Shot A: discharge temperatures are coupled to rejected heat.  The measured
    # values are only the initial iterate; solve the plume/heat balance to a fixed point.
    discharge = list(tdisch)
    for _ in range(MAX_COUPLED_ITERS):
        t_eff_all = []
        q_all = []
        target_discharge = []
        for i in range(n):
            effective_row = [plume_gain * value for value in rows[i]]
            row_sum = sum(effective_row)
            t_eff = (1.0 - row_sum) * tamb + sum(effective_row[j] * discharge[j] for j in range(n))
            dT = fluid_in[i] - t_eff - approach
            if dT <= 0.0:
                raise ValueError(f"unit {ids[i]} non-positive available temperature difference")
            q_gly = flows[i] * cp * dT / 1000.0
            q_curve = interpolate_capacity(models[model_ids[i]], t_eff)
            q_avail = min(q_gly, q_curve)
            t_eff_all.append(t_eff)
            q_all.append(q_avail)
            target_discharge.append(t_eff + q_avail * 1000.0 / (air_flows[i] * air_cp))
        updated = [COUPLED_DAMPING * target_discharge[i] + (1.0 - COUPLED_DAMPING) * discharge[i] for i in range(n)]
        if max(abs(updated[i] - discharge[i]) for i in range(n)) <= COUPLED_TOL:
            discharge = updated
            break
        discharge = updated
    else:
        raise ValueError("coupled plume balance did not converge")

    unit_out = []
    q_site = 0.0
    for i in range(n):
        t_eff = t_eff_all[i]
        q_avail = q_all[i]
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
