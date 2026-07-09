#!/usr/bin/env python3
"""fold-chat-history — fold an exported provider chat history into the luna vault.

HIMMEL-832. Provider 1: ChatGPT export (conversations-*.json + .dat assets).
Zero-LLM: parses + renders markdown notes; enrichment is HIMMEL-833.

Usage:
  python scripts/luna/fold-chat-history.py --provider chatgpt \
      --export <export-dir> --vault <vault-dir> [--dry-run]
"""
import argparse
import hashlib
import json
import re
import shutil
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):  # Windows cp1252 trap
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

# provider-id -> vault subdir under chats/ (spec: stated once)
PROVIDER_DIRS = {"chatgpt": "gpt"}

RENDER_ROLES = ("user", "assistant")
SKIP_CONTENT_TYPES = ("thoughts", "reasoning_recap")
AUDIO_POINTER_TYPES = ("audio_asset_pointer",
                       "real_time_user_audio_video_asset_pointer")

# Segment = ("text", body) | ("image", file_id) | ("audio", file_id)
Segment = tuple


@dataclass
class Turn:
    role: str
    segments: list


@dataclass
class Conversation:
    id: str
    title: str
    created: datetime
    updated: "datetime | None"
    model: "str | None"
    turns: "list[Turn]"


def _normalize_pointer(pointer):
    """'sediment://file_X' / 'file-service://file-X' -> bare file id."""
    return pointer.split("://", 1)[-1]


def _segments_from_content(content):
    """Typed segments from a message content dict (or None to skip)."""
    ctype = content.get("content_type")
    if ctype in SKIP_CONTENT_TYPES:
        return None
    segments = []
    for part in content.get("parts") or []:
        if isinstance(part, str):
            if part.strip():
                segments.append(("text", part.strip()))
        elif isinstance(part, dict):
            ptype = part.get("content_type")
            if ptype == "audio_transcription":
                text = (part.get("text") or "").strip()
                if text:
                    segments.append(("text", text))
            elif ptype == "image_asset_pointer":
                pointer = part.get("asset_pointer") or ""
                if pointer:
                    segments.append(("image", _normalize_pointer(pointer)))
            elif ptype in AUDIO_POINTER_TYPES:
                pointer = part.get("asset_pointer") or ""
                segments.append(("audio", _normalize_pointer(pointer)))
    return segments


def _linearize(raw):
    """Main-thread nodes: current_node -> parent chain, reversed."""
    mapping = raw.get("mapping") or {}
    nodes = []
    seen = set()
    nid = raw.get("current_node")
    while nid and nid in mapping and nid not in seen:
        seen.add(nid)
        nodes.append(mapping[nid])
        nid = mapping[nid].get("parent")
    nodes.reverse()
    return nodes


def parse_conversation(raw):
    """Raw export conversation dict -> Conversation, or None if 0 turns."""
    if not isinstance(raw, dict):
        return None
    ct = raw.get("create_time")
    if ct is None:
        return None
    turns = []
    for node in _linearize(raw):
        message = node.get("message")
        if not message:
            continue
        if (message.get("author") or {}).get("role") not in RENDER_ROLES:
            continue
        if (message.get("metadata") or {}).get("is_visually_hidden_from_conversation"):
            continue
        segments = _segments_from_content(message.get("content") or {})
        if segments:
            turns.append(Turn(message["author"]["role"], segments))
    if not turns:
        return None
    updated = raw.get("update_time")
    cid = raw.get("conversation_id") or ""
    if not cid or not _SAFE_CONV_ID.fullmatch(cid):
        # full-record hash: only byte-identical records share an id, and
        # deduping those is correct; reruns stay idempotent
        seed = json.dumps(raw, sort_keys=True, ensure_ascii=False)
        cid = "synthetic-" + hashlib.sha1(seed.encode("utf-8")).hexdigest()[:16]
    model = raw.get("default_model_slug")
    if model and not isinstance(model, str):
        model = None
    if model and not _SAFE_MODEL.fullmatch(model):
        model = None
    return Conversation(
        id=cid,
        title=(raw.get("title") or "").strip() or "untitled",
        created=datetime.fromtimestamp(ct),
        updated=datetime.fromtimestamp(updated) if updated else None,
        model=model,
        turns=turns,
    )


