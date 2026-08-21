#!/usr/bin/env python3
"""Generate TerminalCore's pinned Unicode width, grapheme, search, and test tables."""

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
    "CaseFolding.txt": (
        f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/CaseFolding.txt",
        "ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183",
    ),
    "NormalizationTest.txt": (
        f"https://www.unicode.org/Public/{UNICODE_VERSION}/ucd/NormalizationTest.txt",
        "5019ffd530751a741900c849c0e010332f142a3612234639bd200b82138a87db",
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

# Swift case names for the two enums the emitted palette spells out. The class
# names key off the table above so the raw values are still stated once.
GRAPHEME_CLASS_CASE_NAMES = {
    "Other": "other",
    "Control": "control",
    "Prepend": "prepend",
    "CR": "cr",
    "LF": "lf",
    "Regional_Indicator": "regionalIndicator",
    "SpacingMark": "spacingMark",
    "L": "l",
    "V": "v",
    "T": "t",
    "LV": "lv",
    "LVT": "lvt",
    "ZWJ": "zwj",
    "ZWNJ": "zwnj",
    "Extended_Pictographic": "extendedPictographic",
    "InCB_Extend": "indicConjunctBreakExtend",
    "InCB_Linker": "indicConjunctBreakLinker",
    "InCB_Consonant": "indicConjunctBreakConsonant",
}
GRAPHEME_CLASS_CASES = {
    value: GRAPHEME_CLASS_CASE_NAMES[name] for name, value in GRAPHEME_CLASS_VALUES.items()
}
CELL_WIDTH_CASES = {0: "zero", 1: "narrow", 2: "wide"}


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


def integer_array(values: list[int], values_per_line: int = 12) -> str:
    lines = []
    for index in range(0, len(values), values_per_line):
        chunk = ", ".join(str(value) for value in values[index : index + values_per_line])
        lines.append(f"        {chunk},")
    return "\n".join(lines)


def hexadecimal_array(values: list[int], values_per_line: int = 10) -> str:
    lines = []
    for index in range(0, len(values), values_per_line):
        chunk = ", ".join(f"0x{value:X}" for value in values[index : index + values_per_line])
        lines.append(f"        {chunk},")
    return "\n".join(lines)


def boolean_array(values: list[bool], values_per_line: int = 12) -> str:
    lines = []
    for index in range(0, len(values), values_per_line):
        chunk = ", ".join(
            str(value).lower() for value in values[index : index + values_per_line]
        )
        lines.append(f"        {chunk},")
    return "\n".join(lines)


def parse_canonical_data(text: str) -> tuple[dict[int, list[int]], dict[int, int]]:
    """Reads the canonical decompositions and the non-zero combining classes.

    Compatibility decompositions carry a `<tag>` prefix and are dropped: the
    search key is NFD, not NFKD.
    """
    decompositions: dict[int, list[int]] = {}
    combining_classes: dict[int, int] = {}
    for raw_line in text.splitlines():
        fields = raw_line.split(";")
        scalar = int(fields[0], 16)
        combining_class = int(fields[3])
        decomposition = fields[5]
        if combining_class != 0:
            combining_classes[scalar] = combining_class
        if decomposition and not decomposition.startswith("<"):
            decompositions[scalar] = [int(value, 16) for value in decomposition.split()]
    return decompositions, combining_classes


def fully_resolved_decompositions(
    decompositions: dict[int, list[int]],
) -> dict[int, list[int]]:
    """Expands each canonical decomposition until no component decomposes further.

    Resolving here is what lets the runtime walk a decomposition as a flat pool
    slice instead of recursing through the table per component. Unicode
    guarantees the canonical mapping graph is acyclic, and the depth bound below
    turns a corrupt input into a loud failure rather than a hang.
    """
    resolved: dict[int, list[int]] = {}

    def resolve(scalar: int, depth: int) -> list[int]:
        if depth > 32:
            raise RuntimeError(f"canonical decomposition of U+{scalar:04X} does not terminate")
        mapping = decompositions.get(scalar)
        if mapping is None:
            return [scalar]
        components: list[int] = []
        for component in mapping:
            components.extend(resolve(component, depth + 1))
        return components

    for scalar in decompositions:
        resolved[scalar] = resolve(scalar, 0)
    return resolved


def parse_full_case_folding(text: str) -> dict[int, list[int]]:
    mappings: dict[int, list[int]] = {}
    for raw_line in text.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        scalar_text, status, mapping_text, _ = (
            part.strip() for part in line.split(";", 3)
        )
        if status in {"C", "F"}:
            mappings[int(scalar_text, 16)] = [
                int(value, 16) for value in mapping_text.split()
            ]
    return mappings


class ScalarPool:
    """Interns scalar runs so identical mappings share one slice of the emitted pool.

    Records carry a start and a length into this pool, and the many scalars that
    fold or decompose to the same run -- every mapping to a bare ASCII letter,
    for one -- then cost nothing beyond the record they share.
    """

    def __init__(self) -> None:
        self.values: list[int] = []
        self._starts: dict[tuple[int, ...], int] = {}

    def intern(self, run: list[int]) -> tuple[int, int]:
        if not run:
            return (0, 0)
        key = tuple(run)
        start = self._starts.get(key)
        if start is None:
            start = len(self.values)
            self._starts[key] = start
            self.values.extend(run)
        return (start, len(run))


# One scalar's whole canonical-caseless answer: combining class, then the start
# and length of its fully resolved canonical decomposition and of its full case
# fold in their pools. A zero length means "no mapping", which is why the
# absence of a decomposition and the absence of a fold are one lookup apart.
CanonicalCaselessRecord = tuple[int, int, int, int, int]


def canonical_caseless_records(
    decompositions: dict[int, list[int]],
    combining_classes: dict[int, int],
    case_folding: dict[int, list[int]],
) -> tuple[list[CanonicalCaselessRecord], ScalarPool, ScalarPool]:
    """Builds one record per scalar in the codespace, plus the two pools they index.

    Hangul syllables are left with no decomposition on purpose: the runtime
    decomposes them arithmetically, and spelling out all 11,172 mappings would
    add a pool entry per syllable to buy nothing.
    """
    decomposition_pool = ScalarPool()
    fold_pool = ScalarPool()
    records: list[CanonicalCaselessRecord] = []
    for value in range(MAX_SCALAR + 1):
        decomposition = decompositions.get(value)
        fold = case_folding.get(value)
        decomposition_start, decomposition_length = (
            decomposition_pool.intern(decomposition) if decomposition else (0, 0)
        )
        fold_start, fold_length = fold_pool.intern(fold) if fold else (0, 0)
        records.append(
            (
                combining_classes.get(value, 0),
                decomposition_start,
                decomposition_length,
                fold_start,
                fold_length,
            )
        )
    return records, decomposition_pool, fold_pool


def canonical_caseless_source(
    packed: PackedClassificationTables,
    decomposition_pool: ScalarPool,
    fold_pool: ScalarPool,
) -> str:
    combining_classes = [record[0] for record in packed.palette]
    decomposition_starts = [record[1] for record in packed.palette]
    decomposition_lengths = [record[2] for record in packed.palette]
    fold_starts = [record[3] for record in packed.palette]
    fold_lengths = [record[4] for record in packed.palette]
    pool_index_type = index_element_type(
        max(len(decomposition_pool.values), len(fold_pool.values)), "caseless pool offset"
    )
    hashes = ", ".join(
        f"{name} {FILES[name][1]}"
        for name in ("UnicodeData.txt", "CaseFolding.txt")
    )
    mask = (1 << packed.shift) - 1
    return f'''// Generated by scripts/generate-terminal-unicode-tables.py; do not edit.
// Unicode {UNICODE_VERSION}; source sha256: {hashes}
//
// Flat, explicitly typed parallel arrays: nested or tuple-shaped literals at this
// scale drive swift-frontend's constraint solver into multi-gigabyte territory,
// while flat homogeneous integer literals typecheck linearly (the same shape as
// GeneratedPackedUnicodeTables, proven at 31k+ elements). That is also why the
// record palette is five parallel arrays rather than an array of structs.

/// One scalar's pinned canonical-caseless facts, so the search key path asks the
/// tables once per scalar instead of searching a sorted array per question.
struct CanonicalCaselessRecord {{
    let combiningClass: UInt8
    let decompositionStart: Int
    let decompositionLength: Int
    let foldStart: Int
    let foldLength: Int

    /// True when the scalar is its own canonical caseless key on its own. Hangul
    /// syllables also satisfy this test and are excluded by the caller, because
    /// their decomposition is arithmetic and therefore absent from the table.
    var mapsToItself: Bool {{
        combiningClass == 0 && decompositionLength == 0 && foldLength == 0
    }}
}}

/// Owns the pinned per-scalar records and the two scalar pools they index.
enum GeneratedCanonicalCaselessTables {{
    static let decompositionPool: [UInt32] = [
{hexadecimal_array(decomposition_pool.values)}
    ]
    static let foldPool: [UInt32] = [
{hexadecimal_array(fold_pool.values)}
    ]

    /// Reads one scalar's record through the two index stages. The stages hold
    /// palette indexes, so every value they can produce is a record the
    /// generator emitted and the read has no failure path.
    static func record(for value: UInt32) -> CanonicalCaselessRecord {{
        let block = Int(stageOne[Int(value >> {packed.shift})])
        let index = Int(stageTwo[(block << {packed.shift}) | Int(value & 0x{mask:X})])
        return CanonicalCaselessRecord(
            combiningClass: combiningClasses[index],
            decompositionStart: Int(decompositionStarts[index]),
            decompositionLength: Int(decompositionLengths[index]),
            foldStart: Int(foldStarts[index]),
            foldLength: Int(foldLengths[index])
        )
    }}

    static let combiningClasses: [UInt8] = [
{integer_array(combining_classes)}
    ]
    static let decompositionStarts: [{pool_index_type}] = [
{integer_array(decomposition_starts)}
    ]
    static let decompositionLengths: [UInt8] = [
{integer_array(decomposition_lengths)}
    ]
    static let foldStarts: [{pool_index_type}] = [
{integer_array(fold_starts)}
    ]
    static let foldLengths: [UInt8] = [
{integer_array(fold_lengths)}
    ]

    static let stageOne: [{packed.stage_one_type}] = [
{integer_array(packed.stage_one)}
    ]

    static let stageTwo: [{packed.stage_two_type}] = [
{integer_array(packed.stage_two)}
    ]
}}
'''


def combining_class_reference_ranges(text: str) -> list[tuple[int, int, int]]:
    """Re-derives the combining class of every scalar straight from UnicodeData.txt.

    The production table reaches its answer through interning, a palette, and two
    index stages. This walk shares none of that, so a packing bug shows up as a
    disagreement rather than as the same wrong answer on both sides.
    """
    classes = bytearray(MAX_SCALAR + 1)
    for raw_line in text.splitlines():
        fields = raw_line.split(";")
        classes[int(fields[0], 16)] = int(fields[3])
    ranges: list[tuple[int, int, int]] = []
    start = 0
    for value in range(1, MAX_SCALAR + 1):
        if classes[value] != classes[start]:
            ranges.append((start, value - 1, classes[start]))
            start = value
    ranges.append((start, MAX_SCALAR, classes[start]))
    return ranges


def combining_class_reference_source(ranges: list[tuple[int, int, int]]) -> str:
    lower_bounds = [lower for lower, _, _ in ranges]
    upper_bounds = [upper for _, upper, _ in ranges]
    values = [value for _, _, value in ranges]
    return f'''// Generated independently from the official Unicode {UNICODE_VERSION} property files.
//
// Flat, explicitly typed parallel arrays: an array-of-initializer literal at this
// scale costs gigabytes of swift-frontend memory to typecheck, while flat
// homogeneous literals typecheck linearly. The structs are rebuilt at runtime.

/// Exhaustive expected combining class run used to validate every Unicode scalar offline.
struct CanonicalCombiningClassReferenceRange {{
    let lowerBound: UInt32
    let upperBound: UInt32
    let combiningClass: UInt8
}}

let canonicalCombiningClassReferenceRanges: [CanonicalCombiningClassReferenceRange] =
    CanonicalCombiningClassReferenceTables.lowerBounds.indices.map {{
        CanonicalCombiningClassReferenceRange(
            lowerBound: CanonicalCombiningClassReferenceTables.lowerBounds[$0],
            upperBound: CanonicalCombiningClassReferenceTables.upperBounds[$0],
            combiningClass: CanonicalCombiningClassReferenceTables.combiningClasses[$0]
        )
    }}

private enum CanonicalCombiningClassReferenceTables {{
    static let lowerBounds: [UInt32] = [
{hexadecimal_array(lower_bounds)}
    ]
    static let upperBounds: [UInt32] = [
{hexadecimal_array(upper_bounds)}
    ]
    static let combiningClasses: [UInt8] = [
{integer_array(values)}
    ]
}}
'''


# One scalar's fully decoded classification: cell width, the three emoji flags,
# and the folded grapheme class. Distinct values of this tuple form the palette.
ClassificationRecord = tuple[int, bool, bool, bool, int]

ELEMENT_BYTES = {"UInt8": 1, "UInt16": 2}


def index_element_type(largest: int, what: str) -> str:
    """Picks the narrowest emitted element type that can hold every index.

    A Unicode revision that outgrows UInt16 stops the generator here rather than
    silently truncating an index in the emitted table.
    """
    if largest <= 0xFF:
        return "UInt8"
    if largest <= 0xFFFF:
        return "UInt16"
    raise RuntimeError(f"packed Unicode table {what} {largest} exceeds UInt16")


class PackedClassificationTables:
    """The whole emitted layout: a record palette behind two index stages.

    The block shift and the two index element types live here and nowhere else,
    so the emitted Swift derives its shift, mask, and array types from the same
    values the packer used.
    """

    def __init__(
        self,
        palette: list[ClassificationRecord],
        stage_one: list[int],
        stage_two: list[int],
        shift: int,
    ):
        self.palette = palette
        self.stage_one = stage_one
        self.stage_two = stage_two
        self.shift = shift
        self.stage_one_type = index_element_type(max(stage_one), "block index")
        self.stage_two_type = index_element_type(len(palette) - 1, "palette index")

    @property
    def byte_size(self) -> int:
        return (
            len(self.stage_one) * ELEMENT_BYTES[self.stage_one_type]
            + len(self.stage_two) * ELEMENT_BYTES[self.stage_two_type]
        )


def classification_records(
    zero_width: list[tuple[int, int]],
    wide: list[tuple[int, int]],
    pictographic: list[tuple[int, int]],
    emoji_modifiers: list[tuple[int, int]],
    emoji_variation_bases: list[tuple[int, int]],
    grapheme_classes: bytearray,
) -> list[ClassificationRecord]:
    """Builds one fully decoded record per scalar: width, three emoji flags, class."""
    widths = bytearray([1]) * (MAX_SCALAR + 1)
    for lower, upper in wide:
        widths[lower : upper + 1] = bytes([2]) * (upper - lower + 1)
    for lower, upper in zero_width:
        widths[lower : upper + 1] = bytes([0]) * (upper - lower + 1)
    flags = [bytearray(MAX_SCALAR + 1) for _ in range(3)]
    for target, ranges in zip(flags, (pictographic, emoji_modifiers, emoji_variation_bases)):
        for lower, upper in ranges:
            target[lower : upper + 1] = bytes([1]) * (upper - lower + 1)
    # Slice assignment past the end would grow the array instead of raising, so a
    # range above MAX_SCALAR would silently add scalars rather than fail.
    for table in [widths, *flags]:
        if len(table) != MAX_SCALAR + 1:
            raise RuntimeError("a parsed range reaches past the last Unicode scalar")
    return [
        (
            widths[value],
            bool(flags[0][value]),
            bool(flags[1][value]),
            bool(flags[2][value]),
            grapheme_classes[value],
        )
        for value in range(MAX_SCALAR + 1)
    ]


def packed_classification_tables(
    records: list[ClassificationRecord],
) -> PackedClassificationTables:
    """Packs the records into the smallest two-stage layout over the shift range.

    Scalars share far fewer distinct records than there are scalars, so the
    stages carry palette indexes and the shift is chosen by measuring emitted
    bytes rather than fixed by hand. Nothing here reads a record's fields, so
    both the feed path's classification and the search path's canonical-caseless
    record pack through this one function.
    """
    palette: list[ClassificationRecord] = []
    palette_indexes: dict[ClassificationRecord, int] = {}
    indexed: list[int] = []
    for record in records:
        index = palette_indexes.get(record)
        if index is None:
            index = len(palette)
            palette_indexes[record] = index
            palette.append(record)
        indexed.append(index)
    # No shift can shrink the palette, so an oversized one fails here and says so
    # rather than surfacing as "no shift fits" once the search comes up empty.
    index_element_type(len(palette) - 1, "palette index")

    smallest: PackedClassificationTables | None = None
    for shift in range(4, 13):
        block_size = 1 << shift
        stage_one: list[int] = []
        stage_two: list[int] = []
        block_indexes: dict[tuple[int, ...], int] = {}
        for start in range(0, len(indexed), block_size):
            block = tuple(indexed[start : start + block_size])
            index = block_indexes.get(block)
            if index is None:
                index = len(stage_two) // block_size
                block_indexes[block] = index
                stage_two.extend(block)
            stage_one.append(index)
        try:
            index_element_type(max(stage_one), "block index")
        except RuntimeError:
            # Too many distinct blocks to index at this shift alone; a smaller
            # block dedupes better, so keep searching rather than failing.
            continue
        candidate = PackedClassificationTables(palette, stage_one, stage_two, shift)
        if smallest is None or candidate.byte_size < smallest.byte_size:
            smallest = candidate
    if smallest is None:
        raise RuntimeError("no block shift packs the Unicode table into UInt16 indexes")
    return smallest


def palette_array(palette: list[ClassificationRecord]) -> str:
    """Emits the palette as explicit struct literals, one per distinct record.

    The reference tables rebuild their structs at runtime because struct
    literals at codespace scale exhaust swift-frontend memory; the palette holds
    a few dozen entries, so spelling them out costs nothing and leaves the
    lookup with no raw-value decode and therefore no failure path.
    """
    lines = []
    for width, pictographic, modifier, variation_base, grapheme_class in palette:
        lines.append("        TerminalUnicodeClassification(")
        lines.append("            properties: TerminalUnicodeProperties(")
        lines.append(f"                cellWidth: .{CELL_WIDTH_CASES[width]},")
        lines.append(f"                isExtendedPictographic: {str(pictographic).lower()},")
        lines.append(f"                isEmojiModifier: {str(modifier).lower()},")
        lines.append(f"                isEmojiVariationBase: {str(variation_base).lower()}")
        lines.append("            ),")
        lines.append(
            f"            graphemeBreakClass: .{GRAPHEME_CLASS_CASES[grapheme_class]}"
        )
        lines.append("        ),")
    return "\n".join(lines)


def production_source(packed: PackedClassificationTables) -> str:
    hashes = ", ".join(
        f"{name} {FILES[name][1]}"
        for name in (
            "EastAsianWidth.txt",
            "UnicodeData.txt",
            "emoji-data.txt",
            "GraphemeBreakProperty.txt",
            "DerivedCoreProperties.txt",
            "emoji-variation-sequences.txt",
            "GraphemeBreakTest.txt",
        )
    )
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
    let isEmojiModifier: Bool
    let isEmojiVariationBase: Bool
}}

