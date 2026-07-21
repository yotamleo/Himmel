#!/usr/bin/env python3
"""Hermetic tests for fold-chat-history (stdlib unittest).

Run: python scripts/luna/test-fold-chat-history.py
"""
import importlib.util
import json
import re
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

_MOD_PATH = Path(__file__).resolve().parent / "fold-chat-history.py"
_spec = importlib.util.spec_from_file_location("fold_chat_history", _MOD_PATH)
fch = importlib.util.module_from_spec(_spec)
sys.modules["fold_chat_history"] = fch
_spec.loader.exec_module(fch)


# ---------- fixture builders ----------

def chain(*msgs, conv_id="conv-1", title="Test chat", create_time=1755500000.0,
          update_time=None, model="gpt-5"):
    """Build a raw conversation dict whose mapping is a linear chain of msgs.

    Each msg: dict(role=..., ctype=..., parts=[...], hidden=False).
    Returns the raw conversation dict (as in conversations-*.json).
    """
    mapping = {"root": {"id": "root", "message": None, "parent": None, "children": []}}
    prev = "root"
    for i, m in enumerate(msgs):
        nid = f"n{i}"
        message = None
        if m is not None:
            message = {
                "author": {"role": m["role"]},
                "content": {"content_type": m.get("ctype", "text"),
                            "parts": m.get("parts", [])},
                "metadata": ({"is_visually_hidden_from_conversation": True}
                             if m.get("hidden") else {}),
            }
        mapping[nid] = {"id": nid, "message": message, "parent": prev, "children": []}
        mapping[prev]["children"].append(nid)
        prev = nid
    return {
        "conversation_id": conv_id,
        "title": title,
        "create_time": create_time,
        "update_time": update_time,
        "default_model_slug": model,
        "mapping": mapping,
        "current_node": prev,
    }


def u(text):
    return {"role": "user", "parts": [text]}


def a(text):
    return {"role": "assistant", "parts": [text]}


class TestParseConversation(unittest.TestCase):
    def test_linear_text_chain(self):
        conv = fch.parse_conversation(chain(u("hi"), a("hello"), u("bye"), a("cya")))
        self.assertEqual(conv.id, "conv-1")
        self.assertEqual(conv.title, "Test chat")
        self.assertEqual([t.role for t in conv.turns],
                         ["user", "assistant", "user", "assistant"])
        self.assertEqual(conv.turns[0].segments, [("text", "hi")])
        self.assertEqual(conv.model, "gpt-5")

    def test_edit_branch_dropped(self):
        # main thread = current_node parent chain; abandoned sibling not rendered
        raw = chain(u("keep-q"), a("keep-a"))
        # graft an abandoned branch off root
        raw["mapping"]["orphan"] = {
            "id": "orphan",
            "message": {"author": {"role": "assistant"},
                        "content": {"content_type": "text", "parts": ["ABANDONED"]},
                        "metadata": {}},
            "parent": "root", "children": [],
        }
        raw["mapping"]["root"]["children"].append("orphan")
        conv = fch.parse_conversation(raw)
        flat = json.dumps([t.segments for t in conv.turns])
        self.assertNotIn("ABANDONED", flat)
        self.assertEqual(len(conv.turns), 2)

    def test_skips_system_tool_hidden_thoughts_recap_empty(self):
        raw = chain(
            {"role": "system", "parts": ["sys"]},
            u("real question"),
            {"role": "assistant", "ctype": "thoughts", "parts": ["thinking..."]},
            {"role": "assistant", "ctype": "reasoning_recap", "parts": ["recap"]},
            {"role": "tool", "parts": ["tool out"]},
            {"role": "assistant", "parts": ["real answer"]},
            {"role": "user", "parts": [""]},          # empty text -> skipped
            {"role": "user", "parts": ["hidden"], "hidden": True},
        )
        conv = fch.parse_conversation(raw)
        self.assertEqual([t.role for t in conv.turns], ["user", "assistant"])
        self.assertEqual(conv.turns[1].segments, [("text", "real answer")])

    def test_zero_renderable_returns_none(self):
        raw = chain({"role": "system", "parts": ["only system"]})
        self.assertIsNone(fch.parse_conversation(raw))

    def test_created_from_create_time(self):
        conv = fch.parse_conversation(chain(u("x"), create_time=1755500000.0))
        self.assertEqual(conv.created.year, 2025)
        self.assertIsNone(conv.updated)

    def test_null_create_time_returns_none(self):
        raw = chain(u("x"), a("y"))
        raw["create_time"] = None
        self.assertIsNone(fch.parse_conversation(raw))

    def test_missing_create_time_returns_none(self):
        raw = chain(u("x"), a("y"))
        del raw["create_time"]
        self.assertIsNone(fch.parse_conversation(raw))

    def test_non_dict_raw_returns_none(self):
        self.assertIsNone(fch.parse_conversation(None))
        self.assertIsNone(fch.parse_conversation("junk"))

    def test_null_author_skipped_not_raised(self):
        raw = chain(u("keep"), a("also-keep"))
        raw["mapping"]["n0"]["message"]["author"] = None  # explicit JSON null
        conv = fch.parse_conversation(raw)
        self.assertIsNotNone(conv)
        self.assertEqual([t.role for t in conv.turns], ["assistant"])

    def test_null_metadata_not_raised(self):
        raw = chain(u("hi"), a("hello"))
        raw["mapping"]["n0"]["message"]["metadata"] = None  # explicit JSON null
        conv = fch.parse_conversation(raw)
        self.assertIsNotNone(conv)
        self.assertEqual([t.role for t in conv.turns], ["user", "assistant"])

    def test_cyclic_parent_chain_returns_fast(self):
        raw = chain(u("a"), a("b"))
        # corrupt mapping into a 2-node cycle (n0 <-> n1) with no path to root
        raw["mapping"]["n0"]["parent"] = "n1"
        conv = fch.parse_conversation(raw)  # must return, not hang
        self.assertIsNotNone(conv)


class TestParseChatgpt(unittest.TestCase):
    def test_reads_all_conversation_files_sorted(self):
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td)
            (ed / "conversations-000.json").write_text(
                json.dumps([chain(u("a"), conv_id="c1")]), encoding="utf-8")
            (ed / "conversations-001.json").write_text(
                json.dumps([chain(u("b"), conv_id="c2"),
                            chain({"role": "system", "parts": ["x"]}, conv_id="c3")]),
                encoding="utf-8")
            convs = fch.parse_chatgpt(ed)
            self.assertEqual([c.id for c in convs], ["c1", "c2"])


def gemini_chat(title="Test chat", updated_at="2026-06-20T17:48:45.000Z",
                 turns=(("user", "hi"), ("assistant", "hello"))):
    """Build a raw Gemini AI-Toolbox chat dict (one file under conversations/)."""
    raw = {
        "exported_at": "2026-07-10T17:31:44.585Z",
        "conversation": [{"role": r, "content": c} for r, c in turns],
        "exported_by": {"name": "AI Toolbox"},
    }
    if title is not None:
        raw["title"] = title
    if updated_at is not None:
        raw["updated_at"] = updated_at
    return raw


