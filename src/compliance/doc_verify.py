#!/data/banxe/compliance-env/bin/python3
"""
Document Verification — MRZ parsing + face comparison.
Two tools:
  1. PassportEye (MIT) — MRZ extraction from passport images
  2. DeepFace (MIT) — face similarity check

Both dependencies are optional — graceful fallback to manual MRZ parser for
ICAO TD3 string input (used in unit tests and server environments without GPU).

Called synchronously (use loop.run_in_executor from async context).
"""
from __future__ import annotations

import re
from typing import Optional

# ── ICAO Doc 9303 canonical test vector (TD3, 2×44 chars) ────────────────────
# Source: ICAO Doc 9303 Part 4 §4.3 — Machine Readable Passports
# Surname: ERIKSSON, Given names: ANNA MARIA, Nationality: UTO, DOB: 1974-08-12
ICAO_TEST_MRZ = [
    "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<",
    "L898902C36UTO7408122F1204159ZE184226B<<<<<10",
]

# ── PassportEye (optional) ────────────────────────────────────────────────────
try:
    from passporteye import read_mrz as _passporteye_read_mrz
    PASSPORTEYE_AVAILABLE = True
except ImportError:
    PASSPORTEYE_AVAILABLE = False

# ── DeepFace (optional) ───────────────────────────────────────────────────────
try:
    from deepface import DeepFace as _DeepFace
    DEEPFACE_AVAILABLE = True
except ImportError:
    DEEPFACE_AVAILABLE = False


# ── ICAO check digit algorithm ────────────────────────────────────────────────
# Per ICAO Doc 9303: 0-9→0-9, A-Z→10-35, '<'→0 (filler has value 0, not 36)

_WEIGHTS = [7, 3, 1]

def _char_value(c: str) -> int:
    if '0' <= c <= '9':
        return int(c)
    if 'A' <= c <= 'Z':
        return ord(c) - ord('A') + 10
    return 0  # '<' and any other filler

def _check_digit(s: str) -> str:
    total = sum(_char_value(ch) * _WEIGHTS[i % 3] for i, ch in enumerate(s))
    return str(total % 10)


def _validate_check_digit(field: str, digit: str) -> bool:
    return _check_digit(field) == digit


# ── Manual TD3 MRZ parser (line1=44, line2=44) ───────────────────────────────

def _parse_td3(line1: str, line2: str) -> Optional[dict]:
    """Parse ICAO TD3 (passport) MRZ. Returns dict or None on format error."""
    l1, l2 = line1.strip(), line2.strip()
    if len(l1) != 44 or len(l2) != 44:
        return None

    doc_type = l1[0:2].replace("<", "").strip()
    issuing_country = l1[2:5].replace("<", "").strip()

    # Names section: l1[5:44] — surname<<given_names
    names_raw = l1[5:44]
    parts = names_raw.split("<<", 1)
    surname = parts[0].replace("<", " ").strip()
    given_names = parts[1].replace("<", " ").strip() if len(parts) > 1 else ""

    # Line 2 fields
    doc_number = l2[0:9].replace("<", "").strip()
    doc_number_check = l2[9]
    nationality = l2[10:13].replace("<", "").strip()
    dob = l2[13:19]           # YYMMDD
    dob_check = l2[19]
    sex = l2[20]
    expiry = l2[21:27]        # YYMMDD
    expiry_check = l2[27]
    optional_data = l2[28:42].replace("<", "").strip()
    composite_check = l2[43]

    # Validate check digits
    doc_ok      = _validate_check_digit(l2[0:9], doc_number_check)
    dob_ok      = _validate_check_digit(dob, dob_check)
    expiry_ok   = _validate_check_digit(expiry, expiry_check)
    composite_s = l2[0:10] + l2[13:20] + l2[21:43]
    composite_ok = _validate_check_digit(composite_s, composite_check)

    all_checks_ok = doc_ok and dob_ok and expiry_ok and composite_ok

    return {
        "doc_type":       doc_type,
        "issuing_country": issuing_country,
        "surname":        surname,
        "given_names":    given_names,
        "doc_number":     doc_number,
        "nationality":    nationality,
        "date_of_birth":  dob,
        "sex":            sex if sex in ("M", "F") else "X",
        "expiry_date":    expiry,
        "optional_data":  optional_data,
        "check_digits_ok": all_checks_ok,
    }


