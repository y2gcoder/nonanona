"""Render the design system export as native mobile constants."""

import argparse
import difflib
import json
import re
import sys
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path


SOURCE = Path("design/tokens.json")
SWIFT = Path("apps/ios/Nonanona/Design/DesignTokens.swift")
KOTLIN = Path("apps/android/app/src/main/java/app/nonanona/design/DesignTokens.kt")
DIMENSIONS = ("Spacing", "Radius", "Size")
HEADER = "// 생성 파일. 직접 수정하지 마세요.\n// 원본: design/tokens.json\n// 생성: mise run design:tokens"
TOKEN_NAME = re.compile(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*")
NUMBER = r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)"
RGBA = re.compile(rf"rgba\(\s*([0-9]{{1,3}})\s*,\s*([0-9]{{1,3}})\s*,\s*([0-9]{{1,3}})\s*,\s*({NUMBER})\s*\)")


@dataclass(frozen=True)
class Color:
    rgb: int
    alpha: Decimal = Decimal(1)

    def swift(self):
        if self.alpha == 1:
            return f"rgb(0x{self.rgb:06X})"
        return f"rgb(0x{self.rgb:06X}, alpha: {literal(self.alpha)})"

    def kotlin(self):
        color = f"Color(0xFF{self.rgb:06X})"
        if self.alpha == 1:
            return color
        return f"{color}.copy(alpha = {literal(self.alpha)}f)"


