"""Tests for the WHATSAPP_ALLOWED_CHATS read-side allowlist.

Every read path (list_chats, list_messages, get_chat, get_contact_chats,
get_last_interaction, get_direct_chat_by_contact, get_message_context,
search_contacts, download_media) must filter out chats not in the configured
allowlist, indistinguishably from those chats not existing at all. Sending
(send_message, send_reaction, send_file, mark_messages_read) is untouched.
"""

import sqlite3

import pytest

import main
import whatsapp

ALLOWED_JID = "allowed@s.whatsapp.net"
BLOCKED_JID = "blocked@s.whatsapp.net"
ALLOWED_GROUP_JID = "group-allowed@g.us"
BLOCKED_GROUP_JID = "group-blocked@g.us"


def _make_messages_db(path):
    conn = sqlite3.connect(path)
    cursor = conn.cursor()
    cursor.executescript(
        """
        CREATE TABLE chats (
            jid TEXT PRIMARY KEY,
            name TEXT,
            last_message_time TIMESTAMP
        );
        CREATE TABLE messages (
            id TEXT,
            chat_jid TEXT,
            sender TEXT,
            content TEXT,
            timestamp TIMESTAMP,
            is_from_me BOOLEAN,
            media_type TEXT,
            filename TEXT,
            url TEXT,
            media_key BLOB,
            file_sha256 BLOB,
            file_enc_sha256 BLOB,
            file_length INTEGER,
            quoted_message_id TEXT,
            PRIMARY KEY (id, chat_jid),
            FOREIGN KEY (chat_jid) REFERENCES chats(jid)
        );
        """
    )
    cursor.executemany(
        "INSERT INTO chats (jid, name, last_message_time) VALUES (?, ?, ?)",
        [
            (ALLOWED_JID, "Allowed Contact", "2024-01-15 10:30:00+00:00"),
            (BLOCKED_JID, "Blocked Contact", "2024-01-15 10:31:00+00:00"),
            (ALLOWED_GROUP_JID, "Allowed Group", "2024-01-15 10:32:00+00:00"),
            (BLOCKED_GROUP_JID, "Blocked Group", "2024-01-15 10:33:00+00:00"),
        ],
    )
    cursor.executemany(
        """INSERT INTO messages
           (id, chat_jid, sender, content, timestamp, is_from_me)
           VALUES (?, ?, ?, ?, ?, ?)""",
        [
            ("msg-allowed", ALLOWED_JID, ALLOWED_JID, "hi from allowed", "2024-01-15 10:30:00+00:00", 0),
            ("msg-blocked", BLOCKED_JID, BLOCKED_JID, "hi from blocked", "2024-01-15 10:31:00+00:00", 0),
            (
                "msg-allowed-group",
                ALLOWED_GROUP_JID,
                "other-member@s.whatsapp.net",
                "hi in allowed group",
                "2024-01-15 10:32:00+00:00",
                0,
            ),
            (
                "msg-blocked-group",
                BLOCKED_GROUP_JID,
                "other-member@s.whatsapp.net",
                "hi in blocked group",
                "2024-01-15 10:33:00+00:00",
                0,
            ),
            (
                "msg-allowed-contact-in-blocked-group",
                BLOCKED_GROUP_JID,
                ALLOWED_JID,
                "allowed contact posting in a blocked group",
                "2024-01-15 10:34:00+00:00",
                0,
            ),
        ],
    )
    conn.commit()
    conn.close()


@pytest.fixture
def messages_db(tmp_path, monkeypatch):
    db_path = tmp_path / "messages.db"
    _make_messages_db(str(db_path))
    monkeypatch.setattr(whatsapp, "MESSAGES_DB_PATH", str(db_path))
    return db_path


@pytest.fixture
def allowlist(monkeypatch):
    """Restrict reads to ALLOWED_JID and ALLOWED_GROUP_JID."""
    monkeypatch.setattr(whatsapp, "ALLOWED_CHATS", frozenset({ALLOWED_JID, ALLOWED_GROUP_JID}))


class TestParseAllowedChats:
    def test_unset_or_blank_means_unrestricted(self):
        assert whatsapp._parse_allowed_chats(None) is None
        assert whatsapp._parse_allowed_chats("") is None
        assert whatsapp._parse_allowed_chats("   ") is None

    def test_splits_and_trims_comma_separated_jids(self):
        parsed = whatsapp._parse_allowed_chats(" a@g.us, b@s.whatsapp.net ,, c@g.us")
        assert parsed == frozenset({"a@g.us", "b@s.whatsapp.net", "c@g.us"})


class TestIsChatAllowed:
    def test_unrestricted_when_unset(self, monkeypatch):
        monkeypatch.setattr(whatsapp, "ALLOWED_CHATS", None)
        assert whatsapp.is_chat_allowed("anything@g.us") is True

    def test_membership_when_set(self, allowlist):
        assert whatsapp.is_chat_allowed(ALLOWED_JID) is True
        assert whatsapp.is_chat_allowed(BLOCKED_JID) is False