class TestParseGemini(unittest.TestCase):
    def _write(self, ed, name, raw):
        convdir = ed / "conversations"
        convdir.mkdir(exist_ok=True)
        (convdir / name).write_text(json.dumps(raw), encoding="utf-8")

    def test_two_turn_fixture(self):
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td)
            self._write(ed, "chat1.json", gemini_chat())
            convs = fch.parse_gemini(ed)
            self.assertEqual(len(convs), 1)
            conv = convs[0]
            self.assertEqual(conv.title, "Test chat")
            self.assertEqual([t.role for t in conv.turns], ["user", "assistant"])
            self.assertEqual(conv.turns[0].segments, [("text", "hi")])
            self.assertEqual(conv.turns[1].segments, [("text", "hello")])
            self.assertTrue(conv.id.startswith("synthetic-"))
            self.assertEqual(conv.model, "gemini")
            self.assertEqual(conv.created, datetime.fromisoformat(
                "2026-06-20T17:48:45.000+00:00"))
            self.assertEqual(conv.updated, conv.created)

    def test_synthetic_id_stable_across_reexport(self):
        # A re-export changes volatile fields (exported_at) but not the chat;
        # the synthetic id must stay identical so a re-fold dedups instead of
        # duplicating (HIMMEL-885 codex-adv).
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td)
            first = gemini_chat()
            second = gemini_chat()
            second["exported_at"] = "2027-01-01T00:00:00.000Z"
            self.assertNotEqual(first["exported_at"], second["exported_at"])
            self._write(ed, "first.json", first)
            id1 = fch.parse_gemini(ed)[0].id
            with tempfile.TemporaryDirectory() as td2:
                ed2 = Path(td2)
                self._write(ed2, "second.json", second)
                id2 = fch.parse_gemini(ed2)[0].id
            self.assertEqual(id1, id2)

    def test_reads_all_files_sorted(self):
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td)
            self._write(ed, "b.json", gemini_chat(title="B"))
            self._write(ed, "a.json", gemini_chat(title="A"))
            convs = fch.parse_gemini(ed)
            self.assertEqual([c.title for c in convs], ["A", "B"])

    def test_empty_conversation_array_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td)
            self._write(ed, "empty.json", gemini_chat(turns=()))
            self.assertEqual(fch.parse_gemini(ed), [])

    def test_non_render_role_and_blank_content_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td)
            self._write(ed, "sys.json", gemini_chat(
                turns=(("system", "sys prompt"), ("user", ""))))
            self.assertEqual(fch.parse_gemini(ed), [])

    def test_missing_updated_at_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td)
            self._write(ed, "nodate.json", gemini_chat(updated_at=None))
            self.assertEqual(fch.parse_gemini(ed), [])

    def test_invalid_updated_at_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td)
            self._write(ed, "baddate.json", gemini_chat(updated_at="not-a-date"))
            self.assertEqual(fch.parse_gemini(ed), [])

    def test_missing_title_defaults_untitled(self):
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td)
            self._write(ed, "notitle.json", gemini_chat(title=None))
            self.assertEqual(fch.parse_gemini(ed)[0].title, "untitled")


class TestMultimodalSegments(unittest.TestCase):
    def test_image_pointer_both_schemes(self):
        raw = chain({"role": "user", "ctype": "multimodal_text", "parts": [
            {"content_type": "image_asset_pointer",
             "asset_pointer": "sediment://file_0001"},
            "what is this?",
            {"content_type": "image_asset_pointer",
             "asset_pointer": "file-service://file-ABC"},
        ]})
        conv = fch.parse_conversation(raw)
        self.assertEqual(conv.turns[0].segments, [
            ("image", "file_0001"),
            ("text", "what is this?"),
            ("image", "file-ABC"),
        ])

    def test_voice_chat_transcription_renders(self):
        # spec round-2: voice chats are NOT empty — transcription is the body
        # real export shape: user-side real_time parts have NO top-level
        # asset_pointer (it is nested under part["audio_asset_pointer"]) ->
        # segment value is "" but the placeholder must still render
        raw = chain(
            {"role": "user", "ctype": "multimodal_text", "parts": [
                {"content_type": "real_time_user_audio_video_asset_pointer",
                 "audio_asset_pointer":
                     {"asset_pointer": "sediment://file_wav1"}},
                {"content_type": "audio_transcription",
                 "text": "how long to cook frozen chicken"},
            ]},
            {"role": "assistant", "ctype": "multimodal_text", "parts": [
                {"content_type": "audio_transcription", "text": "about 25 minutes"},
                {"content_type": "audio_asset_pointer",
                 "asset_pointer": "sediment://file_wav2"},
            ]},
        )
        conv = fch.parse_conversation(raw)
        self.assertIsNotNone(conv)
        self.assertEqual(conv.turns[0].segments, [
            ("audio", ""),
            ("text", "how long to cook frozen chicken"),
        ])
        self.assertEqual(conv.turns[1].segments, [
            ("text", "about 25 minutes"),
            ("audio", "file_wav2"),
        ])

    def test_unknown_dict_part_ignored(self):
        raw = chain({"role": "user", "ctype": "multimodal_text", "parts": [
            {"content_type": "some_future_type", "data": "x"},
            "still works",
        ]})
        conv = fch.parse_conversation(raw)
        self.assertEqual(conv.turns[0].segments, [("text", "still works")])


class TestSlugAndRender(unittest.TestCase):
    def test_slugify_hebrew_kept_windows_unsafe_stripped(self):
        self.assertEqual(fch.slugify("הגדרת מידע: רשמי?"), "הגדרת-מידע-רשמי")
        self.assertEqual(fch.slugify('a<b>c:"d/e\\f|g?h*i'), "abcdefghi")
        self.assertEqual(fch.slugify("[[link]] #tag ^block"), "link-tag-block")
        self.assertEqual(fch.slugify("   "), "untitled")
        self.assertLessEqual(len(fch.slugify("x" * 200)), 60)

    def test_note_filename_collision_same_month(self):
        taken = set()
        c1 = fch.parse_conversation(chain(u("a"), conv_id="aaaa1111-x",
                                          title="New chat",
                                          create_time=1755500000.0))
        c2 = fch.parse_conversation(chain(u("b"), conv_id="bbbb2222-y",
                                          title="New chat",
                                          create_time=1755500000.0))
        f1 = fch.note_filename(c1, taken)
        f2 = fch.note_filename(c2, taken)
        self.assertNotEqual(f1, f2)
        self.assertIn("bbbb2222", f2)

    def test_render_note_frontmatter_and_turns(self):
        conv = fch.parse_conversation(chain(
            u("שאלה בעברית"), a("answer"),
            conv_id="cid-1", title="My chat", model="gpt-5",
            create_time=1755500000.0, update_time=1755600000.0))
        text = fch.render_note(conv, "chats/gpt/_assets", {})
        self.assertTrue(text.startswith("---\n"))
        self.assertIn("type: chat-import", text)
        self.assertIn("source: chatgpt", text)
        self.assertIn("conversation_id: cid-1", text)
        self.assertIn("model: gpt-5", text)
        self.assertIn("messages: 2", text)
        self.assertIn("tags: [chat-import, gpt]", text)
        self.assertIn("enriched: false", text)
        self.assertIn("# My chat", text)
        self.assertIn("## 🧑 User\n\nשאלה בעברית", text)
        self.assertIn("## 🤖 Assistant\n\nanswer", text)

    def test_render_note_assets_and_placeholders(self):
        raw = chain({"role": "user", "ctype": "multimodal_text", "parts": [
            {"content_type": "image_asset_pointer",
             "asset_pointer": "sediment://file_here"},
            {"content_type": "image_asset_pointer",
             "asset_pointer": "sediment://file_gone"},
            {"content_type": "audio_asset_pointer",
             "asset_pointer": "sediment://file_wav"},
            "caption",
        ]})
        conv = fch.parse_conversation(raw)
        text = fch.render_note(conv, "chats/gpt/_assets",
                               {"file_here": "file_here.png"})
        self.assertIn("![[chats/gpt/_assets/file_here.png]]", text)
        self.assertIn("[image: file_gone — not in export archive]", text)
        self.assertIn("[audio: not in export archive]", text)
        self.assertNotIn("file_gone.dat", text)

    def test_render_note_gemini_frontmatter(self):
        conv = fch.Conversation(
            id="synthetic-abc123def456",
            title="Gemini chat",
            created=datetime(2026, 6, 20, 17, 48, 45),
            updated=datetime(2026, 6, 20, 17, 48, 45),
            model="gemini",
            turns=[fch.Turn("user", [("text", "hi")]),
                   fch.Turn("assistant", [("text", "hello")])],
        )
        text = fch.render_note(conv, "chats/gemini/_assets", {}, provider="gemini")
        self.assertIn("source: gemini", text)
        self.assertIn("tags: [chat-import, gemini]", text)
        self.assertIn("model: gemini", text)
        self.assertIn("messages: 2", text)
        self.assertIn("enriched: false", text)
        self.assertIn("conversation_id: synthetic-abc123def456", text)
        self.assertIn("# Gemini chat", text)
        self.assertIn("## 🧑 User\n\nhi", text)
        self.assertIn("## 🤖 Assistant\n\nhello", text)

    def test_render_note_default_provider_is_chatgpt(self):
        # existing 2-arg call sites (no provider kwarg) must stay byte-identical
        conv = fch.parse_conversation(chain(u("hi"), a("hello"), conv_id="cid-2",
                                            title="X", create_time=1755500000.0))
        text_default = fch.render_note(conv, "chats/gpt/_assets", {})
        text_explicit = fch.render_note(conv, "chats/gpt/_assets", {}, provider="chatgpt")
        self.assertEqual(text_default, text_explicit)


