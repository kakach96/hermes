# -*- coding: utf-8 -*-
import io

P = r"D:\projects\hermes\server\src\hermes\envelope.gleam"
c = io.open(P, encoding="utf-8").read()

old2 = '''        decode.success(Notice(text))
      }
      "enc" -> {'''
new2 = '''        decode.success(Notice(text))
      }
      "members" -> {
        use members <- decode.field("members", decode.list(decode.string))
        decode.success(Members(members))
      }
      "enc" -> {'''
assert old2 in c, "decode anchor missing"
c = c.replace(old2, new2)

io.open(P, "w", encoding="utf-8", newline="\n").write(c)
print("decode arm added")
