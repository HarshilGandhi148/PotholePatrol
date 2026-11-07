"""clean_photo: strip everything from a photo except the picture.

Plain English: open the image, turn it the right way up (the rotation lives in
EXIF, which we are about to delete), shrink it, and save a new JPEG. The new file
has no EXIF, so no GPS, device or time data is stored.
"""

from __future__ import annotations

import io

from PIL import Image, ImageOps, UnidentifiedImageError

MAX_SIDE_PX = 1600


class BadPhoto(ValueError):
    pass


def clean_photo(raw: bytes) -> bytes:
    try:
        with Image.open(io.BytesIO(raw)) as image:
            upright = ImageOps.exif_transpose(image).convert("RGB")
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError, SyntaxError) as err:
        raise BadPhoto("photo must be a JPEG or PNG image") from err
    upright.thumbnail((MAX_SIDE_PX, MAX_SIDE_PX))
    out = io.BytesIO()
    upright.save(out, format="JPEG", quality=85)
    return out.getvalue()