/// Classifies a scalar using the generated Unicode {UNICODE_VERSION} tables.
func terminalUnicodeProperties(for scalar: Unicode.Scalar) -> TerminalUnicodeProperties {{
    terminalUnicodeClassification(for: scalar).properties
}}

/// Returns the folded UAX #29 class consumed by the streaming segmenter.
func graphemeBreakClass(for scalar: Unicode.Scalar) -> GraphemeBreakClass {{
    terminalUnicodeClassification(for: scalar).graphemeBreakClass
}}

/// Reads every terminal property for a scalar out of the generated tables.
func terminalUnicodeClassification(for scalar: Unicode.Scalar) -> TerminalUnicodeClassification {{
    GeneratedPackedUnicodeTables.classification(for: scalar.value)
}}

/// Keeps width and segmentation consumers on the same generated scalar record.
struct TerminalUnicodeClassification: Sendable {{
    let properties: TerminalUnicodeProperties
    let graphemeBreakClass: GraphemeBreakClass
}}

// The two stages hold palette indexes, so the only classifications this table
// can produce are the ones the generator emitted. That is why the lookup has no
// raw-value decode and no failure path.
private enum GeneratedPackedUnicodeTables {{
    static let palette: [TerminalUnicodeClassification] = [
{palette_array(packed.palette)}
    ]