PNG_MAGIC = b"\x89PNG\r\n\x1a\n" + b"\x00" * 8
JPEG_MAGIC = b"\xff\xd8\xff\xe0" + b"\x00" * 8


class TestAssets(unittest.TestCase):
    def _export(self, td):
        ed = Path(td)
        (ed / "file-MAPPED.dat").write_bytes(JPEG_MAGIC)
        (ed / "file_sniffed.dat").write_bytes(PNG_MAGIC)
        (ed / "file_mystery.dat").write_bytes(b"\x00unknown\x00" * 4)
        (ed / "conversation_asset_file_names.json").write_text(
            json.dumps({"file-MAPPED.dat": "photo 1.jpg"}), encoding="utf-8")
        return ed

    def _convs(self):
        raw = chain({"role": "user", "ctype": "multimodal_text", "parts": [
            {"content_type": "image_asset_pointer",
             "asset_pointer": "file-service://file-MAPPED"},
            {"content_type": "image_asset_pointer",
             "asset_pointer": "sediment://file_sniffed"},
            {"content_type": "image_asset_pointer",
             "asset_pointer": "sediment://file_mystery"},
            {"content_type": "image_asset_pointer",
             "asset_pointer": "sediment://file_absent"},
            {"content_type": "image_asset_pointer",
             "asset_pointer": "file-service://file-MAPPED"},  # dup -> once
        ]})
        return [fch.parse_conversation(raw)]

    def test_referenced_ids_unique_ordered(self):
        self.assertEqual(fch.referenced_image_ids(self._convs()),
                         ["file-MAPPED", "file_sniffed", "file_mystery",
                          "file_absent"])

    def test_copy_assets(self):
        with tempfile.TemporaryDirectory() as td:
            ed = self._export(td)
            assets = Path(td) / "vault-assets"
            available, copied, skipped, missing, unrecognized = fch.copy_assets(
                self._convs(), ed, assets, dry_run=False)
            # mapped name wins; sniff fallback works; mystery -> unrecognized, absent -> missing
            self.assertEqual(available, {"file-MAPPED": "file-MAPPED.jpg",
                                         "file_sniffed": "file_sniffed.png"})
            self.assertEqual((copied, skipped, missing, unrecognized), (2, 0, 1, 1))
            self.assertTrue((assets / "file-MAPPED.jpg").exists())
            # idempotent second run: 0 copied, 2 skipped-existing
            available2, copied2, skipped2, missing2, unrecognized2 = fch.copy_assets(
                self._convs(), ed, assets, dry_run=False)
            self.assertEqual(available2, available)
            self.assertEqual((copied2, skipped2, missing2, unrecognized2), (0, 2, 1, 1))

    def test_copy_assets_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as td:
            ed = self._export(td)
            assets = Path(td) / "vault-assets"
            available, copied, skipped, missing, unrecognized = fch.copy_assets(
                self._convs(), ed, assets, dry_run=True)
            self.assertEqual(copied, 2)
            self.assertFalse(assets.exists())

    def test_copy_assets_junk_extension_in_map_falls_back_to_sniff(self):
        # HIMMEL-832: a .dat file with PNG magic whose map entry has junk
        # (e.g. "x.png/../../evil") should sniff the magic and return "png",
        # not the crafted string
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td) / "export"
            ed.mkdir()
            # .dat file with PNG magic
            (ed / "file_junk.dat").write_bytes(PNG_MAGIC)
            # map entry with path separator in the extension
            (ed / "conversation_asset_file_names.json").write_text(
                json.dumps({"file_junk.dat": "x.png/../../evil"}), encoding="utf-8")
            assets = Path(td) / "vault-assets"
            raw = chain({"role": "user", "ctype": "multimodal_text", "parts": [
                {"content_type": "image_asset_pointer",
                 "asset_pointer": "sediment://file_junk"},
            ]})
            convs = [fch.parse_conversation(raw)]
            available, copied, skipped, missing, unrecognized = fch.copy_assets(
                convs, ed, assets, dry_run=False)
            # should copy as file_junk.png, not file_junk.png/../../evil
            self.assertEqual(available, {"file_junk": "file_junk.png"})
            self.assertEqual((copied, skipped, missing, unrecognized), (1, 0, 0, 0))
            # verify only the safe file exists
            self.assertTrue((assets / "file_junk.png").exists())
            self.assertFalse((Path(td) / "evil").exists())

    def test_copy_assets_unsafe_id_rejected(self):
        # a crafted asset_pointer with path-traversal segments must never be
        # interpolated into a filesystem path — counted as missing (renders
        # the existing "not in export archive" placeholder)
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td) / "export"
            ed.mkdir()
            assets = Path(td) / "vault-assets"
            raw = chain({"role": "user", "ctype": "multimodal_text", "parts": [
                {"content_type": "image_asset_pointer",
                 "asset_pointer": "sediment://../../evil"},
            ]})
            convs = [fch.parse_conversation(raw)]
            available, copied, skipped, missing, unrecognized = fch.copy_assets(
                convs, ed, assets, dry_run=False)
            self.assertEqual(available, {})
            self.assertEqual((copied, skipped, missing, unrecognized), (0, 0, 1, 0))
            self.assertFalse(assets.exists())
            self.assertFalse((Path(td) / "evil").exists())
            self.assertFalse((Path(td).parent / "evil").exists())
            text = fch.render_note(convs[0], "chats/gpt/_assets", available)
            self.assertIn("not in export archive", text)


