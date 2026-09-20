"""Optional, local-only people metadata reader. Not exposed by the web server."""

from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional
from icloudpd.curator_context import ContextField, read_photo_context


@dataclass(frozen=True)
class PersonLabel:
    person_id: str
    name: Optional[str]


@dataclass(frozen=True)
class PhotoPeople:
    asset_uuid: str
    people: tuple[PersonLabel, ...]
    has_face_evidence: Optional[bool]
    context: tuple[ContextField, ...] = ()
    people_status: str = "available"


@dataclass(frozen=True)
class PeopleSnapshot:
    status: str
    library_id: str
    photos: tuple[PhotoPeople, ...] = ()

    @property
    def permits_research_upload(self) -> bool:
        # Missing labels are never proof that an image contains no faces.
        return False


def _identifier(value: object) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("Missing metadata identifier")
    return value


def read_people_snapshot(
    database: Path,
    library_id: str,
    *,
    enabled: bool = False,
    factory: Optional[Callable] = None,
    context_components: frozenset[str] = frozenset(),
) -> PeopleSnapshot:
    """Read an explicitly selected database; never auto-discover the user's library.

    Production caller must supply an approved consistent snapshot and a stable library
    ID. Asset UUIDs must be mapped to PhotoKit IDs explicitly, not by guessed suffixes.
    No writes, image exports, names in logs, or network calls are performed here.
    """
    if not enabled:
        return PeopleSnapshot("disabled", library_id)
    try:
        _identifier(library_id)
        if not database.is_absolute() or not database.is_file():
            return PeopleSnapshot("invalid_snapshot", library_id)
        if factory is None:
            try:
                from osxphotos import PhotosDB
            except ImportError:
                return PeopleSnapshot("reader_unavailable", library_id)
            factory = PhotosDB
        db = factory(dbfile=str(database))
        records = []
        seen = set()
        for photo in db.photos(images=True, movies=False, intrash=False):
            if photo.hidden:
                continue
            asset = _identifier(photo.uuid)
            if asset in seen:
                raise ValueError("Duplicate asset identifier")
            seen.add(asset)
            people = {}
            people_status = "available"
            evidence = None  # Unknown is not a positive sighting or privacy clearance.
            try:
                for person in photo.person_info:
                    person_id = _identifier(person.uuid)
                    name = person.name
                    if name is not None and not isinstance(name, str):
                        raise ValueError("Invalid person name")
                    label = PersonLabel(person_id, name or None)
                    if person_id in people and people[person_id] != label:
                        raise ValueError("Conflicting person labels")
                    people[person_id] = label
                evidence = bool(photo.face_info) or bool(people)
            except Exception:
                people = {}
                people_status = "unavailable"
            records.append(PhotoPeople(
                asset,
                tuple(people[key] for key in sorted(people)),
                evidence,
                read_photo_context(photo, context_components),
                people_status,
            ))
        return PeopleSnapshot("available", library_id, tuple(sorted(records, key=lambda p: p.asset_uuid)))
    except Exception:
        # No partial success or sensitive exception strings across the process boundary.
        return PeopleSnapshot("incompatible_or_unreadable", library_id)