def literal(number):
    if number == 0:
        return "0"
    text = format(number, "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


def camel_case(name):
    first, *rest = name.split("-")
    return first + "".join(part.capitalize() for part in rest)


def named_tokens(entries):
    tokens = {}
    identifiers = set()
    for token in entries:
        name = token["name"]
        if not TOKEN_NAME.fullmatch(name):
            raise ValueError(f"Invalid token name: {name!r}")
        identifier = camel_case(name)
        if identifier in identifiers:
            raise ValueError(f"Duplicate generated name: {identifier} (from {name})")
        identifiers.add(identifier)
        tokens[name] = token
    return dict(sorted(tokens.items()))


def parse_color(value):
    if re.fullmatch(r"#[0-9a-fA-F]{6}", value):
        return Color(int(value[1:], 16))
    match = RGBA.fullmatch(value)
    if match:
        channels = [int(channel) for channel in match.groups()[:3]]
        alpha = Decimal(match[4])
        if max(channels) <= 255 and 0 <= alpha <= 1:
            return Color(int.from_bytes(bytes(channels), "big"), alpha)
    raise ValueError(f"Invalid color: {value!r}")


def resolve_colors(entries):
    tokens = named_tokens(entries)

    def resolve(name, theme, trail=()):
        chain = " -> ".join((*trail, name))
        if name in trail:
            raise ValueError(f"Circular color reference ({theme}): {chain}")
        if name not in tokens:
            raise ValueError(f"Unknown color reference ({theme}): {chain}")
        value = tokens[name]["value"]
        if isinstance(value, dict):
            if theme not in value:
                raise ValueError(f"Missing color value ({theme}): {chain}")
            value = value[theme]
        if isinstance(value, str):
            reference = re.fullmatch(r"\{([^{}]+)\}", value)
            if reference:
                return resolve(reference[1], theme, (*trail, name))
            try:
                return parse_color(value)
            except ValueError as error:
                raise ValueError(f"{chain} ({theme}): {error}") from error
        raise ValueError(f"Invalid color value ({theme}, {chain}): {value!r}")

    return {
        camel_case(name): (resolve(name, "light"), resolve(name, "dark"))
        for name in tokens
    }


def measure(value, unit, field):
    match = re.fullmatch(rf"({NUMBER}){unit}", value)
    if not match:
        raise ValueError(f"{field}: expected a number in {unit}, got {value!r}")
    return literal(Decimal(match[1]))


@dataclass(frozen=True)
class TypeStyle:
    font_size: str
    line_height: str
    font_weight: int
    letter_spacing: str

    @classmethod
    def from_token(cls, token):
        name = token["name"]
        weight = token["fontWeight"]
        if type(weight) is not int or not 1 <= weight <= 1000:
            raise ValueError(f"{name}.fontWeight: expected an integer from 1 to 1000")
        return cls(
            measure(token["fontSize"], "px", f"{name}.fontSize"),
            measure(token["lineHeight"], "px", f"{name}.lineHeight"),
            weight,
            measure(token.get("letterSpacing", "0em"), "em", f"{name}.letterSpacing"),
        )

    def swift(self):
        return (
            f"fontSize: {self.font_size}, lineHeight: {self.line_height}, "
            f"fontWeight: {self.font_weight}, letterSpacing: {self.letter_spacing}"
        )

    def kotlin(self):
        spacing = self.letter_spacing
        if spacing.startswith("-"):
            spacing = f"({spacing})"
        return f"{self.font_size}.sp, {self.line_height}.sp, FontWeight({self.font_weight}), {spacing}.em"


def swift_source(colors, styles, dimensions):
    color_lines = "\n".join(
        f"    static let {name} = adaptive(light: {light.swift()}, dark: {dark.swift()})"
        for name, (light, dark) in colors.items()
    )
    type_lines = "\n".join(
        f"    static let {name} = TextStyle({style.swift()})" for name, style in styles.items()
    )
    dimension_blocks = []
    for group, tokens in dimensions.items():
        lines = "\n".join(f"    static let {name}: CGFloat = {value}" for name, value in tokens.items())
        dimension_blocks.append(f"  enum {group} {{\n{lines}\n  }}")
    dimension_source = "\n\n".join(dimension_blocks)

    return f"""{HEADER}
import SwiftUI
import UIKit

enum DesignTokens {{
  enum Colors {{
{color_lines}

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {{
      Color(uiColor: UIColor {{ traits in traits.userInterfaceStyle == .dark ? dark : light }})
    }}

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {{
      UIColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
      )
    }}
  }}

  struct TextStyle {{
    let fontSize: CGFloat
    let lineHeight: CGFloat
    let fontWeight: Int
    let letterSpacing: CGFloat
  }}

  enum Typography {{
{type_lines}
  }}

{dimension_source}
}}
"""


def kotlin_source(colors, styles, dimensions):
    color_fields = "\n".join(f"        val {name}: Color," for name in colors)
    palettes = []
    for index, theme in enumerate(("light", "dark")):
        lines = "\n".join(f"            {name} = {pair[index].kotlin()}," for name, pair in colors.items())
        palettes.append(f"    val {theme}Colors =\n        Colors(\n{lines}\n        )")
    palette_source = "\n\n".join(palettes)
    type_lines = "\n".join(
        f"        val {name} = TextStyle({style.kotlin()})" for name, style in styles.items()
    )
    dimension_blocks = []
    for group, tokens in dimensions.items():
        lines = "\n".join(f"        val {name} = {value}.dp" for name, value in tokens.items())
        dimension_blocks.append(f"    object {group} {{\n{lines}\n    }}")
    dimension_source = "\n\n".join(dimension_blocks)

    return f"""{HEADER}
package app.nonanona.design

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp

internal object DesignTokens {{
    class Colors(
{color_fields}
    )

{palette_source}

    data class TextStyle(
        val fontSize: TextUnit,
        val lineHeight: TextUnit,
        val fontWeight: FontWeight,
        val letterSpacing: TextUnit,
    )

    object Typography {{
{type_lines}
    }}

{dimension_source}
}}
"""


def render(tokens):
    colors = resolve_colors(tokens["color"]["tokens"])
    styles = named_tokens(style for group in tokens["type"]["groups"] for style in group["styles"])
    typography = {camel_case(name): TypeStyle.from_token(style) for name, style in styles.items()}
    dimensions = {
        group: {
            camel_case(name): measure(token["value"], "px", name)
            for name, token in named_tokens(tokens[group.lower()]["tokens"]).items()
        }
        for group in DIMENSIONS
    }
    return {
        SWIFT: swift_source(colors, typography, dimensions).encode("utf-8"),
        KOTLIN: kotlin_source(colors, typography, dimensions).encode("utf-8"),
    }


def sync(root, *, check):
    tokens = json.loads((root / SOURCE).read_text(encoding="utf-8"))
    drift = False
    for relative_path, generated in render(tokens).items():
        path = root / relative_path
        try:
            current = path.read_bytes()
        except FileNotFoundError:
            current = b""
        if current == generated:
            continue
        if check:
            drift = True
            diff = difflib.diff_bytes(
                difflib.unified_diff,
                current.splitlines(keepends=True),
                generated.splitlines(keepends=True),
                str(relative_path).encode(),
                f"{relative_path} (generated)".encode(),
            )
            for line in diff:
                sys.stderr.write(line.decode("utf-8", errors="replace"))
                if not line.endswith(b"\n"):
                    print("\n\\ No newline at end of file", file=sys.stderr)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(generated)
    if drift:
        print("토큰 생성 결과가 다릅니다. mise run design:tokens 실행 후 생성 파일을 커밋하세요.", file=sys.stderr)
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="compare with the generated files without writing")
    args = parser.parse_args()
    try:
        return sync(Path(__file__).resolve().parents[2], check=args.check)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"디자인 토큰 생성 오류: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