class TestFold(unittest.TestCase):
    def _make_export(self, td, convs=None):
        ed = Path(td) / "export"
        ed.mkdir()
        (ed / "file-IMG.dat").write_bytes(JPEG_MAGIC)
        (ed / "conversation_asset_file_names.json").write_text(
            json.dumps({"file-IMG.dat": "pic.jpg"}), encoding="utf-8")
        if convs is None:
            convs = [
                chain(u("שאלה"), a("תשובה"), conv_id="c-heb",
                      title="שיחה בעברית", create_time=1755500000.0),
                chain({"role": "user", "ctype": "multimodal_text", "parts": [
                           {"content_type": "image_asset_pointer",
                            "asset_pointer": "file-service://file-IMG"},
                           {"content_type": "audio_asset_pointer",
                            "asset_pointer": "sediment://file_voice"},
                           {"content_type":
                                "real_time_user_audio_video_asset_pointer",
                            "audio_asset_pointer":
                                {"asset_pointer": "sediment://file_rt"}},
                           "look"]},
                      a("nice"), conv_id="c-img", title="Pic chat",
                      create_time=1758200000.0),
                chain({"role": "system", "parts": ["x"]}, conv_id="c-empty",
                      title="Empty", create_time=1758200000.0),
            ]
        (ed / "conversations-000.json").write_text(
            json.dumps(convs), encoding="utf-8")
        return ed

    def test_fold_end_to_end_and_idempotent(self):
        with tempfile.TemporaryDirectory() as td:
            ed = self._make_export(td)
            vault = Path(td) / "vault"
            vault.mkdir()
            report = fch.fold("chatgpt", ed, vault, dry_run=False)
            self.assertEqual(report.notes_created, 2)
            self.assertEqual(report.convs_skipped_empty, 1)
            self.assertEqual(report.assets_copied, 1)
            # named-only count: the empty-pointer real_time part renders a
            # placeholder but does NOT increment the counter
            self.assertEqual(report.audio_placeholders, 1)
            gpt = vault / "chats" / "gpt"
            # Derive expected dates via the same UTC conversion the module uses.
            d1 = datetime.fromtimestamp(1755500000.0, timezone.utc)
            d2 = datetime.fromtimestamp(1758200000.0, timezone.utc)
            heb_name = f"{d1:%Y-%m-%d}-שיחה-בעברית.md"
            pic_name = f"{d2:%Y-%m-%d}-Pic-chat.md"
            notes = sorted(p.name for p in gpt.rglob("*.md"))
            self.assertEqual(notes, sorted([heb_name, pic_name]))
            self.assertTrue((gpt / f"{d1:%Y-%m}" / heb_name).exists())
            self.assertTrue((gpt / "_assets" / "file-IMG.jpg").exists())
            index = (vault / "chats" / "_index.md").read_text(encoding="utf-8")
            self.assertIn("שיחה בעברית", index)
            gi = (vault / ".gitignore").read_text(encoding="utf-8")
            self.assertIn("chats/*/_assets/", gi)
            # second run: nothing new
            report2 = fch.fold("chatgpt", ed, vault, dry_run=False)
            self.assertEqual(report2.notes_created, 0)
            self.assertEqual(report2.notes_skipped_existing, 2)
            self.assertEqual(report2.assets_copied, 0)
            self.assertEqual(report2.assets_skipped_existing, 1)
            # gitignore rule not duplicated
            gi2 = (vault / ".gitignore").read_text(encoding="utf-8")
            self.assertEqual(gi2.count("chats/*/_assets/"), 1)

    def test_index_escapes_pipe_in_title(self):
        with tempfile.TemporaryDirectory() as td:
            conv = chain(u("q"), a("a"), title="Pipe | title")
            ed = self._make_export(td, convs=[conv])
            vault = Path(td) / "vault"
            vault.mkdir()
            fch.fold("chatgpt", ed, vault, dry_run=False)
            index = (vault / "chats" / "_index.md").read_text(encoding="utf-8")
            self.assertRegex(
                index,
                r"\| [^|]+ \| \[\[[^\]]+\\\|Pipe \\\| title\]\] \| \d+ \|",
            )

    def test_fold_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as td:
            ed = self._make_export(td)
            vault = Path(td) / "vault"
            vault.mkdir()
            report = fch.fold("chatgpt", ed, vault, dry_run=True)
            self.assertEqual(report.notes_created, 2)
            self.assertEqual(report.assets_copied, 1)
            self.assertEqual(list(vault.iterdir()), [])

    def test_fold_same_title_same_time_no_id_no_overwrite(self):
        # three conversations, same title + create_time, conversation_id absent
        # but different mapping sizes -> different synthetic ids, each creates
        # a distinct note via the filename collision loop
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td) / "export"
            ed.mkdir()
            # vary message count so mapping sizes differ: 1, 2, 3 messages
            convs = [
                chain(u("q0"), title="Same title",
                      create_time=1755500000.0, conv_id=None),
                chain(u("q1"), a("a1"), title="Same title",
                      create_time=1755500000.0, conv_id=None),
                chain(u("q2"), a("a2"), u("q2b"), title="Same title",
                      create_time=1755500000.0, conv_id=None),
            ]
            (ed / "conversations-000.json").write_text(
                json.dumps(convs), encoding="utf-8")
            vault = Path(td) / "vault"
            vault.mkdir()
            report = fch.fold("chatgpt", ed, vault, dry_run=False)
            self.assertEqual(report.notes_created, 3)
            notes = list((vault / "chats" / "gpt").rglob("*.md"))
            self.assertEqual(len(notes), 3)

    def test_fold_same_title_same_time_same_size_different_content_no_collision(self):
        # HIMMEL-832: two conversations with identical title + create_time +
        # message count but DIFFERENT text must NOT collide (old seed bug:
        # title|create_time|mapping-size would collide; full-record hash fixes)
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td) / "export"
            ed.mkdir()
            # Both have 1 user message (2-node mapping: root + n0), but different content
            convs = [
                chain(u("aaa"), title="Same title",
                      create_time=1755500000.0, conv_id=None),
                chain(u("bbb"), title="Same title",
                      create_time=1755500000.0, conv_id=None),
            ]
            (ed / "conversations-000.json").write_text(
                json.dumps(convs), encoding="utf-8")
            vault = Path(td) / "vault"
            vault.mkdir()
            report = fch.fold("chatgpt", ed, vault, dry_run=False)
            # without the fix, these would collide into 1 note; with fix, 2 distinct notes
            self.assertEqual(report.notes_created, 2)
            notes = list((vault / "chats" / "gpt").rglob("*.md"))
            self.assertEqual(len(notes), 2)
            # verify they have different ids
            ids = []
            for note in sorted(notes):
                text = note.read_text(encoding="utf-8")
                match = re.search(r"^conversation_id:\s*(.+?)$", text, re.MULTILINE)
                if match:
                    ids.append(match.group(1))
            self.assertEqual(len(ids), 2)
            self.assertNotEqual(ids[0], ids[1], "distinct conversations should have distinct ids")

    def test_fold_missing_conversation_id_idempotent_with_synthetic_id(self):
        # conversation with missing conversation_id -> synthetic id generated
        # from title, create_time, mapping size. Reruns are idempotent.
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td) / "export"
            ed.mkdir()
            raw = chain(u("hello"), a("hi"), title="Test", create_time=1755500000.0)
            del raw["conversation_id"]  # simulate missing id in export
            (ed / "conversations-000.json").write_text(
                json.dumps([raw]), encoding="utf-8")
            vault = Path(td) / "vault"
            vault.mkdir()
            # first run
            report1 = fch.fold("chatgpt", ed, vault, dry_run=False)
            self.assertEqual(report1.notes_created, 1)
            self.assertEqual(report1.notes_skipped_existing, 0)
            # verify synthetic id is in frontmatter
            notes = list((vault / "chats" / "gpt").rglob("*.md"))
            self.assertEqual(len(notes), 1)
            note_text = notes[0].read_text(encoding="utf-8")
            self.assertIn("conversation_id: synthetic-", note_text)
            # second run: idempotent (no duplicates)
            report2 = fch.fold("chatgpt", ed, vault, dry_run=False)
            self.assertEqual(report2.notes_created, 0)
            self.assertEqual(report2.notes_skipped_existing, 1)
            self.assertEqual(len(list((vault / "chats" / "gpt").rglob("*.md"))), 1)

    def test_fold_non_dict_conversation_entries_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td) / "export"
            ed.mkdir()
            valid = chain(u("hi"), a("hello"), conv_id="c-valid")
            (ed / "conversations-000.json").write_text(
                json.dumps([None, "junk", valid]), encoding="utf-8")
            vault = Path(td) / "vault"
            vault.mkdir()
            report = fch.fold("chatgpt", ed, vault, dry_run=False)
            self.assertEqual(report.notes_created, 1)
            self.assertEqual(report.convs_skipped_empty, 2)

    def test_fold_intra_run_duplicate_conversation_ids_deduped(self):
        # Fix 1: one export file containing the SAME conversation dict twice
        # -> fold reports notes_created 1, notes_skipped_existing 1 (second
        # occurrence counted as intra-run duplicate via known set)
        with tempfile.TemporaryDirectory() as td:
            same_conv = chain(u("hello"), a("hi"), conv_id="c-dup",
                            title="Duplicate test", create_time=1755500000.0)
            # include the same conversation dict twice
            ed = self._make_export(td, convs=[same_conv, same_conv])
            vault = Path(td) / "vault"
            vault.mkdir()
            report = fch.fold("chatgpt", ed, vault, dry_run=False)
            # first run: should create 1, skip 0 (intra-run dedup)
            self.assertEqual(report.notes_created, 1)
            self.assertEqual(report.notes_skipped_existing, 1)
            notes = list((vault / "chats" / "gpt").rglob("*.md"))
            self.assertEqual(len(notes), 1)

    def test_fold_unsafe_conversation_id_sanitized_to_synthetic(self):
        # Fix 2: conversation with newline/colon in conversation_id gets
        # redirected to synthetic-id path; fold twice stays idempotent
        with tempfile.TemporaryDirectory() as td:
            unsafe_conv = chain(u("test"), title="Evil ID test",
                              create_time=1755500000.0,
                              conv_id="evil\nout: injected")
            ed = self._make_export(td, convs=[unsafe_conv])
            vault = Path(td) / "vault"
            vault.mkdir()
            report1 = fch.fold("chatgpt", ed, vault, dry_run=False)
            self.assertEqual(report1.notes_created, 1)
            # verify unsafe id was replaced with synthetic
            notes = list((vault / "chats" / "gpt").rglob("*.md"))
            self.assertEqual(len(notes), 1)
            note_text = notes[0].read_text(encoding="utf-8")
            self.assertIn("conversation_id: synthetic-", note_text)
            self.assertNotIn("evil\nout:", note_text)
            # second run: idempotent (0 created, 1 skipped)
            report2 = fch.fold("chatgpt", ed, vault, dry_run=False)
            self.assertEqual(report2.notes_created, 0)
            self.assertEqual(report2.notes_skipped_existing, 1)

    def test_fold_unsafe_model_slug_omitted_from_frontmatter(self):
        # Fix 3: conversation with newline/colon in model slug ->
        # parsed model is None, renders NO model: line in frontmatter
        with tempfile.TemporaryDirectory() as td:
            unsafe_conv = chain(u("test"), title="Evil Model test",
                              create_time=1755500000.0,
                              model="gpt\nevil: x")
            ed = self._make_export(td, convs=[unsafe_conv])
            vault = Path(td) / "vault"
            vault.mkdir()
            report = fch.fold("chatgpt", ed, vault, dry_run=False)
            self.assertEqual(report.notes_created, 1)
            notes = list((vault / "chats" / "gpt").rglob("*.md"))
            self.assertEqual(len(notes), 1)
            note_text = notes[0].read_text(encoding="utf-8")
            # model line should be absent, no injection
            self.assertNotIn("model:", note_text)
            self.assertNotIn("evil: x", note_text)
            self.assertNotIn("evil:\n", note_text)

    def test_fold_survives_unreadable_existing_note(self):
        with tempfile.TemporaryDirectory() as td:
            ed = self._make_export(td)
            vault = Path(td) / "vault"
            vault.mkdir()
            report1 = fch.fold("chatgpt", ed, vault, dry_run=False)
            self.assertEqual(report1.notes_created, 2)
            # drop a non-UTF-8 .md file into the provider dir between folds
            gpt = vault / "chats" / "gpt"
            (gpt / "corrupt.md").write_bytes(b"\xff\xfe garbage")
            report2 = fch.fold("chatgpt", ed, vault, dry_run=False)
            self.assertEqual(report2.notes_created, 0)
            self.assertEqual(report2.notes_skipped_existing, 2)
            for line in report2.lines():
                self.assertIsInstance(line, str)


