"""Merge selected synthesis rows into the repository-wide area summary.

Each synthesis driver owns a subset of labels.  Publishing one subset must not
erase rows produced by another driver, so existing row order is preserved,
owned rows are replaced in place, and newly synthesized rows are appended.
"""

from __future__ import annotations

import csv
import pathlib
import sys


def read_rows(path: pathlib.Path) -> tuple[list[str], list[dict[str, str]]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames:
            raise ValueError(f"{path}: missing CSV header")
        rows = list(reader)
    labels = [row.get("label", "") for row in rows]
    if not all(labels) or len(labels) != len(set(labels)):
        raise ValueError(f"{path}: labels must be nonempty and unique")
    return list(reader.fieldnames), rows


def main() -> None:
    if len(sys.argv) < 4:
        raise SystemExit(
            "usage: merge_area_csv.py <destination> <source> <label> [...]"
        )

    destination = pathlib.Path(sys.argv[1])
    source = pathlib.Path(sys.argv[2])
    owned = tuple(sys.argv[3:])
    if len(owned) != len(set(owned)):
        raise ValueError("owned labels must be unique")

    source_fields, source_rows = read_rows(source)
    source_by_label = {row["label"]: row for row in source_rows}
    missing = [label for label in owned if label not in source_by_label]
    if missing:
        raise ValueError(f"{source}: missing owned rows: {', '.join(missing)}")

    if destination.exists():
        destination_fields, destination_rows = read_rows(destination)
        if destination_fields != source_fields:
            raise ValueError(
                f"CSV header mismatch: {destination} vs {source}"
            )
    else:
        destination_rows = []

    merged: list[dict[str, str]] = []
    seen: set[str] = set()
    for row in destination_rows:
        label = row["label"]
        merged.append(source_by_label[label] if label in owned else row)
        seen.add(label)
    for label in owned:
        if label not in seen:
            merged.append(source_by_label[label])

    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=source_fields, lineterminator="\n"
        )
        writer.writeheader()
        writer.writerows(merged)
    print(f"updated {destination} ({len(merged)} rows)")


if __name__ == "__main__":
    main()
