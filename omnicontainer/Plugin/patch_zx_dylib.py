import struct
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = bytearray(f.read())

magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack("<IIIIIIII", data[:32])
assert magic == 0xFEEDFACF, f"Unexpected magic: {hex(magic)}"

dylib_str = b"@rpath/OmniContainerPlugin.dylib\x00"
raw_len = 24 + len(dylib_str)
cmdsize = (raw_len + 7) & ~7
pad_len = cmdsize - raw_len
# LC_LOAD_WEAK_DYLIB = 0x80000018
cmd_bytes = struct.pack("<IIIIII", 0x80000018, cmdsize, 24, 2, 0x00010000, 0x00010000) + dylib_str + (b"\x00" * pad_len)

insert_off = 32 + sizeofcmds
assert all(b == 0 for b in data[insert_off:insert_off + cmdsize]), "Non-zero bytes in header padding!"

data[insert_off:insert_off + cmdsize] = cmd_bytes
struct.pack_into("<II", data, 16, ncmds + 1, sizeofcmds + cmdsize)

with open(path, "wb") as f:
    f.write(data)
print(f"Successfully injected @rpath/OmniContainerPlugin.dylib into {path} (ncmds={ncmds+1})")
