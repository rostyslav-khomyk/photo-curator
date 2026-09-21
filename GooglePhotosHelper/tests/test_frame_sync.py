from pathlib import Path
from unittest import mock

import pytest

from photo_curator_google.frame_sync import FrameSyncPlan, SyncAborted
from photo_curator_google.client import (
    GoogleCreateRejected,
    GooglePhotosClient,
    GooglePhotosError,
    _ProgressReader,
)


class FakeClient:
    def __init__(self):
        self.refresh_token = "test-account"
        self.account = "oauth-client:google-user"
        self.albums = [{"id": "frame", "title": "Desk Travels", "mediaItemsCount": "2"}]
        self.members = {"frame": {"old-one", "old-two"}}
        self.events = []
        self.uploads = 0
        self.fail_upload = False
        self.fail_create = False
        self.fail_add = False
        self.unconfirmed_add = False
        self.missing_media = set()

    def list_albums(self):
        return [dict(album) for album in self.albums]

    def account_identifier(self):
        return self.account

    def album_media_ids(self, album_id):
        return set(self.members[album_id])

    def enable_album_editing(self):
        self.events.append("authorize")

    def create_album(self, title):
        album_id = f"album-{len(self.albums)}"
        self.events.append("create-album")
        self.albums.append({"id": album_id, "title": title})
        self.members[album_id] = set()
        return album_id

    def upload_bytes(self, path, progress):
        self.events.append("upload")
        self.uploads += 1
        if self.fail_upload:
            raise GooglePhotosError("Upload failed")
        progress(Path(path).stat().st_size)
        return f"token-{self.uploads}"

    def create_uploaded_media(self, token, filename):
        self.events.append("create-media")
        if self.fail_create:
            raise GooglePhotosError("Response lost")
        return f"media-{self.uploads}"

    def existing_media_ids(self, ids):
        return set(ids) - self.missing_media

    def change_album_membership(self, album_id, ids, *, remove=False):
        if not ids:
            return
        self.events.append("remove" if remove else "add")
        if not remove and self.fail_add:
            raise GooglePhotosError("Cannot add")
        if remove:
            self.members[album_id] -= ids
        elif not self.unconfirmed_add:
            self.members[album_id] |= ids


def make_plan(tmp_path, client, choices=None, items=None):
    photo = tmp_path / "photo.jpg"
    if not photo.exists():
        photo.write_bytes(b"photo content")
    return FrameSyncPlan(
        client,
        items if items is not None else [(str(photo), "Trip")],
        choices if choices is not None else {"Trip": {"id": "frame"}},
        tmp_path / "ledger.sqlite3",
    )


def test_review_does_not_mutate_google(tmp_path):
    client = FakeClient()
    plan = make_plan(tmp_path, client)
    assert plan.summary()["destinations"][0]["managed_count"] == 2
    assert client.events == []


def test_append_keeps_old_photos_and_reuses_confirmed_upload_after_restart(tmp_path):
    client = FakeClient()
    report = []
    make_plan(tmp_path, client).run("append", report.append)
    make_plan(tmp_path, client).run("append", report.append)
    assert client.uploads == 1
    assert client.members["frame"] == {"old-one", "old-two", "media-1"}
    assert "remove" not in client.events
    assert "authorize" not in client.events
    assert report[-1]["phase"] == "complete"
    assert any(p.get("reused") == 1 for p in report)


def test_deleted_cached_google_item_is_uploaded_again_before_album_update(tmp_path):
    client = FakeClient()
    make_plan(tmp_path, client).run("append", lambda _: None)
    client.members["frame"].discard("media-1")
    client.missing_media.add("media-1")
    make_plan(tmp_path, client).run("append", lambda _: None)
    assert client.uploads == 2
    assert "media-2" in client.members["frame"]


def test_replace_adds_before_removing_and_preserves_album_identity(tmp_path):
    client = FakeClient()
    make_plan(tmp_path, client).run("replace", lambda _: None)
    assert client.members == {"frame": {"media-1"}}
    assert client.events.index("add") < client.events.index("remove")
    assert "create-album" not in client.events
    assert "authorize" in client.events


@pytest.mark.parametrize("failure", ["fail_upload", "fail_create", "fail_add", "unconfirmed_add"])
def test_replace_never_clears_old_album_when_new_selection_fails(tmp_path, failure):
    client = FakeClient()
    setattr(client, failure, True)
    with pytest.raises(GooglePhotosError):
        make_plan(tmp_path, client).run("replace", lambda _: None)
    assert {"old-one", "old-two"} <= client.members["frame"]
    assert "remove" not in client.events


