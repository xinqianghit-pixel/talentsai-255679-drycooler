#!/bin/bash
# Harbor verifier: multi-unit dry-cooler cross-recirc + shared pump/branch hydraulic root
REWARD_FILE="/logs/verifier/reward.json"
mkdir -p /logs/verifier
echo '{"reward": 0}' > "$REWARD_FILE"

python3 << 'PYEOF'
import copy
import json
import math
import os
import subprocess
from pathlib import Path

REWARD_FILE = "/logs/verifier/reward.json"
DATA_PATH = Path("/app/yard_sensors.json")
SPEC_PATH = Path("/app/nameplate.json")
SRC_PATH = Path("/app/dry_cooler_cap.py")
TOLERANCE = 0.001
FLOW_TOL = 1e-9
MAX_FLOW_ITERS = 64
MAX_COUPLED_ITERS = 200
COUPLED_TOL = 1e-8
COUPLED_DAMPING = 0.5


def write_reward(value: float) -> None:
    try:
        os.chmod(REWARD_FILE, 0o644)
    except OSError:
        pass
    with open(REWARD_FILE, "w", encoding="utf-8") as f:
        json.dump({"reward": value}, f)
    try:
        os.chmod(REWARD_FILE, 0o444)
    except OSError:
        pass
    print(f"reward = {value}")


def load_json(path: Path) -> dict:
    text = path.read_text(encoding="utf-8").strip()
    obj, _ = json.JSONDecoder().raw_decode(text)
    return obj


def is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def parse_capacity_curve(raw) -> list:
    points = [(float(p["t_air_eff_c"]), float(p["q_cap_kw"])) for p in raw]
    for i in range(1, len(points)):
        if not (points[i][0] > points[i - 1][0]):
            raise ValueError("curve not increasing")
    return points


def interpolate_capacity(points, t_eff: float) -> float:
    if t_eff <= points[0][0]:
        return points[0][1]
    if t_eff >= points[-1][0]:
        return points[-1][1]
    for (t0, q0), (t1, q1) in zip(points, points[1:]):
        if t0 <= t_eff <= t1:
            w = (t_eff - t0) / (t1 - t0)
            return q0 + w * (q1 - q0)
    raise ValueError("interp fail")


def allocate_flows(zero_head_flow, shutoff_head, openings, resistances, caps):
    def flows_at(h):
        return [0.0 if openings[i] == 0.0 else min(caps[i], openings[i] * math.sqrt(h / resistances[i])) for i in range(len(openings))]
    def f(h):
        q = sum(flows_at(h))
        return h - shutoff_head * (1.0 - (q / zero_head_flow) ** 2)
    lo, hi = 0.0, shutoff_head
    for _ in range(200):
        mid = (lo + hi) * 0.5
        if f(mid) < 0.0:
            lo = mid
        else:
            hi = mid
    return flows_at((lo + hi) * 0.5)


def estimate_gain(calibration, matrix):
    n = len(matrix)
    xx = 0.0
    xy = 0.0
    for sample in calibration:
        ambient = float(sample["ambient_c"])
        discharge = [float(v) for v in sample["discharge_c"]]
        observed = [float(v) for v in sample["observed_inlet_c"]]
        for i in range(n):
            x = sum(float(matrix[i][j]) * (discharge[j] - ambient) for j in range(n))
            xx += x * x
            xy += x * (observed[i] - ambient)
    if xx <= 1e-12:
        raise ValueError("rank deficient calibration")
    return xy / xx


