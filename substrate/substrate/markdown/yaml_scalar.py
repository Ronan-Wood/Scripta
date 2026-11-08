"""Frontmatter scalars every reader agrees on: YAML 1.2, YAML 1.1 (PyYAML), the engine's line reader
and the app's `ScriptaShared/Frontmatter`.

A value is written plain when it cannot mean anything else, and single-quoted otherwise. Single
quotes because they have no escapes: a backslash means itself to every reader, where inside double
quotes YAML reads `\\a` in `$\\alpha$` as a bell. Old notes keep their double-quoted values, which the
line readers read without unescaping, so `decode` leaves those as they always were.

What a single-quoted scalar cannot hold on one line becomes a space: line breaks (YAML 1.1 also
breaks at NEL, LS and PS), the C0 controls other than tab, the C1 controls, DEL, the byte-order
mark, U+FFFE, U+FFFF and lone surrogates. The app's `ScriptaShared/Frontmatter` keeps the same
character rule and the same single-quoted form; it quotes every free-text value, where the engine
leaves one plain when it can, so emitted bytes that were already YAML do not move.

Stdlib only, like the reader.
"""

from __future__ import annotations

import re

# Everything YAML 1.2 allows inside a one-line quoted scalar (nb-char), and PyYAML does too.
_UNSAFE = re.compile("[^\t\x20-\x7e\xa0-\u2027\u202a-\ud7ff\ue000-\ufefe\uff00-\ufffd\U00010000-\U0010ffff]")
# Where a plain scalar may not start, and characters a plain scalar here never holds.
_INDICATORS = frozenset("-?:,[]{}#&*!|>'\"%@`")
_NOT_PLAIN = frozenset(":#\"'\\\t")
_FLOW = frozenset(",[]{}?")  # PyYAML ends a flow plain scalar at `?` too
# Plain scalars YAML 1.1 (PyYAML's resolver, plus the spec's y/n) or YAML 1.2's core schema reads
# as something other than a string.
_SPECIAL = re.compile(r"""
    (?: y|Y|n|N|yes|Yes|YES|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF
      | ~|null|Null|NULL|<<|=
      | [-+]?0b[0-1_]+ | [-+]?0[0-7_]+ | [-+]?(?:0|[1-9][0-9_]*) | [-+]?0x[0-9a-fA-F_]+
      | [-+]?[1-9][0-9_]*(?::[0-5]?[0-9])+ | [-+]?0o[0-7_]*
      | [-+]?(?:[0-9][0-9_]*)\.[0-9_]*(?:[eE][-+][0-9]+)? | \.[0-9_]+(?:[eE][-+][0-9]+)?
      | [-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*
      | [-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?
      | [-+]?\.(?:inf|Inf|INF) | \.(?:nan|NaN|NAN)
      | [0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:(?:[Tt]|[ \t]+)[0-9]{1,2}:[0-9]{2}:[0-9]{2}.*)?
      # ruamel's 1.2 resolver also takes `_` in numbers and a sign before `0o`, which 1.2 does not.
      | [-+]?[0-9_.]*_[0-9_.eE+-]* | [-+][._]+
    )""", re.VERBOSE)


def sanitize(value: str) -> str:
    """`value` with every character a one-line scalar cannot hold replaced by a space."""
    return _UNSAFE.sub(" ", value)


# What a YAML 1.2 reader resolves where PyYAML does not: the core schema, and ruamel's laxer `_`
# and signed `0o` forms, which `_SPECIAL` quotes for the same reason.
_CORE_12 = re.compile(r"""
    (?: ~|null|Null|NULL|true|True|TRUE|false|False|FALSE
      | [-+]?[0-9]+ | [-+]?0o[0-7_]* | 0x[0-9a-fA-F]+
      | [-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?
      | [-+]?\.(?:inf|Inf|INF) | \.(?:nan|NaN|NAN)
      | [-+]?[0-9_.]*_[0-9_.eE+-]* | [-+][._]+
    )""", re.VERBOSE)


def resolves_elsewhere(value: str) -> bool:
    """Whether YAML 1.1 or 1.2, read plain, takes `value` for something other than a string."""
    return bool(_SPECIAL.fullmatch(value))


def resolves_in_yaml_12(value: str) -> bool:
    """Whether YAML 1.2's core schema, read plain, takes `value` for something other than a string."""
    return bool(_CORE_12.fullmatch(value))


def _plain(value: str, flow: bool) -> bool:
    if not value or value != value.strip() or value[0] in _INDICATORS:
        return False
    if any(ch in _NOT_PLAIN or (flow and ch in _FLOW) for ch in value):
        return False
    return not resolves_elsewhere(value)


def encode(value: str, *, flow: bool = False) -> str:
    """`value`, sanitized, as a scalar that reads back as exactly that string. `flow` for an item
    of a `[a, b]` list, where `,[]{}` also need quotes."""
    value = sanitize(value)
    if _plain(value, flow):
        return value
    return "'" + value.replace("'", "''") + "'"


def is_single_quoted(raw: str) -> bool:
    """`raw` is one closed single-quoted scalar: `'…'`, every inner quote doubled."""
    return len(raw) >= 2 and raw[0] == raw[-1] == "'" and "'" not in raw[1:-1].replace("''", "")


def decode(raw: str) -> str:
    """A frontmatter value as written after `key:`, already stripped of surrounding space. A closed
    single-quoted scalar is decoded; a double-quoted one loses its quotes and nothing else, as every
    line reader has always read it; anything else is the value itself."""
    if is_single_quoted(raw):
        return raw[1:-1].replace("''", "'")
    if len(raw) >= 2 and raw[0] == raw[-1] == '"':
        return raw[1:-1]
    return raw