def test_uncertain_create_is_not_uploaded_again(tmp_path):
    client = FakeClient()
    client.fail_create = True
    with pytest.raises(GooglePhotosError, match="Response lost"):
        make_plan(tmp_path, client).run("append", lambda _: None)
    client.fail_create = False
    with pytest.raises(GooglePhotosError, match="uncertain"):
        make_plan(tmp_path, client).run("append", lambda _: None)
    assert client.uploads == 1


def test_same_photo_can_go_to_two_albums_without_two_uploads(tmp_path):
    client = FakeClient()
    photo = tmp_path / "photo.jpg"
    photo.write_bytes(b"same photo")
    other = tmp_path / "renamed.jpg"
    other.write_bytes(b"same photo")
    plan = make_plan(
        tmp_path,
        client,
        {"One": {"id": "frame"}, "Two": {"title": "Spring"}},
        [(str(photo), "One"), (str(other), "Two")],
    )
    plan.run("append", lambda _: None)
    assert client.uploads == 1
    assert "media-1" in client.members["frame"]
    assert "media-1" in client.members["album-1"]


def test_replacement_rejects_album_changed_since_review(tmp_path):
    client = FakeClient()
    plan = make_plan(tmp_path, client)
    client.members["frame"].add("manual-addition")
    with pytest.raises(GooglePhotosError, match="changed since review"):
        plan.run("replace", lambda _: None)
    assert client.uploads == 0
    assert "remove" not in client.events


def test_empty_selection_cannot_clear_album(tmp_path):
    client = FakeClient()
    with pytest.raises(ValueError, match="No photos"):
        make_plan(tmp_path, client, items=[])
    assert client.events == []


def test_title_ambiguity_requires_explicit_album_id(tmp_path):
    client = FakeClient()
    client.albums.append({"id": "other", "title": "Desk Travels"})
    client.members["other"] = set()
    with pytest.raises(ValueError, match="Several Google albums"):
        make_plan(tmp_path, client, {"Trip": {"title": "Desk Travels"}})
    plan = make_plan(tmp_path, client, {"Trip": {"id": "other"}})
    plan.run("append", lambda _: None)
    assert client.members["frame"] == {"old-one", "old-two"}
    assert client.members["other"] == {"media-1"}


def test_changed_export_is_rejected_before_upload(tmp_path):
    client = FakeClient()
    plan = make_plan(tmp_path, client)
    (tmp_path / "photo.jpg").write_bytes(b"a different photo")
    with pytest.raises(GooglePhotosError, match="changed since review"):
        plan.run("append", lambda _: None)
    assert client.events == []


def test_expired_review_is_rejected(tmp_path):
    client = FakeClient()
    plan = make_plan(tmp_path, client)
    plan.created_at -= 1801
    with pytest.raises(ValueError, match="expired"):
        plan.run("replace", lambda _: None)
    assert client.events == []


def test_progress_reader_reports_bytes_without_reading_whole_file(tmp_path):
    path = tmp_path / "file"
    path.write_bytes(b"1234567890")
    progress = []
    with _ProgressReader(str(path), progress.append) as stream:
        assert stream.read(3) == b"123"
        assert progress == [3]
        assert stream.read(2) == b"45"
        stream.seek(0)
        assert stream.read(1) == b"1"
    assert progress == [3, 5, 1]


def test_album_media_listing_follows_pages():
    client = GooglePhotosClient.__new__(GooglePhotosClient)
    client.access_token = "access"
    first = mock.Mock()
    first.json.return_value = {"mediaItems": [{"id": "one"}], "nextPageToken": "next"}
    second = mock.Mock()
    second.json.return_value = {"mediaItems": [{"id": "two"}]}
    client._retry_after_unauthorized = mock.Mock(side_effect=[first, second])
    assert client.album_media_ids("frame") == {"one", "two"}
    assert client._retry_after_unauthorized.call_args.kwargs["json"]["pageToken"] == "next"


def test_new_refresh_token_does_not_discard_upload_history(tmp_path):
    client = FakeClient()
    make_plan(tmp_path, client).run("append", lambda _: None)
    client.refresh_token = "new-token-from-consent"
    make_plan(tmp_path, client).run("replace", lambda _: None)
    assert client.uploads == 1
    assert client.members["frame"] == {"media-1"}