def expected_from(s: dict, np: dict) -> dict:
    tamb = float(s["tamb_c"])
    total = float(s["glycol_total_kg_s"])
    shutoff_head = float(s["pump_shutoff_head_kpa"])
    cp = float(s["cp_j_per_kg_k"])
    air_cp = float(s["air_cp_j_per_kg_k"])
    approach = float(np["design_approach_k"])
    models = {
        mid: parse_capacity_curve(m["capacity_curve"]) for mid, m in np["models"].items()
    }
    units = s["units"]
    n = len(units)
    matrix = s["recirc_matrix"]
    tdisch = [float(u["tdisch_c"]) for u in units]
    plume_gain = estimate_gain(s["plume_calibration"], matrix)
    fluid_in = [float(u["fluid_in_c"]) for u in units]
    weights = [float(u["valve_weight"]) for u in units]
    caps = [float(u["max_flow_kg_s"]) for u in units]
    resistances = [float(u["branch_resistance_kpa_per_kg_s2"]) for u in units]
    flows = allocate_flows(total, shutoff_head, weights, resistances, caps)
    air_flows = [float(u["air_mass_flow_kg_s"]) for u in units]
    discharge = list(tdisch)
    for _ in range(MAX_COUPLED_ITERS):
        t_eff_all, q_all, target = [], [], []
        for i, u in enumerate(units):
            row = [plume_gain * float(x) for x in matrix[i]]
            t_eff = (1.0 - sum(row)) * tamb + sum(row[j] * discharge[j] for j in range(n))
            dT = fluid_in[i] - t_eff - approach
            q_gly = flows[i] * cp * dT / 1000.0
            q_curve = interpolate_capacity(models[u["model_id"]], t_eff)
            q = min(q_gly, q_curve)
            t_eff_all.append(t_eff)
            q_all.append(q)
            target.append(t_eff + q * 1000.0 / (air_flows[i] * air_cp))
        updated = [COUPLED_DAMPING * target[i] + (1.0 - COUPLED_DAMPING) * discharge[i] for i in range(n)]
        if max(abs(updated[i] - discharge[i]) for i in range(n)) <= COUPLED_TOL:
            discharge = updated
            break
        discharge = updated
    else:
        raise ValueError("coupled plume balance did not converge")
    out_units = []
    q_site = 0.0
    for i, u in enumerate(units):
        t_eff, q_avail = t_eff_all[i], q_all[i]
        q_site += q_avail
        out_units.append({"id": u["id"], "t_air_eff_c": round(t_eff, 2), "flow_kg_s": round(flows[i], 2), "q_avail_kw": round(q_avail, 2)})
    return {"q_site_kw": round(q_site, 2), "units": out_units}


def close_num(a, b) -> bool:
    if not is_number(a) or not is_number(b):
        return False
    av, bv = float(a), float(b)
    if not math.isfinite(av) or not math.isfinite(bv):
        return False
    return abs(av - bv) <= max(TOLERANCE * max(abs(bv), 1.0), 1e-6)


def close(a: dict, b: dict) -> bool:
    try:
        if not close_num(a.get("q_site_kw"), b.get("q_site_kw")):
            return False
        ua, ub = a.get("units"), b.get("units")
        if not isinstance(ua, list) or not isinstance(ub, list) or len(ua) != len(ub):
            return False
        for x, y in zip(ua, ub):
            if x.get("id") != y.get("id"):
                return False
            for k in ("t_air_eff_c", "flow_kg_s", "q_avail_kw"):
                if not close_num(x.get(k), y.get(k)):
                    return False
        return True
    except Exception:
        return False


def parse_success_output(stdout: str):
    lines = stdout.splitlines()
    if len(lines) != 1:
        return None
    obj = json.loads(lines[0])
    if not isinstance(obj, dict) or "q_site_kw" not in obj or "units" not in obj:
        return None
    if not is_number(obj["q_site_kw"]) or not math.isfinite(float(obj["q_site_kw"])):
        return None
    if not isinstance(obj["units"], list):
        return None
    for u in obj["units"]:
        if not isinstance(u, dict) or "id" not in u:
            return None
        for k in ("t_air_eff_c", "flow_kg_s", "q_avail_kw"):
            if k not in u or not is_number(u[k]) or not math.isfinite(float(u[k])):
                return None
    return obj