class TestFoldGemini(unittest.TestCase):
    def _make_export(self, td, chats=None):
        ed = Path(td) / "export"
        convdir = ed / "conversations"
        convdir.mkdir(parents=True)
        if chats is None:
            chats = [
                ("real-chat.json", gemini_chat(title="Real chat")),
                ("empty-chat.json", gemini_chat(title="Empty", turns=())),
            ]
        for name, raw in chats:
            (convdir / name).write_text(json.dumps(raw), encoding="utf-8")
        return ed

    def test_fold_end_to_end_writes_gemini_dir(self):
        with tempfile.TemporaryDirectory() as td:
            ed = self._make_export(td)
            vault = Path(td) / "vault"
            vault.mkdir()
            report = fch.fold("gemini", ed, vault, dry_run=False)
            self.assertEqual(report.notes_created, 1)
            self.assertEqual(report.convs_skipped_empty, 1)
            gemini_dir = vault / "chats" / "gemini"
            notes = list(gemini_dir.rglob("*.md"))
            self.assertEqual(len(notes), 1)
            created = datetime.fromisoformat("2026-06-20T17:48:45.000+00:00")
            self.assertTrue((gemini_dir / f"{created:%Y-%m}").is_dir())
            text = notes[0].read_text(encoding="utf-8")
            self.assertIn("source: gemini", text)
            self.assertIn("tags: [chat-import, gemini]", text)
            self.assertIn("model: gemini", text)
            self.assertIn("conversation_id: synthetic-", text)

    def test_fold_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as td:
            ed = self._make_export(td)
            vault = Path(td) / "vault"
            vault.mkdir()
            report = fch.fold("gemini", ed, vault, dry_run=True)
            self.assertEqual(report.notes_created, 1)
            self.assertEqual(list(vault.iterdir()), [])

    def test_fold_idempotent_rerun(self):
        with tempfile.TemporaryDirectory() as td:
            ed = self._make_export(td)
            vault = Path(td) / "vault"
            vault.mkdir()
            report1 = fch.fold("gemini", ed, vault, dry_run=False)
            self.assertEqual(report1.notes_created, 1)
            report2 = fch.fold("gemini", ed, vault, dry_run=False)
            self.assertEqual(report2.notes_created, 0)
            self.assertEqual(report2.notes_skipped_existing, 1)
            notes = list((vault / "chats" / "gemini").rglob("*.md"))
            self.assertEqual(len(notes), 1)