    static let stageOne: [{packed.stage_one_type}] = [
{integer_array(packed.stage_one)}
    ]

    static let stageTwo: [{packed.stage_two_type}] = [
{integer_array(packed.stage_two)}
    ]

    static func classification(for value: UInt32) -> TerminalUnicodeClassification {{
        let block = Int(stageOne[Int(value >> {packed.shift})])
        return palette[Int(stageTwo[(block << {packed.shift}) | Int(value & 0x{(1 << packed.shift) - 1:X})])]
    }}
}}
'''


def reference_ranges(
    zero_width: list[tuple[int, int]],
    wide: list[tuple[int, int]],
    pictographic: list[tuple[int, int]],
    emoji_modifiers: list[tuple[int, int]],
) -> list[tuple[int, int, int, bool, bool]]:
    widths = bytearray([1]) * (MAX_SCALAR + 1)
    pictographs = bytearray(MAX_SCALAR + 1)
    modifiers = bytearray(MAX_SCALAR + 1)
    for lower, upper in wide:
        widths[lower : upper + 1] = bytes([2]) * (upper - lower + 1)
    for lower, upper in zero_width:
        widths[lower : upper + 1] = bytes([0]) * (upper - lower + 1)
    for lower, upper in pictographic:
        pictographs[lower : upper + 1] = bytes([1]) * (upper - lower + 1)
    for lower, upper in emoji_modifiers:
        modifiers[lower : upper + 1] = bytes([1]) * (upper - lower + 1)

    result: list[tuple[int, int, int, bool, bool]] = []
    start = 0
    prior = (widths[0], bool(pictographs[0]), bool(modifiers[0]))
    for value in range(1, MAX_SCALAR + 1):
        current = (widths[value], bool(pictographs[value]), bool(modifiers[value]))
        if current != prior:
            result.append((start, value - 1, prior[0], prior[1], prior[2]))
            start = value
            prior = current
    result.append((start, MAX_SCALAR, prior[0], prior[1], prior[2]))
    return result


def reference_source(ranges: list[tuple[int, int, int, bool, bool]]) -> str:
    lower_bounds = [lower for lower, _, _, _, _ in ranges]
    upper_bounds = [upper for _, upper, _, _, _ in ranges]
    widths = [width for _, _, width, _, _ in ranges]
    pictographic_flags = [pictographic for _, _, _, pictographic, _ in ranges]
    modifier_flags = [is_modifier for _, _, _, _, is_modifier in ranges]
    return f'''// Generated independently from the official Unicode {UNICODE_VERSION} property files.