def run_raw(timeout: float = 30):
    try:
        return subprocess.run(
            ["python3", "/app/dry_cooler_cap.py"],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return None


def run_program():
    run = run_raw()
    if run is None:
        print("FAIL: program timed out")
        return None
    if run.returncode != 0:
        print("FAIL: program crashed")
        print(run.stderr[:400])
        return None
    try:
        obj = parse_success_output(run.stdout)
    except Exception as exc:
        print(f"FAIL: bad json ({exc})")
        return None
    if obj is None:
        print("FAIL: stdout must be exactly one JSON object line")
        print(run.stdout[:200])
        return None
    return obj


def expect_reject(label: str, timeout: float = 10) -> bool:
    run = run_raw(timeout=timeout)
    if run is None:
        print(f"FAIL [{label}]: timed out")
        return False
    if run.returncode == 0:
        print(f"FAIL [{label}]: expected non-zero exit")
        return False
    if not (run.stderr or "").strip():
        print(f"FAIL [{label}]: expected stderr")
        return False
    print(f"PASS [{label}]")
    return True


def backup():
    return DATA_PATH.read_text(encoding="utf-8"), SPEC_PATH.read_text(encoding="utf-8")


def restore(data_txt, spec_txt):
    DATA_PATH.write_text(data_txt, encoding="utf-8")
    SPEC_PATH.write_text(spec_txt, encoding="utf-8")


def mutate_and_check(mutator, label: str) -> bool:
    data_txt, spec_txt = backup()
    try:
        s, np = load_json(DATA_PATH), load_json(SPEC_PATH)
        s2, np2 = mutator(copy.deepcopy(s), copy.deepcopy(np))
        DATA_PATH.write_text(json.dumps(s2, ensure_ascii=False, indent=2), encoding="utf-8")
        SPEC_PATH.write_text(json.dumps(np2, ensure_ascii=False, indent=2), encoding="utf-8")
        got = run_program()
        if got is None:
            print(f"FAIL [{label}]: no output")
            return False
        exp = expected_from(s2, np2)
        if not close(got, exp):
            print(f"FAIL [{label}]: expected {exp}, got {got}")
            return False
        print(f"PASS [{label}]")
        return True
    finally:
        restore(data_txt, spec_txt)


def mutate_and_reject(mutator, label: str) -> bool:
    data_txt, spec_txt = backup()
    try:
        s, np = load_json(DATA_PATH), load_json(SPEC_PATH)
        s2, np2 = mutator(copy.deepcopy(s), copy.deepcopy(np))
        DATA_PATH.write_text(json.dumps(s2, ensure_ascii=False, indent=2), encoding="utf-8")
        SPEC_PATH.write_text(json.dumps(np2, ensure_ascii=False, indent=2), encoding="utf-8")
        return expect_reject(label)
    finally:
        restore(data_txt, spec_txt)


all_ok = True
try:
    s0 = load_json(DATA_PATH)
    np0 = load_json(SPEC_PATH)
    exp0 = expected_from(s0, np0)
    got0 = run_program()
    if got0 is None or not close(got0, exp0):
        print(f"FAIL [A baseline]: expected {exp0}, got {got0}")
        all_ok = False
    else:
        print("PASS [A baseline]")

    # Wrong paths that ignore matrix / hydraulics / curve
    if got0 is not None:
        wrong_equal = copy.deepcopy(exp0)
        n = len(s0["units"])
        share = float(s0["glycol_total_kg_s"]) / n
        for u in wrong_equal["units"]:
            u["flow_kg_s"] = round(share, 2)
        if close(got0, wrong_equal) and not close(wrong_equal, exp0):
            print("FAIL: matches equal-split flow path")
            all_ok = False

    # Matrix direction: transpose must change answer
    def mut_transpose(s, np):
        m = s["recirc_matrix"]
        s["recirc_matrix"] = [[m[j][i] for j in range(len(m))] for i in range(len(m))]
        # keep row sums < 1 by scaling if needed
        for i, row in enumerate(s["recirc_matrix"]):
            rs = sum(row)
            if rs >= 1.0:
                s["recirc_matrix"][i] = [x * 0.4 for x in row]
        return s, np

    if not mutate_and_check(mut_transpose, "B matrix transpose"):
        all_ok = False

    # Hydraulic cap: tighten B cap so the common-head root redistributes flow
    if not mutate_and_check(
        lambda s, np: (
            s
            | {
                "units": [
                    u | ({"max_flow_kg_s": 10.0} if u["id"] == "B" else {})
                    for u in s["units"]
                ]
            },
            np,
        ),
        "C hydraulic cap retighten B",
    ):
        all_ok = False

    if not mutate_and_check(lambda s, np: (s | {"pump_shutoff_head_kpa": 125.0}, np), "C2 pump head"):
        all_ok = False
    if not mutate_and_check(
        lambda s, np: (s | {"units": [u | ({"branch_resistance_kpa_per_kg_s2": 0.75} if u["id"] == "C" else {}) for u in s["units"]]}, np),
        "C3 branch resistance C",
    ):
        all_ok = False

    # Model swap on unit A
    if not mutate_and_check(
        lambda s, np: (
            s
            | {
                "units": [
                    u | ({"model_id": "DC-Y300"} if u["id"] == "A" else {})
                    for u in s["units"]
                ]
            },
            np,
        ),
        "D swap model A",
    ):
        all_ok = False

    # Independent field tracking
    if not mutate_and_check(lambda s, np: (s | {"tamb_c": 30.0}, np), "E tamb"):
        all_ok = False
    if not mutate_and_check(
        lambda s, np: (
            s
            | {
                "units": [
                    u | ({"tdisch_c": 45.0} if u["id"] == "A" else {}) for u in s["units"]
                ]
            },
            np,
        ),
        "F one discharge",
    ):
        all_ok = False
    if not mutate_and_check(
        lambda s, np: (
            s
            | {
                "units": [
                    u | ({"valve_weight": 2.0} if u["id"] == "C" else {}) for u in s["units"]
                ]
            },
            np,
        ),
        "G valve weight",
    ):
        all_ok = False
    if not mutate_and_check(lambda s, np: (s | {"glycol_total_kg_s": 50.0}, np), "H total flow"):
        all_ok = False
    if not mutate_and_check(lambda s, np: (s, np | {"design_approach_k": 6.0}), "I approach"):
        all_ok = False

    # Curve derate on one model
    def mut_curve(s, np):
        np = copy.deepcopy(np)
        np["models"]["DC-Y300"]["capacity_curve"] = [
            {"t_air_eff_c": 25.0, "q_cap_kw": 200.0},
            {"t_air_eff_c": 40.0, "q_cap_kw": 120.0},
        ]
        return s, np

    if not mutate_and_check(mut_curve, "J curve derate Y"):
        all_ok = False

    # Left clamp: force very low t_eff via low tamb + zero matrix
    def mut_left_clamp(s, np):
        n = len(s["units"])
        s = s | {"tamb_c": 20.0, "recirc_matrix": [[1e-6 * float(v) for v in row] for row in s["recirc_matrix"]]}
        return s, np

    if not mutate_and_check(mut_left_clamp, "K curve left clamp"):
        all_ok = False

    # Right clamp: force every effective inlet above the last curve point.
    # This separates endpoint clamping from a tempting linear extrapolation.
    def mut_right_clamp(s, np):
        n = len(s["units"])
        s = copy.deepcopy(s)
        s["tamb_c"] = 45.0
        s["recirc_matrix"] = [[1e-6 * float(v) for v in row] for row in s["recirc_matrix"]]
        for u in s["units"]:
            u["fluid_in_c"] = 55.0
        return s, np

    if not mutate_and_check(mut_right_clamp, "K2 curve right clamp"):
        all_ok = False

    # Distractors changed must not affect
    if not mutate_and_check(
        lambda s, np: (
            s
            | {
                "units": [
                    u | {"twb_c": 1.0, "bms_duty_kw": 1.0, "fluid_out_c": 0.0} for u in s["units"]
                ]
            },
            np,
        ),
        "L distractors",
    ):
        all_ok = False

    # Calibration observations drive the inferred plume gain.
    def mut_calibration_gain(s, np):
        s = copy.deepcopy(s)
        for sample in s["plume_calibration"]:
            ambient = sample["ambient_c"]
            sample["observed_inlet_c"] = [ambient + 0.72 * (value - ambient) / 1.15 for value in sample["observed_inlet_c"]]
        return s, np

    if not mutate_and_check(mut_calibration_gain, "M inferred plume gain"):
        all_ok = False

    # Rejects
    if not mutate_and_reject(lambda s, np: (s | {"glycol_total_kg_s": 0.0}, np), "R zero total"):
        all_ok = False
    if not mutate_and_reject(lambda s, np: (s | {"cp_j_per_kg_k": -1.0}, np), "R2 neg cp"):
        all_ok = False

    def mut_bad_resistance(s, np):
        s = copy.deepcopy(s)
        s["units"][0]["branch_resistance_kpa_per_kg_s2"] = 0.0
        return s, np

    if not mutate_and_reject(mut_bad_resistance, "R2b zero branch resistance"):
        all_ok = False

    def mut_rank_deficient_calibration(s, np):
        s = copy.deepcopy(s)
        for sample in s["plume_calibration"]:
            ambient = sample["ambient_c"]
            sample["discharge_c"] = [ambient] * len(s["units"])
            sample["observed_inlet_c"] = [ambient] * len(s["units"])
        return s, np

    if not mutate_and_reject(mut_rank_deficient_calibration, "R2c rank deficient calibration"):
        all_ok = False

    def mut_row_sum(s, np):
        s = copy.deepcopy(s)
        s["recirc_matrix"][0] = [0.5, 0.5, 0.1]
        return s, np

    if not mutate_and_reject(mut_row_sum, "R3 row sum >=1"):
        all_ok = False

    def mut_neg_matrix(s, np):
        s = copy.deepcopy(s)
        s["recirc_matrix"][1][0] = -0.1
        return s, np

    if not mutate_and_reject(mut_neg_matrix, "R4 neg matrix"):
        all_ok = False

    def mut_dup_id(s, np):
        s = copy.deepcopy(s)
        s["units"][1]["id"] = s["units"][0]["id"]
        return s, np

    if not mutate_and_reject(mut_dup_id, "R5 dup id"):
        all_ok = False

    def mut_bad_model(s, np):
        s = copy.deepcopy(s)
        s["units"][0]["model_id"] = "NOPE"
        return s, np

    if not mutate_and_reject(mut_bad_model, "R6 unknown model"):
        all_ok = False

    def mut_non_square(s, np):
        s = copy.deepcopy(s)
        s["recirc_matrix"] = s["recirc_matrix"][:2]
        return s, np

    if not mutate_and_reject(mut_non_square, "R7 non square"):
        all_ok = False

    def mut_dT0(s, np):
        s = copy.deepcopy(s)
        n = len(s["units"])
        s["tamb_c"] = 40.0
        s["recirc_matrix"] = [[0.0] * n for _ in range(n)]
        for u in s["units"]:
            u["fluid_in_c"] = 45.0
        return s, np | {"design_approach_k": 5.0}

    if not mutate_and_reject(mut_dT0, "R8 dT==0"):
        all_ok = False

    def mut_curve_one(s, np):
        np = copy.deepcopy(np)
        np["models"]["DC-X480"]["capacity_curve"] = [{"t_air_eff_c": 30.0, "q_cap_kw": 400.0}]
        return s, np

    if not mutate_and_reject(mut_curve_one, "R9 curve <2"):
        all_ok = False

    for key in ("tamb_c", "glycol_total_kg_s", "pump_shutoff_head_kpa", "cp_j_per_kg_k", "air_cp_j_per_kg_k"):
        for kind, value in (("NaN", float("nan")), ("bool", True), ("null", None), ("str", "1.0")):
            def mut(s, np, key=key, value=value):
                s = copy.deepcopy(s)
                s[key] = value
                return s, np

            if not mutate_and_reject(mut, f"T {key} {kind}"):
                all_ok = False

    write_reward(1.0 if all_ok else 0.0)
except Exception as exc:
    print(f"FAIL: verifier exception {exc}")
    write_reward(0.0)
PYEOF
