"""Normalize existing Photos context without exports, inference, or network lookups."""

from dataclasses import dataclass
import math


@dataclass(frozen=True)
class ContextField:
    key: str
    status: str
    value: object = None
    source: str = "photos_database"


# Explicit allowlist: never serialize arbitrary library objects or call asdict/export.
FIELDS = {
    "places": {"place.name": "text", "place.country_code": "text", "place.ishome": "bool"},
    "user": {"title": "text", "description": "text", "keywords": "texts", "albums": "texts", "favorite": "bool"},
    "categories": {"labels": "texts", "search_info.activities": "texts", "search_info.holidays": "texts",
                   "search_info.season": "text", "search_info.venues": "texts"},
    "capture": {"panorama": "bool", "screenshot": "bool", "live_photo": "bool", "burst": "bool"},
    "scores": {"score.overall": "number", "score.curation": "number"},
}


def _validated(value, kind):
    if kind == "text" and isinstance(value, str):
        return value
    if kind == "bool" and type(value) is bool:
        return value
    if kind == "number" and type(value) in (int, float) and math.isfinite(value):
        return value
    if kind == "texts" and isinstance(value, (list, tuple)) and all(isinstance(v, str) for v in value):
        return tuple(value)
    raise ValueError("Unsupported context value")


def read_photo_context(photo, components=frozenset()):
    """Missing/failed fields stay distinct from valid empty strings/lists and zero scores.

    All output is local-only. Album names are context, never ownership identifiers.
    An absent home flag is unknown, not evidence that a place is public.
    """
    if not set(components) <= FIELDS.keys():
        raise ValueError("Unknown context component")
    result = []
    for component in sorted(components):
        for key, kind in FIELDS[component].items():
            try:
                value = photo
                for attribute in key.split("."):
                    if value is None:
                        break
                    value = getattr(value, attribute)
                if value is None:
                    result.append(ContextField(key, "missing"))
                else:
                    result.append(ContextField(key, "available", _validated(value, kind)))
            except AttributeError:
                result.append(ContextField(key, "unsupported"))
            except Exception:
                result.append(ContextField(key, "failed"))
    return tuple(result)