//
// Flat, explicitly typed parallel arrays: an array-of-initializer literal at this
// scale costs gigabytes of swift-frontend memory to typecheck, while flat
// homogeneous literals typecheck linearly. The structs are rebuilt at runtime.

/// Exhaustive expected-property run used to validate every Unicode scalar offline.
struct UnicodeReferenceRange {{
    let lowerBound: UInt32
    let upperBound: UInt32
    let cellWidth: UInt8
    let isExtendedPictographic: Bool
    let isEmojiModifier: Bool
}}

let unicodeReferenceRanges: [UnicodeReferenceRange] = UnicodeReferenceTables.lowerBounds.indices.map {{
    UnicodeReferenceRange(
        lowerBound: UnicodeReferenceTables.lowerBounds[$0],
        upperBound: UnicodeReferenceTables.upperBounds[$0],
        cellWidth: UnicodeReferenceTables.cellWidths[$0],
        isExtendedPictographic: UnicodeReferenceTables.pictographicFlags[$0],
        isEmojiModifier: UnicodeReferenceTables.emojiModifierFlags[$0]
    )
}}

private enum UnicodeReferenceTables {{
    static let lowerBounds: [UInt32] = [
{hexadecimal_array(lower_bounds)}
    ]
    static let upperBounds: [UInt32] = [
{hexadecimal_array(upper_bounds)}
    ]
    static let cellWidths: [UInt8] = [
{integer_array(widths)}
    ]
    static let pictographicFlags: [Bool] = [
{boolean_array(pictographic_flags)}
    ]
    static let emojiModifierFlags: [Bool] = [
{boolean_array(modifier_flags)}
    ]
}}
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
    lower_bounds = [lower for lower, _, _, _ in ranges]
    upper_bounds = [upper for _, upper, _, _ in ranges]
    break_classes = [break_class for _, _, break_class, _ in ranges]
    variation_flags = [is_variation_base for _, _, _, is_variation_base in ranges]
    return f'''// Generated independently from the official Unicode {UNICODE_VERSION} property files.
//
// Flat, explicitly typed parallel arrays: an array-of-initializer literal at this
// scale costs gigabytes of swift-frontend memory to typecheck, while flat
// homogeneous literals typecheck linearly. The structs are rebuilt at runtime.

/// Exhaustive grapheme-property run used to validate every Unicode scalar offline.
struct UnicodeGraphemeReferenceRange {{
    let lowerBound: UInt32
    let upperBound: UInt32
    let breakClass: UInt8
    let isEmojiVariationBase: Bool
}}

let unicodeGraphemeReferenceRanges: [UnicodeGraphemeReferenceRange] = UnicodeGraphemeReferenceTables.lowerBounds.indices.map {{
    UnicodeGraphemeReferenceRange(
        lowerBound: UnicodeGraphemeReferenceTables.lowerBounds[$0],
        upperBound: UnicodeGraphemeReferenceTables.upperBounds[$0],
        breakClass: UnicodeGraphemeReferenceTables.breakClasses[$0],
        isEmojiVariationBase: UnicodeGraphemeReferenceTables.variationBaseFlags[$0]
    )
}}

private enum UnicodeGraphemeReferenceTables {{
    static let lowerBounds: [UInt32] = [
{hexadecimal_array(lower_bounds)}
    ]
    static let upperBounds: [UInt32] = [
{hexadecimal_array(upper_bounds)}
    ]
    static let breakClasses: [UInt8] = [
{integer_array(break_classes)}
    ]
    static let variationBaseFlags: [Bool] = [
{boolean_array(variation_flags)}
    ]
}}
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
    lines = [line for line, _, _ in cases]
    scalar_offsets: list[int] = []
    scalar_pool: list[int] = []
    boundary_pool: list[bool] = []
    for _, scalars, boundaries in cases:
        if len(boundaries) != len(scalars) + 1:
            raise RuntimeError("corpus fixture boundary count must be scalar count + 1")
        scalar_offsets.append(len(scalar_pool))
        scalar_pool.extend(scalars)
        boundary_pool.extend(boundaries)
    scalar_offsets.append(len(scalar_pool))
    return f'''// Generated from Unicode {UNICODE_VERSION} GraphemeBreakTest.txt; do not edit.
