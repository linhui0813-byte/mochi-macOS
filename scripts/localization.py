"""Checks that every interface string the compiler extracted has a finished translation in every shipped language.

The compiler writes one .stringsdata file per source file while building. A string that is in the source but missing
from the catalog would silently show in English, so it fails here instead; a catalog entry no source uses is stale.
"""
import json
import re
import sys
from pathlib import Path

LANGUAGES = ("zh-Hans", "zh-Hant", "ja", "ko")
ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Sources/MochiApp/Resources/Localizable.xcstrings"
INFO_PLIST_CATALOG = ROOT / "Sources/MochiApp/Resources/InfoPlist.xcstrings"
INFO_PLIST_KEYS = {"NSMicrophoneUsageDescription"}
BUILD_SCRIPT = ROOT / "scripts/build-app.sh"
# The MCP helper ships no translations, and test support never ships.
EXCLUDED_TARGETS = ("mochi-mcp-", "MochiTestSupport-")
# The build also emits strings data generated from the catalogs themselves; reading it would hide stale entries.
GENERATED_PREFIX = "GeneratedStringSymbols_"
SPECIFIER = re.compile(r"%(?:(\d+)\$)?(@|lld|lf)")


def specifiers(text):
    """The argument types in the order they are consumed; positional forms are put back in argument order."""
    found = [(match.group(1), match.group(2)) for match in SPECIFIER.finditer(text)]
    positional = [(int(index), kind) for index, kind in found if index]
    if positional and len(positional) != len(found):
        raise ValueError(f"mixes positional and sequential specifiers: {text!r}")
    return [kind for _, kind in sorted(positional)] if positional else [kind for _, kind in found]


def source_keys(intermediates):
    """Every key the compiler extracted from the shipping targets."""
    keys = set()
    files = [
        path for path in Path(intermediates).glob("*/Objects-normal/*/*.stringsdata")
        if not path.parents[2].name.startswith(EXCLUDED_TARGETS) and not path.name.startswith(GENERATED_PREFIX)
    ]
    if not files:
        raise ValueError(f"no .stringsdata files under {intermediates}; build in release configuration first")
    for path in files:
        tables = json.loads(path.read_text()).get("tables", {})
        unexpected = set(tables) - {"Localizable"}
        if unexpected:
            raise ValueError(f"{path.name} uses tables {sorted(unexpected)}; Mochi ships only Localizable")
        keys.update(entry["key"] for entry in tables.get("Localizable", []))
    return keys


def translation_problems(key, entry):
    if entry.get("shouldTranslate") is False:
        return []
    problems = []
    expected = specifiers(key)
    for language in LANGUAGES:
        unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
        value = unit.get("value", "")
        if unit.get("state") != "translated" or not value.strip():
            problems.append(f"{language}: no translation for {key!r}")
            continue
        try:
            if specifiers(value) != expected:
                problems.append(f"{language}: placeholders differ for {key!r}: {value!r}")
        except ValueError as error:
            problems.append(f"{language}: {error}")
    return problems


def catalog_problems(keys, catalog):
    strings = catalog.get("strings", {})
    if catalog.get("sourceLanguage") != "en":
        return ["the catalog's source language must be en"]
    problems = [f"missing from the catalog: {key!r}" for key in sorted(keys - set(strings))]
    problems += [f"stale (no source uses it): {key!r}" for key in sorted(set(strings) - keys)]
    for key in sorted(keys & set(strings)):
        problems += translation_problems(key, strings[key])
    return problems


def info_plist_problems(catalog, build_script):
    """The English entry is compiled into en.lproj, so it must say what Info.plist says."""
    problems = [f"InfoPlist: {problem}" for problem in catalog_problems(INFO_PLIST_KEYS, catalog)]
    for key in sorted(INFO_PLIST_KEYS):
        match = re.search(rf"<key>{key}</key><string>(.*?)</string>", build_script)
        english = catalog["strings"].get(key, {}).get("localizations", {}).get("en", {}).get("stringUnit", {})
        if not match or english.get("value") != match.group(1):
            problems.append(f"InfoPlist: the English {key} differs from Info.plist in build-app.sh")
    return problems


def check(intermediates, catalog_path=CATALOG, info_plist_path=INFO_PLIST_CATALOG, build_script=BUILD_SCRIPT):
    keys = source_keys(intermediates)
    problems = catalog_problems(keys, json.loads(Path(catalog_path).read_text()))
    problems += info_plist_problems(json.loads(Path(info_plist_path).read_text()), Path(build_script).read_text())
    if problems:
        raise ValueError("\n".join(problems))
    return len(keys)


if __name__ == "__main__":
    if sys.argv[1:] == ["languages"]:
        print(*LANGUAGES)
    elif len(sys.argv) == 3 and sys.argv[1] == "check":
        try:
            count = check(sys.argv[2])
        except (OSError, ValueError) as error:
            sys.exit(str(error))
        print(f"{count} strings translated into {', '.join(LANGUAGES)}")
    else:
        sys.exit("usage: localization.py languages | check <Intermediates.noindex/Mochi.build/Release>")
