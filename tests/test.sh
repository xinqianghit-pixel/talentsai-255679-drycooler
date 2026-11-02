#!/bin/bash
# Harbor verifier for dry-cooler recirculation capacity
REWARD_FILE="/logs/verifier/reward.json"
mkdir -p /logs/verifier
echo '{"reward": 0}' > "$REWARD_FILE"

python3 << 'PYEOF'
import json
import os
import shutil
import subprocess
from pathlib import Path

REWARD_FILE = "/logs/verifier/reward.json"
DATA_PATH = Path("/app/yard_sensors.json")
SPEC_PATH = Path("/app/nameplate.json")
SRC_PATH = Path("/app/dry_cooler_cap.py")
TOLERANCE = 0.001


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


def expected_from(s: dict, np: dict) -> dict:
    r = float(s["recirc_ratio"])
    t_eff = (1.0 - r) * float(s["tamb_c"]) + r * float(s["tdisch_c"])
    dT = float(s["fluid_in_c"]) - t_eff - float(np["design_approach_k"])
    q_kw = float(s["glycol_kg_s"]) * float(s["cp_j_per_kg_k"]) * dT / 1000.0
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


def close(a: dict, b: dict) -> bool:
    try:
        for k in ("t_air_eff_c", "q_avail_kw"):
            av = float(a[k])
            bv = float(b[k])
            if abs(av - bv) > max(TOLERANCE * max(abs(bv), 1.0), 1e-6):
                return False
        return True
    except Exception:
        return False


def run_program():
    try:
        run = subprocess.run(
            ["python3", "/app/dry_cooler_cap.py"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        print("FAIL: program timed out")
        return None
    if run.returncode != 0:
        print("FAIL: program crashed")
        print(run.stderr[:400])
        return None
    try:
        return json.loads(run.stdout.strip().splitlines()[-1])
    except Exception as exc:
        print(f"FAIL: bad json ({exc})")
        print(run.stdout[:200])
        return None


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
        s2, np2 = mutator(s, np)
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

    # Reject common wrong answers on baseline
    if got0 is not None:
        for name, fn in [
            ("wetbulb", wrong_wetbulb),
            ("ambient", wrong_ambient_only),
            ("bms", wrong_bms),
            ("baseline-bug", wrong_buggy_baseline),
        ]:
            w = fn(s0, np0)
            if close(got0, w) and not close(w, exp0):
                print(f"FAIL: output matches wrong_{name} {w}")
                all_ok = False

    # Case B: change recirculation ratio
    def mut_r(s, np):
        s = dict(s)
        s["recirc_ratio"] = 0.45
        return s, np

    if not mutate_and_check(mut_r, "B recirc"):
        all_ok = False

    # Case C: change approach in nameplate
    def mut_a(s, np):
        np = dict(np)
        np["design_approach_k"] = 6.5
        return s, np

    if not mutate_and_check(mut_a, "C approach"):
        all_ok = False

    # Case D: scale flow
    def mut_m(s, np):
        s = dict(s)
        s["glycol_kg_s"] = float(s["glycol_kg_s"]) * 1.15
        return s, np

    if not mutate_and_check(mut_m, "D flow"):
        all_ok = False

    # Case E: rewrite temperatures
    def mut_t(s, np):
        s = dict(s)
        s["tamb_c"] = 30.0
        s["tdisch_c"] = 39.0
        s["fluid_in_c"] = 46.0
        return s, np

    if not mutate_and_check(mut_t, "E temps"):
        all_ok = False

    # Case F: non-positive dT should fail (crash/nonzero or clearly not success json of positive Q)
    data_txt, spec_txt = backup()
    try:
        s = load_json(DATA_PATH)
        s["fluid_in_c"] = 20.0  # too cold vs air+approach
        DATA_PATH.write_text(json.dumps(s, ensure_ascii=False, indent=2), encoding="utf-8")
        try:
            run = subprocess.run(
                ["python3", "/app/dry_cooler_cap.py"],
                capture_output=True,
                text=True,
                timeout=30,
            )
        except subprocess.TimeoutExpired:
            print("PASS [F non-positive dT]: timed out treated as reject")
        else:
            ok_reject = run.returncode != 0
            if run.returncode == 0:
                try:
                    obj = json.loads(run.stdout.strip().splitlines()[-1])
                    # Accept only if it did not emit a plausible positive available duty
                    ok_reject = float(obj.get("q_avail_kw", 1)) <= 0
                except Exception:
                    ok_reject = True
            if ok_reject:
                print("PASS [F non-positive dT]")
            else:
                print("FAIL [F non-positive dT]: should reject")
                all_ok = False
    finally:
        restore(data_txt, spec_txt)

    # Case G: invalid recirc_ratio
    data_txt, spec_txt = backup()
    try:
        s = load_json(DATA_PATH)
        s["recirc_ratio"] = 1.5
        DATA_PATH.write_text(json.dumps(s, ensure_ascii=False, indent=2), encoding="utf-8")
        try:
            run = subprocess.run(
                ["python3", "/app/dry_cooler_cap.py"],
                capture_output=True,
                text=True,
                timeout=30,
            )
        except subprocess.TimeoutExpired:
            print("PASS [G bad ratio]: timed out treated as reject")
        else:
            if run.returncode != 0:
                print("PASS [G bad ratio]")
            else:
                print("FAIL [G bad ratio]: should reject")
                all_ok = False
    finally:
        restore(data_txt, spec_txt)

    # Anti-cheat: ensure source still present and not a trivial constant printer
    src = SRC_PATH.read_text(encoding="utf-8")
    if "bms_duty_kw" in src and "recirc_ratio" not in src:
        print("FAIL: source still looks like BMS-only path without recirculation")
        all_ok = False

    write_reward(1.0 if all_ok else 0.0)
except Exception as exc:
    print(f"FAIL: verifier exception {exc}")
    write_reward(0.0)
PYEOF
