#!/bin/bash
# Harbor verifier for dry-cooler recirculation capacity
REWARD_FILE="/logs/verifier/reward.json"
mkdir -p /logs/verifier
echo '{"reward": 0}' > "$REWARD_FILE"

python3 << 'PYEOF'
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
REQUIRED_SENSOR = (
    "recirc_ratio",
    "tamb_c",
    "tdisch_c",
    "fluid_in_c",
    "glycol_kg_s",
    "cp_j_per_kg_k",
)
REQUIRED_SPEC = ("design_approach_k", "capacity_curve")


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


def parse_capacity_curve(raw) -> list:
    if not isinstance(raw, list) or len(raw) < 2:
        raise ValueError("bad capacity_curve")
    points = []
    for item in raw:
        points.append((float(item["t_air_eff_c"]), float(item["q_cap_kw"])))
    for i in range(1, len(points)):
        if not (points[i][0] > points[i - 1][0]):
            raise ValueError("capacity_curve not strictly increasing")
    return points


def interpolate_capacity(points: list, t_eff: float) -> float:
    if t_eff <= points[0][0]:
        return points[0][1]
    if t_eff >= points[-1][0]:
        return points[-1][1]
    for (t0, q0), (t1, q1) in zip(points, points[1:]):
        if t0 <= t_eff <= t1:
            w = (t_eff - t0) / (t1 - t0)
            return q0 + w * (q1 - q0)
    raise ValueError("interpolate failed")


def expected_from(s: dict, np: dict) -> dict:
    r = float(s["recirc_ratio"])
    t_eff = (1.0 - r) * float(s["tamb_c"]) + r * float(s["tdisch_c"])
    dT = float(s["fluid_in_c"]) - t_eff - float(np["design_approach_k"])
    q_gly = float(s["glycol_kg_s"]) * float(s["cp_j_per_kg_k"]) * dT / 1000.0
    q_curve = interpolate_capacity(parse_capacity_curve(np["capacity_curve"]), t_eff)
    q_kw = min(q_gly, q_curve)
    return {"t_air_eff_c": round(t_eff, 2), "q_avail_kw": round(q_kw, 2)}


def wrong_wetbulb(s: dict, np: dict) -> dict:
    t_air = float(s["twb_c"])
    dT = float(s["fluid_in_c"]) - t_air - float(np["design_approach_k"])
    q_kw = float(s["glycol_kg_s"]) * float(s["cp_j_per_kg_k"]) * dT / 1000.0
    return {"t_air_eff_c": round(t_air, 2), "q_avail_kw": round(q_kw, 2)}


def wrong_ambient_only(s: dict, np: dict) -> dict:
    t_air = float(s["tamb_c"])
    dT = float(s["fluid_in_c"]) - t_air - float(np["design_approach_k"])
    q_kw = float(s["glycol_kg_s"]) * float(s["cp_j_per_kg_k"]) * dT / 1000.0
    return {"t_air_eff_c": round(t_air, 2), "q_avail_kw": round(q_kw, 2)}


def wrong_bms(s: dict, np: dict) -> dict:
    r = float(s["recirc_ratio"])
    t_eff = (1.0 - r) * float(s["tamb_c"]) + r * float(s["tdisch_c"])
    return {"t_air_eff_c": round(t_eff, 2), "q_avail_kw": round(float(s["bms_duty_kw"]), 2)}


def wrong_buggy_baseline(s: dict, np: dict) -> dict:
    t_air = float(s["twb_c"])
    return {"t_air_eff_c": round(t_air, 2), "q_avail_kw": round(float(s["bms_duty_kw"]), 2)}


def wrong_glycol_only(s: dict, np: dict) -> dict:
    """Pre-P1 formula: mix + glycol sensible, ignore capacity_curve."""
    r = float(s["recirc_ratio"])
    t_eff = (1.0 - r) * float(s["tamb_c"]) + r * float(s["tdisch_c"])
    dT = float(s["fluid_in_c"]) - t_eff - float(np["design_approach_k"])
    q_kw = float(s["glycol_kg_s"]) * float(s["cp_j_per_kg_k"]) * dT / 1000.0
    return {"t_air_eff_c": round(t_eff, 2), "q_avail_kw": round(q_kw, 2)}


def wrong_curve_only(s: dict, np: dict) -> dict:
    r = float(s["recirc_ratio"])
    t_eff = (1.0 - r) * float(s["tamb_c"]) + r * float(s["tdisch_c"])
    q_kw = interpolate_capacity(parse_capacity_curve(np["capacity_curve"]), t_eff)
    return {"t_air_eff_c": round(t_eff, 2), "q_avail_kw": round(q_kw, 2)}


