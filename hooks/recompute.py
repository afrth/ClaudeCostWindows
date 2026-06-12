#!/usr/bin/env python3
"""Backfill: rebuild cost_log.jsonl + cost_tracker.json with current pricing.

Why this exists: historical entries were written with a stale price (any model
that fell through get_pricing's substring match) and the log accumulated
duplicate rows (per-session dedup re-logged resumed sessions). This rereads the
raw token counts in the log, recomputes every cost with the current PRICING
table, drops duplicate msg_ids, and rebuilds the summary totals.

Both files are backed up (.bak-<timestamp>) before they are rewritten.
Safe to re-run — it always rebuilds from the raw token columns, never from the
previously-computed cost_usd.

Run:  py -3 recompute.py     (or: python3 recompute.py)
"""
import json, os, sys, shutil
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cost_tracker as ct  # reuse PRICING / get_pricing — single source of truth

M = 1_000_000


def entry_cost(e: dict) -> float:
    p_in, p_c5, p_c1h, p_hit, p_out = ct.get_pricing(e.get("model", ""))
    return (
        e.get("input_tokens", 0)   * p_in  +
        e.get("output_tokens", 0)  * p_out +
        e.get("cache_read", 0)     * p_hit +
        e.get("cache_write_5m", 0) * p_c5  +
        e.get("cache_write_1h", 0) * p_c1h
    ) / M


def main():
    if not os.path.exists(ct.LOG_FILE):
        print("no log file:", ct.LOG_FILE)
        return

    try:
        tracker = json.load(open(ct.COST_FILE, encoding="utf-8"))
    except Exception:
        tracker = {}

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    shutil.copy2(ct.LOG_FILE, f"{ct.LOG_FILE}.bak-{stamp}")
    if os.path.exists(ct.COST_FILE):
        shutil.copy2(ct.COST_FILE, f"{ct.COST_FILE}.bak-{stamp}")

    seen = set()
    kept = []
    by_day, by_project, by_model = {}, {}, {}
    total = 0.0
    raw = dups = 0

    with open(ct.LOG_FILE, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            raw += 1
            mid = e.get("msg_id")
            if mid in seen:
                dups += 1
                continue
            seen.add(mid)

            c = entry_cost(e)
            e["cost_usd"] = round(c, 8)
            kept.append(json.dumps(e))

            day   = e.get("date") or e.get("ts", "")[:10]
            proj  = e.get("project", "unknown")
            model = e.get("model", "unknown")
            by_day[day]       = by_day.get(day, 0) + c
            by_project[proj]  = by_project.get(proj, 0) + c
            by_model[model]   = by_model.get(model, 0) + c
            total            += c

    with open(ct.LOG_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(kept) + ("\n" if kept else ""))

    tracker["total_cost"]     = total
    tracker["total_requests"] = len(kept)
    tracker["by_day"]         = by_day
    tracker["by_project"]     = by_project
    tracker["by_model"]       = by_model
    tracker["seen_ids"]       = list(seen)   # global dedup set the hook now reads
    tracker.pop("sessions", None)            # legacy per-session dedup, no longer used
    tracker["last_updated"]   = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    with open(ct.COST_FILE, "w", encoding="utf-8") as f:
        json.dump(tracker, f, indent=2)

    print(f"raw lines:     {raw}")
    print(f"duplicates:    {dups}")
    print(f"kept (unique): {len(kept)}")
    print(f"total cost:    ${total:,.2f}")
    print(f"backups:       *.bak-{stamp}")


if __name__ == "__main__":
    main()
