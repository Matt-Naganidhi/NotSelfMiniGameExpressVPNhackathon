#!/usr/bin/env python3
"""
rename.py — EQGate project rebranding utility
Usage:
  python rename.py --from EQGate --to MyProduct
  python rename.py --from eqgate --to myproduct
  python rename.py --list          # show every unique brand string found
  python rename.py --preview       # dry-run: show what would change
"""

import argparse
import os
import re
import sys
from pathlib import Path

# ── Files that should be scanned / renamed ──────────────────
TARGET_EXTENSIONS = {'.html', '.js', '.json', '.md', '.txt', '.ts', '.css', '.bat', '.sh', '.py'}

# ── Brand token pairs (case-aware) ──────────────────────────
# Each tuple: (pattern_to_find, replacement_template)
# Use {NEW} as placeholder for the replacement value.
BRAND_TOKENS = [
    # Title case
    ("EQGate",          "{NEW}"),
    # lowercase
    ("eqgate",          "{new}"),
    # Screaming snake (for env vars etc.)
    ("EQGATE",          "{NEW_UPPER}"),
    # Camel / mixed – catches eqGateResult style custom events
    ("eqGate",          "{newCamel}"),
    ("EQgate",          "{NEW}"),
]

# Fields in package.json to also rename
JSON_NAME_FIELDS = ['"name"']


def collect_files(root: Path):
    """Walk root and yield all text files with target extensions."""
    for path in root.rglob("*"):
        if path.is_file() and path.suffix.lower() in TARGET_EXTENSIONS:
            # Skip node_modules, .git, __pycache__
            parts = path.parts
            if any(p in parts for p in ("node_modules", ".git", "__pycache__", "dist", ".cache")):
                continue
            yield path


def build_replacements(old_brand: str, new_brand: str):
    """
    Build a list of (search, replace) pairs covering common casing variants.
    Accepts either mixed or lower input for both sides.
    """
    old = old_brand.strip()
    new = new_brand.strip()

    def _variants(s):
        return {
            "title":  s[0].upper() + s[1:] if s else s,
            "lower":  s.lower(),
            "upper":  s.upper(),
            # camelCase interior: first letter lower, rest as-is
            "camel":  s[0].lower() + s[1:] if s else s,
        }

    ov = _variants(old)
    nv = _variants(new)

    pairs = []
    # longest first to avoid partial clobbers
    for variant in ("upper", "title", "camel", "lower"):
        pairs.append((ov[variant], nv[variant]))

    # deduplicate while preserving order
    seen = set()
    unique = []
    for pair in pairs:
        if pair[0] not in seen and pair[0]:
            seen.add(pair[0])
            unique.append(pair)
    return unique


def replace_in_file(path: Path, replacements, dry_run=False):
    """Apply all (search, replace) pairs to a file. Returns True if changed."""
    try:
        original = path.read_text(encoding="utf-8", errors="replace")
    except Exception as e:
        print(f"  [SKIP] {path}: {e}")
        return False

    updated = original
    for search, replace in replacements:
        updated = updated.replace(search, replace)

    if updated == original:
        return False

    if dry_run:
        print(f"  [WOULD CHANGE] {path}")
        # Show first diff line
        for i, (a, b) in enumerate(zip(original.splitlines(), updated.splitlines())):
            if a != b:
                print(f"    line {i+1}: {a!r}  →  {b!r}")
                break
    else:
        path.write_text(updated, encoding="utf-8")
        print(f"  [UPDATED] {path}")
    return True


def rename_file_if_needed(path: Path, replacements, dry_run=False):
    """Rename the file itself if its name contains the old brand string."""
    new_name = path.name
    for search, replace in replacements:
        new_name = new_name.replace(search, replace)

    if new_name == path.name:
        return

    new_path = path.parent / new_name
    if dry_run:
        print(f"  [WOULD RENAME FILE] {path.name}  →  {new_name}")
    else:
        path.rename(new_path)
        print(f"  [RENAMED FILE] {path.name}  →  {new_name}")


def list_brand_strings(root: Path):
    """Print every unique brand-like token found across files."""
    pattern = re.compile(r'[Ee][Qq][Gg]ate|EQGATE|eqgate', re.IGNORECASE)
    found = {}
    for path in collect_files(root):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except Exception:
            continue
        for m in pattern.finditer(text):
            token = m.group()
            found.setdefault(token, []).append(str(path))

    if not found:
        print("No brand strings found.")
        return

    print(f"\nBrand strings found ({len(found)} variants):\n")
    for token, files in sorted(found.items()):
        unique_files = sorted(set(files))
        print(f"  {token!r:30s}  in {len(unique_files)} file(s):")
        for f in unique_files[:5]:
            print(f"    • {f}")
        if len(unique_files) > 5:
            print(f"    … and {len(unique_files) - 5} more")


def main():
    parser = argparse.ArgumentParser(
        description="EQGate project rebranding utility",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--from", dest="old", help="Brand name to replace (e.g. EQGate)")
    parser.add_argument("--to",   dest="new", help="New brand name (e.g. MyProduct)")
    parser.add_argument("--dir",  dest="root", default=".", help="Project root (default: .)")
    parser.add_argument("--preview", action="store_true", help="Dry run — show changes without applying")
    parser.add_argument("--list",    action="store_true", help="List all brand strings found in project")
    parser.add_argument("--rename-files", action="store_true", help="Also rename files whose names contain the brand string")
    args = parser.parse_args()

    root = Path(args.root).resolve()

    if args.list:
        list_brand_strings(root)
        return

    if not args.old or not args.new:
        parser.print_help()
        sys.exit(1)

    replacements = build_replacements(args.old, args.new)
    mode = "DRY RUN" if args.preview else "LIVE"

    print(f"\n{'='*55}")
    print(f"  EQGate Rename Utility  [{mode}]")
    print(f"  {args.old!r}  →  {args.new!r}")
    print(f"  Root: {root}")
    print(f"{'='*55}\n")
    print("Replacement pairs:")
    for s, r in replacements:
        print(f"  {s!r:30s} → {r!r}")
    print()

    changed = 0
    for path in sorted(collect_files(root)):
        if replace_in_file(path, replacements, dry_run=args.preview):
            changed += 1
        if args.rename_files:
            rename_file_if_needed(path, replacements, dry_run=args.preview)

    print(f"\n{'='*55}")
    if args.preview:
        print(f"  {changed} file(s) would be changed  (preview only)")
    else:
        print(f"  {changed} file(s) updated")
    print(f"{'='*55}\n")


if __name__ == "__main__":
    main()
