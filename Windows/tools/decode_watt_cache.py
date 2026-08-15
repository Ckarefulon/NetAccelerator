"""Decode Watt Toolkit's MessagePack-CSharp Lz4BlockArray cache without dependencies."""
import json
import struct
import sys
from pathlib import Path


class Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, count):
        value = self.data[self.pos:self.pos + count]
        if len(value) != count:
            raise ValueError("unexpected end of MessagePack data")
        self.pos += count
        return value

    def uint(self, count):
        return int.from_bytes(self.take(count), "big", signed=False)

    def sint(self, count):
        return int.from_bytes(self.take(count), "big", signed=True)

    def value(self):
        code = self.uint(1)
        if code <= 0x7F:
            return code
        if code >= 0xE0:
            return code - 0x100
        if 0xA0 <= code <= 0xBF:
            return self.take(code & 0x1F).decode("utf-8")
        if 0x90 <= code <= 0x9F:
            return [self.value() for _ in range(code & 0x0F)]
        if 0x80 <= code <= 0x8F:
            return {str(self.value()): self.value() for _ in range(code & 0x0F)}
        if code == 0xC0:
            return None
        if code == 0xC2:
            return False
        if code == 0xC3:
            return True
        if code in (0xC4, 0xC5, 0xC6):
            size = self.uint({0xC4: 1, 0xC5: 2, 0xC6: 4}[code])
            return self.take(size)
        if code in (0xC7, 0xC8, 0xC9):
            size = self.uint({0xC7: 1, 0xC8: 2, 0xC9: 4}[code])
            kind = self.sint(1)
            return {"$ext": kind, "$data": self.take(size)}
        if code == 0xCA:
            return struct.unpack(">f", self.take(4))[0]
        if code == 0xCB:
            return struct.unpack(">d", self.take(8))[0]
        if code in (0xCC, 0xCD, 0xCE, 0xCF):
            return self.uint({0xCC: 1, 0xCD: 2, 0xCE: 4, 0xCF: 8}[code])
        if code in (0xD0, 0xD1, 0xD2, 0xD3):
            return self.sint({0xD0: 1, 0xD1: 2, 0xD2: 4, 0xD3: 8}[code])
        if code in (0xD9, 0xDA, 0xDB):
            size = self.uint({0xD9: 1, 0xDA: 2, 0xDB: 4}[code])
            return self.take(size).decode("utf-8")
        if code in (0xDC, 0xDD):
            return [self.value() for _ in range(self.uint(2 if code == 0xDC else 4))]
        if code in (0xDE, 0xDF):
            return {str(self.value()): self.value() for _ in range(self.uint(2 if code == 0xDE else 4))}
        if code in (0xD4, 0xD5, 0xD6, 0xD7, 0xD8):
            size = {0xD4: 1, 0xD5: 2, 0xD6: 4, 0xD7: 8, 0xD8: 16}[code]
            return {"$ext": self.sint(1), "$data": self.take(size)}
        raise ValueError(f"unsupported MessagePack byte 0x{code:02x} at {self.pos - 1}")


def lz4_block(data, expected):
    source = memoryview(data)
    output = bytearray()
    pos = 0
    while pos < len(source):
        token = source[pos]
        pos += 1
        literals = token >> 4
        if literals == 15:
            while True:
                extra = source[pos]
                pos += 1
                literals += extra
                if extra != 255:
                    break
        output.extend(source[pos:pos + literals])
        pos += literals
        if pos >= len(source):
            break
        offset = source[pos] | (source[pos + 1] << 8)
        pos += 2
        if offset == 0 or offset > len(output):
            raise ValueError("invalid LZ4 match offset")
        length = token & 0x0F
        if length == 15:
            while True:
                extra = source[pos]
                pos += 1
                length += extra
                if extra != 255:
                    break
        length += 4
        for _ in range(length):
            output.append(output[-offset])
    if len(output) != expected:
        raise ValueError(f"LZ4 size mismatch: expected {expected}, got {len(output)}")
    return bytes(output)


def decode_lz4_block_array(data):
    reader = Reader(data)
    outer = reader.value()
    if not isinstance(outer, list) or len(outer) < 2:
        raise ValueError("not an Lz4BlockArray envelope")
    header = outer[0]
    if not isinstance(header, dict) or header.get("$ext") != 98:
        raise ValueError("MessagePack extension is not Lz4BlockArray (98)")
    lengths_reader = Reader(header["$data"])
    lengths = []
    while lengths_reader.pos < len(lengths_reader.data):
        lengths.append(lengths_reader.value())
    blocks = outer[1:]
    if len(lengths) != len(blocks):
        raise ValueError("LZ4 block count mismatch")
    raw = b"".join(lz4_block(block, size) for block, size in zip(blocks, lengths))
    return Reader(raw).value()


def json_default(value):
    if isinstance(value, bytes):
        return {"$bytes": value.hex()}
    raise TypeError(type(value).__name__)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: decode_watt_cache.py INPUT OUTPUT")
    decoded = decode_lz4_block_array(Path(sys.argv[1]).read_bytes())
    Path(sys.argv[2]).write_text(json.dumps(decoded, ensure_ascii=False, indent=2, default=json_default), encoding="utf-8")


if __name__ == "__main__":
    main()