def test_list_chats_filters_to_allowlist(messages_db, allowlist):
    chats = whatsapp.list_chats(limit=10)
    jids = {chat["jid"] for chat in chats}
    assert jids == {ALLOWED_JID, ALLOWED_GROUP_JID}


def test_list_chats_unrestricted_without_allowlist(messages_db):
    chats = whatsapp.list_chats(limit=10)
    jids = {chat["jid"] for chat in chats}
    assert jids == {ALLOWED_JID, BLOCKED_JID, ALLOWED_GROUP_JID, BLOCKED_GROUP_JID}


def test_list_messages_returns_empty_for_blocked_chat_jid(messages_db, allowlist):
    assert whatsapp.list_messages(chat_jid=BLOCKED_JID, include_context=False) == []


def test_list_messages_returns_allowed_chat_jid(messages_db, allowlist):
    messages = whatsapp.list_messages(chat_jid=ALLOWED_JID, include_context=False)
    assert [m["id"] for m in messages] == ["msg-allowed"]


def test_list_messages_without_chat_jid_only_returns_allowed_chats(messages_db, allowlist):
    messages = whatsapp.list_messages(include_context=False, limit=50)
    chat_jids = {m["chat_jid"] for m in messages}
    assert chat_jids == {ALLOWED_JID, ALLOWED_GROUP_JID}


def test_get_chat_returns_none_for_blocked_jid(messages_db, allowlist):
    assert whatsapp.get_chat(BLOCKED_JID) is None


def test_get_chat_returns_allowed_jid(messages_db, allowlist):
    chat = whatsapp.get_chat(ALLOWED_JID)
    assert chat is not None
    assert chat["jid"] == ALLOWED_JID


def test_get_message_context_raises_for_message_in_blocked_chat(messages_db, allowlist):
    with pytest.raises(ValueError):
        whatsapp.get_message_context("msg-blocked")


def test_get_message_context_returns_message_in_allowed_chat(messages_db, allowlist):
    context = whatsapp.get_message_context("msg-allowed")
    assert context.message.id == "msg-allowed"


def test_get_contact_chats_excludes_blocked_chats(messages_db, allowlist):
    # Without the allowlist, ALLOWED_JID posting inside BLOCKED_GROUP_JID would
    # surface that group too — the allowlist must still drop it.
    chats = whatsapp.get_contact_chats(ALLOWED_JID)
    jids = {chat["jid"] for chat in chats}
    assert jids == {ALLOWED_JID}


def test_get_contact_chats_unrestricted_includes_blocked_group(messages_db):
    chats = whatsapp.get_contact_chats(ALLOWED_JID)
    jids = {chat["jid"] for chat in chats}
    assert BLOCKED_GROUP_JID in jids


def test_get_last_interaction_none_when_only_blocked_chat_matches(messages_db, allowlist):
    assert whatsapp.get_last_interaction(BLOCKED_JID) is None


def test_get_last_interaction_returns_allowed_chat(messages_db, allowlist):
    result = whatsapp.get_last_interaction(ALLOWED_JID)
    assert result is not None
    assert result["chat_jid"] == ALLOWED_JID


def test_get_direct_chat_by_contact_none_for_blocked(messages_db, allowlist):
    assert whatsapp.get_direct_chat_by_contact("blocked") is None


def test_get_direct_chat_by_contact_finds_allowed(messages_db, allowlist):
    chat = whatsapp.get_direct_chat_by_contact("allowed")
    assert chat is not None
    assert chat["jid"] == ALLOWED_JID


def test_search_contacts_excludes_blocked_contact(messages_db, allowlist):
    results = whatsapp.search_contacts("Contact")
    jids = {contact["jid"] for contact in results}
    assert jids == {ALLOWED_JID}


def test_download_media_refuses_blocked_chat(allowlist, monkeypatch):
    def should_not_post(*_args, **_kwargs):
        raise AssertionError("blocked chat must never reach the bridge")

    monkeypatch.setattr(whatsapp.requests, "post", should_not_post)

    assert whatsapp.download_media("any-message", BLOCKED_JID) is None


def test_download_media_allows_allowed_chat(allowlist, monkeypatch):
    class DummyResponse:
        status_code = 200

        def json(self):
            return {"success": True, "path": "/tmp/file.jpg"}

    monkeypatch.setattr(whatsapp.requests, "post", lambda *a, **k: DummyResponse())

    assert whatsapp.download_media("any-message", ALLOWED_JID) == "/tmp/file.jpg"


def test_transcribe_audio_tool_rejects_blocked_chat(allowlist, monkeypatch):
    def should_not_download(*_args, **_kwargs):
        raise AssertionError("blocked chat must never reach download_media")

    monkeypatch.setattr(main, "whatsapp_download_media", should_not_download)

    result = main.transcribe_audio("any-message", BLOCKED_JID)

    assert result["success"] is False
    assert "WHATSAPP_ALLOWED_CHATS" in result["message"]