def wrong_design_cap(s: dict, np: dict) -> dict:
    r = float(s["recirc_ratio"])
    t_eff = (1.0 - r) * float(s["tamb_c"]) + r * float(s["tdisch_c"])
    return {"t_air_eff_c": round(t_eff, 2), "q_avail_kw": round(float(np["design_capacity_kw"]), 2)}


def is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def close(a: dict, b: dict) -> bool:
    try:
        for k in ("t_air_eff_c", "q_avail_kw"):
            if k not in a or k not in b:
                return False
            if not is_number(a[k]) or not is_number(b[k]):
                return False
            av = float(a[k])
            bv = float(b[k])
            if not math.isfinite(av) or not math.isfinite(bv):
                return False
            if abs(av - bv) > max(TOLERANCE * max(abs(bv), 1.0), 1e-6):
                return False
        return True
    except Exception:
        return False


def parse_success_output(stdout: str):
    lines = stdout.splitlines()
    if len(lines) != 1:
        return None
    obj = json.loads(lines[0])
    if not isinstance(obj, dict):
        return None
    for k in ("t_air_eff_c", "q_avail_kw"):
        if k not in obj or not is_number(obj[k]) or not math.isfinite(float(obj[k])):
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
        print(run.stdout[:200])
        return None
    if obj is None:
        print("FAIL: stdout must be exactly one JSON object line with finite numbers")
        print(run.stdout[:200])
        return None
    return obj


def expect_reject(label: str, timeout: float = 10) -> bool:
    run = run_raw(timeout=timeout)
    if run is None:
        print(f"FAIL [{label}]: timed out (timeout is not accept)")
        return False
    if run.returncode == 0:
        print(f"FAIL [{label}]: expected non-zero exit, got 0; stdout={run.stdout[:120]!r}")
        return False
    if not (run.stderr or "").strip():
        print(f"FAIL [{label}]: expected stderr error message")
        return False
    print(f"PASS [{label}]")
    return True


def backup() -> tuple:
    return DATA_PATH.read_text(encoding="utf-8"), SPEC_PATH.read_text(encoding="utf-8")


def restore(data_txt: str, spec_txt: str) -> None:
    DATA_PATH.write_text(data_txt, encoding="utf-8")
    SPEC_PATH.write_text(spec_txt, encoding="utf-8")


def mutate_and_check(mutator, label: str) -> bool:
    data_txt, spec_txt = backup()
    try:
        s = load_json(DATA_PATH)
        np = load_json(SPEC_PATH)
        s2, np2 = mutator(dict(s), dict(np))
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
        s = load_json(DATA_PATH)
        np = load_json(SPEC_PATH)
        s2, np2 = mutator(dict(s), dict(np))
        DATA_PATH.write_text(json.dumps(s2, ensure_ascii=False, indent=2), encoding="utf-8")
        SPEC_PATH.write_text(json.dumps(np2, ensure_ascii=False, indent=2), encoding="utf-8")
        return expect_reject(label)
    finally:
        restore(data_txt, spec_txt)