def parse_chatgpt(export_dir):
    """All renderable Conversations from conversations-*.json (sorted)."""
    export_dir = Path(export_dir)
    conversations = []
    for jf in sorted(export_dir.glob("conversations-*.json")):
        for raw in json.loads(jf.read_text(encoding="utf-8")):
            conv = parse_conversation(raw)
            if conv:
                conversations.append(conv)
    return conversations


# Windows-unsafe + Obsidian-link-breaking chars, stripped from slugs
_SLUG_STRIP = re.compile(r'[<>:"/\\|?*#^\[\]]')
_ROLE_HEADINGS = {"user": "## 🧑 User", "assistant": "## 🤖 Assistant"}


def slugify(title):
    slug = _SLUG_STRIP.sub("", title)
    slug = re.sub(r"\s+", "-", slug.strip())
    slug = re.sub(r"-{2,}", "-", slug).strip("-")
    return slug[:60].rstrip("-") or "untitled"


def note_filename(conv, taken):
    """'YYYY-MM-DD-<slug>.md', collision -> '-<id[:8]>', then '-<n>'. Adds result to taken."""
    base = f"{conv.created:%Y-%m-%d}-{slugify(conv.title)}"
    id8 = conv.id[:8]
    candidates = [f"{base}.md"]
    if id8:
        candidates.append(f"{base}-{id8}.md")
    for name in candidates:
        if name not in taken:
            taken.add(name)
            return name
    stem = f"{base}-{id8}" if id8 else base
    n = 2
    while True:
        name = f"{stem}-{n}.md"
        if name not in taken:
            taken.add(name)
            return name
        n += 1


def _render_segment(segment, assets_dir_rel, available):
    kind, value = segment
    if kind == "text":
        return value
    if kind == "image":
        if value in available:
            return f"![[{assets_dir_rel}/{available[value]}]]"
        return f"[image: {value} — not in export archive]"
    return "[audio: not in export archive]"


def render_note(conv, assets_dir_rel, available):
    lines = [
        "---",
        "type: chat-import",
        "source: chatgpt",
        f"conversation_id: {conv.id}",
        f"created: {conv.created:%Y-%m-%d}",
    ]
    if conv.updated:
        lines.append(f"updated: {conv.updated:%Y-%m-%d}")
    if conv.model:
        lines.append(f"model: {conv.model}")
    lines += [
        f"messages: {len(conv.turns)}",
        "tags: [chat-import, gpt]",
        "enriched: false",
        "---",
        "",
        f"# {conv.title}",
    ]
    for turn in conv.turns:
        lines += ["", _ROLE_HEADINGS[turn.role], ""]
        lines.append("\n\n".join(
            _render_segment(s, assets_dir_rel, available) for s in turn.segments))
    return "\n".join(lines) + "\n"


_MAGIC_EXTS = ((b"\x89PNG", "png"), (b"\xff\xd8\xff", "jpg"))


def referenced_image_ids(convs):
    seen, ordered = set(), []
    for conv in convs:
        for turn in conv.turns:
            for kind, value in turn.segments:
                if kind == "image" and value not in seen:
                    seen.add(value)
                    ordered.append(value)
    return ordered


def asset_ext(export_dir, file_id):
    """Extension (no dot): export's own name map first, magic-byte fallback."""
    names_file = export_dir / "conversation_asset_file_names.json"
    if names_file.exists():
        names = json.loads(names_file.read_text(encoding="utf-8"))
        original = names.get(f"{file_id}.dat", "")
        if "." in original:
            ext = original.rsplit(".", 1)[1].lower()
            if _SAFE_EXT.fullmatch(ext):
                return ext
    dat = export_dir / f"{file_id}.dat"
    if dat.exists():
        with dat.open("rb") as fh:
            head = fh.read(8)
        for magic, ext in _MAGIC_EXTS:
            if head.startswith(magic):
                return ext
    return None


# file_id comes from export data (asset_pointer) and is interpolated into
# src/dest paths below — reject anything but a bare filename-safe token
# (blocks path traversal via a crafted "sediment://../../evil" pointer).
_SAFE_ASSET_ID = re.compile(r"[A-Za-z0-9_-]+\Z")

