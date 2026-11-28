import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

from generate import KOTLIN, SWIFT, render, sync


def token_fixture():
    return {
        "color": {
            "tokens": [
                {"name": "color-alias", "value": "{nested-alias}"},
                {"name": "surface", "value": {"light": "#123456", "dark": "rgba(1, 2, 3, .42)"}},
                {"name": "nested-alias", "value": {"light": "{surface}", "dark": "{surface}"}},
            ]
        },
        "type": {
            "groups": [
                {"styles": [{"name": "title", "fontSize": "26px", "lineHeight": "34px",
                             "fontWeight": 800, "letterSpacing": "-0.02em"}]}
            ]
        },
        "spacing": {"tokens": [{"name": "space-xs", "value": "4.5px"}]},
        "radius": {"tokens": [{"name": "radius-s", "value": "8px"}]},
        "size": {"tokens": [{"name": "touch-min", "value": "44px"}]},
    }


class GenerateTests(unittest.TestCase):
    def test_resolves_color_aliases_for_both_appearances(self):
        output = render(token_fixture())
        swift = output[SWIFT].decode()
        kotlin = output[KOTLIN].decode()
        self.assertIn("colorAlias = adaptive(light: rgb(0x123456), dark: rgb(0x010203, alpha: 0.42))", swift)
        self.assertIn("colorAlias = Color(0xFF123456)", kotlin)
        self.assertIn("colorAlias = Color(0xFF010203).copy(alpha = 0.42f)", kotlin)

    def test_converts_dimensions_and_typography(self):
        output = render(token_fixture())
        swift = output[SWIFT].decode()
        kotlin = output[KOTLIN].decode()
        self.assertIn("spaceXs: CGFloat = 4.5", swift)
        self.assertIn("fontSize: 26, lineHeight: 34, fontWeight: 800, letterSpacing: -0.02", swift)
        self.assertIn("spaceXs = 4.5.dp", kotlin)
        self.assertIn("26.sp, 34.sp, FontWeight(800), (-0.02).em", kotlin)

    def test_rejects_cycle_with_appearance_and_reference_chain(self):
        tokens = token_fixture()
        tokens["color"]["tokens"][1]["value"]["dark"] = "{color-alias}"
        with self.assertRaisesRegex(ValueError, r"dark.*color-alias -> nested-alias -> surface -> color-alias"):
            render(tokens)

    def test_output_is_independent_of_token_order(self):
        tokens = token_fixture()
        original = render(tokens)
        tokens["color"]["tokens"].reverse()
        self.assertEqual(original, render(tokens))

    def test_check_reports_changed_and_missing_outputs_without_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "design").mkdir()
            (root / "design/tokens.json").write_text(json.dumps(token_fixture()), encoding="utf-8")
            self.assertEqual(sync(root, check=False), 0)
            self.assertEqual(sync(root, check=True), 0)
            changed = b"// stale contents\n"
            (root / SWIFT).write_bytes(changed)
            (root / KOTLIN).unlink()

            diagnostics = io.StringIO()
            with redirect_stderr(diagnostics):
                self.assertEqual(sync(root, check=True), 1)

            self.assertIn(f"--- {SWIFT}", diagnostics.getvalue())
            self.assertIn("-// stale contents", diagnostics.getvalue())
            self.assertIn(f"+++ {KOTLIN} (generated)", diagnostics.getvalue())
            self.assertIn("mise run design:tokens", diagnostics.getvalue())
            self.assertEqual((root / SWIFT).read_bytes(), changed)
            self.assertFalse((root / KOTLIN).exists())