class TestCli(unittest.TestCase):
    def test_main_dry_run_prints_report(self):
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td) / "export"
            ed.mkdir()
            (ed / "conversations-000.json").write_text(
                json.dumps([chain(u("q"), a("a"), conv_id="c1")]),
                encoding="utf-8")
            vault = Path(td) / "vault"
            vault.mkdir()
            import contextlib, io
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = fch.main(["--provider", "chatgpt", "--export", str(ed),
                               "--vault", str(vault), "--dry-run"])
            self.assertEqual(rc, 0)
            self.assertIn("notes created: 1", buf.getvalue())
            self.assertEqual(list(vault.iterdir()), [])

    def test_main_rejects_unknown_provider(self):
        with self.assertRaises(SystemExit):
            fch.main(["--provider", "bogus", "--export", "x", "--vault", "y"])

    def test_main_rejects_missing_export_dir(self):
        with tempfile.TemporaryDirectory() as td:
            rc = fch.main(["--provider", "chatgpt",
                           "--export", str(Path(td) / "nope"),
                           "--vault", td])
            self.assertEqual(rc, 1)

    def test_main_rejects_missing_vault_dir(self):
        with tempfile.TemporaryDirectory() as td:
            export = Path(td) / "export"
            export.mkdir()
            rc = fch.main(["--provider", "chatgpt", "--export", str(export),
                           "--vault", str(Path(td) / "nope")])
            self.assertEqual(rc, 1)

    def test_main_empty_export_reports_all_zero(self):
        with tempfile.TemporaryDirectory() as td:
            export = Path(td) / "export"
            vault = Path(td) / "vault"
            export.mkdir()
            vault.mkdir()
            import contextlib, io
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = fch.main(["--provider", "chatgpt", "--export", str(export),
                               "--vault", str(vault), "--dry-run"])
            self.assertEqual(rc, 0)
            report = buf.getvalue()
            self.assertIn("notes created: 0", report)
            self.assertIn("conversations skipped (empty): 0", report)
            self.assertIn("assets copied: 0", report)


# ---------- Telegram HTML group export (HIMMEL-1170) ----------

# Minimal Telegram Desktop HTML export shape: a page_header group name, one
# `service` date separator (must be skipped), one message with <b>+<br> in the
# text, one `joined` message (no from_name -> inherits previous sender), and one
# message with a full-res photo_wrap href (thumb lives in src=, must be ignored).
TG_HTML = """<!DOCTYPE html>
<html><head><meta charset="utf-8"></head><body>
<div class="page_wrap">
  <div class="page_header"><div class="content">
    <div class="text bold">Test Group</div>
  </div></div>
  <div class="page_body"><div class="history">
    <div class="message service" id="service1">
      <div class="body details">18 July 2026</div>
    </div>
    <div class="message default clearfix" id="msg1">
      <div class="body">
        <div class="pull_right date details" title="18.07.2026 09:00:00">09:00</div>
        <div class="from_name">Alice</div>
        <div class="text">Hello <b>world</b><br>second line</div>
      </div>
    </div>
    <div class="message default clearfix joined" id="msg2">
      <div class="body">
        <div class="pull_right date details" title="18.07.2026 09:05:00">09:05</div>
        <div class="text">follow-up</div>
      </div>
    </div>
    <div class="message default clearfix" id="msg3">
      <div class="body">
        <div class="pull_right date details" title="18.07.2026 10:00:00">10:00</div>
        <div class="from_name">Bob</div>
        <div class="text">look</div>
        <a class="photo_wrap clearfix" href="photos/photo_1@18-07-2026.jpg">
          <img class="photo" src="photos/photo_1@18-07-2026_thumb.jpg">
        </a>
      </div>
    </div>
  </div></div>
</div>
</body></html>"""


def _tg_export(td, html=None):
    """Build a Telegram export dir: messages.html + the referenced full-res photo."""
    ed = Path(td) / "export"
    ed.mkdir()
    (ed / "messages.html").write_text(html or TG_HTML, encoding="utf-8")
    (ed / "photos").mkdir()
    (ed / "photos" / "photo_1@18-07-2026.jpg").write_bytes(JPEG_MAGIC)
    return ed


class TestParseTelegram(unittest.TestCase):
    def test_group_name_from_header(self):
        with tempfile.TemporaryDirectory() as td:
            group, msgs = fch.parse_telegram(_tg_export(td))
            self.assertEqual(group, "Test Group")

    def test_service_skipped_timestamps_parsed(self):
        with tempfile.TemporaryDirectory() as td:
            _, msgs = fch.parse_telegram(_tg_export(td))
            # 4 message divs, but the `service` date separator is skipped -> 3
            self.assertEqual(len(msgs), 3)
            self.assertEqual([m.ts for m in msgs], [
                datetime(2026, 7, 18, 9, 0, 0),
                datetime(2026, 7, 18, 9, 5, 0),
                datetime(2026, 7, 18, 10, 0, 0),
            ])

    def test_joined_message_inherits_sender(self):
        with tempfile.TemporaryDirectory() as td:
            _, msgs = fch.parse_telegram(_tg_export(td))
            self.assertEqual(msgs[0].sender, "Alice")
            self.assertEqual(msgs[1].sender, "Alice")  # joined, no from_name
            self.assertEqual(msgs[2].sender, "Bob")

    def test_br_to_newline_tags_stripped_unescaped(self):
        with tempfile.TemporaryDirectory() as td:
            _, msgs = fch.parse_telegram(_tg_export(td))
            # <b>world</b> stripped, <br> -> newline
            self.assertEqual(msgs[0].body, "Hello world\nsecond line")
            self.assertEqual(msgs[1].body, "follow-up")

    def test_media_full_res_captured_thumb_ignored(self):
        with tempfile.TemporaryDirectory() as td:
            _, msgs = fch.parse_telegram(_tg_export(td))
            # href = full-res; the _thumb lives in src= and is never matched
            self.assertEqual(msgs[2].media, ["photos/photo_1@18-07-2026.jpg"])

    def test_no_messages_returns_empty(self):
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td) / "export"
            ed.mkdir()
            (ed / "messages.html").write_text(
                "<html><body><div class='page_wrap'></div></body></html>",
                encoding="utf-8")
            group, msgs = fch.parse_telegram(ed)
            self.assertEqual(group, "")
            self.assertEqual(msgs, [])