def test_different_google_accounts_never_share_upload_history(tmp_path):
    client = FakeClient()
    make_plan(tmp_path, client).run("append", lambda _: None)
    client.account = "oauth-client:another-google-user"
    make_plan(tmp_path, client).run("append", lambda _: None)
    assert client.uploads == 2


def test_account_switch_during_consent_blocks_mutation(tmp_path):
    client = FakeClient()
    plan = make_plan(tmp_path, client)
    client.enable_album_editing = lambda: setattr(client, "account", "another-user")
    with pytest.raises(GooglePhotosError, match="account changed"):
        plan.run("replace", lambda _: None)
    assert client.uploads == 0
    assert client.events == []


def test_manual_album_edit_during_upload_preserves_old_selection(tmp_path):
    client = FakeClient()
    original_upload = client.upload_bytes

    def upload(path, progress):
        client.members["frame"].add("manual-photo")
        return original_upload(path, progress)

    client.upload_bytes = upload
    plan = make_plan(tmp_path, client)
    with pytest.raises(GooglePhotosError, match="changed during sync"):
        plan.run("replace", lambda _: None)
    assert client.members["frame"] == {"manual-photo", "old-one", "old-two", "media-1"}
    assert "remove" not in client.events


def test_lost_album_create_response_cannot_create_duplicate_on_retry(tmp_path):
    client = FakeClient()
    choices = {"Trip": {"title": "Summer"}}
    original_create = client.create_album

    def lost_response(title):
        original_create(title)
        # Simulate a created album not yet visible in list results.
        client.albums.pop()
        raise GooglePhotosError("Album response lost")

    client.create_album = lost_response
    with pytest.raises(GooglePhotosError, match="Album response lost"):
        make_plan(tmp_path, client, choices).run("append", lambda _: None)
    client.create_album = original_create
    with pytest.raises(GooglePhotosError, match="no duplicate"):
        make_plan(tmp_path, client, choices).run("append", lambda _: None)
    assert client.events.count("create-album") == 1


def test_eta_is_transfer_only_and_appears_after_enough_samples(tmp_path, monkeypatch):
    client = FakeClient()
    clock = [100.0]
    monkeypatch.setattr("photo_curator_google.frame_sync.time.monotonic", lambda: clock[0])

    def upload(path, progress):
        client.uploads += 1
        clock[0] += 10
        progress(5)
        return "token"

    client.upload_bytes = upload
    reports = []
    make_plan(tmp_path, client).run("append", reports.append)
    sending = next(report for report in reports if report.get("eta_seconds") is not None)
    assert sending["bytes_per_second"] == 0.5
    assert sending["eta_seconds"] == 16
    assert reports[-1]["eta_seconds"] is None


def test_abort_before_start_does_not_upload_or_change_albums(tmp_path):
    client = FakeClient()
    plan = make_plan(tmp_path, client)
    plan.abort_requested.set()
    with pytest.raises(SyncAborted):
        plan.run("replace", lambda _: None)
    assert client.events == []


def test_abort_during_stream_stops_before_creating_media(tmp_path):
    client = FakeClient()
    plan = make_plan(tmp_path, client)

    def upload(path, progress):
        plan.abort_requested.set()
        progress(1)

    client.upload_bytes = upload
    with pytest.raises(SyncAborted):
        plan.run("replace", lambda _: None)
    assert "create-media" not in client.events
    assert "remove" not in client.events
    assert client.members["frame"] == {"old-one", "old-two"}


def test_abort_during_google_finalization_records_success_before_stopping(tmp_path):
    client = FakeClient()
    plan = make_plan(tmp_path, client)
    original_create = client.create_uploaded_media

    def create(token, filename):
        plan.abort_requested.set()
        return original_create(token, filename)

    client.create_uploaded_media = create
    with pytest.raises(SyncAborted):
        plan.run("replace", lambda _: None)
    assert "remove" not in client.events
    client.create_uploaded_media = original_create
    make_plan(tmp_path, client).run("append", lambda _: None)
    assert client.uploads == 1
    assert client.members["frame"] == {"old-one", "old-two", "media-1"}


