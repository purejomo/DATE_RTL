"""Build the requested 22nm-projected compute comparison CSV.

All synthesis and power reports consumed here are Nangate45 measurements.  The
compact output follows the comparison-table convention requested for the
paper: area and power are projected to 22nm, while ``WNS45`` remains the raw
45nm timing result.

    area    / 4.545
    energy  / 2.100
    power   / 1.625

The energy factor includes the assumed node speed-up, whereas the displayed
MHz and GMAC/s retain the design target clocks.  Consequently ``pJ/MAC`` is an
independent energy projection and is intentionally not ``Power W / GMAC/s``.

These are logic-synthesis projections, not 22nm measurements.  No 22nm library
or place-and-route result is used.
"""

from __future__ import annotations

import csv
import math
import pathlib
import re

from build_compute_table import ROWS as EXISTING_ROWS

HERE = pathlib.Path(__file__).resolve().parent
RESULTS = HERE.parent / "results"

AREA_SCALE = 4.545
ENERGY_SCALE = 2.100
POWER_SCALE = 1.625

# The final paper table intentionally omits the two 32-multiplier P3-LLM
# diagnostic rows.  Keep this explicit list so a future addition to
# build_compute_table.ROWS cannot silently change the requested row set/order.
FINAL_EXISTING_LABELS = (
    "compute_hbmpim_250",
    "int4fp16_compute_16_500",
    "int4bf16_compute_16_500",
    "int4fp16_compute_32_500",
    "int4bf16_compute_32_500",
    "int4fp16_compute_64_500",
    "int4bf16_compute_64_500",
    "int4fp16_pcu_top_pcu500",
    "int4bf16_pcu_top_pcu500",
    "p3llm_pcu_500",
)

CSV_FIELDS = (
    "design",
    "MHz",
    "mul",
    "add",
    "MAC/cy",
    "GMAC/s",
    "면적µm²",
    "µm²/MAC",
    "Power W",
    "pJ/MAC",
    "WNS45",
)

TOTAL_POWER_RE = re.compile(
    r"^Total\s+\S+\s+\S+\s+\S+\s+(\S+)", re.MULTILINE
)
ACTIVITY_RE = re.compile(
    r"^activity source: vectorless, input activity (\S+)\s*$", re.MULTILINE
)


def finite_float(raw: str, *, source: pathlib.Path, field: str) -> float:
    """Parse one required finite numeric field with a useful error message."""
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{source}: invalid {field}: {raw!r}") from exc
    if not math.isfinite(value):
        raise ValueError(f"{source}: non-finite {field}: {raw!r}")
    return value


def load_area(path: pathlib.Path, required_labels: tuple[str, ...]) -> dict[str, dict]:
    """Load an area CSV and fail rather than silently dropping required rows."""
    if not path.is_file():
        raise FileNotFoundError(f"missing synthesis summary: {path}")

    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        required_fields = {"label", "top", "area_um2", "wns_ns"}
        missing_fields = required_fields - set(reader.fieldnames or ())
        if missing_fields:
            missing = ", ".join(sorted(missing_fields))
            raise ValueError(f"{path}: missing columns: {missing}")

        rows: dict[str, dict] = {}
        for line_number, row in enumerate(reader, start=2):
            label = (row.get("label") or "").strip()
            if not label:
                raise ValueError(f"{path}:{line_number}: empty label")
            if label in rows:
                raise ValueError(f"{path}:{line_number}: duplicate label {label!r}")
            rows[label] = row

    missing_labels = [label for label in required_labels if label not in rows]
    if missing_labels:
        raise ValueError(f"{path}: missing required rows: {', '.join(missing_labels)}")
    return rows


def power_of(
    power_dir: pathlib.Path, top: str, netlist: pathlib.Path | None = None
) -> float | None:
    """Read vectorless power, or mark it stale after a newer synthesis."""
    if not top:
        raise ValueError(f"{power_dir}: empty synthesis top name")
    path = power_dir / f"{top}_power.rpt"
    if not path.is_file():
        raise FileNotFoundError(f"missing power report: {path}")
    if netlist is not None and netlist.is_file() \
            and path.stat().st_mtime < netlist.stat().st_mtime:
        return None
    report = path.read_text(encoding="utf-8")
    totals = TOTAL_POWER_RE.findall(report)
    if len(totals) != 1:
        raise ValueError(f"{path}: expected one Total power row, found {len(totals)}")
    activities = ACTIVITY_RE.findall(report)
    if len(activities) != 1:
        raise ValueError(
            f"{path}: expected one vectorless activity row, found {len(activities)}"
        )
    activity = finite_float(
        activities[0], source=path, field="vectorless input activity"
    )
    if not math.isclose(activity, 0.20, rel_tol=0.0, abs_tol=1e-12):
        raise ValueError(f"{path}: expected input activity 0.20, got {activity}")
    power = finite_float(totals[0], source=path, field="total power")
    if power < 0.0:
        raise ValueError(f"{path}: negative total power: {power}")
    return power


