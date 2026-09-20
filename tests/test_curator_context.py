from types import SimpleNamespace as NS
import pytest

from icloudpd.curator_context import read_photo_context
from icloudpd.curator_people import read_people_snapshot


def test_opt_out_does_not_read_any_properties():
    class Forbidden:
        def __getattr__(self, key):
            raise AssertionError("Should not read")
    assert read_photo_context(Forbidden()) == ()


def test_missing_unsupported_and_empty_remain_distinct():
    values = {v.key: v for v in read_photo_context(NS(title="", description=None, keywords=[]), {"user"})}
    assert values["title"].status == "available"
    assert values["keywords"].value == ()
    assert values["description"].status == "missing"
    assert values["albums"].status == "unsupported"


def test_bad_score_does_not_erase_place_context():
    obj = NS(place=NS(name="Amsterdam", country_code="NL", ishome=None), score=NS(overall=float("nan"), curation=0))
    values = {v.key: v for v in read_photo_context(obj, {"places", "scores"})}
    assert values["place.name"].value == "Amsterdam"
    assert values["place.ishome"].status == "missing"
    assert values["score.overall"].status == "failed"
    assert values["score.curation"].value == 0


def test_property_error_is_sanitized_and_isolated():
    class Broken:
        title = "Trip"
        @property
        def description(self):
            raise RuntimeError("private caption")
    values = {v.key: v for v in read_photo_context(Broken(), {"user"})}
    assert values["description"].status == "failed"
    assert values["title"].value == "Trip"
    assert "private caption" not in repr(values)


def test_invalid_categories_not_coerced():
    values = read_photo_context(NS(labels="not-a-list"), {"categories"})
    assert next(v for v in values if v.key == "labels").status == "failed"
    with pytest.raises(ValueError):
        read_photo_context(NS(), {"arbitrary_export"})


def test_reader_preserves_context_when_people_unavailable(tmp_path):
    path = tmp_path / "snapshot"
    path.touch()
    obj = NS(uuid="a", hidden=False, title="Weekend", place=NS(name="Paris", country_code="FR", ishome=False))
    result = read_people_snapshot(path, "library", enabled=True,
                                  factory=lambda **kw: NS(photos=lambda **kw: [obj]),
                                  context_components=frozenset({"places", "user"}))
    assert result.status == "available"
    assert result.photos[0].people_status == "unavailable"
    assert next(v for v in result.photos[0].context if v.key == "place.name").value == "Paris"
    assert not result.permits_research_upload