class TestFoldTelegram(unittest.TestCase):
    def test_fold_writes_monthly_note_frontmatter_and_body(self):
        with tempfile.TemporaryDirectory() as td:
            ed = _tg_export(td)
            vault = Path(td) / "vault"
            vault.mkdir()
            report = fch.fold("telegram", ed, vault, dry_run=False)
            self.assertEqual(report.tg_group, "Test Group")
            self.assertEqual(report.tg_messages, 3)
            self.assertEqual(report.tg_months, 1)
            self.assertEqual(report.notes_created, 1)
            self.assertEqual(report.assets_copied, 1)
            # monthly note path: chats/telegram/<group-slug>/<YYYY-MM>.md
            # slugify preserves case -> "Test Group" becomes "Test-Group"
            note = vault / "chats" / "telegram" / "Test-Group" / "2026-07.md"
            self.assertTrue(note.exists())
            text = note.read_text(encoding="utf-8")
            # frontmatter keys (no enriched: key for telegram)
            self.assertIn("type: chat-import", text)
            self.assertIn("source: telegram", text)
            self.assertIn('group: "Test Group"', text)
            self.assertIn("created: 2026-07-18", text)
            self.assertIn("month: 2026-07", text)
            self.assertIn("messages: 3", text)
            self.assertIn("tags: [chat-import, telegram]", text)
            self.assertNotIn("enriched:", text)
            # body: title + day header + per-message header + preserved body
            self.assertIn("# Test Group — 2026-07", text)
            self.assertIn("## 2026-07-18 (", text)  # weekday is locale-dependent
            self.assertIn("**09:00 · Alice**", text)
            self.assertIn("**09:05 · Alice**", text)  # joined sender preserved
            self.assertIn("**10:00 · Bob**", text)
            self.assertIn("Hello world\nsecond line", text)  # <br> -> newline
            # media embed + copied file are GROUP-SCOPED (<slug>__) to avoid
            # cross-group basename collisions (Telegram numbers photos from 1)
            self.assertIn("![[chats/telegram/_assets/Test-Group__photo_1@18-07-2026.jpg]]", text)
            # full-res media copied (thumb was not)
            self.assertTrue((vault / "chats" / "telegram" / "_assets"
                             / "Test-Group__photo_1@18-07-2026.jpg").exists())
            # gitignore + index refreshed
            self.assertIn("chats/*/_assets/",
                          (vault / ".gitignore").read_text(encoding="utf-8"))
            self.assertIn("Test Group",
                          (vault / "chats" / "_index.md").read_text(encoding="utf-8"))

    def test_fold_group_slug_override(self):
        with tempfile.TemporaryDirectory() as td:
            ed = _tg_export(td)
            vault = Path(td) / "vault"
            vault.mkdir()
            fch.fold("telegram", ed, vault, dry_run=False, group_slug="custom-slug")
            self.assertTrue(
                (vault / "chats" / "telegram" / "custom-slug" / "2026-07.md").exists())
            # derived slug dir is NOT used when override is given
            self.assertFalse((vault / "chats" / "telegram" / "Test-Group").exists())

    def test_fold_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as td:
            ed = _tg_export(td)
            vault = Path(td) / "vault"
            vault.mkdir()
            report = fch.fold("telegram", ed, vault, dry_run=True)
            self.assertEqual(report.tg_messages, 3)
            self.assertEqual(report.tg_months, 1)
            self.assertEqual(report.assets_copied, 1)  # would have copied
            self.assertEqual(report.notes_created, 1)
            self.assertEqual(list(vault.iterdir()), [])

    def test_fold_idempotent_overwrites_note_skips_existing_asset(self):
        with tempfile.TemporaryDirectory() as td:
            ed = _tg_export(td)
            vault = Path(td) / "vault"
            vault.mkdir()
            fch.fold("telegram", ed, vault, dry_run=False)
            report2 = fch.fold("telegram", ed, vault, dry_run=False)
            # month note re-written (no skip); asset already present -> skipped
            self.assertEqual(report2.notes_created, 1)
            self.assertEqual(report2.assets_copied, 0)
            self.assertEqual(report2.assets_skipped_existing, 1)
            self.assertEqual(report2.tg_messages, 3)

    def test_fold_path_traversal_media_counted_missing(self):
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td) / "export"
            ed.mkdir()
            (ed / "messages.html").write_text(TG_HTML.replace(
                "photos/photo_1@18-07-2026.jpg",
                "photos/../../evil.jpg"), encoding="utf-8")
            vault = Path(td) / "vault"
            vault.mkdir()
            report = fch.fold("telegram", ed, vault, dry_run=False)
            self.assertEqual(report.assets_missing, 1)
            self.assertFalse((vault / "evil.jpg").exists())
            self.assertFalse((Path(td) / "evil.jpg").exists())

    def test_note_signature_preserves_media_presence(self):
        # Same message text, media re-hashed (same COUNT) -> equal signature:
        # an idempotent re-import must still overwrite (documented intent).
        a = ("---\nmessages: 3\n---\n# G — 2026-07\n\n## day\n"
             "**09:00 · Alice**\nhello\n![[chats/telegram/_assets/g__photo_1.jpg]]\n")
        b = ("---\nmessages: 3\n---\n# G — 2026-07\n\n## day\n"
             "**09:00 · Alice**\nhello\n![[chats/telegram/_assets/g__photo_1.abc123.jpg]]\n")
        self.assertEqual(fch._tg_note_signature(a), fch._tg_note_signature(b))
        # Same text but media REMOVED (fewer embeds) -> different signature, so
        # the overwrite guard treats it as a different note and won't silently
        # drop the existing media embed (codex + CodeRabbit, PR #1295).
        c = ("---\nmessages: 3\n---\n# G — 2026-07\n\n## day\n"
             "**09:00 · Alice**\nhello\n")
        self.assertNotEqual(fch._tg_note_signature(a), fch._tg_note_signature(c))


class TestCliTelegram(unittest.TestCase):
    def test_main_telegram_dry_run_prints_report(self):
        with tempfile.TemporaryDirectory() as td:
            ed = _tg_export(td)
            vault = Path(td) / "vault"
            vault.mkdir()
            import contextlib, io
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = fch.main(["--provider", "telegram", "--export", str(ed),
                               "--vault", str(vault), "--dry-run"])
            self.assertEqual(rc, 0)
            out = buf.getvalue()
            self.assertIn("group: Test Group", out)
            self.assertIn("messages: 3", out)
            self.assertIn("months: 1", out)
            self.assertEqual(list(vault.iterdir()), [])

    def test_main_telegram_group_slug_flag(self):
        with tempfile.TemporaryDirectory() as td:
            ed = _tg_export(td)
            vault = Path(td) / "vault"
            vault.mkdir()
            import contextlib, io
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = fch.main(["--provider", "telegram", "--export", str(ed),
                               "--vault", str(vault), "--group-slug", "cli-slug"])
            self.assertEqual(rc, 0)
            self.assertTrue(
                (vault / "chats" / "telegram" / "cli-slug" / "2026-07.md").exists())