# extension from the name map must also be safe (1-8 lowercase alphanumeric)
# to prevent smuggled path separators (e.g., "photo.png/../../evil" -> "png/../../evil")
_SAFE_EXT = re.compile(r"[a-z0-9]{1,8}\Z")

# conversation_id must be safe for YAML frontmatter and filenames
# (blocks newlines, colons, and other problematic chars that corrupt YAML)
_SAFE_CONV_ID = re.compile(r"[A-Za-z0-9_-]{1,64}\Z")

# model slug must be safe for YAML frontmatter
# (blocks newlines, colons, and other problematic chars)
_SAFE_MODEL = re.compile(r"[A-Za-z0-9._-]{1,64}\Z")


def copy_assets(convs, export_dir, assets_dir, dry_run):
    """Copy referenced image assets. -> (available, copied, skipped, missing, unrecognized)."""
    export_dir = Path(export_dir)
    available, copied, skipped, missing, unrecognized = {}, 0, 0, 0, 0
    for file_id in referenced_image_ids(convs):
        if not _SAFE_ASSET_ID.match(file_id):
            missing += 1
            continue
        src = export_dir / f"{file_id}.dat"
        if not src.exists():
            missing += 1
            continue
        ext = asset_ext(export_dir, file_id)
        if not ext:
            unrecognized += 1
            continue
        final = f"{file_id}.{ext}"
        dest = assets_dir / final
        available[file_id] = final
        if dest.exists():
            skipped += 1
            continue
        if not dry_run:
            assets_dir.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dest)
        copied += 1
    return available, copied, skipped, missing, unrecognized


_FRONTMATTER_ID = re.compile(r"^conversation_id:\s*(.+?)\s*$", re.MULTILINE)
_GITIGNORE_RULE = "chats/*/_assets/"


@dataclass
class Report:
    notes_created: int = 0
    notes_skipped_existing: int = 0
    convs_skipped_empty: int = 0
    assets_copied: int = 0
    assets_skipped_existing: int = 0
    assets_missing: int = 0
    assets_unrecognized: int = 0
    audio_placeholders: int = 0
    dry_run: bool = False

    def lines(self):
        mode = "DRY-RUN — would have: " if self.dry_run else ""
        return [
            f"{mode}notes created: {self.notes_created}",
            f"notes skipped (already imported): {self.notes_skipped_existing}",
            f"conversations skipped (empty): {self.convs_skipped_empty}",
            f"assets copied: {self.assets_copied}",
            f"assets skipped (already present): {self.assets_skipped_existing}",
            f"assets missing from export: {self.assets_missing}",
            f"assets present but unrecognized format (left in export): {self.assets_unrecognized}",
            f"audio placeholders (named voice audio, not in export): {self.audio_placeholders}",
        ]


def existing_conversation_ids(provider_dir):
    ids = set()
    if provider_dir.is_dir():
        for note in provider_dir.rglob("*.md"):
            try:
                text = note.read_text(encoding="utf-8")[:2000]
            except (OSError, UnicodeDecodeError):
                continue
            match = _FRONTMATTER_ID.search(text)
            if match:
                ids.add(match.group(1))
    return ids


def ensure_gitignore(vault_dir, dry_run):
    gitignore = vault_dir / ".gitignore"
    content = gitignore.read_text(encoding="utf-8") if gitignore.exists() else ""
    if _GITIGNORE_RULE in content.splitlines():
        return False
    if not dry_run:
        joiner = "" if (not content or content.endswith("\n")) else "\n"
        gitignore.write_text(content + joiner + _GITIGNORE_RULE + "\n",
                             encoding="utf-8")
    return True


def _note_meta(note_path):
    """(created, title, messages) for the index, from a note on disk."""
    text = note_path.read_text(encoding="utf-8")
    created = re.search(r"^created:\s*(\S+)", text, re.MULTILINE)
    messages = re.search(r"^messages:\s*(\d+)", text, re.MULTILINE)
    title = re.search(r"^# (.+)$", text, re.MULTILINE)
    return (created.group(1) if created else "",
            title.group(1) if title else note_path.stem,
            messages.group(1) if messages else "?")


