#!/usr/bin/env python3
"""fold-chat-history — fold an exported provider chat history into the luna vault.

HIMMEL-832. ChatGPT (conversations-*.json + .dat assets) and Gemini
(conversations/*.json) exports fold one note per conversation; enrichment
is HIMMEL-833. HIMMEL-1170: Telegram Desktop HTML group export
(messages*.html + photos/video_files) folds into monthly notes.

Usage:
  python scripts/luna/fold-chat-history.py --provider chatgpt \
      --export <export-dir> --vault <vault-dir> [--dry-run]
  python scripts/luna/fold-chat-history.py --provider telegram \
      --export <ChatExport-dir> --vault <vault-dir> [--group-slug SLUG] [--dry-run]
"""
import argparse
import hashlib
import html
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
PROVIDER_DIRS = {"chatgpt": "gpt", "gemini": "gemini", "telegram": "telegram"}

# provider-id -> (source: value, tags: gpt-style second tag) for render_note
_SOURCE_TAGS = {"chatgpt": ("chatgpt", "gpt"), "gemini": ("gemini", "gemini")}

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


def parse_gemini(export_dir):
    """All renderable Conversations from conversations/*.json (sorted).

    AI Toolbox export: one chat object per file, no natural id/create_time/
    model — id is synthetic (full-record hash), created/updated both come
    from updated_at, model is the constant "gemini".
    """
    export_dir = Path(export_dir)
    conversations = []
    for jf in sorted(export_dir.glob("conversations/*.json")):
        raw = json.loads(jf.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            continue
        updated_at = raw.get("updated_at")
        if not isinstance(updated_at, str) or not updated_at:
            continue
        try:
            created = datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
        except ValueError:
            continue
        turns = []
        for item in raw.get("conversation") or []:
            if not isinstance(item, dict):
                continue
            role = item.get("role")
            content = item.get("content")
            if role in RENDER_ROLES and isinstance(content, str) and content.strip():
                turns.append(Turn(role, [("text", content.strip())]))
        if not turns:
            continue
        # Hash only the STABLE identifying fields, not the whole record: the
        # export carries volatile per-export fields (exported_at) that would
        # otherwise change the id on every re-export and defeat idempotent
        # dedup, duplicating notes when the full history is re-exported later.
        seed = json.dumps(
            {"title": raw.get("title"),
             "updated_at": updated_at,
             "conversation": raw.get("conversation")},
            sort_keys=True, ensure_ascii=False)
        cid = "synthetic-" + hashlib.sha1(seed.encode("utf-8")).hexdigest()[:16]
        conversations.append(Conversation(
            id=cid,
            title=(raw.get("title") or "").strip() or "untitled",
            created=created,
            updated=created,
            model="gemini",
            turns=turns,
        ))
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


def render_note(conv, assets_dir_rel, available, provider="chatgpt"):
    source, tag = _SOURCE_TAGS[provider]
    lines = [
        "---",
        "type: chat-import",
        f"source: {source}",
        f"conversation_id: {conv.id}",
        f"created: {conv.created:%Y-%m-%d}",
    ]
    if conv.updated:
        lines.append(f"updated: {conv.updated:%Y-%m-%d}")
    if conv.model:
        lines.append(f"model: {conv.model}")
    lines += [
        f"messages: {len(conv.turns)}",
        f"tags: [chat-import, {tag}]",
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
    # telegram-only (HIMMEL-1170); unused for chatgpt/gemini
    provider: str = ""
    tg_group: str = ""
    tg_months: int = 0
    tg_messages: int = 0

    def lines(self):
        if self.provider == "telegram":
            mode = "DRY-RUN — would have: " if self.dry_run else ""
            return [
                f"{mode}group: {self.tg_group}",
                f"months: {self.tg_months}",
                f"messages: {self.tg_messages}",
                f"month notes written: {self.notes_created}",
                f"media copied: {self.assets_copied}",
                f"media skipped (already present): {self.assets_skipped_existing}",
                f"media missing from export: {self.assets_missing}",
            ]
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


# --------------------------------------------------------------------------
# Telegram Desktop HTML group export (HIMMEL-1170)
# One chronological group log -> monthly notes. It has no user/assistant
# turns, so it does NOT go through render_note; it has its own parse+render.
# --------------------------------------------------------------------------

_TG_TS_RE = re.compile(r'title="(\d{2})\.(\d{2})\.(\d{4}) (\d{2}):(\d{2}):(\d{2})')
_TG_FROM_RE = re.compile(r'<div class="from_name">\s*(.*?)\s*</div>', re.S)
_TG_TEXT_RE = re.compile(r'<div class="text">(.*?)</div>', re.S)
_TG_MEDIA_RE = re.compile(r'href="((?:photos|video_files)/[^"]+)"')
_TG_HEADER_RE = re.compile(r'<div class="text bold">\s*(.*?)\s*</div>', re.S)


@dataclass
class TgMessage:
    ts: datetime
    sender: str
    body: str
    media: list


def _tg_strip_text(raw):
    """`<br>` -> newline, drop remaining tags, unescape entities, strip."""
    raw = re.sub(r'<br\s*/?>', '\n', raw)
    raw = re.sub(r'<[^>]+>', '', raw)
    return html.unescape(raw).strip()


def _tg_page_key(path):
    """Natural page order: messages.html=1, messages2.html=2, ... — NOT the
    lexical sort (which puts messages10.html before messages2.html and would
    mis-order sender inheritance across page boundaries)."""
    m = re.search(r'messages(\d*)\.html$', path.name)
    return int(m.group(1)) if (m and m.group(1)) else 1


def parse_telegram(export_dir):
    """All non-service messages from sorted messages*.html, chronologically.

    Returns (group_name, [TgMessage]). `service` divs (date separators,
    group-creation events) are skipped. `joined` messages (no from_name)
    inherit the previous sender. Full-res media hrefs are captured per message;
    thumbnails (which live in `src=`, not `href=`) never match, and any
    `_thumb` href is filtered defensively.
    """
    export_dir = Path(export_dir)
    group_name = ""
    blocks = []
    for hf in sorted(export_dir.glob("messages*.html"), key=_tg_page_key):
        text = hf.read_text(encoding="utf-8")
        if not group_name:
            m = _TG_HEADER_RE.search(text)
            if m:
                group_name = _tg_strip_text(m.group(1))
        # split on message-div boundaries; keep the delimiter with the block
        blocks += re.split(r'(?=<div class="message )', text)[1:]
    msgs = []
    last_sender = None
    for blk in blocks:
        if 'class="message service"' in blk:
            continue
        m = _TG_TS_RE.search(blk)
        if not m:
            continue
        dd, mm, yyyy, hh, mi, ss = m.groups()
        ts = datetime(int(yyyy), int(mm), int(dd), int(hh), int(mi), int(ss))
        fm = _TG_FROM_RE.search(blk)
        if fm:
            last_sender = _tg_strip_text(fm.group(1))
        sender = last_sender or "?"
        tx = _TG_TEXT_RE.search(blk)
        body = _tg_strip_text(tx.group(1)) if tx else ""
        media, seen = [], set()
        for ref in _TG_MEDIA_RE.findall(blk):
            if "_thumb" in ref or ref in seen:
                continue
            seen.add(ref)
            media.append(ref)
        msgs.append(TgMessage(ts, sender, body, media))
    msgs.sort(key=lambda x: x.ts)
    return group_name, msgs


def _tg_group_slug(group_name, export_dir, override=None):
    """Directory slug for the group. `override` (--group-slug) wins; otherwise
    slugify the header group name (preserving Unicode — Hebrew survives — and
    stripping only FS-unsafe chars). Empty -> export-dir basename -> telegram-group.
    """
    slug = _tg_clean_slug(slugify(override if override else group_name))
    if not slug:
        slug = _tg_clean_slug(slugify(Path(export_dir).name))
    return slug or "telegram-group"


def _tg_clean_slug(slug):
    """Strip path-dangerous parts so a group dir can NEVER escape
    chats/telegram/: slugify's empty sentinel 'untitled' -> '', the reserved
    '_assets' media-dir name -> '' (a '_assets' group dir would equal assets_dir
    and drop notes into the gitignored media folder; casefold guards
    case-insensitive filesystems), path separators dropped, dot runs -> '-' (so a
    group named `.`/`..` cannot become a `..` traversal), then trim. The reserved
    check runs AFTER normalization so variants like `_assets/`, `_assets.` (which
    normalize back to `_assets`) are also rejected. May return '' -> caller falls
    back."""
    slug = slug.replace("/", "").replace("\\", "")
    slug = re.sub(r"\.+", "-", slug).strip("-. ")
    if slug.casefold() in {"untitled", "_assets"}:
        return ""
    return slug


def _tg_asset_name(group_slug, ref, content_hash=None):
    """Filename inside the shared `chats/telegram/_assets/` dir, GROUP-SCOPED:
    Telegram numbers photos per-export from `photo_1`, so two unrelated groups
    can share a basename; the `<slug>__` prefix keeps them from aliasing (a
    skipped-because-exists copy would otherwise make a note embed the wrong
    group's media). `content_hash` (set only on a same-basename BYTE collision)
    disambiguates WITHIN a group: Telegram renumbers per export, so a
    partial/disjoint re-export can reuse `photo_1` for DIFFERENT bytes; the hash
    keeps the stale and the new asset distinct instead of one aliasing the other.
    """
    p = Path(ref)
    if content_hash:
        return f"{group_slug}__{p.stem}-{content_hash}{p.suffix}"
    return f"{group_slug}__{p.name}"


_TG_CHUNK_SIZE = 1 << 20  # 1 MiB — bounds memory for large media (videos)


def _tg_same_bytes(a, b):
    """True iff files a and b hold identical content. Streamed in bounded
    chunks so a large video is never pulled fully into memory."""
    try:
        if a.stat().st_size != b.stat().st_size:
            return False
        with a.open("rb") as fa, b.open("rb") as fb:
            while True:
                chunk_a = fa.read(_TG_CHUNK_SIZE)
                chunk_b = fb.read(_TG_CHUNK_SIZE)
                if chunk_a != chunk_b:
                    return False
                if not chunk_a:
                    return True
    except OSError:
        return False


def _tg_sha256_file(path):
    """SHA-256 hex digest of a file's contents, read in bounded chunks so a
    large video is never pulled fully into memory."""
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(_TG_CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _tg_copy_media(refs, export_dir, assets_dir, group_slug, dry_run):
    """Copy referenced full-res photos/videos into assets_dir under a
    group-scoped name (deduped, skip existing). -> (copied, skipped_existing,
    missing, ref_to_name). `ref_to_name` maps each resolved ref to the asset
    basename the note must embed — content-addressed on a same-basename byte
    collision so a note never embeds a stale image. A ref whose resolved src
    escapes export_dir (path traversal) or is absent counts as missing.
    """
    export_dir, assets_dir = Path(export_dir), Path(assets_dir)
    copied = skipped = missing = 0
    ref_to_name = {}
    try:
        export_root = export_dir.resolve()
    except OSError:
        export_root = export_dir.absolute()
    for ref in refs:
        try:
            resolved = (export_dir / ref).resolve()
            resolved.relative_to(export_root)  # containment guard
        except (ValueError, OSError):
            missing += 1
            continue
        if not resolved.exists():
            missing += 1
            continue
        name = _tg_asset_name(group_slug, ref)  # group-scoped basename -> no traversal + no cross-group alias
        dest = assets_dir / name
        if dest.exists() and not _tg_same_bytes(dest, resolved):
            # same basename, DIFFERENT bytes (Telegram renumbers per export, so a
            # partial re-export can reuse photo_N for other content) -> keep both
            # under a content-hashed name; the note embeds this one, not the stale.
            digest = _tg_sha256_file(resolved)[:12]
            name = _tg_asset_name(group_slug, ref, digest)
            dest = assets_dir / name
        ref_to_name[ref] = name
        if dest.exists():
            skipped += 1
            continue
        if not dry_run:
            assets_dir.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(resolved, dest)
        copied += 1
    return copied, skipped, missing, ref_to_name


def _tg_month_note(group_name, group_slug, month, entries, assets_dir_rel,
                   ref_to_name=None):
    """Render one month of messages as a markdown note (timestamps preserved).
    `ref_to_name` maps a media ref to its (possibly content-hashed) asset
    basename; a ref absent from the map (missing media) falls back to the plain
    group-scoped name."""
    ref_to_name = ref_to_name or {}
    first = entries[0].ts
    group_fm = re.sub(r"\s+", " ", group_name).strip()
    display = group_fm or "Telegram"
    # escape for a double-quoted YAML scalar — a `"` or `\` in the group name
    # would otherwise break the frontmatter (invalid YAML / Obsidian props)
    group_yaml = group_fm.replace("\\", "\\\\").replace('"', '\\"')
    lines = [
        "---",
        "type: chat-import",
        "source: telegram",
        f'group: "{group_yaml}"',
        f"created: {first:%Y-%m-%d}",
        f"month: {month}",
        f"messages: {len(entries)}",
        "tags: [chat-import, telegram]",
        "---",
        "",
        f"# {display} — {month}",
    ]
    cur_day = None
    for msg in entries:
        day = f"{msg.ts:%Y-%m-%d (%A)}"
        if day != cur_day:
            cur_day = day
            lines += ["", f"## {day}"]
        lines += ["", f"**{msg.ts:%H:%M} · {msg.sender}**"]
        if msg.body:
            lines.append(msg.body)
        for ref in msg.media:
            name = ref_to_name.get(ref) or _tg_asset_name(group_slug, ref)
            lines.append(f"![[{assets_dir_rel}/{name}]]")
    return "\n".join(lines) + "\n"


def _tg_note_signature(text):
    """The comparable content of a rendered month note: title+day/message
    text with the frontmatter (carries the `messages:` count) and media
    embed lines (`![[...]]`, whose name is content-hashed on a byte
    collision — see `_tg_asset_name`) stripped off. Two renders of the same
    messages compare equal even if the count metadata or a re-hashed media
    name differs."""
    m = re.search(r"^# ", text, re.M)
    body = text[m.start():] if m else text
    return "\n".join(line for line in body.splitlines()
                     if not line.startswith("![["))


def _fold_telegram(export_dir, vault_dir, dry_run, group_slug_override=None):
    export_dir, vault_dir = Path(export_dir), Path(vault_dir)
    group_name, msgs = parse_telegram(export_dir)
    group_slug = _tg_group_slug(group_name, export_dir, group_slug_override)
    group_dir = vault_dir / "chats" / "telegram" / group_slug
    assets_dir = vault_dir / "chats" / "telegram" / "_assets"
    assets_dir_rel = "chats/telegram/_assets"

    report = Report(dry_run=dry_run, provider="telegram")
    report.tg_group = group_name or group_slug
    report.tg_messages = len(msgs)

    by_month = {}
    for msg in msgs:
        by_month.setdefault(f"{msg.ts:%Y-%m}", []).append(msg)
    report.tg_months = len(by_month)

    # unique media refs across all messages (deduped, order-preserving)
    uniq_refs, seen = [], set()
    for msg in msgs:
        for ref in msg.media:
            if ref not in seen:
                seen.add(ref)
                uniq_refs.append(ref)
    copied, skipped, missing, ref_to_name = _tg_copy_media(
        uniq_refs, export_dir, assets_dir, group_slug, dry_run)
    report.assets_copied = copied
    report.assets_skipped_existing = skipped
    report.assets_missing = missing

    # monthly notes — idempotent re-import: a re-run overwrites the month note
    # with THIS export's messages, but only when doing so can't lose data.
    # Message COUNT alone doesn't prove that: Telegram HTML carries no stable
    # message id, so an equal-or-larger-count re-export could still be a
    # different/disjoint set for that month. Instead compare rendered content:
    # skip + warn unless the incoming render reproduces the existing note
    # verbatim (identical re-import) or as a prefix (a fuller, later export) —
    # to force a replace, delete the month note first.
    written = 0
    for month, entries in sorted(by_month.items()):
        dest = group_dir / f"{month}.md"
        note_text = _tg_month_note(group_name, group_slug, month, entries,
                                   assets_dir_rel, ref_to_name)
        if dest.exists():  # guard runs in dry-run too, so the reported count
            existing_sig = _tg_note_signature(dest.read_text(encoding="utf-8"))
            new_sig = _tg_note_signature(note_text)
            if not new_sig.startswith(existing_sig):
                print(f"warning: {dest.relative_to(vault_dir)} holds messages "
                      f"not reproduced by this import — skipping to avoid "
                      f"clobbering them (delete the note to force)",
                      file=sys.stderr)
                continue
        if not dry_run:
            group_dir.mkdir(parents=True, exist_ok=True)
            dest.write_text(note_text, encoding="utf-8")
        written += 1
    report.notes_created = written

    try:
        ensure_gitignore(vault_dir, dry_run)
        if not dry_run and (vault_dir / "chats").is_dir():
            write_index(vault_dir / "chats", dry_run)
    except Exception as e:
        print(f"warning: index/gitignore update failed: {e}", file=sys.stderr)
    return report


def fold(provider, export_dir, vault_dir, dry_run, group_slug=None):
    if provider == "telegram":
        return _fold_telegram(export_dir, vault_dir, dry_run, group_slug)
    export_dir, vault_dir = Path(export_dir), Path(vault_dir)
    provider_dir = vault_dir / "chats" / PROVIDER_DIRS[provider]
    assets_dir = provider_dir / "_assets"
    assets_dir_rel = f"chats/{PROVIDER_DIRS[provider]}/_assets"

    if provider == "gemini":
        all_raw_count = len(list(export_dir.glob("conversations/*.json")))
        conversations = parse_gemini(export_dir)
    else:
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
                render_note(conv, assets_dir_rel, available, provider=provider),
                encoding="utf-8")
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
    parser.add_argument("--group-slug", default=None, metavar="SLUG",
                        help="(telegram only) override the derived group dir slug")
    parser.add_argument("--dry-run", action="store_true",
                        help="report what would happen; write nothing")
    args = parser.parse_args(argv)
    if args.group_slug is not None and args.provider != "telegram":
        parser.error("--group-slug is telegram-only "
                      f"(provider is {args.provider!r})")

    export_dir, vault_dir = Path(args.export), Path(args.vault)
    if not export_dir.is_dir():
        print(f"error: export dir not found: {export_dir}", file=sys.stderr)
        return 1
    if not vault_dir.is_dir():
        print(f"error: vault dir not found: {vault_dir}", file=sys.stderr)
        return 1

    report = fold(args.provider, export_dir, vault_dir, args.dry_run,
                  group_slug=args.group_slug)
    for line in report.lines():
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
