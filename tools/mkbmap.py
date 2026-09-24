#!/usr/bin/env python3
"""Generate a bmap file for a raw disk image.

A bmap lists the blocks of an image that hold data, so the flasher writes those
and skips the holes: ~1 GiB instead of 4 GiB on the SD card. The format is the
bmaptool XML (version 2.0), so the file also works with bmaptool itself:

  <bmap version="2.0">
    <ImageSize>, <BlockSize>, <BlocksCount>, <MappedBlocksCount>,
    <BmapFileSHA1>, <ChecksumType>, <Ranges>
      <Range chksum="<sha256 of this range>"> offset length </Range>

Every range carries a sha256, which lets the flasher verify what it wrote by
reading the target back, with no second pass over the network.

Only non-zero blocks are mapped. Consequence, and it matters: unmapped blocks are
never written, so the target must already have zeros there (a fresh card, or one
this tool wrote before). Use a full write when in doubt.

Usage: mkbmap.py <image> [output.bmap]
"""
import hashlib
import os
import sys

BLOCK = 4096


def scan(path, block=BLOCK):
    """One pass: [(offset, length, sha256hex), ...] for every non-zero run."""
    ranges = []
    cur_off = cur_len = 0
    cur_hash = None
    with open(path, "rb") as fh:
        off = 0
        while True:
            chunk = fh.read(block * 256)
            if not chunk:
                break
            for i in range(0, len(chunk), block):
                blk = chunk[i:i + block]
                if any(blk):
                    if cur_len and off + i == cur_off + cur_len:
                        cur_len += len(blk)
                        cur_hash.update(blk)
                    else:
                        if cur_len:
                            ranges.append((cur_off, cur_len, cur_hash.hexdigest()))
                        cur_off, cur_len = off + i, len(blk)
                        cur_hash = hashlib.sha256(blk)
            off += len(chunk)
    if cur_len:
        ranges.append((cur_off, cur_len, cur_hash.hexdigest()))
    return ranges


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 1
    img = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else img + ".bmap"

    size = os.path.getsize(img)
    if size % BLOCK:
        print(f"image size {size} is not a multiple of {BLOCK}", file=sys.stderr)
        return 1

    ranges = scan(img)
    blocks = size // BLOCK
    mapped = sum(length // BLOCK for _, length, _ in ranges)

    body = "\n".join(
        f'      <Range chksum="{chksum}"> {off} {length} </Range>'
        for off, length, chksum in ranges
    )
    xml = f"""<?xml version="1.0" ?>
<bmap version="2.0">
   <ImageSize> {size} </ImageSize>
   <BlockSize> {BLOCK} </BlockSize>
   <BlocksCount> {blocks} </BlocksCount>
   <MappedBlocksCount> {mapped} </MappedBlocksCount>
   <ChecksumType> sha256 </ChecksumType>
   <BmapFileSHA1> PLACEHOLDER </BmapFileSHA1>
   <Ranges>
{body}
   </Ranges>
</bmap>
"""
    # BmapFileSHA1 is the sha1 of the bmap file with the field blanked out,
    # rehashed until the value is stable, as bmaptool does.
    for _ in range(10):
        digest = hashlib.sha1(xml.encode()).hexdigest()
        new = xml.replace("PLACEHOLDER", digest)
        if new == xml:
            break
        xml = new

    with open(out, "w") as fh:
        fh.write(xml)

    print(f"{out}: {len(ranges)} ranges, {mapped}/{blocks} blocks mapped "
          f"({100.0 * mapped / blocks:.1f}%), image {size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