//
// Flat, explicitly typed parallel arrays with an offsets-plus-pool encoding for
// the variable-length fields: an array-of-initializer literal with nested array
// literals per element costs gigabytes of swift-frontend memory to typecheck,
// while flat homogeneous literals typecheck linearly. The fixtures are rebuilt
// at runtime.

/// One official UAX #29 sequence with every boundary retained verbatim.
struct GraphemeBreakCorpusFixture {{
    let line: Int
    let scalars: [UInt32]
    let boundaries: [Bool]
}}

let graphemeBreakCorpus: [GraphemeBreakCorpusFixture] = GraphemeBreakCorpusTables.lines.indices.map {{ index in
    let scalarLower = GraphemeBreakCorpusTables.scalarOffsets[index]
    let scalarUpper = GraphemeBreakCorpusTables.scalarOffsets[index + 1]
    // Every fixture holds exactly one more boundary than scalars, so the
    // boundary pool's offsets are the scalar offsets shifted by the fixture
    // index; the generator validates that invariant when it emits the pools.
    return GraphemeBreakCorpusFixture(
        line: GraphemeBreakCorpusTables.lines[index],
        scalars: Array(GraphemeBreakCorpusTables.scalarPool[scalarLower..<scalarUpper]),
        boundaries: Array(
            GraphemeBreakCorpusTables.boundaryPool[(scalarLower + index)..<(scalarUpper + index + 1)]
        )
    )
}}

