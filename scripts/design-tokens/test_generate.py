import io
import json
import re
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
                {
                    "name": "Heading",
                    "styles": [{
                        "name": "title",
                        "fontSize": "26px",
                        "lineHeight": "34px",
                        "fontWeight": 800,
                        "letterSpacing": "-0.02em",
                    }],
                }
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
        palettes = dict(re.findall(r"val (light|dark)Colors =\n        Colors\(\n(.*?)\n        \)", kotlin, re.DOTALL))
        self.assertEqual(set(palettes), {"light", "dark"})
        for name in ("colorAlias", "nestedAlias", "surface"):
            with self.subTest(name=name):
                self.assertIn(f"{name} = Color(0xFF123456),", palettes["light"])
                self.assertIn(f"{name} = Color(0xFF010203).copy(alpha = 0.42f),", palettes["dark"])

    def test_swift_color_provider_selects_colors_by_interface_style(self):
        swift = render(token_fixture())[SWIFT].decode()
        self.assertIn("Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light })", swift)

    def test_converts_dimensions_and_typography(self):
        output = render(token_fixture())
        swift = output[SWIFT].decode()
        kotlin = output[KOTLIN].decode()
        self.assertIn("spaceXs: CGFloat = 4.5", swift)
        self.assertIn("title = TypeStyleToken(fontSize: 26, lineHeight: 34, fontWeight: 800, letterSpacing: -0.02)", swift)
        self.assertIn("spaceXs = 4.5.dp", kotlin)
        self.assertIn("title = TypeStyleToken(26.sp, 34.sp, FontWeight(800), (-0.02).em)", kotlin)

    def test_rejects_cycle_with_appearance_and_reference_chain(self):
        tokens = token_fixture()
        tokens["color"]["tokens"][1]["value"]["dark"] = "{color-alias}"
        with self.assertRaisesRegex(ValueError, r"dark.*color-alias -> nested-alias -> surface -> color-alias"):
            render(tokens)

    def test_rejects_alpha_outside_closed_unit_interval(self):
        for alpha in ("-0.01", "1.01"):
            with self.subTest(alpha=alpha):
                tokens = token_fixture()
                tokens["color"]["tokens"][1]["value"]["dark"] = f"rgba(1, 2, 3, {alpha})"
                with self.assertRaisesRegex(ValueError, r"surface.*dark.*Invalid color"):
                    render(tokens)

    def test_accepts_alpha_at_both_endpoints(self):
        tokens = token_fixture()
        tokens["color"]["tokens"][1]["value"] = {"light": "rgba(1, 2, 3, 0)", "dark": "rgba(1, 2, 3, 1)"}
        swift = render(tokens)[SWIFT].decode()
        self.assertIn("surface = adaptive(light: rgb(0x010203, alpha: 0), dark: rgb(0x010203))", swift)

    def test_rejects_distinct_names_that_generate_the_same_identifier(self):
        tokens = token_fixture()
        tokens["size"]["tokens"].extend([{"name": "size-2", "value": "8px"}, {"name": "size2", "value": "16px"}])
        with self.assertRaisesRegex(ValueError, r"Duplicate generated name: size2"):
            render(tokens)

    def test_rejects_duplicate_style_names_across_groups(self):
        tokens = token_fixture()
        heading = tokens["type"]["groups"][0]
        tokens["type"]["groups"].append({"name": "Body", "styles": heading["styles"]})
        with self.assertRaisesRegex(ValueError, r"Duplicate generated name: title"):
            render(tokens)

    def test_rejects_swift_and_kotlin_reserved_identifiers(self):
        for name in ("associatedtype", "when", "class"):
            with self.subTest(name=name):
                tokens = token_fixture()
                tokens["size"]["tokens"][0]["name"] = name
                with self.assertRaisesRegex(ValueError, rf"Reserved generated name: {name}.*size"):
                    render(tokens)

    def test_missing_fields_report_token_group_name_and_field(self):
        tokens = token_fixture()
        color = tokens["color"]["tokens"][1]
        style = tokens["type"]["groups"][0]["styles"][0]
        space = tokens["spacing"]["tokens"][0]
        cases = [
            (color, "value", "color.surface.value"),
            (color["value"], "dark", "color.surface.dark"),
            (style, "fontSize", "type.groups[Heading].title.fontSize"),
            (style, "lineHeight", "type.groups[Heading].title.lineHeight"),
            (style, "fontWeight", "type.groups[Heading].title.fontWeight"),
            (space, "value", "spacing.space-xs.value"),
            (space, "name", "spacing.tokens[0].name"),
        ]
        for token, field, path in cases:
            with self.subTest(path=path):
                value = token.pop(field)
                try:
                    with self.assertRaisesRegex(ValueError, rf"Missing field: {re.escape(path)}"):
                        render(tokens)
                finally:
                    token[field] = value

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
