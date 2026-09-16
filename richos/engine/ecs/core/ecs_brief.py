# SPDX-License-Identifier: AGPL-3.0-only
"""Bounded briefs with fair section allocation and an explicit recovery path.

The store owns ordering and escaping. This module only allocates space. It
never interprets a stored sentence as an instruction or decides it is stale.
"""
from __future__ import annotations

import json
import re

TRUNCATED = "[TRUNCATED deterministically at budget boundary]"
JSON_STRING = re.compile(r'"(?:[^"\\]|\\.)*"')


def compact(entry: str, budget: int) -> str | None:
    """Keep identifiers intact and JSON valid; explicitly mark shortened text."""
    if len(entry) <= budget:
        return entry
    for size in (120, 60, 20, 0):
        def shorten(match: re.Match) -> str:
            value = json.loads(match.group())

            return match.group() if len(match.group()) <= size else json.dumps(
                value[:size] + "...", ensure_ascii=True
            )
        value = JSON_STRING.sub(shorten, entry) + " | partial=true"
        if len(value) <= budget:
            return value
    return None


def render_sections(header: list[str], sections: list[tuple[str, list[str]]], budget: int) -> str:
    def render(groups: list[tuple[str, list[str]]]) -> str:
        lines = list(header)
        for title, entries in groups:
            lines.extend(["", f"## {title}"])
            lines.extend(f"- {entry}" for entry in entries or ["UNKNOWN (no authoritative ECS record)"])
        return "\n".join(lines) + "\n"

    full = render(sections)
    if len(full) <= budget:
        return full
    nonempty = render([(title, entries) for title, entries in sections if entries])
    if len(nonempty) <= budget:
        return nonempty

    context, *data = sections


    selected: dict[str, list[str]] = {title: [] for title, _ in data}
    counts = {title: len(entries) for title, entries in data}

    def document() -> str:
        omitted = {title: counts[title] - len(selected[title]) for title, _ in data}
        retrieval = [
            "omitted=" + json.dumps(json.dumps(omitted, separators=(",", ":"))),
            'read="scripts/ecs/ecs inspect" | partial_records="retrieve full records before acting"',
        ]
        groups = [context, ("Retrieval", retrieval)]
        groups.extend((title, selected[title]) for title, _ in data if selected[title])
        return render(groups) + TRUNCATED + "\n"

    base = document()
    if len(base) > budget:


        fallback = render([context, ("Retrieval", [
            f'omitted_total={sum(counts.values())} | read="scripts/ecs/ecs inspect"',
        ])]) + TRUNCATED + "\n"
        if len(fallback) > budget:
            raise ValueError("brief budget cannot hold active context and retrieval instructions")
        return fallback

    pending = [(title, entries) for title, entries in data if entries]


    while pending:
        next_round = []
        for index, (title, entries) in enumerate(pending):
            available = budget - len(document())
            share = available // (len(pending) - index)
            overhead = 3 + (len(title) + 5 if not selected[title] else 0)
            entry = compact(entries[len(selected[title])], share - overhead)
            if entry is None:
                continue
            selected[title].append(entry)
            if len(document()) > budget:
                selected[title].pop()
                continue
            if len(selected[title]) < len(entries):
                next_round.append((title, entries))
        pending = next_round
    return document()