private enum GraphemeBreakCorpusTables {{
    static let lines: [Int] = [
{integer_array(lines)}
    ]
    static let scalarOffsets: [Int] = [
{integer_array(scalar_offsets)}
    ]
    static let scalarPool: [UInt32] = [
{hexadecimal_array(scalar_pool)}
    ]
    static let boundaryPool: [Bool] = [
{boolean_array(boundary_pool)}
    ]
}}
'''


def main() -> None:
    args = parse_args()
    data = verified_data(args.data_dir)
    zero_width = parse_zero_width_ranges(data["UnicodeData.txt"])
    grapheme_properties = parse_named_property_ranges(data["GraphemeBreakProperty.txt"])
    wide = merge_ranges(
        parse_property_ranges(data["EastAsianWidth.txt"], {"W", "F"})
        + grapheme_properties["Regional_Indicator"]
    )
    reference_wide = merge_ranges(
        parse_property_ranges(data["EastAsianWidth.txt"], {"W", "F"})
        + parse_property_ranges(
            data["GraphemeBreakProperty.txt"], {"Regional_Indicator"}
        )
    )
    pictographic = parse_property_ranges(data["emoji-data.txt"], {"Extended_Pictographic"})
    emoji_modifiers = parse_property_ranges(data["emoji-data.txt"], {"Emoji_Modifier"})
    emoji_variation_bases = parse_emoji_variation_bases(
        data["emoji-variation-sequences.txt"]
    )
    classes = folded_grapheme_classes(
        grapheme_properties,
        parse_incb_ranges(data["DerivedCoreProperties.txt"]),
        pictographic,
    )
    packed = packed_classification_tables(
        classification_records(
            zero_width,
            wide,
            pictographic,
            emoji_modifiers,
            emoji_variation_bases,
            classes,
        )
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
    canonical_caseless = (
        repo_root
        / "lib/TerminalCore/Sources/TerminalCore/CanonicalCaseless.generated.swift"
    )
    combining_class_reference = (
        repo_root
        / "lib/TerminalCore/Tests/TerminalCoreTests/CanonicalCombiningClassReference.generated.swift"
    )
    conformance_corpus_directory = (
        repo_root
        / "lib/TerminalCore/Tests/TerminalCoreTests/Fixtures/unicode"
    )
    conformance_corpus_directory.mkdir(parents=True, exist_ok=True)
    normalization_corpus = conformance_corpus_directory / "NormalizationTest-17.0.0.txt"
    case_folding_corpus = conformance_corpus_directory / "CaseFolding-17.0.0.txt"
    production.write_text(production_source(packed), encoding="utf-8")
    reference.write_text(
        reference_source(
            reference_ranges(zero_width, reference_wide, pictographic, emoji_modifiers)
        ),
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
    decompositions, combining_classes = parse_canonical_data(data["UnicodeData.txt"])
    case_folding = parse_full_case_folding(data["CaseFolding.txt"])
    caseless_records, decomposition_pool, fold_pool = canonical_caseless_records(
        fully_resolved_decompositions(decompositions),
        combining_classes,
        case_folding,
    )
    canonical_caseless.write_text(
        canonical_caseless_source(
            packed_classification_tables(caseless_records),
            decomposition_pool,
            fold_pool,
        ),
        encoding="utf-8",
    )
    combining_class_reference.write_text(
        combining_class_reference_source(
            combining_class_reference_ranges(data["UnicodeData.txt"])
        ),
        encoding="utf-8",
    )
    normalization_corpus.write_text(
        data["NormalizationTest.txt"],
        encoding="utf-8",
    )
    case_folding_corpus.write_text(
        data["CaseFolding.txt"],
        encoding="utf-8",
    )
    print(f"generated {production.relative_to(repo_root)}")
    print(f"generated {reference.relative_to(repo_root)}")
    print(f"generated {grapheme_reference.relative_to(repo_root)}")
    print(f"generated {grapheme_corpus.relative_to(repo_root)}")
    print(f"generated {canonical_caseless.relative_to(repo_root)}")
    print(f"generated {combining_class_reference.relative_to(repo_root)}")
    print(f"generated {normalization_corpus.relative_to(repo_root)}")
    print(f"generated {case_folding_corpus.relative_to(repo_root)}")


if __name__ == "__main__":
    main()
