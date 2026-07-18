#!/usr/bin/env python3
"""Generate TerminalCore's pinned Unicode width, grapheme, and test tables."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import urllib.request


UNICODE_VERSION = "17.0.0"
FILES = {
    "EastAsianWidth.txt": (
        f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/EastAsianWidth.txt",
        "ea7ce50f3444a050333448dffef1cadd9325af55cbb764b4a2280faf52170a33",
    ),
    "UnicodeData.txt": (
        f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/UnicodeData.txt",
        "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c",
    ),
    "emoji-data.txt": (
        f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/emoji/emoji-data.txt",
        "2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b",
    ),
    "GraphemeBreakProperty.txt": (
        f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/auxiliary/GraphemeBreakProperty.txt",
        "d6b51d1d2ae5c33b451b7ed994b48f1f4dc62b2272a5831e7fd418514a6bae89",
    ),
    "DerivedCoreProperties.txt": (
        f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/DerivedCoreProperties.txt",
        "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08",
    ),
    "emoji-variation-sequences.txt": (
        f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/emoji/emoji-variation-sequences.txt",
        "bb3d09ef03f206012c7532dd52dc0a21c9efddba0135ea4cf0d9201b8b9bba7e",
    ),
    "GraphemeBreakTest.txt": (
        f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/auxiliary/GraphemeBreakTest.txt",
        "e2d134d2c52919bace503ebb6a551c1855fe1a1faec18478c78fff254a1793ec",
    ),
}
MAX_SCALAR = 0x10FFFF

GRAPHEME_CLASS_VALUES = {
    "Other": 0,
    "Control": 1,
    "Prepend": 2,
    "CR": 3,
    "LF": 4,
    "Regional_Indicator": 5,
    "SpacingMark": 6,
    "L": 7,
    "V": 8,
    "T": 9,
    "LV": 10,
    "LVT": 11,
    "ZWJ": 12,
    "ZWNJ": 13,
    "Extended_Pictographic": 14,
    "InCB_Extend": 15,
    "InCB_Linker": 16,
    "InCB_Consonant": 17,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--data-dir",
        type=Path,
        help="read already-downloaded Unicode files from this directory",
    )
    return parser.parse_args()


def verified_data(data_dir: Path | None) -> dict[str, str]:
    contents: dict[str, str] = {}
    for name, (url, expected_hash) in FILES.items():
        if data_dir is None:
            with urllib.request.urlopen(url) as response:
                data = response.read()
        else:
            data = (data_dir / name).read_bytes()
        actual_hash = hashlib.sha256(data).hexdigest()
        if actual_hash != expected_hash:
            raise RuntimeError(f"{name}: expected sha256 {expected_hash}, got {actual_hash}")
        contents[name] = data.decode("utf-8")
    return contents


def parse_codepoint_range(value: str) -> tuple[int, int]:
    parts = value.strip().split("..")
    lower = int(parts[0], 16)
    upper = int(parts[-1], 16)
    return lower, upper


def merge_ranges(ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
    merged: list[tuple[int, int]] = []
    for lower, upper in sorted(ranges):
        if merged and lower <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(upper, merged[-1][1]))
        else:
            merged.append((lower, upper))
    return merged


def parse_zero_width_ranges(text: str) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    pending: tuple[int, str] | None = None
    for line in text.splitlines():
        fields = line.split(";")
        codepoint = int(fields[0], 16)
        name = fields[1]
        category = fields[2]
        if name.endswith(", First>"):
            pending = (codepoint, category)
        elif name.endswith(", Last>"):
            if pending is None or pending[1] != category:
                raise RuntimeError(f"unmatched UnicodeData range ending at {fields[0]}")
            if category in {"Mn", "Me", "Cf"}:
                result.append((pending[0], codepoint))
            pending = None
        elif category in {"Mn", "Me", "Cf"}:
            result.append((codepoint, codepoint))
    if pending is not None:
        raise RuntimeError("unterminated UnicodeData range")
    return merge_ranges(result)


def parse_property_ranges(text: str, accepted: set[str]) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        codepoints, property_name = (part.strip() for part in line.split(";", 1))
        if property_name in accepted:
            result.append(parse_codepoint_range(codepoints))
    return merge_ranges(result)


def parse_named_property_ranges(text: str) -> dict[str, list[tuple[int, int]]]:
    result: dict[str, list[tuple[int, int]]] = {}
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line or line.startswith("@missing"):
            continue
        codepoints, property_name = (part.strip() for part in line.split(";", 1))
        result.setdefault(property_name, []).append(parse_codepoint_range(codepoints))
    return {name: merge_ranges(ranges) for name, ranges in result.items()}


def parse_incb_ranges(text: str) -> dict[str, list[tuple[int, int]]]:
    result: dict[str, list[tuple[int, int]]] = {}
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line or "; InCB;" not in line:
            continue
        fields = [part.strip() for part in line.split(";")]
        result.setdefault(fields[2], []).append(parse_codepoint_range(fields[0]))
    return {name: merge_ranges(ranges) for name, ranges in result.items()}


def parse_emoji_variation_bases(text: str) -> list[tuple[int, int]]:
    values: set[int] = set()
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        sequence = line.split(";", 1)[0].strip().split()
        if len(sequence) != 2 or sequence[1] not in {"FE0E", "FE0F"}:
            raise RuntimeError(f"unexpected emoji variation sequence: {raw_line}")
        values.add(int(sequence[0], 16))
    return merge_ranges((value, value) for value in values)


def folded_grapheme_classes(
    grapheme_properties: dict[str, list[tuple[int, int]]],
    incb_properties: dict[str, list[tuple[int, int]]],
    pictographic: list[tuple[int, int]],
) -> bytearray:
    classes = bytearray(MAX_SCALAR + 1)

    for name, ranges in grapheme_properties.items():
        class_name = "ZWNJ" if name == "Extend" else name
        value = GRAPHEME_CLASS_VALUES[class_name]
        for lower, upper in ranges:
            classes[lower : upper + 1] = bytes([value]) * (upper - lower + 1)

    for lower, upper in incb_properties.get("Extend", []):
        classes[lower : upper + 1] = bytes(
            [GRAPHEME_CLASS_VALUES["InCB_Extend"]]
        ) * (upper - lower + 1)
    classes[0x200D] = GRAPHEME_CLASS_VALUES["ZWJ"]

    for property_name, class_name in (
        ("Linker", "InCB_Linker"),
        ("Consonant", "InCB_Consonant"),
    ):
        value = GRAPHEME_CLASS_VALUES[class_name]
        for lower, upper in incb_properties.get(property_name, []):
            classes[lower : upper + 1] = bytes([value]) * (upper - lower + 1)

    for lower, upper in pictographic:
        classes[lower : upper + 1] = bytes(
            [GRAPHEME_CLASS_VALUES["Extended_Pictographic"]]
        ) * (upper - lower + 1)
    return classes


def reference_grapheme_properties(
    grapheme_text: str,
    incb_text: str,
    emoji_text: str,
    emoji_variation_text: str,
) -> tuple[bytearray, bytearray]:
    classes = bytearray(MAX_SCALAR + 1)
    for raw_line in grapheme_text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        codepoints, property_name = (part.strip() for part in line.split(";", 1))
        class_name = "ZWNJ" if property_name == "Extend" else property_name
        value = GRAPHEME_CLASS_VALUES[class_name]
        lower, upper = parse_codepoint_range(codepoints)
        classes[lower : upper + 1] = bytes([value]) * (upper - lower + 1)

    for raw_line in incb_text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line or "; InCB;" not in line:
            continue
        fields = [part.strip() for part in line.split(";")]
        class_name = {
            "Extend": "InCB_Extend",
            "Linker": "InCB_Linker",
            "Consonant": "InCB_Consonant",
        }[fields[2]]
        lower, upper = parse_codepoint_range(fields[0])
        value = GRAPHEME_CLASS_VALUES[class_name]
        classes[lower : upper + 1] = bytes([value]) * (upper - lower + 1)
    classes[0x200D] = GRAPHEME_CLASS_VALUES["ZWJ"]

    for raw_line in emoji_text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        codepoints, property_name = (part.strip() for part in line.split(";", 1))
        if property_name != "Extended_Pictographic":
            continue
        lower, upper = parse_codepoint_range(codepoints)
        value = GRAPHEME_CLASS_VALUES["Extended_Pictographic"]
        classes[lower : upper + 1] = bytes([value]) * (upper - lower + 1)

    variation_bases = bytearray(MAX_SCALAR + 1)
    for raw_line in emoji_variation_text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        base = int(line.split(";", 1)[0].strip().split()[0], 16)
        variation_bases[base] = 1
    return classes, variation_bases


def byte_runs(values: bytearray) -> list[tuple[int, int, int]]:
    result: list[tuple[int, int, int]] = []
    start = 0
    prior = values[0]
    for value in range(1, len(values)):
        current = values[value]
        if current != prior:
            result.append((start, value - 1, prior))
            start = value
            prior = current
    result.append((start, len(values) - 1, prior))
    return result


def grapheme_boundary_array(ranges: list[tuple[int, int, int]]) -> str:
    values = [value for item in ranges for value in item]
    lines = []
    for index in range(0, len(values), 9):
        chunk = []
        for offset, value in enumerate(values[index : index + 9]):
            chunk.append(str(value) if (index + offset) % 3 == 2 else f"0x{value:X}")
        lines.append(f"        {', '.join(chunk)},")
    return "\n".join(lines)


def boundary_array(ranges: list[tuple[int, int]]) -> str:
    values = [value for item in ranges for value in item]
    lines = []
    for index in range(0, len(values), 8):
        chunk = ", ".join(f"0x{value:X}" for value in values[index : index + 8])
        lines.append(f"        {chunk},")
    return "\n".join(lines)


def production_source(
    zero_width: list[tuple[int, int]],
    wide: list[tuple[int, int]],
    pictographic: list[tuple[int, int]],
    emoji_variation_bases: list[tuple[int, int]],
    grapheme_classes: list[tuple[int, int, int]],
) -> str:
    hashes = ", ".join(f"{name} {digest}" for name, (_, digest) in FILES.items())
    return f'''// Generated by scripts/generate-terminal-unicode-tables.py; do not edit.
// Unicode {UNICODE_VERSION}; source sha256: {hashes}

let terminalUnicodeVersion = "{UNICODE_VERSION}"

/// Protocol widths used by the grid without consulting toolchain Unicode properties.
enum TerminalCellWidth: UInt8, Equatable, Sendable {{
    case zero = 0
    case narrow = 1
    case wide = 2
}}

/// Pinned scalar properties needed to form this slice's terminal cells.
struct TerminalUnicodeProperties: Equatable, Sendable {{
    let cellWidth: TerminalCellWidth
    let isExtendedPictographic: Bool
    let isEmojiVariationBase: Bool
}}

/// Classifies a scalar using the generated Unicode {UNICODE_VERSION} tables.
func terminalUnicodeProperties(for scalar: Unicode.Scalar) -> TerminalUnicodeProperties {{
    let value = scalar.value
    let width: TerminalCellWidth
    if GeneratedUnicodeTables.contains(value, in: GeneratedUnicodeTables.zeroWidth) {{
        width = .zero
    }} else if GeneratedUnicodeTables.contains(value, in: GeneratedUnicodeTables.wide) {{
        width = .wide
    }} else {{
        width = .narrow
    }}
    return TerminalUnicodeProperties(
        cellWidth: width,
        isExtendedPictographic: GeneratedUnicodeTables.contains(
            value,
            in: GeneratedUnicodeTables.extendedPictographic
        ),
        isEmojiVariationBase: GeneratedUnicodeTables.contains(
            value,
            in: GeneratedUnicodeTables.emojiVariationBase
        )
    )
}}

/// Returns the folded UAX #29 class consumed by the streaming segmenter.
func graphemeBreakClass(for scalar: Unicode.Scalar) -> GraphemeBreakClass {{
    GeneratedUnicodeTables.graphemeBreakClass(for: scalar.value)
}}

/// Generated range boundaries kept private so storage can change without API impact.
private enum GeneratedUnicodeTables {{
    static let zeroWidth: [UInt32] = [
{boundary_array(zero_width)}
    ]

    static let wide: [UInt32] = [
{boundary_array(wide)}
    ]

    static let extendedPictographic: [UInt32] = [
{boundary_array(pictographic)}
    ]

    static let emojiVariationBase: [UInt32] = [
{boundary_array(emoji_variation_bases)}
    ]

    static let graphemeBreak: [UInt32] = [
{grapheme_boundary_array(grapheme_classes)}
    ]

    static func contains(_ value: UInt32, in boundaries: [UInt32]) -> Bool {{
        var lower = 0
        var upper = boundaries.count / 2
        while lower < upper {{
            let middle = lower + (upper - lower) / 2
            let start = boundaries[middle * 2]
            let end = boundaries[middle * 2 + 1]
            if value < start {{
                upper = middle
            }} else if value > end {{
                lower = middle + 1
            }} else {{
                return true
            }}
        }}
        return false
    }}

    static func graphemeBreakClass(for value: UInt32) -> GraphemeBreakClass {{
        var lower = 0
        var upper = graphemeBreak.count / 3
        while lower < upper {{
            let middle = lower + (upper - lower) / 2
            let start = graphemeBreak[middle * 3]
            let end = graphemeBreak[middle * 3 + 1]
            if value < start {{
                upper = middle
            }} else if value > end {{
                lower = middle + 1
            }} else {{
                guard let result = GraphemeBreakClass(
                    rawValue: UInt8(graphemeBreak[middle * 3 + 2])
                ) else {{
                    preconditionFailure("Generated grapheme class is invalid")
                }}
                return result
            }}
        }}
        preconditionFailure("Unicode scalar is outside the generated table")
    }}
}}
'''


def reference_ranges(
    zero_width: list[tuple[int, int]],
    wide: list[tuple[int, int]],
    pictographic: list[tuple[int, int]],
) -> list[tuple[int, int, int, bool]]:
    widths = bytearray([1]) * (MAX_SCALAR + 1)
    pictographs = bytearray(MAX_SCALAR + 1)
    for lower, upper in wide:
        widths[lower : upper + 1] = bytes([2]) * (upper - lower + 1)
    for lower, upper in zero_width:
        widths[lower : upper + 1] = bytes([0]) * (upper - lower + 1)
    for lower, upper in pictographic:
        pictographs[lower : upper + 1] = bytes([1]) * (upper - lower + 1)

    result: list[tuple[int, int, int, bool]] = []
    start = 0
    prior = (widths[0], bool(pictographs[0]))
    for value in range(1, MAX_SCALAR + 1):
        current = (widths[value], bool(pictographs[value]))
        if current != prior:
            result.append((start, value - 1, prior[0], prior[1]))
            start = value
            prior = current
    result.append((start, MAX_SCALAR, prior[0], prior[1]))
    return result


def reference_source(ranges: list[tuple[int, int, int, bool]]) -> str:
    entries = "\n".join(
        f"    UnicodeReferenceRange(lowerBound: 0x{lower:X}, upperBound: 0x{upper:X}, "
        f"cellWidth: {width}, isExtendedPictographic: {str(pictographic).lower()}),"
        for lower, upper, width, pictographic in ranges
    )
    return f'''// Generated independently from the official Unicode {UNICODE_VERSION} property files.

/// Exhaustive expected-property run used to validate every Unicode scalar offline.
struct UnicodeReferenceRange {{
    let lowerBound: UInt32
    let upperBound: UInt32
    let cellWidth: UInt8
    let isExtendedPictographic: Bool
}}

let unicodeReferenceRanges: [UnicodeReferenceRange] = [
{entries}
]
'''


def grapheme_reference_ranges(
    classes: bytearray,
    variation_bases: bytearray,
) -> list[tuple[int, int, int, bool]]:
    result: list[tuple[int, int, int, bool]] = []
    start = 0
    prior = (classes[0], bool(variation_bases[0]))
    for value in range(1, MAX_SCALAR + 1):
        current = (classes[value], bool(variation_bases[value]))
        if current != prior:
            result.append((start, value - 1, prior[0], prior[1]))
            start = value
            prior = current
    result.append((start, MAX_SCALAR, prior[0], prior[1]))
    return result


def grapheme_reference_source(ranges: list[tuple[int, int, int, bool]]) -> str:
    entries = "\n".join(
        f"    UnicodeGraphemeReferenceRange(lowerBound: 0x{lower:X}, "
        f"upperBound: 0x{upper:X}, breakClass: {break_class}, "
        f"isEmojiVariationBase: {str(is_variation_base).lower()}),"
        for lower, upper, break_class, is_variation_base in ranges
    )
    return f'''// Generated independently from the official Unicode {UNICODE_VERSION} property files.

/// Exhaustive grapheme-property run used to validate every Unicode scalar offline.
struct UnicodeGraphemeReferenceRange {{
    let lowerBound: UInt32
    let upperBound: UInt32
    let breakClass: UInt8
    let isEmojiVariationBase: Bool
}}

let unicodeGraphemeReferenceRanges: [UnicodeGraphemeReferenceRange] = [
{entries}
]
'''


def parse_grapheme_corpus(text: str) -> list[tuple[int, list[int], list[bool]]]:
    result: list[tuple[int, list[int], list[bool]]] = []
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        tokens = line.split()
        if len(tokens) % 2 == 0:
            raise RuntimeError(f"GraphemeBreakTest line {line_number}: malformed token count")
        boundaries = [token == "÷" for token in tokens[0::2]]
        if any(token not in {"÷", "×"} for token in tokens[0::2]):
            raise RuntimeError(f"GraphemeBreakTest line {line_number}: invalid boundary")
        if not boundaries[0] or not boundaries[-1]:
            raise RuntimeError(f"GraphemeBreakTest line {line_number}: missing edge break")
        scalars = [int(token, 16) for token in tokens[1::2]]
        result.append((line_number, scalars, boundaries))
    return result


def grapheme_corpus_source(cases: list[tuple[int, list[int], list[bool]]]) -> str:
    entries = "\n".join(
        "    GraphemeBreakCorpusFixture("
        f"line: {line}, "
        f"scalars: [{', '.join(f'0x{value:X}' for value in scalars)}], "
        f"boundaries: [{', '.join(str(value).lower() for value in boundaries)}]),"
        for line, scalars, boundaries in cases
    )
    return f'''// Generated from Unicode {UNICODE_VERSION} GraphemeBreakTest.txt; do not edit.

/// One official UAX #29 sequence with every boundary retained verbatim.
struct GraphemeBreakCorpusFixture {{
    let line: Int
    let scalars: [UInt32]
    let boundaries: [Bool]
}}

let graphemeBreakCorpus: [GraphemeBreakCorpusFixture] = [
{entries}
]
'''


def main() -> None:
    args = parse_args()
    data = verified_data(args.data_dir)
    zero_width = parse_zero_width_ranges(data["UnicodeData.txt"])
    wide = parse_property_ranges(data["EastAsianWidth.txt"], {"W", "F"})
    pictographic = parse_property_ranges(data["emoji-data.txt"], {"Extended_Pictographic"})
    emoji_variation_bases = parse_emoji_variation_bases(
        data["emoji-variation-sequences.txt"]
    )
    classes = folded_grapheme_classes(
        parse_named_property_ranges(data["GraphemeBreakProperty.txt"]),
        parse_incb_ranges(data["DerivedCoreProperties.txt"]),
        pictographic,
    )
    reference_classes, reference_variation_bases = reference_grapheme_properties(
        data["GraphemeBreakProperty.txt"],
        data["DerivedCoreProperties.txt"],
        data["emoji-data.txt"],
        data["emoji-variation-sequences.txt"],
    )

    repo_root = Path(__file__).resolve().parents[1]
    production = repo_root / "lib/TerminalCore/Sources/TerminalCore/UnicodeProperties.generated.swift"
    reference = repo_root / "lib/TerminalCore/Tests/TerminalCoreTests/UnicodeReference.generated.swift"
    grapheme_reference = (
        repo_root
        / "lib/TerminalCore/Tests/TerminalCoreTests/GraphemeReference.generated.swift"
    )
    grapheme_corpus = (
        repo_root
        / "lib/TerminalCore/Tests/TerminalCoreTests/GraphemeBreakCorpus.generated.swift"
    )
    production.write_text(
        production_source(
            zero_width,
            wide,
            pictographic,
            emoji_variation_bases,
            byte_runs(classes),
        ),
        encoding="utf-8",
    )
    reference.write_text(
        reference_source(reference_ranges(zero_width, wide, pictographic)),
        encoding="utf-8",
    )
    grapheme_reference.write_text(
        grapheme_reference_source(
            grapheme_reference_ranges(reference_classes, reference_variation_bases)
        ),
        encoding="utf-8",
    )
    grapheme_corpus.write_text(
        grapheme_corpus_source(parse_grapheme_corpus(data["GraphemeBreakTest.txt"])),
        encoding="utf-8",
    )
    print(f"generated {production.relative_to(repo_root)}")
    print(f"generated {reference.relative_to(repo_root)}")
    print(f"generated {grapheme_reference.relative_to(repo_root)}")
    print(f"generated {grapheme_corpus.relative_to(repo_root)}")


if __name__ == "__main__":
    main()
