"""Promote chosen tags out of a provider's tag map into their own columns."""

from collections.abc import Mapping, Sequence


def _candidates(name: str) -> tuple[str, ...]:
    # AWS does not document how FOCUS writes user-defined cost allocation tag
    # keys, and CUR 2.0 writes them as user_<name>; accept every known form,
    # the plain key first.
    return (name, f"user:{name}", f"user_{name.lower()}")


def promote(tags: Mapping[str, str] | None, names: Sequence[str]) -> dict[str, str | None]:
    """The value of each named tag, or None when it is missing or blank."""
    tags = tags or {}
    promoted: dict[str, str | None] = {}
    for name in names:
        value = None
        for key in _candidates(name):
            if key in tags and tags[key] is not None:
                value = str(tags[key]).strip() or None
                break
        promoted[name] = value
    return promoted
