"""Shared PE helpers for the ABL analysis scripts.

The payload is expected to be an extracted ABL EFI/PE image, not the raw
abl_a.img partition.  The first valid PE header is located automatically so
the scripts also work when the PE is embedded at a small offset (for example
0xb8 in the original case).
"""

import struct


def find_pe(data):
    """Return (mz_offset, pe_offset) for the first valid PE in the first 0x2000 bytes."""
    limit = min(len(data) - 0x40, 0x2000)
    if limit < 0:
        raise ValueError("file is too small to contain a PE image")

    for mz in range(0, limit + 1):
        if data[mz:mz + 2] != b"MZ":
            continue
        if mz + 0x40 > len(data):
            continue
        e_lfanew = struct.unpack_from("<I", data, mz + 0x3c)[0]
        if e_lfanew < 0x40 or e_lfanew > 0x1000:
            continue
        pe = mz + e_lfanew
        if pe + 24 > len(data) or data[pe:pe + 4] != b"PE\0\0":
            continue
        nsec = struct.unpack_from("<H", data, pe + 6)[0]
        optsz = struct.unpack_from("<H", data, pe + 20)[0]
        if not (0 < nsec <= 32) or not (0x60 <= optsz <= 0x200):
            continue
        if pe + 24 + optsz > len(data):
            continue
        return mz, pe

    raise ValueError("no valid PE header found; pass a decompressed ABL payload, not abl_a.img")


def parse_pe(data):
    """Parse enough of the PE header to describe sections and the image base."""
    mz, pe = find_pe(data)
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    optsz = struct.unpack_from("<H", data, pe + 20)[0]
    magic = struct.unpack_from("<H", data, pe + 24)[0]

    if magic == 0x10b:  # PE32
        image_base = struct.unpack_from("<I", data, pe + 24 + 28)[0]
    elif magic == 0x20b:  # PE32+
        image_base = struct.unpack_from("<Q", data, pe + 24 + 24)[0]
    else:
        raise ValueError("unsupported PE optional header magic 0x%x" % magic)

    sections = []
    sec_off = pe + 24 + optsz
    for i in range(nsec):
        off = sec_off + i * 40
        if off + 40 > len(data):
            break
        name = data[off:off + 8].rstrip(b"\0").decode("latin1", "replace")
        vsize, va, raw_size, raw_ptr = struct.unpack_from("<IIII", data, off + 8)
        sections.append({
            "name": name,
            "vsize": vsize,
            "va": va,
            "raw_size": raw_size,
            "raw_ptr": raw_ptr,
        })

    return {
        "mz": mz,
        "pe": pe,
        "image_base": image_base,
        "sections": sections,
    }


def text_section(data, info=None):
    """Return the absolute file offset, VA and size of the .text section."""
    info = info or parse_pe(data)
    for sec in info["sections"]:
        if sec["name"] != ".text":
            continue
        size = sec["vsize"] or sec["raw_size"]
        if sec["raw_size"]:
            size = min(size, sec["raw_size"])
        return {
            "offset": info["mz"] + sec["raw_ptr"],
            "va": info["image_base"] + sec["va"],
            "size": size,
        }
    raise ValueError("no .text section found")


def file_to_va(info, offset):
    """Map a file offset to a PE VA, or return None if it is not in a section."""
    for sec in info["sections"]:
        start = info["mz"] + sec["raw_ptr"]
        end = start + sec["raw_size"]
        if start <= offset < end:
            return info["image_base"] + sec["va"] + (offset - start)
    return None