all_ok = True
try:
    # Case A: baseline
    s0 = load_json(DATA_PATH)
    np0 = load_json(SPEC_PATH)
    exp0 = expected_from(s0, np0)
    got0 = run_program()
    if got0 is None or not close(got0, exp0):
        print(f"FAIL [A baseline]: expected {exp0}, got {got0}")
        all_ok = False
    else:
        print("PASS [A baseline]")

    if got0 is not None:
        for name, fn in [
            ("wetbulb", wrong_wetbulb),
            ("ambient", wrong_ambient_only),
            ("bms", wrong_bms),
            ("baseline-bug", wrong_buggy_baseline),
            ("glycol-only", wrong_glycol_only),
            ("curve-only", wrong_curve_only),
            ("design-cap", wrong_design_cap),
        ]:
            w = fn(s0, np0)
            if close(got0, w) and not close(w, exp0):
                print(f"FAIL: output matches wrong_{name} {w}")
                all_ok = False

    # Case B-E: independent / combined mutations that must track
    if not mutate_and_check(lambda s, np: (s | {"recirc_ratio": 0.45}, np), "B recirc"):
        all_ok = False
    if not mutate_and_check(lambda s, np: (s, np | {"design_approach_k": 6.5}), "C approach"):
        all_ok = False
    def mut_flow_glycol_limited(s, np):
        # Ensure glycol path is active so flow tracking is observable under min().
        curve = [
            {"t_air_eff_c": 20.0, "q_cap_kw": 900.0},
            {"t_air_eff_c": 45.0, "q_cap_kw": 800.0},
        ]
        return s | {"glycol_kg_s": float(s["glycol_kg_s"]) * 1.15}, np | {"capacity_curve": curve}

    if not mutate_and_check(mut_flow_glycol_limited, "D flow"):
        all_ok = False
    if not mutate_and_check(
        lambda s, np: (s | {"tamb_c": 30.0, "tdisch_c": 39.0, "fluid_in_c": 46.0}, np), "E temps"
    ):
        all_ok = False

    # Independent temperature / cp tracking
    if not mutate_and_check(lambda s, np: (s | {"tamb_c": 31.0}, np), "H tamb only"):
        all_ok = False
    if not mutate_and_check(lambda s, np: (s | {"tdisch_c": 43.0}, np), "I tdisch only"):
        all_ok = False
    if not mutate_and_check(lambda s, np: (s | {"fluid_in_c": 46.5}, np), "J fluid_in only"):
        all_ok = False
    if not mutate_and_check(lambda s, np: (s | {"cp_j_per_kg_k": 3900.0}, np), "K cp only"):
        all_ok = False

    # Legal boundary ratios 0 and 1 (keep available dT strictly positive)
    if not mutate_and_check(lambda s, np: (s | {"recirc_ratio": 0.0}, np), "L ratio 0"):
        all_ok = False
    if not mutate_and_check(
        lambda s, np: (s | {"recirc_ratio": 1.0, "fluid_in_c": 50.0}, np), "M ratio 1"
    ):
        all_ok = False

    # Curve mutations: shift plateaus / force clamp / force glycol-limited regime
    def mut_curve_down(s, np):
        curve = [
            {"t_air_eff_c": 25.0, "q_cap_kw": 200.0},
            {"t_air_eff_c": 30.0, "q_cap_kw": 180.0},
            {"t_air_eff_c": 35.0, "q_cap_kw": 160.0},
            {"t_air_eff_c": 40.0, "q_cap_kw": 140.0},
        ]
        return s, np | {"capacity_curve": curve}

    if not mutate_and_check(mut_curve_down, "U curve derated"):
        all_ok = False

    def mut_curve_clamp_high(s, np):
        # t_eff ~35 stays above rightmost point -> clamp to 250
        curve = [
            {"t_air_eff_c": 20.0, "q_cap_kw": 400.0},
            {"t_air_eff_c": 25.0, "q_cap_kw": 300.0},
            {"t_air_eff_c": 28.0, "q_cap_kw": 250.0},
        ]
        return s, np | {"capacity_curve": curve}

    if not mutate_and_check(mut_curve_clamp_high, "U2 curve clamp high"):
        all_ok = False

    def mut_glycol_limited(s, np):
        # Raise curve far above glycol so min() takes glycol path
        curve = [
            {"t_air_eff_c": 20.0, "q_cap_kw": 900.0},
            {"t_air_eff_c": 45.0, "q_cap_kw": 800.0},
        ]
        return s, np | {"capacity_curve": curve}

    if not mutate_and_check(mut_glycol_limited, "U3 glycol-limited regime"):
        all_ok = False

    # Distractor fields must not affect answer
    if not mutate_and_check(
        lambda s, np: (
            s | {"twb_c": 10.0, "bms_duty_kw": 1.0, "fluid_out_c": 0.0},
            np | {"design_capacity_kw": 1.0},
        ),
        "N distractors changed",
    ):
        all_ok = False

    data_txt, spec_txt = backup()
    try:
        s = load_json(DATA_PATH)
        for key in ("twb_c", "bms_duty_kw", "fluid_out_c"):
            s.pop(key, None)
        DATA_PATH.write_text(json.dumps(s, ensure_ascii=False, indent=2), encoding="utf-8")
        got = run_program()
        if got is None or not close(got, exp0):
            print(f"FAIL [O distractors removed]: expected {exp0}, got {got}")
            all_ok = False
        else:
            print("PASS [O distractors removed]")
    finally:
        restore(data_txt, spec_txt)

    # Reject cases: non-positive dT (<0 and ==0), bad ratios, missing fields, non-finite/non-positive params
    if not mutate_and_reject(lambda s, np: (s | {"fluid_in_c": 20.0}, np), "F dT < 0"):
        all_ok = False

    def mut_dT0(s, np):
        # Binary-exact values make dT == 0 unambiguous across implementations.
        return (
            s | {"recirc_ratio": 0.5, "tamb_c": 30.0, "tdisch_c": 40.0, "fluid_in_c": 40.0},
            np | {"design_approach_k": 5.0},
        )

    if not mutate_and_reject(mut_dT0, "F2 dT == 0"):
        all_ok = False
    if not mutate_and_reject(lambda s, np: (s | {"recirc_ratio": 1.5}, np), "G ratio > 1"):
        all_ok = False
    if not mutate_and_reject(lambda s, np: (s | {"recirc_ratio": -0.1}, np), "G2 ratio < 0"):
        all_ok = False
    if not mutate_and_reject(lambda s, np: (s | {"recirc_ratio": 1.1}, np), "G3 ratio 1.1"):
        all_ok = False
    if not mutate_and_reject(lambda s, np: (s | {"glycol_kg_s": 0.0}, np), "P zero flow"):
        all_ok = False
    if not mutate_and_reject(lambda s, np: (s | {"glycol_kg_s": -1.0}, np), "P2 negative flow"):
        all_ok = False
    if not mutate_and_reject(lambda s, np: (s | {"cp_j_per_kg_k": 0.0}, np), "Q zero cp"):
        all_ok = False
    if not mutate_and_reject(lambda s, np: (s | {"cp_j_per_kg_k": float("nan")}, np), "Q2 nan cp"):
        all_ok = False
    if not mutate_and_reject(lambda s, np: (s | {"cp_j_per_kg_k": -1.0}, np), "Q3 negative cp"):
        all_ok = False

    for key in REQUIRED_SENSOR:
        def mut_missing(s, np, key=key):
            s = dict(s)
            s.pop(key, None)
            return s, np

        if not mutate_and_reject(mut_missing, f"R missing {key}"):
            all_ok = False

    for key in REQUIRED_SPEC:
        def mut_missing_spec(s, np, key=key):
            np = dict(np)
            np.pop(key, None)
            return s, np

        if not mutate_and_reject(mut_missing_spec, f"S missing {key}"):
            all_ok = False

    def mut_curve_one_point(s, np):
        return s, np | {"capacity_curve": [{"t_air_eff_c": 30.0, "q_cap_kw": 400.0}]}

    if not mutate_and_reject(mut_curve_one_point, "S2 curve < 2 points"):
        all_ok = False

    def mut_curve_nonincreasing(s, np):
        return s, np | {
            "capacity_curve": [
                {"t_air_eff_c": 30.0, "q_cap_kw": 400.0},
                {"t_air_eff_c": 30.0, "q_cap_kw": 350.0},
            ]
        }

    if not mutate_and_reject(mut_curve_nonincreasing, "S3 curve not increasing"):
        all_ok = False

    def mut_curve_bad_point(s, np):
        return s, np | {
            "capacity_curve": [
                {"t_air_eff_c": 25.0, "q_cap_kw": 400.0},
                {"t_air_eff_c": 35.0},
            ]
        }

    if not mutate_and_reject(mut_curve_bad_point, "S4 curve point missing q"):
        all_ok = False

    # Every required numeric field must preserve the input contract, even when
    # a candidate silently substitutes a plausible finite default for bad data.
    for side, keys in (("sensor", REQUIRED_SENSOR), ("nameplate", ("design_approach_k",))):
        for key in keys:
            for kind, value in (
                ("NaN", float("nan")),
                ("Infinity", float("inf")),
                ("-Infinity", -float("inf")),
                ("bool", True),
                ("string", "35.0"),
                ("null", None),
            ):
                def mut_bad_number(s, np, side=side, key=key, value=value):
                    target = s if side == "sensor" else np
                    target[key] = value
                    return s, np

                if not mutate_and_reject(mut_bad_number, f"T invalid {side}.{key} {kind}"):
                    all_ok = False

    # Anti-cheat: source must mention recirculation + curve path, not BMS-only
    src = SRC_PATH.read_text(encoding="utf-8")
    if "recirc_ratio" not in src:
        print("FAIL: source does not reference recirc_ratio")
        all_ok = False
    if "capacity_curve" not in src:
        print("FAIL: source does not reference capacity_curve")
        all_ok = False
    if "bms_duty_kw" in src and "recirc_ratio" not in src:
        print("FAIL: source still looks like BMS-only path without recirculation")
        all_ok = False

    write_reward(1.0 if all_ok else 0.0)
except Exception as exc:
    print(f"FAIL: verifier exception {exc}")
    write_reward(0.0)
PYEOF