def write_index(chats_dir, dry_run):
    lines = ["# Chat-history imports", "",
             "Machine-generated by fold-chat-history (HIMMEL-832). "
             "Regenerated every run — do not hand-edit.", ""]
    for provider_dir in sorted(p for p in chats_dir.iterdir()
                               if p.is_dir() and not p.name.startswith("_")):
        rows = []
        for note in provider_dir.rglob("*.md"):
            try:
                created, title, messages = _note_meta(note)
            except (OSError, UnicodeDecodeError):
                continue
            link = note.relative_to(chats_dir.parent).with_suffix("").as_posix()
            rows.append((created, f"| {created} | [[{link}\\|{title}]] | {messages} |"))
        lines += [f"## {provider_dir.name}", "",
                  f"{len(rows)} conversations.", "",
                  "| date | conversation | msgs |", "|---|---|---|"]
        lines += [row for _, row in sorted(rows, reverse=True)]
        lines.append("")
    if not dry_run:
        (chats_dir / "_index.md").write_text("\n".join(lines) + "\n",
                                             encoding="utf-8")


def fold(provider, export_dir, vault_dir, dry_run):
    export_dir, vault_dir = Path(export_dir), Path(vault_dir)
    provider_dir = vault_dir / "chats" / PROVIDER_DIRS[provider]
    assets_dir = provider_dir / "_assets"
    assets_dir_rel = f"chats/{PROVIDER_DIRS[provider]}/_assets"

    all_raw_count = 0
    conversations = []
    for jf in sorted(export_dir.glob("conversations-*.json")):
        for raw in json.loads(jf.read_text(encoding="utf-8")):
            all_raw_count += 1
            conv = parse_conversation(raw)
            if conv:
                conversations.append(conv)

    report = Report(dry_run=dry_run)
    report.convs_skipped_empty = all_raw_count - len(conversations)

    known = existing_conversation_ids(provider_dir)
    new_convs = []
    for conv in conversations:
        if conv.id in known:
            report.notes_skipped_existing += 1
        else:
            new_convs.append(conv)
            known.add(conv.id)

    available, copied, skipped, missing, unrecognized = copy_assets(
        conversations, export_dir, assets_dir, dry_run)
    report.assets_copied = copied
    report.assets_skipped_existing = skipped
    report.assets_missing = missing
    report.assets_unrecognized = unrecognized
    # named audio ids only — user-side real_time parts carry no top-level
    # asset_pointer and emit ("audio", ""); they still render placeholders
    report.audio_placeholders = len({value
                                     for conv in conversations
                                     for turn in conv.turns
                                     for kind, value in turn.segments
                                     if kind == "audio" and value})

    taken = {p.name for p in provider_dir.rglob("*.md")} if provider_dir.is_dir() else set()
    for conv in new_convs:
        name = note_filename(conv, taken)
        month_dir = provider_dir / f"{conv.created:%Y-%m}"
        if not dry_run:
            month_dir.mkdir(parents=True, exist_ok=True)
            (month_dir / name).write_text(
                render_note(conv, assets_dir_rel, available), encoding="utf-8")
        report.notes_created += 1

    try:
        ensure_gitignore(vault_dir, dry_run)
        if not dry_run and provider_dir.is_dir():
            write_index(vault_dir / "chats", dry_run)
    except Exception as e:
        print(f"warning: index/gitignore update failed: {e}", file=sys.stderr)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Fold an exported provider chat history into the luna vault "
                    "(HIMMEL-832; create-only, idempotent).")
    parser.add_argument("--provider", required=True,
                        choices=sorted(PROVIDER_DIRS))
    parser.add_argument("--export", required=True, metavar="DIR",
                        help="export root (holds conversations-*.json)")
    parser.add_argument("--vault", required=True, metavar="DIR",
                        help="luna vault root")
    parser.add_argument("--dry-run", action="store_true",
                        help="report what would happen; write nothing")
    args = parser.parse_args(argv)

    export_dir, vault_dir = Path(args.export), Path(args.vault)
    if not export_dir.is_dir():
        print(f"error: export dir not found: {export_dir}", file=sys.stderr)
        return 1
    if not vault_dir.is_dir():
        print(f"error: vault dir not found: {vault_dir}", file=sys.stderr)
        return 1

    report = fold(args.provider, export_dir, vault_dir, args.dry_run)
    for line in report.lines():
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
