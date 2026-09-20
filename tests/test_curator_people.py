from types import SimpleNamespace as NS

from icloudpd.curator_people import read_people_snapshot


def photo(uuid="asset", people=(), faces=(), hidden=False):
    return NS(uuid=uuid, person_info=people, face_info=faces, hidden=hidden)


def reader(tmp_path, photos):
    path = tmp_path / "snapshot.sqlite3"
    path.touch()

    def factory(**kwargs):
        assert kwargs == {"dbfile": str(path)}

        def fetch(**options):
            assert options == {"images": True, "movies": False, "intrash": False}
            return photos

        return NS(photos=fetch)

    return read_people_snapshot(path, "library-one", enabled=True, factory=factory)


def test_disabled_never_opens_database(tmp_path):
    def forbidden(**kwargs):
        raise AssertionError("Must not open")

    result = read_people_snapshot(tmp_path / "missing", "library", factory=forbidden)
    assert result.status == "disabled"
    assert not result.permits_research_upload


def test_same_name_keeps_separate_person_ids(tmp_path):
    result = reader(tmp_path, [photo(people=[NS(uuid="one", name="Alex"), NS(uuid="two", name="Alex")])])
    assert result.status == "available"
    assert [p.person_id for p in result.photos[0].people] == ["one", "two"]
    assert result.photos[0].has_face_evidence


def test_unnamed_faces_and_missing_labels_are_not_clearance(tmp_path):
    result = reader(tmp_path, [photo("unknown", faces=[object()]), photo("unlabeled")])
    assert result.status == "available"
    assert next(p for p in result.photos if p.asset_uuid == "unknown").has_face_evidence
    assert not result.permits_research_upload


def test_hidden_photos_omitted(tmp_path):
    assert reader(tmp_path, [photo(hidden=True)]).photos == ()


def test_incompatible_people_data_is_explicitly_unavailable(tmp_path):
    result = reader(tmp_path, [photo("valid"), NS(uuid="broken", hidden=False)])
    assert result.status == "available"
    broken = next(p for p in result.photos if p.asset_uuid == "broken")
    assert broken.people_status == "unavailable"
    assert broken.has_face_evidence is None


def test_duplicate_assets_rejected(tmp_path):
    assert reader(tmp_path, [photo(), photo()]).status == "incompatible_or_unreadable"


def test_invalid_path_does_not_discover_default_library(tmp_path):
    result = read_people_snapshot(tmp_path / "missing", "library", enabled=True)
    assert result.status == "invalid_snapshot"
