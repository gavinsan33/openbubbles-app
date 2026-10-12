#!/usr/bin/env python3
# flutter_rust_bridge 2.3.0 emits a second `impl SseDecode/SseEncode for Option<i64>` (and u64)
# when the type appears both with and without type_64bit_int. Run after codegen to drop the dupes.
import re, sys

path = sys.argv[1] if len(sys.argv) > 1 else "src/frb_generated.rs"
lines = open(path).read().split("\n")
seen, out, i = set(), [], 0
header = re.compile(r"^impl (SseDecode|SseEncode) for (.+) \{$")
while i < len(lines):
    m = header.match(lines[i])
    if m and m.group(0) in seen:
        # top-level impls end at the first line that is exactly "}"
        while lines[i] != "}":
            i += 1
        i += 2 if i + 1 < len(lines) and lines[i + 1] == "" else 1
        continue
    if m:
        seen.add(m.group(0))
    out.append(lines[i])
    i += 1
open(path, "w").write("\n".join(out))