def existing_metadata() -> dict[str, tuple]:
    """Index and validate the row definitions shared with the 45nm table."""
    indexed: dict[str, tuple] = {}
    for row in EXISTING_ROWS:
        label = row[4]
        if label in indexed:
            raise ValueError(f"duplicate row definition: {label}")
        indexed[label] = row
    missing = [label for label in FINAL_EXISTING_LABELS if label not in indexed]
    if missing:
        raise ValueError(f"missing row definitions: {', '.join(missing)}")
    return indexed


def measured_row(
    *,
    design: str,
    mhz: int,
    mul: int,
    add: int,
    mac_per_cycle: float,
    entry: dict,
    area_source: pathlib.Path,
    power_dir: pathlib.Path,
    netlist: pathlib.Path | None = None,
) -> dict:
    """Validate and normalize one measured 45nm row before projection."""
    if mhz <= 0 or mul <= 0 or add <= 0 or mac_per_cycle <= 0:
        raise ValueError(f"{design}: operator counts and throughput must be positive")
    top = (entry.get("top") or "").strip()
    area = finite_float(entry.get("area_um2"), source=area_source, field="area_um2")
    wns = finite_float(entry.get("wns_ns"), source=area_source, field="wns_ns")
    if area <= 0.0:
        raise ValueError(f"{area_source}: non-positive area for {design}: {area}")
    return {
        "design": design,
        "mhz": mhz,
        "mul": mul,
        "add": add,
        "mac_per_cycle": float(mac_per_cycle),
        "area45": area,
        "power45": power_of(power_dir, top, netlist),
        "wns45": wns,
    }


def collect() -> list[dict]:
    """Collect exactly the ten rows requested for the final table."""
    area_path = RESULTS / "area.csv"
    area_rows = load_area(area_path, FINAL_EXISTING_LABELS)
    metadata = existing_metadata()
    rows: list[dict] = []

    for label in FINAL_EXISTING_LABELS:
        paper, precision, org, _ops, _label, mul, add, mac_cy, mhz, _acc = \
            metadata[label]
        display_org = "SIMD" if org == "SIMD bank" else org
        rows.append(measured_row(
            design=f"{paper} {precision} {display_org}",
            mhz=mhz,
            mul=mul,
            add=add,
            mac_per_cycle=mac_cy,
            entry=area_rows[label],
            area_source=area_path,
            power_dir=RESULTS / "power",
            netlist=HERE.parent / "build" / "results" / label / "1_synth.v",
        ))

    if len(rows) != 10:
        raise AssertionError(f"expected 10 final rows, collected {len(rows)}")
    return rows


def compact_number(value: float) -> str:
    """Print integer counts without a trailing decimal point."""
    if value.is_integer():
        return str(int(value))
    return f"{value:.1f}"


def project(row: dict) -> dict[str, str | int]:
    """Apply the fixed projection factors and exact requested presentation."""
    mac_per_cycle = row["mac_per_cycle"]
    gmac_per_s = mac_per_cycle * row["mhz"] / 1000.0
    area22 = row["area45"] / AREA_SCALE
    power45 = row["power45"]
    power22 = None if power45 is None else power45 / POWER_SCALE
    pj_per_mac22 = None if power45 is None \
        else power45 / gmac_per_s * 1000.0 / ENERGY_SCALE

    return {
        "design": row["design"],
        "MHz": row["mhz"],
        "mul": row["mul"],
        "add": row["add"],
        "MAC/cy": compact_number(mac_per_cycle),
        "GMAC/s": f"{gmac_per_s:.1f}",
        "면적µm²": f"{area22:.0f}",
        "µm²/MAC": f"{area22 / mac_per_cycle:.0f}",
        "Power W": "" if power22 is None else f"{power22:.4f}",
        "pJ/MAC": "" if pj_per_mac22 is None else f"{pj_per_mac22:.1f}",
        "WNS45": f"{row['wns45']:.2f}",
    }


def main() -> None:
    rows = [project(row) for row in collect()]
    path = RESULTS / "comparison_22nm.csv"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=CSV_FIELDS, lineterminator="\n"
        )
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {path} ({len(rows)} rows)")


if __name__ == "__main__":
    main()