class TestTelegramRobustness(unittest.TestCase):
    """CR-fix regressions (HIMMEL-1170): natural page order, group-scoped
    assets, and no-clobber on a partial re-export."""

    def test_page_key_natural_order(self):
        k = fch._tg_page_key
        self.assertEqual(k(Path("messages.html")), 1)
        self.assertEqual(k(Path("messages2.html")), 2)
        self.assertEqual(k(Path("messages10.html")), 10)
        self.assertLess(k(Path("messages2.html")), k(Path("messages10.html")))

    def test_joined_sender_across_pages_uses_natural_order(self):
        # page1 ends Alice; messages2 opens with a joined msg that must inherit
        # Alice; messages10 has Bob. Lexical order (messages10 < messages2)
        # would mis-attribute the joined msg to Bob.
        def msg(mid, ts, sender=None, text="x"):
            frm = f'<div class="from_name">{sender}</div>' if sender else ""
            cls = "message default clearfix" + ("" if sender else " joined")
            return (f'<div class="{cls}" id="{mid}"><div class="body">'
                    f'<div class="pull_right date details" title="{ts}">t</div>'
                    f'{frm}<div class="text">{text}</div></div></div>')
        with tempfile.TemporaryDirectory() as td:
            ed = Path(td) / "export"
            ed.mkdir()
            (ed / "messages.html").write_text(
                '<div class="page_header"><div class="text bold">G</div></div>'
                + msg("m1", "18.07.2026 09:00:00", "Alice"), encoding="utf-8")
            (ed / "messages2.html").write_text(
                msg("m2", "18.07.2026 09:05:00", None, "joined"), encoding="utf-8")
            (ed / "messages10.html").write_text(
                msg("m3", "18.07.2026 10:00:00", "Bob"), encoding="utf-8")
            _, msgs = fch.parse_telegram(ed)
            by_ts = {m.ts.strftime("%H:%M"): m.sender for m in msgs}
            self.assertEqual(by_ts["09:05"], "Alice")  # not Bob

    def test_assets_group_scoped_no_cross_group_alias(self):
        # two groups share a photo basename with DIFFERENT bytes -> both survive
        # under <slug>__ names; neither note aliases the other's media.
        with tempfile.TemporaryDirectory() as td:
            vault = Path(td) / "luna"
            (vault / "chats").mkdir(parents=True)
            for slug, magic in (("ga", b"\x89PNG-A"), ("gb", b"\x89PNG-B")):
                base = Path(td) / slug
                base.mkdir()
                ed = _tg_export(str(base))
                (ed / "photos" / "photo_1@18-07-2026.jpg").write_bytes(magic)
                fch.fold("telegram", ed, vault, False, group_slug=slug)
            adir = vault / "chats" / "telegram" / "_assets"
            self.assertEqual((adir / "ga__photo_1@18-07-2026.jpg").read_bytes(), b"\x89PNG-A")
            self.assertEqual((adir / "gb__photo_1@18-07-2026.jpg").read_bytes(), b"\x89PNG-B")
            note_b = (vault / "chats" / "telegram" / "gb" / "2026-07.md").read_text(encoding="utf-8")
            self.assertIn("gb__photo_1@18-07-2026.jpg", note_b)
            self.assertNotIn("ga__photo_1", note_b)

    def test_slug_cannot_escape_telegram_dir(self):
        # a group named `.`/`..`/path-sep must never yield a traversal slug
        self.assertEqual(fch._tg_clean_slug(".."), "")
        self.assertEqual(fch._tg_clean_slug("."), "")
        self.assertEqual(fch._tg_clean_slug("untitled"), "")
        self.assertEqual(fch._tg_clean_slug("a/b"), "ab")
        for bad in ("..", ".", "../../etc"):
            slug = fch._tg_group_slug(bad, Path("/x/ChatExport"), None)
            self.assertNotIn("..", slug)
            self.assertNotIn("/", slug)
            self.assertTrue(slug)  # non-empty (fallback)

    def test_group_name_yaml_escaped(self):
        entry = fch.TgMessage(datetime(2026, 7, 18, 9, 0, 0), "Alice", "hi", [])
        text = fch._tg_month_note('Ops "Primary"\\x', "g", "2026-07", [entry], "rel")
        self.assertIn(r'group: "Ops \"Primary\"\\x"', text)

    def test_partial_reexport_does_not_clobber(self):
        with tempfile.TemporaryDirectory() as td:
            vault = Path(td) / "luna"
            (vault / "chats").mkdir(parents=True)
            base = Path(td) / "full"
            base.mkdir()
            fch.fold("telegram", _tg_export(str(base)), vault, False, group_slug="g")
            note = vault / "chats" / "telegram" / "g" / "2026-07.md"
            self.assertIn("messages: 3", note.read_text(encoding="utf-8"))
            # partial re-export of the SAME month (1 msg) must NOT clobber the 3
            partial = (
                '<div class="page_header"><div class="text bold">Test Group</div></div>'
                '<div class="message default clearfix" id="p1"><div class="body">'
                '<div class="pull_right date details" title="18.07.2026 09:00:00">09:00</div>'
                '<div class="from_name">Alice</div><div class="text">only one</div>'
                '</div></div>')
            pbase = Path(td) / "partial"
            pbase.mkdir()
            fch.fold("telegram", _tg_export(str(pbase), html=partial), vault,
                     False, group_slug="g")
            self.assertIn("messages: 3", note.read_text(encoding="utf-8"))

    def test_reserved_assets_slug_rejected(self):
        # --group-slug _assets (any case on a case-insensitive FS) would make
        # group_dir == assets_dir and drop notes into the gitignored media dir.
        for slug in ("_assets", "_Assets", "_assets/", "_assets\\", "_assets."):
            self.assertEqual(fch._tg_clean_slug(slug), "")
        with tempfile.TemporaryDirectory() as td:
            vault = Path(td) / "luna"
            (vault / "chats").mkdir(parents=True)
            base = Path(td) / "src"
            base.mkdir()
            fch.fold("telegram", _tg_export(str(base)), vault, False,
                     group_slug="_assets")
            tg = vault / "chats" / "telegram"
            self.assertFalse((tg / "_assets" / "2026-07.md").exists())
            notes = list(tg.glob("*/2026-07.md"))
            self.assertEqual(len(notes), 1)
            self.assertNotEqual(notes[0].parent.name, "_assets")

    def test_asset_same_basename_diff_bytes_no_alias(self):
        # Telegram renumbers per export: a re-export reusing photo_1 for DIFFERENT
        # bytes must not alias the stale asset — both survive, note embeds the new.
        with tempfile.TemporaryDirectory() as td:
            vault = Path(td) / "luna"
            (vault / "chats").mkdir(parents=True)
            b1 = Path(td) / "e1"
            b1.mkdir()
            ed1 = _tg_export(str(b1))
            (ed1 / "photos" / "photo_1@18-07-2026.jpg").write_bytes(b"OLD-BYTES")
            fch.fold("telegram", ed1, vault, False, group_slug="g")
            b2 = Path(td) / "e2"
            b2.mkdir()
            ed2 = _tg_export(str(b2))
            (ed2 / "photos" / "photo_1@18-07-2026.jpg").write_bytes(b"NEW-BYTES")
            fch.fold("telegram", ed2, vault, False, group_slug="g")
            adir = vault / "chats" / "telegram" / "_assets"
            names = sorted(p.name for p in adir.iterdir())
            self.assertEqual(len(names), 2)  # stale kept + new distinct
            self.assertIn("g__photo_1@18-07-2026.jpg", names)
            note = (vault / "chats" / "telegram" / "g" / "2026-07.md").read_text(
                encoding="utf-8")
            m = re.search(r"g__photo_1@18-07-2026-[0-9a-f]{12}\.jpg", note)
            self.assertIsNotNone(m)  # note embeds the content-hashed name
            self.assertIn(m.group(0), names)
            self.assertEqual((adir / m.group(0)).read_bytes(), b"NEW-BYTES")
            self.assertEqual(
                (adir / "g__photo_1@18-07-2026.jpg").read_bytes(), b"OLD-BYTES")

    def test_dry_run_reports_shrink_skip(self):
        # dry-run must report the SAME notes_created a real run would: the
        # shrink-guard applies in dry-run, so a shrinking month isn't counted.
        with tempfile.TemporaryDirectory() as td:
            vault = Path(td) / "luna"
            (vault / "chats").mkdir(parents=True)
            base = Path(td) / "full"
            base.mkdir()
            fch.fold("telegram", _tg_export(str(base)), vault, False, group_slug="g")
            partial = (
                '<div class="page_header"><div class="text bold">Test Group</div></div>'
                '<div class="message default clearfix" id="p1"><div class="body">'
                '<div class="pull_right date details" title="18.07.2026 09:00:00">09:00</div>'
                '<div class="from_name">Alice</div><div class="text">only one</div>'
                '</div></div>')
            pbase = Path(td) / "partial"
            pbase.mkdir()
            report = fch.fold("telegram", _tg_export(str(pbase), html=partial),
                              vault, True, group_slug="g")  # dry_run=True
            self.assertEqual(report.notes_created, 0)  # shrinking month skipped


if __name__ == "__main__":
    unittest.main(verbosity=2)
