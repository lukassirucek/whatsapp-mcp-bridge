"""Tests for the WHATSAPP_DISABLE_SEND kill switch.

When set, send_message, send_file, send_audio_message, send_reaction, and
mark_messages_read must all refuse before ever reaching the bridge — the
bridge process must never see a request from any of them. Unset (the
default) must behave exactly as before this feature existed.
"""

import pytest

import whatsapp


def _fail_if_called(*_args, **_kwargs):
    raise AssertionError("requests.post must not be called while WHATSAPP_DISABLE_SEND is set")


@pytest.fixture
def send_disabled(monkeypatch):
    monkeypatch.setattr(whatsapp, "DISABLE_SEND", True)
    monkeypatch.setattr(whatsapp.requests, "post", _fail_if_called)


class TestParseBoolEnv:
    @pytest.mark.parametrize("value", ["1", "true", "True", "TRUE", "yes", "on"])
    def test_truthy_values(self, value):
        assert whatsapp._parse_bool_env(value) is True

    @pytest.mark.parametrize("value", [None, "", "0", "false", "no", "off", "garbage"])
    def test_falsy_values(self, value):
        assert whatsapp._parse_bool_env(value) is False


def test_send_message_refuses_when_disabled(send_disabled):
    success, message = whatsapp.send_message("12025551234", "hello")
    assert success is False
    assert "disabled" in message.lower()


def test_send_file_refuses_when_disabled(send_disabled, tmp_path):
    media = tmp_path / "photo.jpg"
    media.write_bytes(b"fake image")
    success, message = whatsapp.send_file("12025551234", str(media))
    assert success is False
    assert "disabled" in message.lower()


def test_send_audio_message_refuses_when_disabled(send_disabled, tmp_path):
    media = tmp_path / "voice.ogg"
    media.write_bytes(b"fake audio")
    success, message = whatsapp.send_audio_message("12025551234", str(media))
    assert success is False
    assert "disabled" in message.lower()


def test_send_reaction_refuses_when_disabled(send_disabled):
    success, message = whatsapp.send_reaction("12025551234@s.whatsapp.net", "3AABCDEF01234567", "👍")
    assert success is False
    assert "disabled" in message.lower()


def test_mark_messages_read_refuses_when_disabled(send_disabled):
    success, message = whatsapp.mark_messages_read(["3AABCDEF01234567"], "12025551234@s.whatsapp.net")
    assert success is False
    assert "disabled" in message.lower()


def test_sending_unaffected_when_unset(monkeypatch):
    """Default (unset) behavior must be unchanged: sending reaches the bridge."""
    monkeypatch.setattr(whatsapp, "DISABLE_SEND", False)
    calls = []

    class DummyResponse:
        status_code = 200

        def json(self):
            return {"success": True, "message": "sent"}

    def fake_post(url, json, headers=None):
        calls.append(url)
        return DummyResponse()

    monkeypatch.setattr(whatsapp.requests, "post", fake_post)

    success, message = whatsapp.send_message("12025551234", "hello")

    assert success is True
    assert message == "sent"
    assert len(calls) == 1