# ── Public API ────────────────────────────────────────────────────────────────

def verify_passport(
    *,
    image_path: Optional[str] = None,
    mrz_lines: Optional[list] = None,
) -> dict:
    """
    Verify passport document.

    Args:
        image_path: path to passport scan (uses PassportEye if available)
        mrz_lines:  pre-extracted MRZ lines list [line1, line2] (used in tests)

    Returns:
        {
            valid: bool,
            mrz_data: {surname, given_names, doc_number, nationality,
                       date_of_birth, sex, expiry_date, check_digits_ok, ...},
            source: "passporteye" | "manual_parser",
            error: str | None,
        }
    """
    base: dict = {"valid": False, "mrz_data": {}, "source": "manual_parser", "error": None}

    # ── Path 1: MRZ lines provided directly ──────────────────────────────────
    if mrz_lines is not None:
        if len(mrz_lines) < 2:
            base["error"] = "mrz_lines must have at least 2 lines"
            return base
        parsed = _parse_td3(mrz_lines[0], mrz_lines[1])
        if parsed is None:
            base["error"] = "MRZ lines are not valid TD3 format (must be 44 chars each)"
            return base
        base["valid"] = parsed.get("check_digits_ok", False)
        base["mrz_data"] = parsed
        return base

    # ── Path 2: Image file ────────────────────────────────────────────────────
    if image_path is None:
        base["error"] = "Provide either image_path or mrz_lines"
        return base

    if PASSPORTEYE_AVAILABLE:
        try:
            mrz = _passporteye_read_mrz(image_path)
            if mrz is None:
                base["error"] = "PassportEye could not detect MRZ in image"
                return base
            d = mrz.to_dict()
            base["source"] = "passporteye"
            base["valid"] = d.get("valid_score", 0) >= 70
            base["mrz_data"] = {
                "doc_type":       d.get("type", ""),
                "issuing_country": d.get("country", ""),
                "surname":        d.get("surname", ""),
                "given_names":    d.get("names", ""),
                "doc_number":     d.get("number", ""),
                "nationality":    d.get("nationality", ""),
                "date_of_birth":  d.get("date_of_birth", ""),
                "sex":            d.get("sex", ""),
                "expiry_date":    d.get("expiration_date", ""),
                "check_digits_ok": d.get("valid_score", 0) >= 90,
            }
            return base
        except Exception as exc:
            base["error"] = f"PassportEye error: {exc}"
            return base
    else:
        base["error"] = "PassportEye not installed; provide mrz_lines for string-based parsing"
        return base


def verify_face(image_path1: str, image_path2: str, threshold: float = 0.60) -> dict:
    """
    Compare two face images using DeepFace (VGG-Face model, cosine distance).

    Returns:
        {
            match: bool,
            distance: float,
            threshold: float,
            model: str,
            error: str | None,
        }
    """
    base: dict = {
        "match": False, "distance": 1.0,
        "threshold": threshold, "model": "VGG-Face", "error": None,
    }
    if not DEEPFACE_AVAILABLE:
        base["error"] = "DeepFace not installed"
        return base
    try:
        result = _DeepFace.verify(
            img1_path=image_path1,
            img2_path=image_path2,
            model_name="VGG-Face",
            distance_metric="cosine",
            enforce_detection=False,
        )
        base["match"]    = result.get("verified", False)
        base["distance"] = round(result.get("distance", 1.0), 4)
        return base
    except Exception as exc:
        base["error"] = str(exc)
        return base


# ── Standalone test ───────────────────────────────────────────────────────────

if __name__ == "__main__":
    print("Testing ICAO TD3 MRZ parser with canonical test vector…")
    r = verify_passport(mrz_lines=ICAO_TEST_MRZ)
    print(f"  valid={r['valid']}")
    print(f"  surname={r['mrz_data'].get('surname')}")
    print(f"  given_names={r['mrz_data'].get('given_names')}")
    print(f"  doc_number={r['mrz_data'].get('doc_number')}")
    print(f"  nationality={r['mrz_data'].get('nationality')}")
    print(f"  check_digits_ok={r['mrz_data'].get('check_digits_ok')}")
    assert r["valid"] is True, "ICAO test MRZ should parse as valid"
    assert r["mrz_data"]["surname"] == "ERIKSSON", f"Expected ERIKSSON, got {r['mrz_data']['surname']}"
    print("  ✅ All assertions passed")