def test_abort_before_create_request_does_not_leave_uncertain_upload(tmp_path):
    client = FakeClient()
    plan = make_plan(tmp_path, client)
    original_create = client.create_uploaded_media

    def create(token, filename):
        plan.abort_requested.set()
        client.check_cancelled()

    client.create_uploaded_media = create
    with pytest.raises(SyncAborted):
        plan.run("append", lambda _: None)
    client.create_uploaded_media = original_create
    make_plan(tmp_path, client).run("append", lambda _: None)
    assert "media-2" in client.members["frame"]


def test_abort_at_replacement_stage_preserves_old_selection(tmp_path):
    client = FakeClient()
    plan = make_plan(tmp_path, client)

    def report(state):
        if state.get("phase") == "replacing":
            plan.abort_requested.set()

    with pytest.raises(SyncAborted):
        plan.run("replace", report)
    assert "remove" not in client.events
    assert client.members["frame"] == {"old-one", "old-two", "media-1"}


def test_abort_stops_between_google_membership_batches():
    client = GooglePhotosClient.__new__(GooglePhotosClient)
    client.access_token = "token"
    client.session = mock.Mock()
    canceled = [False]

    def checkpoint():
        if canceled[0]:
            raise SyncAborted()

    client.check_cancelled = checkpoint

    def request(*args, **kwargs):
        canceled[0] = True
        return mock.Mock(status_code=200)

    client.session.request.side_effect = request
    with pytest.raises(SyncAborted):
        client.change_album_membership("album", {str(i) for i in range(101)}, remove=True)
    assert client.session.request.call_count == 1


def test_unresolved_photo_is_reviewed_and_can_be_left_out_without_erasing_history(tmp_path):
    import hashlib

    from photo_curator_google.frame_sync import UploadLedger

    client = FakeClient()
    blocked = tmp_path / "IMG_5009.HEIC"
    blocked.write_bytes(b"unresolved")
    good = tmp_path / "good.jpg"
    good.write_bytes(b"confirmed")
    account = hashlib.sha256(client.account.encode()).hexdigest()
    ledger = UploadLedger(tmp_path / "ledger.sqlite3", account)
    digest = hashlib.sha256(b"unresolved").hexdigest()
    ledger.record(digest, None)
    ledger.record(hashlib.sha256(b"confirmed").hexdigest(), "already-uploaded")
    ledger.close()
    plan = make_plan(
        tmp_path,
        client,
        {"Trip": {"title": "New Trip"}},
        [(str(blocked), "Trip"), (str(good), "Trip")],
    )
    assert plan.summary()["unresolved_files"] == ["IMG_5009.HEIC"]
    assert client.events == []
    reports = []
    plan.run("append", reports.append, skip_unresolved=True)
    assert client.members["album-1"] == {"already-uploaded"}
    assert client.uploads == 0
    assert reports[-1]["skipped"] == 1
    ledger = UploadLedger(tmp_path / "ledger.sqlite3", account)
    assert digest in ledger.uncertain_digests()
    ledger.close()


def test_replacement_cannot_be_used_with_skip_unresolved(tmp_path):
    plan = make_plan(tmp_path, FakeClient())
    with pytest.raises(ValueError, match="Replacement is not allowed"):
        plan.run("replace", lambda _: None, skip_unresolved=True)


def test_new_album_is_created_before_sending_photos(tmp_path):
    client = FakeClient()
    make_plan(tmp_path, client, {"Trip": {"title": "New Trip"}}).run("append", lambda _: None)
    assert client.events.index("create-album") < client.events.index("upload")


def test_explicit_rejection_does_not_leave_an_uncertain_record(tmp_path):
    client = FakeClient()
    original_create = client.create_uploaded_media
    client.create_uploaded_media = mock.Mock(side_effect=GoogleCreateRejected("Invalid media"))
    with pytest.raises(GoogleCreateRejected):
        make_plan(tmp_path, client).run("append", lambda _: None)
    client.create_uploaded_media = original_create
    make_plan(tmp_path, client).run("append", lambda _: None)
    assert "media-2" in client.members["frame"]


def test_google_rejection_preserves_the_reported_reason():
    client = GooglePhotosClient.__new__(GooglePhotosClient)
    client.access_token = "token"
    response = mock.Mock(status_code=200)
    response.json.return_value = {
        "newMediaItemResults": [{"status": {"code": 3, "message": "Unsupported media"}}]
    }
    client._retry_after_unauthorized = mock.Mock(return_value=response)
    with pytest.raises(GoogleCreateRejected, match="IMG_5009.HEIC.*Unsupported media"):
        client.create_uploaded_media("upload-token", "IMG_5009.HEIC")
