import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("localization", Path(__file__).parents[1] / "localization.py")
localization = importlib.util.module_from_spec(spec)
spec.loader.exec_module(localization)


def entry(**values):
    return {"localizations": {
        language: {"stringUnit": {"state": "translated", "value": value}} for language, value in values.items()}}


def complete(value):
    return entry(**{language: value for language in localization.LANGUAGES})


class LocalizationTests(unittest.TestCase):
    def test_specifiers_follow_argument_order(self):
        self.assertEqual(localization.specifiers("Delete %lld items from %@?"), ["lld", "@"])
        self.assertEqual(localization.specifiers("%2$@ から %1$lld 件"), ["lld", "@"])
        with self.assertRaises(ValueError):
            localization.specifiers("%1$@ and %@")

    def test_complete_catalog_passes(self):
        catalog = {"sourceLanguage": "en", "strings": {"Hello %@": complete("你好 %@"), "": {"shouldTranslate": False}}}
        self.assertEqual(localization.catalog_problems({"Hello %@", ""}, catalog), [])

    def test_missing_stale_untranslated_and_wrong_placeholders_all_fail(self):
        partial = complete("x")
        partial["localizations"]["ko"]["stringUnit"]["state"] = "new"
        catalog = {"sourceLanguage": "en", "strings": {
            "Old": complete("旧"), "Partial": partial, "%lld left": complete("还剩 %@")}}
        problems = "\n".join(localization.catalog_problems({"New", "Partial", "%lld left"}, catalog))
        self.assertIn("missing from the catalog: 'New'", problems)
        self.assertIn("stale (no source uses it): 'Old'", problems)
        self.assertIn("ko: no translation for 'Partial'", problems)
        self.assertIn("placeholders differ for '%lld left'", problems)

    def test_info_plist_english_must_match_the_bundle_template(self):
        key = "NSMicrophoneUsageDescription"
        catalog = {"sourceLanguage": "en", "strings": {key: complete("x")}}
        catalog["strings"][key]["localizations"]["en"] = {"stringUnit": {"state": "translated", "value": "Old text"}}
        script = f"<key>{key}</key><string>New text</string>"
        self.assertTrue(any("differs" in p for p in localization.info_plist_problems(catalog, script)))
        self.assertEqual(localization.info_plist_problems(catalog, script.replace("New", "Old")), [])

    def test_source_keys_skip_unshipped_targets_and_refuse_an_empty_build(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):
                localization.source_keys(d)
            for target, name, key in (
                ("MochiApp-p.build", "File", "Shipped"), ("mochi-mcp-p.build", "File", "Helper only"),
                ("MochiApp-p.build", "GeneratedStringSymbols_Localizable", "Echoed from the catalog"),
            ):
                folder = Path(d) / target / "Objects-normal" / "arm64"
                folder.mkdir(parents=True, exist_ok=True)
                (folder / f"{name}.stringsdata").write_text(
                    json.dumps({"tables": {"Localizable": [{"key": key}]}}))
            self.assertEqual(localization.source_keys(d), {"Shipped"})


if __name__ == "__main__":
    unittest.main()
