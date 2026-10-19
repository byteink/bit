#!/usr/bin/env bash
# Shared IR type-ID canonicalizer and strict SSA derivations (#1766, #5909).
# Object-backed proofs use the direct-only bounded JSON mode below.
# Source this file to call canon_ir_ids without starting a proof process.
canon_ir_ids() {
  # LC_ALL=C: a dump can hold bytes that are not valid UTF-8 (a string literal);
  # awk in a UTF-8 locale dies on them with `towc: multibyte conversion failure` (#6716).
  LC_ALL=C awk '
    {
      line = $0
      out = ""
      while (match(line, /\$t[0-9]+/)) {
        tok = substr(line, RSTART, RLENGTH)
        if (!(tok in map)) {
          map[tok] = "$c" n++
        }
        out = out substr(line, 1, RSTART - 1) map[tok]
        line = substr(line, RSTART + RLENGTH)
      }
      print out line
    }
  ' <<<"$1"
}
# Pure fixture constructors are separate from the production proof library.
diffiropt_literal_fixture_library() {
  DIFFIROPT_LITERAL_FIXTURES=
  local read_rc=0
  IFS= builtin read -r -d '' DIFFIROPT_LITERAL_FIXTURES <<'DIFFIROPT_LITERAL_FIXTURES' || read_rc=$?
def literal_test_macho(values):
    rodata = b''.join(values)
    payloads, headers, at = [], [], 0
    for value in values:
        payloads.append(at)
        headers.append(struct.pack('<3Q', 0, len(value), 0))
        at += len(value)
    strings, symbols, index = b'\0', [], 0
    for i in range(len(values)):
        for suffix, section, offset in ((b'_data', 1, payloads[i]), (b'', 2, i * 24)):
            name = b'___bitstr_' + str(i).encode() + suffix
            symbols.append(struct.pack('<IBBHQ', len(strings), 0xe, section, 0, offset))
            strings += name + b'\0'
            index += 1
    segment_size = 72 + 160
    start = 32 + segment_size + 24
    dataoff = (start + len(rodata) + 7) // 8 * 8
    relocoff = dataoff + len(headers) * 24
    relocs = b''.join(struct.pack('<iI', i * 24, 0xe000000 + 2 * i) for i in range(len(values)))
    symoff = relocoff + len(relocs)
    stringoff = symoff + len(symbols) * 16
    head = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 1, 2, segment_size + 24, 0, 0)
    segment = struct.pack('<II16sQQQQiiII', 0x19, segment_size, b'', 0, 0, 0, 0, 0, 0, 2, 0)
    sections = struct.pack('<16s16sQQIIIIIIII', b'__const', b'__TEXT', 0, len(rodata), start, 0, 0, 0, 0, 0, 0, 0)
    sections += struct.pack('<16s16sQQIIIIIIII', b'__data', b'__DATA', 0, len(headers) * 24, dataoff, 3, relocoff, len(values), 0, 0, 0, 0)
    symtab = struct.pack('<6I', 2, 24, symoff, len(symbols), stringoff, len(strings))
    padding = bytes(dataoff - start - len(rodata))
    return head + segment + sections + symtab + rodata + padding + b''.join(headers) + relocs + b''.join(symbols) + strings

def literal_test_elf(values):
    rodata, strings, symbols, relocs = b'', b'\0', [bytes(24)], []
    for i, value in enumerate(values):
        offset = len(rodata)
        rodata += value
        rodata += bytes((-len(rodata)) % 8)
        header = len(rodata)
        rodata += struct.pack('<3Q', 0, len(value), 0)
        for suffix, location, size in ((b'_data', offset, len(value)), (b'', header, 24)):
            name = b'__bitstr_' + str(i).encode() + suffix
            symbols.append(struct.pack('<IBBHQQ', len(strings), 1, 0, 1, location, size))
            strings += name + b'\0'
        relocs.append(struct.pack('<QQq', header, ((1 + i * 2) << 32) | 257, 0))
    names = b'\0.rodata\0.rela.rodata\0.symtab\0.strtab\0.shstrtab\0'
    chunks = [rodata, b''.join(relocs), b''.join(symbols), strings, names]
    offsets, cursor = [], 64
    for chunk in chunks:
        offsets.append(cursor)
        cursor += len(chunk)
    shdrs = [bytes(64)]
    rows = [(1, 1, 2, 0, 0, 8, 0), (9, 4, 0, 3, 1, 8, 24),
            (22, 2, 0, 4, 1, 8, 24), (30, 3, 0, 0, 0, 1, 0),
            (38, 3, 0, 0, 0, 1, 0)]
    for i, (name, kind, flags, link, info, align, entry) in enumerate(rows):
        shdrs.append(struct.pack('<IIQQQQIIQQ', name, kind, flags, 0,
                                 offsets[i], len(chunks[i]), link, info, align, entry))
    ident = b'\x7fELF\x02\x01\x01' + bytes(9)
    head = struct.pack('<16sHHIQQQIHHHHHH', ident, 1, 183, 1, 0, 0,
                       cursor, 0, 64, 0, 0, 64, 6, 5)
    return head + b''.join(chunks) + b''.join(shdrs)
# Exact retained public046/candidate captures and their own O0 objects (#5909).
# This is compressed fixture DATA, never a compiler or IR generator.
THREAD_AUTHENTIC_CASES = (
    b"eNrtfVlz6sqS7n/Zr6s7rImpI/pBEyCwANlM4sZ9AAGyzWQb2wI6zn+/VVlSliSKYa3ldfqcu1knzrblUs1ZWanKL7/6P//z13q8"
    b"mv31X3/Nds/bj+d1+Nd//BVsPtcff/2X8h9/zZ9ny+n2r//6n782yyl5abTuf/p7YzMePnQmq12hafai9rPx4Q/18rjrS/em0fFX"
    b"mx/3pr50u5uQ/q35aLy2XrxwFr0++y/6ptHVi05NfgqsHf371rErz+MXbeuYvR0pi/7ttR1uQvK8dywpDNYPc1+pbicmrceYB8ru"
    b"a2qGS9eMwkbXfnVqC6Wlw/sH+r6vVD4D9WE+HhQkSDP1yHzWybte2CFt8RU5Gqqt9ejReJ4oFVrvHtobQRmyqM7pqrodKlWJ9hfe"
    b"fV6EXaXxxsr1abkvE6VwmFYrn+NB1HTIO629XnFqy5cJyT9Z9UJ/Vfma0L8/0nb75B3jOXim70UkzTmQsuXmI/y+a5qLZvyzSOvw"
    b"1w5t/9apNZ7d5/CVjDMZS5eMZe/VXLG/xWO2c01a7/RlSNtfq7w49dbrbNWrtE0jmtYbh07/YwpjTt+vvcqToZ7UT/JCvez3lw30"
    b"sdnd8Laa0D4yDgtoS+sxhPpbJq+/BfWPXkeD3WKoTJdTkIXGxK1KIA+0P8GqL8G7OpWJ3obVQd/LjOXrZO1BHseUdpl84WuFVLma"
    b"DgovTq3wNbUr7zdZ/LvIIp1PN91PNna10dOk3lqycbAlOnbjQesjqFaWAR9ficmDi312475QGWZ96ZG+2PumR2XE+xXZTMrQiAxR"
    b"GcTxaD+K1saTcG20vZSM1xtLf/BgjNYPy+CZyJu1CSeDatQBmYpgbDrPIINFJmcL1rb6lo5hdNXaSPr5TNpYb0hDpfU0qUVQD5HR"
    b"7UT16HqBtRGvI/Y+yFbra7JukTzLz6nJ1pjL1kF6Hg4jhcueC+11mXw+iuok81mtPPH15byirJg9Jb2+Jqvlls17wNeVUliSef2a"
    b"KDRvj7Zb4fIbJPJL6ma6zI11Gf0Zz1eB1jFSWnN/sNtOFDcMlGVx1JU0p25IwdqtDGQJ19543f8IQH4cMk6LZC2Q8SVzQtv9zNYP"
    b"la1zuiGzvvaJTNKxt3dsvhxW9j6vcwVz4GXWlQRrCda8LSXyTX5XYjmFuW0dcvLQDemYrsaD/nZUraxHQ4/mVwYHY5rSd7FsVxej"
    b"uG7yjsraG9K1to/zFcw1acZqJE9WbjitVd9Hj0yeYX2L9HN27ARtMYTrJ10P6E+78TWthVfpfDYfRgnG2bxqvcXtc2j79kQ/vFCZ"
    b"gXqI3BPdx/X14wLb2sjqMa5TLJ2tC5Pr7YDoCy7PDm3vgZXRE9WpkN/n/hDX7J6MLZ1jVu5zWl4KrxM2h2pqrX6m9iSZtrsFOrqx"
    b"p+/do5z3Yvm0N0yebNSXTB5+WvfvyTgVWFkOyHxGh7L6pWTPifeoWK6T/QJlBfbg0Wq5nNQe5iOFyYXb30bDtP5ie7FgDuw4Hcb3"
    b"aVRL9D0pY8/WUEbv8/WkHul9oU00Fet9Pa33W9JEbSy9VX9Ff16jx+F3sl8+1irbUa2//wWbB+SF/O5MlN1iNHSSfhx+0gaSzttA"
    b"vVM20AHkTed6/qINtE/bQIHQBmqbJ2wgWMcB2gNtZuNSOVRO2UCkn9Gv7w12lJLvfVa+YxlRW0xGllRWSbupzHH5l4/l/0j2ZaHs"
    b"L9OyjzpZPrLhT+zp9107nU+lOpZ8MK5n0e3j8E8a5NK/18chSX8++kCkija/mQuFtFU9I6SPvyakiSEwWVWkrrK9GQHfZgT0zhgB"
    b"GbnYJ4cGxHClRncz/ttvKlQ3pVDdY4UKm3W6n2zsRmTNBkovbQDEHw39HR9f2Ah3sPZZn3eCAxA0yDMK9Pkq2VRimaZGcn5tFERr"
    b"oy1eGxmjmhgSTyO7uprSzf+mg79LB+/P6WDywUfrWPtyhXzA7r7IPngYD1+XHfLxFNQf9sGBqFJce8bbdCBHyQdoG9cCkbVu/qDD"
    b"OaMbMuvrgDIJutZmsvt8ZBicMsp22XWV/uD0Ujrcj+UU5lbNycMJQ3eUMXQT2fYHD4u4bvJOwOSLykm9EedbNOfephnbFZI/+EgM"
    b"YFjfIv2cGTvRYYt4/aTrAf3pkX1ibN4OWv6dD1rOHaQk+0XuQDF/yLHLH3KcPWih6ceHIId4DYkMbir3eb2vCW0iWSi3Wkbvqw9f"
    b"RPebo8GI/Oz90ofez9s8IC+kD09fpL3LAPvh/qQN5J23gR5P2UAuHOqm9PwlG+iQsYH2QhtIO2EDKWADcXtA4wch/smDELer//Le"
    b"QPKm5NvJyEoiIwGTkT3IKmk3tYG4/PeO5P9Y9nsi2d9nZB91cq8Z2z+JvKon9pMPWBOYL6A69r/Jx+JmOd1MXsj34uHu/eMujHRd"
    b"t3X459H/OOT/VsR+x38j+h8lee/cP1t3k18dKIv+M3QLXwjof+rwV6zDmA/Vh+Wsnq10KFd6D/2n3qmqvngjQ/I/Vl5Nb5P/rpIO"
    b"hflM1cp8VKtKfqYqUr/0YPTtbP/4IFgh/tomNeisOwu9TLt28h9pP1tPufr7dt/vZ940QyNpaENL1U//6F4ec9p+pfFK1t3ajzL1"
    b"217/wcjNTz35dcDnJzQ9qJD2h/7WOFkVab+/WpK1+vA8is6P34qMUNy/DU7EfXifjN+Atswsn+5WCE2jr3s2aVUnguEgQ2eU9ehE"
    b"nk7Z0qf1yixqv94Frr6Yt7p6cy0PotprRS2bb3OXaLR3WY+abxXdNd6+eoZ+7zV0x3rskzo+mgvT66xDPVq91SO9W9zbhl7NpNdS"
    b"6b2iQvpc7Sr6bvBGx7CqJ6NnPtD/LjsBre+gh1ahovv6j3mvqXfW5P3ZGx3phUnyN+w+Lb8ambr0qVvVtw3N36sQy+It9VyOWiS/"
    b"Vyf1y6ZEygsr5DnokufKTCL9jVxjEejWsDK506P6w91wa73NVUtv1A+9yHyt9LfG23z6or+tD8Tif6t4rvn25Vn6GMoHCV/A7JP+"
    b"QLqtf5A5DFsNMuam9EaG4cdMt8zxZq4bnXeHpPcz6aNUevedrrE+6X91vKEj0mNrhpZvQ39+kMl8eyLz0Vn0jMgqVL0t7Y9Va74P"
    b"6Xhpujt4+3It0j/JoP31Pki63yHPqk2efxhT8iyXvOKa9Lf2EOmtufx1Z+ktOv/N1zufz/+czH85YuNpF9l4kvnTy/NHdV14f6L9"
    b"JfV130LoP4xPQNI/Oj36fpO2n67jjzk80zXUs+l8hfn5juVr136rksX20dSpPB102n6dtrd3z+aLtK9M2gfz5RNlaT7m5/du+EHk"
    b"9Y7On67LdwP6vkT6S+avEkbmQ1km/Zn37/Qxm0/efm9O1syucj+brz5t2p6Qtoe37/VA54vMP3mfjIXxIJFnmT0HVJF2qTzm5wvG"
    b"7wv639M9UyZ/0xdH80Pm4219F5H2wXy8XdP/CXnfovJK+qtweR2WjXi98vaTpa936tJH4cdY87LzCe1bE31534XxN8j8VQ2XyKeT"
    b"l+9E/mG8iPxC/6E8suZI/0Paf3iG9i+eSPq9BvriQn9DW2f6ofb2B+XxKvlrofwtiFon8nJBvjakoB/zC/070Z9B0h+qT96O5ku+"
    b"MF/KVfMVkvF49U2iL2Qif1IkbC/oh6vWF9OfF+YvPDZwzv+TLmzVF9L1zYX07YX04EJ670L64kK6dyE9/M32a6I/+r/UFOH4c3vK"
    b"PGHACv7dXyh1cn3/Mwbm2X9tnt4k9v1+9EjsSbWxvF8RW6/WeiLfHYd7ZbkfKvCdRWxN+cMfVN7J82ugup/UTpt0yRKoN8j33MN2"
    b"spKiRq2wnEr9fbCq7Me1pdRVCtvZgAG40ueWAAwY0DOKnTlRHzbZb9v+h2s+fIyGrYM/mC4bdW/fitDUFw36Mlg3voJlSwpWy8+R"
    b"RM82sgaw7sJkVun8SJ27u7udpyvws6dr8NPXi/Az0Mv0J9EdEz6Ofd0I9Gpo+lie4dPnBbbKEIhQyIxPYmJ29ZZFCi339NYL/dnX"
    b"2/A80NvwPNQ78OzrHXg2+QeNQ8xDYkrXIxRKeCaFVoXz6+iv8NPV7cgKSWF3Vd3awE/PiujP2PCP2+3qLS5aXfrsZ557//TyV79Z"
    b"fv9C+dbZVeHo6z9c/1s8j6fKr4aWFtez4PLmUts/UV5W/NwlQhj/KX42hKrMvKAMkvVhnH3JE8v3WT159P2VyM9Z5Tqg/xnnPw1p"
    b"F2q5fsD3m+nkXh0f9a/pXdxc67SoWk6/UvtCN7aiTeg537PwaHx8bOLJ8aGvGPlNdS3alOhHwlH/QQUZkWiTn+bzR0e9cH9l/tZn"
    b"tsz43wHOB3J/hHVSE5Vv5I0CWbTT3dP2O7nGWsGJ9XXWDimJetCB9uXLp/aUkTeafojm39N/ZXwXKCFUfjoDLy7acEGILVK1qcSn"
    b"OCSdHSw1afoS0rc0PUzafz+DX2lSBTppknGwDzDz7ZCawp4RN73SpsuBLh07KtM2QvoooukV+im6pekWUTmm2qPpDVJKZxoaTD4N"
    b"V4V02j4ZJqtD3rnve2Y8Ph8zev5jkvmx5DJNp/m7DphFRZpeoOl0fE1Vg/y0/gdQz1TEKlU6fDS/HflUfUH7/NBK2rem6dA+RaLp"
    b"0L5JaCXt+4J02j5pQxsN7etGdtK+Pu0Ua59P06F9VUiH9nF7VQNRMUm69YKi3IYPWHpGpxdg0OkZkrWGX7s0HYQa9D98kID+srZ4"
    b"3tmGWQXVUoL5oceTVgjjO6fpTZgf2pzChjbViaB8I25U+xPS/YxNay3DRI+3t3py3lrSEnvQWkAaLbT9DD+gfXD+SKXQ+oTy6fdf"
    b"24O8Ybb8J5Todh2NTG2T/NV6gfrp0LQfML3gJVrTWuHibE/QHi+U41NQMl1MVOn/15jOxg/a/x4m+0N7h+mlHub/9DB/BdM1aJvB"
    b"2m/ES5+0307St9B2mv8F5B/ydzG9EGD6iqfP+Pg5NJ1uHdarh+kbSKdVFeGol46X9c7zH7D8Ei//k6ff8fa5MHb0/0+hmcxPk86P"
    b"AekSpi9g/UH+PswftH+B6WueHuL8FuEgG07mXyMzPhRuM71VNgTfnx2atsvttxZdOg63IZwI8y9QmZsbzL/H82Gm7yF/jZtnbcxP"
    b"Fkmyd9k9zG+iYjUeMf893+N9qFOzMuffdZflD9Pn78Ydkx+S1rRr2S9VYovrlo+dasTySX68h/g58MHqd2jJWD8TRVq/dY/1uxus"
    b"38Q9yhpg/a0e1l+Ikvr1EH0ZHRfr1/gOZoP80PqtsMr/aCf1r7F+0zaS+nt8j/xg8ufSQcf6O6Ed129ssH57YyT1V7ykfmOC9Ts6"
    b"1j+KsP4CH/8Q619h/aaN9es2+g+WWL8ZYf1NF+u38CyCbEBJ/S7vfxQm9ZPxS+SntcX6NT7+X1i/Gda5aekk+SPMb0hmkt/h4//F"
    b"1hfdb7aY/wHkG8aPy1+VrT8D1GWA/g2Wn26yvP4xq59usrz+eg/zt/mi0jE/d4rpzxHmd/AsouFjfo3nf8L8Zoi+mXc9yW9y2/8+"
    b"YPm9tP/Fslj+HtUcmP/A6q9SrY75W1vM7+FZlLXG/I2wmeQvY37dMyP0v2D+Nj/ruQd5oPnv+VlKNXKT/D4qFdO1BN85YD/k7bRH"
    b"Jo+5j5BQkN94FeXXqxV6jhHRM4lpbfcZP3+OhtMqnFeExhzPSDyKUQLsoj5UU8FA5B04KyHpqSAH8k4WOB6XnTszMeZDufI8Hj4c"
    b"pvXG3K1WFv7w4Yn62MCfV29JwbIc5Z53Q+XhaVqzqX8PfHGB+rAfHvLPjdjPmasjzD3LwjoPuWdJXKeXe+4L62zln5fCOpXcsyqu"
    b"M8g9PwnrbOu5576wzkJ+bE/Mwc7Nled2q+Lx7fL2TuvLaNQv79r98r5VLe9Iv79Gq1FqbB8KQa1P8izn7ssD+enn8+5bclkbHojs"
    b"KaNVwOVFmg2N5fDgqLT/pM2f/kBeHpX7Mp23q2n5YX9vkfraJ/JAWqqvk35G/j4ycqbIGXki7x6y73qZd9NyQN5Vsu8GmXdTbVj4"
    b"q+nczT97uecw9xxln1u5/K1c/lYufyuXn7YH/N4qxW5x/DbpA31nTvGQVB7Hg8J6qLS+JqvW0zSdRzVompR+P4U302P/PcXOZPCU"
    b"uv7f/80A/n8Qs1ELRZiNzZ/AbCgizIYTfhtmQxFhNjohYjY+vw+zoYkwG8qfwGxUUzYHnx8NMRtgGHwPZiMSYTbaOmI2wusxGxpi"
    b"NtrhDbNxw2z8NGZj8Hs+cpdjNvxrfObgg+5TnznJX30jpS6swnU+YyL2jfs8xkGxrsdwTH4Lw0HVbYLhCK/BcNDxeJXi/IO3cMEU"
    b"8bU+cjGm42f6+5uYlaswKjpNh/mf0fJgO+vR400JymfzS4+rn38Q3TZ+v4TRMXQb5Nt42/4vY1ZePKL/HqH9dL9czP8gBgf0D/RH"
    b"ovr3aL4mF+branl8G1D90aL6y71evsQYJCEGJDd//g3TccN03DAdN0zHt2A6ttdjBq7DXkQMK1A99ulL8ZR04/704v704/4M4v5Y"
    b"fDHYpF2oxACrYEf49cKwCqHeP/LJN0JM1+L5K8bzl8yXw9dtV7c8HA+btr+aee7/NOaBneX/ufqbzC14snwinz/iehqZefLAQcPn"
    b"ic47CqPFnhlGQj/lcz6pai37sh5cHMnf1+V97Ouo//eXM1WFmItAhGnwRS2rhSfl94w+10Q+/bkIMwHz38gN1hHcJMEsncVErESY"
    b"CBDBI0xEKMKcvIp26mbiOM7k357APP3k/LH1UTuXyY0SYE4aM+GJUC9feGiUxoR4ySDnMSFmvrHqifVVvbgf5ntgRSLMSUUEHKKY"
    b"hCNgj63/yvi+ooRQ+bHkRYL56DIhBsxBmNhzlmInotBl8kfhHB+bpP2muklEszOLYsyH4ZYRMyJJgBmguIpuaCSYkg5iNhTwOQMm"
    b"YgLLBTARMmAKKCZC9RPMR7cFPmloXxcxG3KImA0ffFqA2XhOMB/2HnzWgNnwdMRsVBGzIW0Rs9HVEbPRQsyGsqDprH3gc4H2SQkm"
    b"xFJ7Sf5uC9KhfQ/gyIP2gc8W2jeEiYH2TRPMh73TDB3bl5zQtGtob2pRIsrWAuE1bQboAkwGGJ029TsxQBvV/+wDBfRXSU/gRBab"
    b"VWp6tMtoz2uAGaAmgPUM80ORFe0xjL/LyvdYo6x3SF/FfvvEO+wj5uIdTdM2k0GXYS4SzMMr5K8yTEiCSShB+VTLWkvI62TL1xAw"
    b"Zz1FeoIJaKKca6z/DHOA6T3UmgVcnNaKYzrmHNPhImbjlae/6UlRRS3ZH6wtx3TIHPOxwPxfPJ21zWPt99jSJ+1HTMU9x1SUEXOx"
    b"4OlDjvngmJA1Hz/AzMDWUexh+hsMcw3HF7auIi9/y8tXOeaDl//F0y3EbGg+nF8z+aDzM6PpLY7psBHTseSYjhFP55iQDZ/fBaxP"
    b"UDcBpMMY2oipyMP1AFPhern9lmIyTG5DmC7mT1lMb5i/7ZkZfc8wHfy8loGiIP8zmi9GFfObHirWHtZvubjH1xzERHziHmwcEJPR"
    b"CjH/PEJMCMckNHTEZJR5pwLEZLg+7iDvHmIyHPRV3C84JiNCM62J9Zt8j5IRk2J9YP3tAOtvc0zCAetn/oXYqEdMhof1GzpiIu6w"
    b"fqJPEkxEjWMi7j3ERNhoYVkaYiJCrN9ockyGxGM6I8Rk+Fh/LcD6bS/gRlZS/z3v/xNiUvQR1t/wsf49x4S8cEyGh/V/eEn9FsfE"
    b"uA7W30YLyeKYlA7vfwkxKUbKwmSYCJr/kVtYU1gfDFNT4xjUBBNidDG/7SEmZMblr4eYipR/ZYiYDJNjOmobxGSY/PNNTuV3uHmP"
    b"+Te4qJwt5i9zTMcA8+sc07HxkvyGh5iMZoT537h/RhVhOiIRpsPlmAybYzommL/GMR0Fnp+ZuQzTJMB0WHc8Pz9LMRHTYfmICTEC"
    b"i2NKcFJfRJgMsC/ydpq9EWE6fFH+sSfIrxvzzJlJyJ4nq776MGzsJ6qjD5Wn16ld+ZzUF+R3dnaiVyv70aC68AYjaTQk76gPT2Ol"
    b"pzPuDnaGQt45TGvkvV5jOVqRn15c9qB/CJTqevT4ILkvecyCIcYO5DEGYszCLve8F+MknNxzS1xnDoPSEuMfpNyzLK6zl3seifEg"
    b"OQxKS4xBUXPPmrjOMPe8FONBjnAaJ+agq+dxNafwNrvTOI7RCbyGXSDzIpGfyimsxlCprEZr9zQOZFX9GHkncCB6/u+9Av27OA9N"
    b"C7NYjizuY5fFZzjZd6PMu1L23V4W95HFiKjZd3kbRrXGenjQc8927tnJPbu5Zy/33Ms9+7nnIPccprEYnDMkSmM54jNPhhV48YcZ"
    b"/AbDk2XwIpx75Rj/EXP/6Pp///WP//hrSzRMocgJ/+dTdTZTg9m4LAWFoDApzsaBWizMA206lYvF2WxSKcmSrI6DqVyelioSaVBZ"
    b"KStqRZHHM3WK5JDaZKxpRbWojqVSWZpP5Ep5osiBOpkXg7KkTGdScVaaVaTSWC5olelkPA0CaVJRZ1NSXKAV08QhRUUqFUqz8WQs"
    b"SZOJOisp5P/lwlRTZ8FYqYzLJWUyKxbHBbk8U8uk0KJcCpRySSrLlXGxLKUBLeOpNlXGpcmkohSlQJrNx7PJuFgqlbTxXFHlaWU2"
    b"G08najAujdW5pBYDeVbRNHk6k2dacVwq/vWPf/wH3qGw+lx+PL8uZ/8ZjNfT5+n4Y7a95jqFw2jYePUH0c8w9vwiQ2HM1pNhK/w7"
    b"MfW4Z5h6Yja1RwFb4fMRW+HuN9gKdym2wkOerTDLMCViK+ydYCvsMfpuPcVW+ChgKzSROXLn7hfXs/l09SyrJjIXLk7J7J7KI6ck"
    b"ztOgO+fZA7sLVoaZlj3nAoOgc5oF7cVh5TEWwf1FJrSk/gyToHOCDc05xZq5Z2yCTooRzYmZMykVuZMwCioxo6CSZXV1YqrrIKH6"
    b"1ZpQJryr8nlzf5E9k7bBjdkz4fe9gG57HzMMFnBNdPV47Sw4i9TBE7BIOXkGtQPTDwIGta4elwO64WM6iBK67QPTW64c91UVMKQd"
    b"stTGtJwwT9t9YFTPrpqi2z604QoSO+Jj6UUn18BLeg14UYZZdlB9nTyHr0599DUecDZNHB/zLHvf7hwr4wlG2c/RMECmQFhjZK0c"
    b"6f8Udfe18nFaxwNNdjLHBzYOLWB37Dyep+ymLGXNhMkT1oSbjJVAv6fGJ+R6/vr2L0603xW0/wnb345Z/FyhbqCU3GHMpghslRrZ"
    b"n5SJslxkr3WAPuukv/vxoLrN9jlIs6EyZtpUPRzBO9oT6wjkIGZTxrQ0i+cRvbecp7YXMrsdBoenLKshY6uFNng1KWrUGVp4UtPo"
    b"HhVfmdJL9oxwuqq8jvTzLMx4LYSZKrveWhLr9GmC48hYSlv7xRE7aEp+6JfR62Q1nY/WZK/rw3zC9Spk/OO0gPX3RRf1t5DTQXsh"
    b"M2h3OWlnWEqdzHxmvuApG98LY1SOr9MoZGUh2adOyAKTHzXD7vniZdd4Ha38VbCqfLCxpfXSdROnpfeyfH9eHnKsq2zvysnMvlXd"
    b"ahmZeWH0+dAG28hEqDRT+xnb073UGga9mLD8ZSjhbwbuP83A7SHVN6Q/n6Bczdwj4CTGxQHuPIjvJuD0kPav0VfugZI1uauGUqzm"
    b"qU4zVMTMUDNWZIwOowydKhvr0dDOUTSz+zeYoWTLSG/J+iJzKmh493B8n1Nw8j4nV89SV8bl7drdU/LnRGn5PaJxfjlLCb9rs0UV"
    b"ZRXCeVr4WGEI6bJZn52YGt65RJmd1J+hh3dfxLTZsYIQUP86MlMKnDqbvAvy16YfCi8JTbwfG49+5sPLfYnv4UKq0thAhneDlKH5"
    b"a3Sqbao/DoxOlf3uCOiCE4N7AcZwQvdNdA/LR/txyF9j4IquMdgf3TNz8E/dMxOlDdvJsL9FWuwDbLqHVmzECem1D3lF7x7Tax9g"
    b"wzlk6LUPjMLc5bT1kvt4irbeiVJGs+Sm7yYjsjweaJtkA+RU2Mn46Ofl+PEspbLwI5EenXPdTWVPfxXsKyna7CuvvDh9Z40qoNw9"
    b"cMpdj1+pcNZwtBO9nzIWTughy0ndW3N1+wsn2n8QtF/j7V+kdf2RnhrBngUf0HCnV9vMGoHu80UjL2vs5PfkU8YOpSLPGjsn7pds"
    b"5Snm5RMGctbYia8GOGHs7Jg9YcvxnYGZD5aT+4flpe9NS8pO2UAO/2DLfRC0H6/7IKDjn/0gcCLhdRF5HfRinzCQn7IG8tkPAieK"
    b"D3SY3faYkYV9TFN/ShZAfrIGPzu0uWzwO4djg1/0geNIeYOffeAcG8g5g189b/D32IEO21ul9BqmejG+C+nP0lu73NXJQyUtHV2d"
    b"3xgqGXFYPw+VbAPso/QdoZK8/BRUpM1YUDBU8gxE9/pQyZQrv66l8KKL7w+VdDm99YzPT4reGvzt1e8IlWyjK910cPyqgMeA8QOi"
    b"GWN7Raik7tNQyfsQ8HBd4JMKb6GSt1BJUajkVfP/E6FaPg3VUiBUK6KhgEAHLUMoITxD6NZAFLoF8/dF+v/22qd00I5eOxWKBf25"
    b"G36Q+SLtH7HQrWrI5MEuvj/pu8efDpWj8JQq1an3w+tD5z5o6FwXQuc8r6ZLIalw9PnEQul04/nu+vb7evOn+kvlF0Ihi+tKlA39"
    b"VP2o+apDaCK1yjdPyXizULoj+ZVY6CR5n0IH6Xol/ddCt/f2bCf971V1UairR+cb6K0pVInKMxn/Zzr+npe87/WA/prKD5TXMLE9"
    b"Oq/fpO8v6fg/Nuj4kfFt0FBS8n6PytMzXS9zn6wXIo+eKeXfJ+U33p7KenW2fSLKspdON9Lpnx9PFK5F5LGHoarZ8dBoe6pEXn48"
    b"+HW63kyy3sj7/htFFjYodNd8gPEg2y0ZHz/u3zAOHVbjUNT42Rtm+9/8+/Z/k5t/vr7YemT9pXuWNKb6c+5R/Qj7SY+GYtdgP5Hp"
    b"flKOUN/y91P6NKVv4/S0vh3G+hZCuYX6tsLox+l6kI2Qhm5vYPyrRUqJZXo01HfxAO3v/eZ+pFUF65tu+LS9+vg9Dk1NGUDn/7Uu"
    b"pD9fSG9eSL8U6li7kH7JMG5fX+gVNvbxv+6FUEzh+JoXQjFTTK3O9U25YK9a3N4zVy16DdQXC/MsJBAz2Vcf5GBV3d4rsjypP7wG"
    b"td3ynoZlrh5eqe0+Gl4O80wcGuD0hDR5Gaitp5HSW0wtRz050jWWvxd/u9Iz0nyozC4OKbYjy4tDGf04lDGMQxlZaGOU0C2jkWtR"
    b"VG2Vhr41Qh5KGZLnJvLTcUbkTChaHMp0bajoLoxD8xw+IzSE0fBZnBgTCniuHUd1xe+TyjxQp9eGitY4JhZCKsvpkMpqiCFrSUjl"
    b"MA6BSkIQh3E/dUZfTZ7Je0X+QQbPVU8wPm0IMfj58SHvNTMhkpn29HIhkj1Orxs/O3r2ueGl+p8OzQV6azv+DrLjZ5+G2rQSSYRQ"
    b"yYDIh5F8b7J8kdGLnyEkdpC8H4da7uJnCHklzzCfHc/IjmPAl3EY15M8034bkZlqtxOrETZPVF7vQzMjr65nnpHXf71QTjsyLoXa"
    b"wfdvXRRvb+bjIqGcPMkPY/IOjfPUBA6RZ+cS5UBTtCmBvj4S/kgU1N8SDoLHJO+YesAo5+agIVL7FjsqMi/Nz0+FEtKo4DiUsMpD"
    b"CVc8lNDHUEKDhxKuMZSQ6ps4lLDGQwlHGEpIpy4OJazyUMIBhhJCurKg6U0WqmfEoT8fEOpEVbelAlUW3Q+7bS8JZftoQCjSgpYP"
    b"TJRUld33YR3RULmKD/S2WxqqB/SxVOXfz2H8aMDbx48k3VIh6gHKZ2cjUH4dQgVpqKQEoYQ0vfMIoYIT2v57SKftJ5+WEZMXUr8V"
    b"C8SHD+lAT23TdOh/APmh/wfMr0L5dHw7M0iv0fS7JFTRlCA+hQrl/QPEn0D5cKgD5SvAyQrl+xCqBOVD/Es8vkY8f50xpNcYvXUc"
    b"ymiqvPwpL7+A5csQqgTl96JqUj7Qv7L+A70rlD+AdCgfQoGgfMWl6VC+h+s3DpUMMFTS5KGS9xgqCawALFTS4qGSDzxUkqq4EiyU"
    b"Kqe/HrLy7VgpFHykV+a6sj3AdVKMEtPNemERj6x+JwkF5GvwCY2smL4a6K3z9NUQSveA6Uf01XBSOkHqFUZfbXL6ajpUMX01hApu"
    b"Mf09pjwg6XvoP9Bz9zD908P8Fcyvwb4H6U+wfiCUrwF9h3SJ0SFDKGYiCu0+pIcsFDMJBV3Djx4LxUzSIfyLhdrlo7hZqB1PMDh9"
    b"c8h11DMPFYzM7EcDhApKRoo1Lwm1StHfNjBUzuV7TB/pkw2Dh0r5GCqn8FC1PYbK2RruQCHSJ1ucPtgpY/0Bpw8OsX6dh3qxqFqo"
    b"v4j130tYP6f/tRpYv9PD+hkpP4RGcSo/tiqg/ucIQ9VUrL+a+qzBUDWzw+mHPQyVG6cvUklC5Zp8B25jqJzJg/FtCUPl3vj4LzD/"
    b"fep8G0P9LJ7f4fk/sf3mM4bapSyALaNftiE/Hz8jCTWr4beW5bD6gSMdN00pwvxcqFoa5nd4qNkry9+j/0FztMJCHatw/STqDRtD"
    b"zZ45bVILQ8063JyteUmomslDzUygX85/D7LzdC//Uekc7+PVjSC/8S7KPw8F+R1NkN+cifJfQz+cfOfRNH+w/LzRCH8/jfCNptf7"
    b"/hCs/5UQqqP3KUD7iFqXYi/EtL3cx/9Pod1thyJf8uZP+JJVkS9ZB9rdb/ElayJfcjxALP3bfMmhyJcc/glfcpvvlWHqWxH2KiYK"
    b"3+ZL9kW+ZHa0BeM3vtqXbOjoS4b7K26+5Jsv+Rd8yYr7+77kpwB9yT/0a3zJIfUly3F+/y3csqt4/VO0tKd9MeBbfiKqrnXPfKMe"
    b"9Z3pP0kzG/0Cre6mRynOgFb3k9KYLg3dJ+/XI2NVtOEqXmK53v9sfy75mn9pfuk3Yuv+mcqvg75f5is/mh8d1hf1heqxvHXfPh2r"
    b"mvZVk01F4HsHX6kv8lUvcr5q5uuH8rwQfdG8/oxvlfoae+hr7MOBDegbheqbio7rkb+f8iWm1iP31WL6hK/H5rn12KPrcQDrUU/W"
    b"Y9rXCOMB+qoW968aYxkqMa118pzos6T/4d+2/29Gbv67OSxE2rdM9x+J9pf5zun38cOrkfjiv1zcr1Lv8/0otV+lfNVJep/vV+1z"
    b"+5UE+5VH9ytXtF9B+5nvPYj10TilL99Tzz+5vv/0VdXmJbfo79Ia+xfSL3EB32iFMzSK8bHeEa0w/Q5e91+m9f7eH0RfNL5hWltG"
    b"k1rvw1eqn6Pakn5HL4M9+KgzZxJZmpxGjKHewVmEiObm1EiPWP5ujCumsSFCX9lP+GIt7sAHn+mQ+lpWfGgH9PmVz7+AjjXxtflX"
    b"+7prekzjG+KMmODzDo0yCgU8M9+naFXptdD4NV+3n/PlRmnf7IBzrcb0s0BXbGoZH21kuRkfNfXJdni+6knaYQuuA/kFWuVezmee"
    b"bQ+/fzl5zl2pbOq55x4HFbvp+QbfsCHyFVvHvmIv42MO9D7/rqdXNhsZn7eb5PfYM4yrJcWSnozjkKuJ2NdveCmfsx7Eyx3a/Zx8"
    b"TyY+8dBMbnuLaa4tm79/Sk9evip7d3kfaJzAYpzFLN0fXVVsbGIsxQXszBFtsI0O07Tq9US4Hp/9KVtH/QRWonF2awtFAKGtrh/f"
    b"B+6KNDX4Xo4GYSFqH2Cj5rk5MD3RtlJm+cML86Nfnh+A2zBPBdV7lVHii7Z3jJYWaGERplV5SsbX3kP/KW3r/Rg3+Y9i7IbQLXWb"
    b"+KK7cB8z8+UCxgN83ZKW+KK7VoS+5FfwRVNfsgLp4EueQjr4krXEF20fwNfRYFchm7FofDyCLxquMt4mvuTOUDcTX/EU0sEX7tLh"
    b"oVdp3z94VlJ+jU4jlB8FQEsL5YMveAushUm6JduJL7prh+irHqGvWtZg+IG2FnzR9GrRDw3y0/4zXzP0v83zM6GA8bETX3HXCBPa"
    b"249G4kA0JebsC/Eq5A+GBfDi8pmvGcpvQn4oP8LyVV5+i5dfwPJVXr4HJu0H618vwSpsEl90twa+Zij/CT4BoH4n8UV3G5AO5b/B"
    b"UVPI/Nnx+rWewmR9tl1cHwUnwXrEvlq4qnmG8l9ktLY0/xu/qnmvJ0uT0fLCVc1PIV4VPEDa10tXLWsgf3Ad5Qr0hK0LaHWBdpXR"
    b"6oIvN0+ra3FaXUjP0+oCLe+K+5rn3Nfsoi/5lae/83R+FfSWX9UsYzqj1TU5rW6T+dvQ19xDX/Mz9zW3uK+Z+6qX3FftIy1vAUQJ"
    b"aIHXEab/9lXDnBaWXytmhphf4ufTGvpqa1y3PyKta4pWtNpDX63PaU1X6KtN0YoGSOtqfOIO5PCrhm38bDA7WH+D18+sVfAVb9DX"
    b"2uRXDa9C9LVWsH6b+4r36Cs3l/yqW37V8ID7qldYf5NfVVtBX7nBL27Q+VW77+jr1Xv8ql/uK3f4VcN8B7YW6KvecFrUFvqaXU6L"
    b"OuL5PX7+nr6qF8eP52/x9m/wquDUVb/3DvqKNT01fomv2eK0qns98TWbKa5iN+WrxqtuZ5jf5r7mosjX3OkZAl+zgb7me25uW+hr"
    b"1lO0pgv0VUf8W3cp8vW2RL5iOxL5msei/ONIkL8u9DW3RfnXovqvoUVV4/hR+i7FGoc3etPvpze90Yfiu7WH55Gc8mWz513ueZ97"
    b"PuSeM/7dFGlV2heMMc40Vt+nV62mfcKwJjyB73j3JfAzJ7wyR+/TtSS48nWZvRpWEHt/gg60rM2mpbIqB4WZXJjIhel8Wpioc2U8"
    b"V6fKvDIrjiflQkkmT0GxqMlKRZ3PC1ox0CaVeVCUZ0gMJAVBMRgrWrlSlMvlyjgISkppVp5PK/NSMJmrcmlaUotaoJSKZVVVJpSQ"
    b"UysFUqCVxrN5pZIOtJbkeaVYqJByZC1QZ/JY1SbTYKYpc3laqpSUmTaVKuqkMCONUwtyUJ6owWxGnopqaaYE8wwdaKE8V8vl4rRA"
    b"/qeUJ+XimHS3qE3VICgrclEuVgpEgDTyikbKLYxn5bE0nmlkHIpypVDJ0IFOxsFiNg1nnANUPskBSsSjEvXqjS9/1fvfpEk6QdOR"
    b"ovVBDkkbaYZiHsld0+zJpE1E9PQy430EGpYfEPL/wrkgWwf+ezvmiEzoXdoZeqWdxOllQqCR4FQtMbXRM6eLOUFddIp2R44pktK0"
    b"Efvz/JL24SS/ZMxl5qZ5PM/wS8YURrsM5Q7jazum3GE0FQLKHeRm4zQ6XZ9zfXa914T3NOEczVDuUMoq+q6ZjGEP+N6OqZIWv0S5"
    b"E/ODviJXaI4DNKZuOiAtEKPbUfncpLj2MpRBSI90nm8yobp5cWO+zN6+dZrCSUmvrbSMui9hbq04hfN8jYyPM0PB8xKyNUtpbWqv"
    b"ZMD0MF4zOU41RtXjMj5QLcXxuT/JS+mlaX0cysHWjPUKHJU3E7oWriMSyp/ogryfoixicyCiuyHyOd1ndASltTrSCSmdc6VcEXk4"
    b"waHJaNBieg+g2yFtAy5E8v55SrY0tc0u1mVpOpNTfLh7VmaG4iWnw3mZWbqTxVXUN8cUL7aI4iXPbbgTcRu2+3naG+cs7U08d9D2"
    b"HL3LLkPvQuZsohoeaffz6DHDjZmj+7mS27DrHtP9CLka85RXtojbcHfEbdgNztP9MJ3M1mHXy9H9XDfXWb7if38uyxS1TYbT8Waw"
    b"3AyW7zVYnv/9DBZqcFxjtFDuqhzR+17IY/aS5TGL+fb2LZ1xIMZGilBeieGQXitaZt11szIbcyie3tgPdp48e884It0oSyBub3KG"
    b"y77NyLp3Cak4r9M9ybeZJuR2oxu34D+XW/DcZn7M3XclR93xhtYVbWjL/Ea+Exs5WcLq8/x0Nps71vYcMbOdIWYmc/YVVA3S7sYy"
    b"IWdu7Y+JuvO68SRR9/7IaJNPGCaRgIcwv9lLR0Td+7P9jnkKfUaqneNovHKusxy0VxqrxDg6IqV2TbFhkiOl3p3gLcyRUp81WPfx"
    b"pRYxp+LiFCn1n+Xms0XcfMYf4ebri+IpauDLlL4jnmIgiqeoh8jNp39bPIXloz+pznEmP6D13xxPUeX+tAGfnwi5+Wpwheu3xFOk"
    b"rsnzcfxciLexWEBsWQBFEcZTbJILW/Ua5eaz9rd4ils8hRhvX4nn//H1ziPjMe/A/Ct0/n/QeIrFnIy/qP89ih/5wfD40P/6Xrfk"
    b"h3KoV4Zz/Wn4Xgw9vd8WcuWpIq486N8aQCQFfffM5KMeUNAKPFPRPpaXkMoLpC8pV5ep0/4foP867X+P9l+h/a/saP/DCXku1Fm8"
    b"gv02r2C8ghz6+mK2IPkXr3fTO2c8/7r7gPq6I8AIEr22+HKpPEkgTx6VJ5/Kk1qF8aX1LeZMvsh4StfKF5llIs8snsHJcZXpAi68"
    b"dyEXnnPjwjvmglvcuADJ+zcuvN/jwrsKj29dSK9ewMObF6D1l7jhzAv1XyL0s0T1G+GvFCU2dS9x13m/EI+Rii81r2+KdSG9lKJF"
    b"YjEJCvDifSY4iumgJU2HjaeJWXn2B6330eBhHfPlnYtFSJ1/9m/xCL8Tj6ADzq9Ocen7OB5BiuMRlDgeQYvjEYpxPAKLS1jEcQnE"
    b"NknHJdQyHHM+RzC77NlY6Gr6ffptB9xkobh999Evct85P8l9l45TwMUQxx1YPh9Pzm1nHnHb6b0st52+SXPb3ee47VaieAU3PIpX"
    b"kHPxCsV0vEIn0SHQ7uCI286Jstx2jfDfi9sukc9L8VFHm4aXEDhlv0JjUPORanbzg0HXi+WK4hW0S/tFaALnmXk5qCuvlFvsfEGw"
    b"nzSE49vLzUGH/VEQb9DyDMHO0/v/Md7gDeMNVA/jDWbQf+CmM5CbTnI4Nx2sE8gP5xOA91eiGCtPufOQ++4Lue8OOnLfTSH/J81f"
    b"hm2ZlqFKkJ/2r59w05GvuiRewN6FGI8wTLjp9Moclh+MjwfpNP8I4g1gfLaQTstXJODGg3iHhJtOr9STeAE7AmUSxzvYSfmdJF7A"
    b"3sGgQPn9KAGRfwSQ7kC8gxGHusTcdQMWr5GUf1hg+fMIy9eTeAE76lETHcp/hLW3iWMOYrNVYzSJEXDDJfLXfkR7heHp6dK21mEi"
    b"322QfAO45TaJPRTj5enSaYNehv1OY9x0LB7AiPHpKbx/wU9UhfWOpk+7qSenPgWYXyNr07VtXL9akGSynnm8QRuh7AUb05e8fB9X"
    b"VIFzz615PMALjwcIMP2Np3/xeAAeT/DBuevY+gHuOgnTQx4PUOXxAguMF3jh6Q88XqCH8QIrHi8QYLxAUcd4gc33xQs0ML/p8niB"
    b"LeZ/5OevJcTLtzjevYt4fcPn8QKc207xEO/+inj9Oj97nCJe31pxbjXObffMz2cfsf6OhPVvEK9v8niFJue2Mzi3nI713/N4hYOe"
    b"1K8/8ngBzm3H4yUYYyPUb3C8/Q/ktrM2/Kzbx3iBOo8XGKa44Xi8AHLbkc0X4wUixPvXeLyAh3h/KxUvgPkzd78Yx/EOJs9v8/a/"
    b"cm48fj5930O8f09PjV+C92/y+vfITZfag1s+5p9xbrsnzN/ge19JT+IFzA3u7Z0Q4wUkbtvYnJsubPA/Ijcd/xZlHMSQv8a3/Y0I"
    b"r9/2RPECZVG8wFSU/0nEbdcQceOZwvo/RfECrogbzxr/Krdd2vd347e78dv9rfntVOML4g6U1mY0ID9rlS3gfuoPy8n64ZWUMadg"
    b"VrpufpkTj94PsOpHE0XIrfevzZVXFfp2vT/h2/VFvt369/l2fZFv1+H3rtnf59sNRb5d/U9w5VX53uvz+dHQt1v/Pt/up8i32+K+"
    b"3dX1vl0Nfbv1m2/35ts959v9Ec//4PWuJ/Ltrt918n4jor4W6nvpWfob5c6rMV9tW6ftAd8kjP8T9+02ie34W77dCH27xQu+XUiX"
    b"qe+ps7Bqb5tQl2h7aX+9ezr/Fh2PJyoPwZD6dmp0PB6oPGxemDyQ/msoDwMjNB+KHnn/cU2WQfj64+4H6Mhlaw7nsbpDuft+ufyb"
    b"r/fm6735ev++954NL6T/7r1njYuIwgu0a6I/3u49u3TvWePJVz6Wo9qU8dNlcLSF7DnBKoWTHVAsekFwPnBqJIwllLGMv8UkigPP"
    b"+TZcj31dXOtbJGttwt03/Zi7K3UPFuXuMhc4PyLuLuob0n+JS83k3naHui8Hej1CXxc8AzeZaCzo7azsTNeOTC32Leuxb9mJfcte"
    b"7Fv2Y98y+JxrHvM510LmczY4Rxb4NMdcRLu0ft559lwLyXdeO31vGE0CLjBNbJ8z39kvjM/jT3LNbdL9mGT6QeQg04/YN6sf+2ar"
    b"Od9sM+2bNaMsl1wjFHHJOUdccuiri7nk2mHKx4vf0dDu4TGXnJvlkiPy+W/FJafDd50RXdRHmkjJPua1gBc7qHJf4QKHMXzDyiIl"
    b"2w6v8G07+gVOT1e0KUErjggXNZFXucGUVe4eoIhpsOP2WXnfcKzsnAu+61jZn/Ptg4pjpwtwb9XAi32/hjuOP80p9XziW++wgxG4"
    b"twpsSXZvVZhs4vezMDkPqpQS3699iNB33PWMxPfYTny/dlRGrrgxrDPgipPA97th9355MRec56Hv1kTfbeSi73YAbgLggoN5TO4V"
    b"S7jmghC55g7INafC2fk9832asavhA6aZqnhTRi64zoDfSzbBe8kUG+8l8/m9ZGu8l0zZAJcdHZ8Jv/cswvIl5ILrPPJ7ye7xXjIZ"
    b"ueA6PX4v2RDvJZM3eC/ZkN9LBg4RKF/dYPmzCMsvY/kScsF1PH4vmYP3kknbf8d7yR7/Je8l4+kH7vv1Eze09cm54s7cSwb5G/xe"
    b"MQnTF9y320ffcIH7htm9ZDbThHasVIsupoN4Md9s3r5n947xhBpywaXOPxmtK+Rfcf30jvmrHp4dMq5j8M3y800GiATfIj9fZZsd"
    b"+BbbNprlY+SSMzQ8K65zLrlSiOZcDX2zDX52uUAuOb2Ke1STc8m98fPdL6xfL9czqJ/k3i6MTeFccjXkkrOmWH+L+4aL6JvWX7D+"
    b"DueSK/Pz6xr6Vs2gzrGzyMXm4PiZnEuuze/0LKNv2OSfNT1d4NutBZj/kd9b9gPz13j+Bc/f5ePXE3DRmTL6ZlPnyxHnguO+aXeL"
    b"vl2T+3YHmN/hXHKah/lD3PvaEfp2+fmypeG9ZW1u2xjo29Ud7tvV0be74FxyAfqGTX7XT1Pkm7UWIt9uR+RbHYp8w44n8u32Rfnf"
    b"RPXfC327TVF+5Ve55JTUt5x345O78cn9rfnkognzyb6Ma/0F9f9OapRD7kEaDQrSeFD5HCrVxaju/A4H3cEfjJZBrSLksvtubrrJ"
    b"NNAq2mRensnF+bgyLpfUklYsyoo8lWRJm6hySZ3NZGVaKM1VRVIrxUJ5LAWzSRBoJXlSRoITRSnOyV+nEyWYTwpKeVyQAk0uBJVK"
    b"YU4KUyeSXBxrFVUZa6VyRdaUiqwo05kyDYrzYrGgpAONCyTfZFyZTVVNLRaVSqk4KZaViSpVZup0Ildmc6k8ns5KqjpTK0FZK5Im"
    b"BgWpMJnKhXmpnOGmK02LklqazcpBoCgB6aCmTLSZPC3M1dJ0Lo9LQWUuTyaqIpNqyK8zlTRcliaSNpfGxbGU4aabzeez4GP+ufzP"
    b"l83zmjPUSScZ6paj1Wjpqw88aPxa0ha79TWlAfIsoDucRZQYQv8Z0hhrovY/p1nil1MkKTFxQ5okxTtLEtHKELhMU2Ql7vYCe1Qi"
    b"9LQvCfkCZ6vap8knCq8TFoivpQhZPkePxvNEqdC8QKLBmKwae/peQoRC6o7JTuyYFMXOkKK0GAHJvmnGBDP7kJLENOO/FTPEClx5"
    b"hIGyLI66kubUDSlYu5WBLMEcZgk+aP32LiFjoQQKOSKTnZDIZJknOOidJxxh45smHNkx+bFlATnGnpNj2AonZukdkcOcIIbJEy0c"
    b"hKxxXRhDmY8hIyu4yMD2Yt8Y2L6Zge2S3HpECZOxoWsimdsDm9spEE50Hkm5rLxCmgBkNCBabdCSLrO2Mfa1y0xeiyMGMzFDl5En"
    b"PtmLiDDcIwYz9zxzGyNpYiRXlLgmw2DmnSWDSdZoXPaxvn/mBE65sVGuZDmTj0lhAtF6VPKsdm0hmcgox3JmF86ynDFSph0jKLKV"
    b"LDGMI2LXU4Vsa5eJYPbuEXufI5rfvdvP6cmTrJYZIpiYPOoUEYzD5v/FjVndUuuJ6iidEiwloLnbBn/b4G8b/G2Dv23wtw3+tsH/"
    b"/7bB/1nGM1N0g7z+R26Qr4tQ8Xb4bah4h0e08RNnm6Pii+CNk74XFe+4fxYVX+Nei0ecH9NBVHz1+1DxW4670TgqXkdU/AxQ8Ztr"
    b"UPEOouJtQMWHN1T8DRUvRsXfWXqLzn/z9c7Pzj9DwXsUBc9vWGeodlmEaof31/QG5/jGZYpip17Z+yE8U09flaNw0+PHxpfe0L7R"
    b"4YZ1g8gDoLy7VN6ICC8oKlY0n6Q/b+u7KDIfkhuUw8b9QQfGM9rfHkWtKxZDvRJ5vqPzCyhXykgmkfxGc12h41GWSfvn/Yk+Xqs+"
    b"GY8fw7LFblh32A3p4Z+9YR1Q1JtF9ob1Z37DOlsfPbxBO7X+FH6DNh3vR3aDdkRv0D67XgcX1uswXq/a6fW6oO0h9VuFVhTQ+bon"
    b"7Sfvr47XKx2/p0V8g/bzWyqqgT/bdhrlnYwf9J9etpUe//SN4TkUO0dhMxT7gaPY+ftiFDu/gVyAYu9eiWLvilDs0P6rUOyPIO/8"
    b"xvEbah0YBR8+YL0/NNd33j/rBnXjQvpv36B+Kf12g3qWbOcMlP+XUPG9C6j46CdQ8f3VaNV/mdZG8sSU32iU7mV0fJwnjqIHRMWK"
    b"vF+TlwGN9lV6i6nlqCdHutbfk2/PfS/+jqJnU/F3vsA+/BsxojFIMjB9aXFUQDGOCijHUQE/4miARg413ubyBs92hDeaW+xZ1E8Y"
    b"X2BiMmg+Nx5fNx7fVjy+rXh82zHqnY33KB7vRx76Aej3cg7t7p9Avyc3q9u5Z4e3GxjP+nrH4xgwQK/3KDOTT9T1Eaq9RkfAy+Qn"
    b"k+hl0fA2R8dXKcr+nqPjq3H0AJnXDS/HY+j4jpfONyTvp25aN6IjBrSmnmVAa0bnGNDMC8oiiRo5i2oXMoJdRFWXT8i/dzFKaSJC"
    b"vddFqHczEKHeM/1redfdoG6J9qOjEAPYBKYi1HtTdIO6HoluUA9EjGadHKMZE/nNP4PRDFDNZxjNaP6Y0YzapucYzYAR6wyjGaRv"
    b"ANW+ZYxfHtsk76ch3qCu8hvUQz1BXQ+8GJGuf0yQ8UyOkPGsDulQ/gJQ7RotH6JF6PFQZwTrZEo38g2kU0o7BaJzAPkewLqiIvrR"
    b"wBvQpQ3egG5yxrKHhNHMkp0E9d6tQjqg9seAaocb3st4w7oPN7h/sfHDG9a3WH5Hx/JNfsO6izegM3pGKJ+h4mn5UhkZzcY6Mpq9"
    b"IqPZnqPimdDB/O6QMe0ANEIwvzOAkr7p/wKMZsAkCXDYizegO3gD+ov+L3MD+huqCnYDuk3Tt/yG8+tuQAdUO2cse+ao9hZHtduI"
    b"Wl9yVLuPqPbC9vtQ7QHm73Cz8gPzG/zsr+OJUO0aorr5+agxFqLakXFMT6HaAxGq3UFUeZXXz8jpAFV+n0JlY/1jjmrfYf1Gj6Oy"
    b"kXHMTKHaNazf4Yxdc46qT6HaEdWvv3NUO0f1b7mt7XBUO0fV15AxzHIMHlWAqHSPo9o5Kr3N+88CZACV7nBU+wLzc8YxNr95VPyC"
    b"55/w8QsMHpWA469i+6satv+gI+MZn/9WhKj2MR+/NaLaXb53l0NkPPPxW6sjYf6Ab4oOQ6VD6BRnLIuQsSxC28UoI6pd4RFv74hq"
    b"T0VgtzC/4fMgTBfz829VMardF6HS674I1W6L8i9FqPhmKMqvifLv9V9FtWe/wW5MZjcmszNMZnE9fnQaCU/Tbjer/9Gb1f80W9nN"
    b"L3vzy978sje/7M0ve/PL3vyyN7/szS9788ve/LI3v+zNL3vzy978sje/7M0ve/PL3vyyN7/szS9788ve/LI3v+zNL3vzy978sje/"
    b"7N/dLytgFRsHxakqqaVCaTKbVMbjQlmWNUlSA2U+m6jqtFKQJLlULJWLwVgqVAKpMp7LRWkyLgWlqTaTkWTjGwrirGJaWQlUuVwc"
    b"B6VKqahMihN5OlGUUjAh2aeVYmlaUQqTWaBp2kwhv5XmRfLmuDIjpc0VJe2A/u2y/vGP//v/AIjNmiQ="
)


def thread_fixture_cases():
    import zlib
    packed = base64.b64decode(THREAD_AUTHENTIC_CASES, validate=True)
    decoder = zlib.decompressobj()
    raw = decoder.decompress(packed, 8 * 1024 * 1024 + 1)
    assert len(raw) <= 8 * 1024 * 1024 and decoder.eof and not decoder.unused_data
    cases = json.loads(raw)
    for case in cases:
        case.update({k: base64.b64decode(v, validate=True) for k, v in case.pop('fields').items()})
        assert all(hashlib.sha256(case[k]).hexdigest() == v for k, v in case['sha256'].items())
    return cases

def thread_fixture_envelope(case, queries):
    global remaining
    remaining = 1000000
    originals, objects = [case['old'], case['new']], [case['oldobj'], case['newobj']]
    frames = [literal_frames(raw, obj) for raw, obj in zip(originals, objects)]
    kind = 'nonnull-map-guard-thread' if queries else 'canonical'
    proof = dict(version=1, work_left=1000000, kind=kind, queries=queries)
    return dict(version=2, comparison='iropt', work_left=1000000, proof=proof,
                original=[base64.b64encode(raw).decode() for raw in originals],
                objects=[base64.b64encode(obj).decode() for obj in objects],
                framed_sha256=[hashlib.sha256(raw).hexdigest() for raw in frames])

def thread_fixture_parent(case):
    import tempfile
    with tempfile.TemporaryDirectory(prefix='t5909-proof-') as folder:
        paths = [os.path.join(folder, name) for name in ['old', 'new', 'oldobj', 'newobj']]
        for path, name in zip(paths, ['old', 'new', 'oldobj', 'newobj']):
            with open(path, 'wb') as stream:
                stream.write(case[name])
        command = 'source "$1"; IFS= read -r -d "" a && IFS= read -r -d "" b && explainMismatch "$a" "$b" "$2" "" "$5" "$6" "$3" "$4"'
        argv = ['/bin/bash', '-c', command, 'proof', os.path.join(sys.argv[1], 'selfhost-ir-signatures.sh'), 'iropt', *paths]
        raw = case['old'].rstrip(b'\n') + b'\0' + case['new'].rstrip(b'\n') + b'\0'
        env = {k: v for k, v in os.environ.items() if k not in ('BASH_ENV', 'ENV')}
        return subprocess.run(argv, input=raw, capture_output=True, timeout=10, env=env)

def thread_fixture_change(case, label, old, new, both=False):
    altered = dict(case, name=label)
    targets = ['old', 'new'] if both else ['new']
    for key in targets:
        assert old in altered[key], (label, key)
        altered[key] = altered[key].replace(old, new, 1)
    return altered

def thread_fixture_negatives(case):
    changes = [
        ('predicate', b'icmp_sge bool', b'icmp_sgt bool', True),
        ('zero', b'const_int i64 0', b'const_int i64 1', True),
        ('nil orientation', b'icmp_ne bool', b'icmp_eq bool', True),
        ('slot argument', b'map_val_at(%0, %2)', b'map_val_at(%0, %1)', True),
        ('map argument', b'map_val_at(%0, %2)', b'map_val_at(%1, %2)', True),
        ('runtime symbol', b'map_val_at', b'map_val_other', True),
        ('guard effect', b'%13 = const_bool false', b'%13 = rt_call safepoint() bool', True),
        ('guard operand', b'icmp_eq bool %4, %13', b'icmp_eq bool %7, %13', True),
        ('unrelated literal', b'const_int i64 -1', b'const_int i64 -2', False),
        ('unrelated opcode', b'field_get %14[0] i64', b'atomic_load %14 i64', False),
        ('metadata offset', b'ptrs=[]', b'ptrs=[%0]', False),
        ('allocation body', b'gc_alloc size=8', b'gc_alloc size=16', False),
        ('field offset', b'field_get %14[0]', b'field_get %14[8]', False),
        ('phi type', b'bb4(%14: Obj)', b'bb4(%14: i64)', False),
        ('edge argument', b'bb4(%5)', b'bb4(%0)', False),
        ('edge arity', b'bb4(%5)', b'bb4(%5, %5)', False),
        ('swapped edges', b'br %7, bb4(%5), bb1()', b'br %7, bb1(), bb4(%5)', False),
        ('duplicate definition', b'%2 = rt_call', b'%0 = rt_call', False),
        ('missing definition', b'field_get %14[0]', b'field_get %999[0]', False),
        ('unrelated function', b'func take(', b'func other(', False),
    ]
    return [thread_fixture_change(case, *change) for change in changes]

def thread_fixture_graph_negatives(case):
    shared = dict(case, name='shared successor')
    shared['old'] = case['old'].replace(b'ret %16', b'jump bb4()', 1)
    shared['new'] = case['new'].replace(b'ret %17', b'jump bb4(%12)', 1)
    free = dict(case, name='unguarded free use')
    free['old'] = case['old'].replace(b'%16 = const_int i64 -1', b'%16 = field_get %12[0] i64', 1)
    free['new'] = case['new'].replace(b'%17 = const_int i64 -1', b'%17 = field_get %12[0] i64', 1)
    return [shared, free, thread_fixture_unreachable(case), thread_fixture_backward(case)]

def thread_fixture_unreachable(case):
    altered = dict(case, name='unreachable free use')
    for key in ['old', 'new']:
        funcs = thread_modules(case[key])
        f = thread_function(funcs[0])
        slot = sum(len(b['params']) + len(b['ins']) for b in f['blocks'])
        p = f['blocks'][3]['params'][0][0]
        extra = ('bb%d():\n  %%%d = field_get %%%d[0] i64\n  ret %%%d\n' % (len(f['blocks']), slot, p, slot)).encode()
        funcs[0] = funcs[0][:-2] + extra + b'}\n'
        altered[key] = b'\n'.join(funcs)
    return altered

def thread_fixture_backward(case):
    altered = dict(case, name='backward physical successor')
    for key in ['old', 'new']:
        funcs = thread_modules(case[key])
        f = thread_function(funcs[0])
        j, s = f['blocks'][3:5]
        jl, sl = len(j['params']) + len(j['ins']), len(s['params']) + len(s['ins'])
        assert j['start'] + jl == s['start']
        remap = {v: v + sl for v in range(j['start'], j['start'] + jl)}
        remap.update({v: v - jl for v in range(s['start'], s['start'] + sl)})
        funcs[0] = thread_refs(funcs[0], lambda v: remap.get(v, v))
        altered[key] = b'\n'.join(funcs)
    return altered

def thread_fixture_reply(packet):
    answer = protocol(wire(packet))
    assert answer.returncode == 0 and answer.stderr == b'', (answer.returncode, answer.stderr)
    reply = json.loads(answer.stdout)
    assert set(reply) == {'version', 'query_ids', 'work_left'} and reply['version'] == 2
    assert reply['query_ids'] == [q['id'] for q in packet['proof']['queries']]
    assert type(reply['work_left']) is int and 0 <= reply['work_left'] < packet['work_left']

def thread_fixture_packets(packet):
    changes = [('comparison', 'ir'), ('work_left', 1)]
    for key, value in changes:
        altered = copy.deepcopy(packet)
        altered[key] = value
        protocol_refuses(wire(altered))
    for queries in [[], packet['proof']['queries'][:1], packet['proof']['queries'] * 2]:
        altered = copy.deepcopy(packet)
        altered['proof']['queries'] = queries
        protocol_refuses(wire(altered))
    altered = copy.deepcopy(packet)
    altered['proof']['queries'][0]['head'] = True
    protocol_refuses(wire(altered))
    altered = copy.deepcopy(packet)
    altered['work_left'] = altered['proof']['work_left'] = 1
    protocol_refuses(wire(altered))

def thread_fixture_interactions(cases):
    serial, loop = cases[1:3]
    changes = [
        thread_fixture_change(serial, 'serial first key', b'bb5(%0, %2, %6)', b'bb5(%0, %1, %6)'),
        thread_fixture_change(serial, 'serial first value', b'field_get %21[0]', b'field_get %34[0]'),
        thread_fixture_change(loop, 'loop latch roles', b'jump bb1(%26, %27, %28, %31)', b'jump bb1(%26, %28, %27, %31)'),
    ]
    for altered in changes:
        original = serial if altered['name'].startswith('serial') else loop
        protocol_refuses(wire(thread_fixture_envelope(altered, original['queries'])))
    thread_fixture_packets(thread_fixture_envelope(serial, serial['queries']))

def thread_fixture_literals(case, queries):
    payload = b'x"\nfunc forged() void {\nbb0():\n  unreachable\n}\n'
    literal = b'\nfunc opaque() string {\nbb0():\n  %0 = const_string "' + payload + b'"\n  ret %0\n}\n'
    altered = dict(case, old=case['old'] + literal, new=case['new'] + literal,
                   oldobj=literal_test_macho([payload]), newobj=literal_test_macho([payload]))
    thread_fixture_reply(thread_fixture_envelope(altered, queries))
    altered['new'] = altered['new'].replace(payload, payload + b'y')
    altered['newobj'] = literal_test_macho([payload + b'y'])
    protocol_refuses(wire(thread_fixture_envelope(altered, queries)))

def thread_fixture_driver():
    with open(os.path.join(sys.argv[1], 'selfhost-diffdump.sh'), encoding='utf8') as stream:
        source = stream.read()
    driver = source.split('run_ir() {\n', 1)[1].split('\ncase "$KIND" in', 1)[0]
    helper = 'ir_signature_bucket() {\n' + source.split('ir_signature_bucket() {\n', 1)[1].split('\n}\n', 1)[0] + '\n}\n'
    mocks = b'''source "$1"
MOCK_SIG=$2 MOCK_RC=$3 NAME=$4 MOCK_FILES=$5
LABEL=IR PREFIX=mock VERB=post SKIPLABEL=mock CORPUS=mock ORACLE=oracle BIT2=current FLAG=mock
find() { case "$MOCK_FILES" in two) printf 'same.bit\\nchanged.bit\\n' ;; *) printf '%s.bit\\n' "$MOCK_FILES" ;; esac; }
alarmrun_retry_cap() { case "$6" in same.bit) printf same ;; *) printf '%s' "$1" ;; esac > "$3"; }
classify_rc() { echo ok; }
diffiropt_capture_text() { return 3; }
oracle_ir_coverage() { echo ok; }
ir_mismatch_signature() { printf '%s\\n' "$MOCK_SIG"; return "$MOCK_RC"; }
declaredSignatureNames() { [ "$NAME" != iropt ] || echo 5909-nonnull-map-guard-thread; }
'''
    program = mocks + helper.encode() + b'run_ir() {\n' + driver.encode() + b'\nrun_ir\n'
    cases = [(0, 'iropt', 'two', '5909-nonnull-map-guard-thread', 0),
             (1, 'iropt', 'two', '5909-nonnull-map-guard-thread', 1),
             (0, 'ir', 'two', '5909-nonnull-map-guard-thread', 1),
             (0, 'iropt', 'two', 'unknown', 1),
             (0, 'iropt', 'changed', '5909-nonnull-map-guard-thread', 1),
             (0, 'iropt', 'same', '5909-nonnull-map-guard-thread', 1)]
    for rc, kind, files, sig, want in cases:
        argv = ['/bin/bash', '-s', '--', os.path.join(sys.argv[1], 'diffexit.sh'), sig, str(rc), kind, files]
        answer = subprocess.run(argv, input=program, capture_output=True, timeout=10)
        assert answer.returncode == want, (kind, files, sig, answer.stdout, answer.stderr)
        thread_fixture_driver_output(answer, files, want)

def thread_fixture_driver_output(answer, files, want):
    if not want:
        assert b'MATCH=1 MISMATCH=0 EXPLAINED=1 ' in answer.stdout
    if files == 'changed':
        assert b'INVALID: compared 0 files' in answer.stderr
    if files == 'same':
        assert b'RETIRED:' in answer.stdout
    if files == 'two' and want:
        assert b'MATCH=1 MISMATCH=1 EXPLAINED=0 ' in answer.stdout

def thread_fixture_selfcheck():
    global remaining
    cases = thread_fixture_cases()
    for case in cases:
        remaining = 1000000
        queries = thread_proof(case['old'], case['new']) if case['count'] else []
        assert len(queries) == case['count']
        case['queries'] = queries
        thread_fixture_reply(thread_fixture_envelope(case, queries))
        if queries:
            answer = thread_fixture_parent(case)
            assert (answer.returncode, answer.stdout, answer.stderr) == (0, b'5909-nonnull-map-guard-thread\n', b'')
    case = cases[0]
    negatives = thread_fixture_negatives(case) + thread_fixture_graph_negatives(case)
    for altered in negatives:
        protocol_refuses(wire(thread_fixture_envelope(altered, case['queries'])))
    for altered in negatives[:3] + negatives[-2:]:
        answer = thread_fixture_parent(altered)
        assert (answer.returncode, answer.stdout, answer.stderr) == (1, b'', b''), altered['name']
    thread_fixture_packets(thread_fixture_envelope(case, case['queries']))
    thread_fixture_interactions(cases)
    thread_fixture_literals(case, case['queries'])
    thread_fixture_driver()
    print('nonnull map guard proof: 4 authentic pairs, 5 heads, strict mutations and protocol passed')

DIFFIROPT_LITERAL_FIXTURES
  [ "$read_rc" -eq 1 ]
}

# Proof mode replaces this shell so a bounded caller also owns the Python PID.
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "$#" -ne 0 ]; then
  [ "$#" -eq 1 ] && [ "$1" = --prove-owned-appends ] || exit 1
  case "${BASH_SOURCE[0]}" in
    scripts/selfhost-ir-canon.sh) ROOT=. ;;
    */scripts/selfhost-ir-canon.sh) ROOT=${BASH_SOURCE[0]%/scripts/selfhost-ir-canon.sh} ;;
    *) exit 1 ;;
  esac
  . "${ROOT}/scripts/selfhost-diffdump-setup.sh" || exit 1
  . "${ROOT}/scripts/selfhost-diffiropt.sh" || exit 1
  diffdump_owned_append_library && diffiropt_literal_library || exit 1
  DIFFDUMP_OWNED_APPEND_ENGINE=
  diffdump_engine_rc=0
  IFS= builtin read -r -d '' DIFFDUMP_OWNED_APPEND_ENGINE <<'DIFFDUMP_OWNED_APPEND_ENGINE' || diffdump_engine_rc=$?
import base64
import binascii
import hashlib
import json
import sys

remaining = 0

def require(ok):
    if not ok:
        raise ValueError("unsupported proof")

def spend(n=1):
    global remaining
    require(type(n) is int and n >= 0)
    remaining -= n
    require(remaining >= 0)

def framing_bytes(value):
    return [base64.b64decode(s, validate=True) for s in sequence(value, 2, 2)]

def framed_proof(envelope):
    keys(envelope, "version comparison work_left proof original objects framed_sha256")
    require(type(envelope["version"]) is int and envelope["version"] == 2)
    original = framing_bytes(envelope["original"])
    objects = framing_bytes(envelope["objects"])
    require(sum(map(len, original + objects)) <= 8 * 1024 * 1024)
    memo = {}
    framed = [literal_frames(raw, obj, memo) for raw, obj in zip(original, objects)]
    require(envelope["framed_sha256"] == [hashlib.sha256(r).hexdigest() for r in framed])
    proof = envelope["proof"]
    require(type(proof) is dict and type(proof.get("version")) is int and proof["version"] == 1)
    require(type(proof["work_left"]) is int and proof["work_left"] == envelope["work_left"])
    return proof, framed

def main():
    global remaining
    data = sys.stdin.buffer.read(8 * 1024 * 1024 + 1)
    require(0 < len(data) <= 8 * 1024 * 1024)
    envelope = json.loads(data, object_pairs_hook=unique_object)
    require(type(envelope) is dict)
    remaining = integer(envelope["work_left"], 1, 1000000)
    require(envelope["comparison"] in {"ir", "iropt"})
    obj, framed = framed_proof(envelope)
    keys(obj, "version work_left kind queries")
    normalized = [literal_canonical(raw) for raw in framed]
    if obj["kind"] == "canonical":
        require(obj["queries"] == [] and normalized[0] == normalized[1])
    else:
        require(obj["kind"] == "nonnull-map-guard-thread" and envelope["comparison"] == "iropt")
        thread_proof(*normalized, obj["queries"])
    response = json.dumps({"version": 2, "query_ids": [q["id"] for q in obj["queries"]],
                           "work_left": remaining}, separators=(",", ":")).encode("ascii") + b"\n"
    require(len(response) <= 65536)
    sys.stdout.buffer.write(response)

try:
    main()
except (ValueError, TypeError, KeyError, IndexError, OverflowError, RecursionError, binascii.Error, struct.error):
    sys.exit(1)
DIFFDUMP_OWNED_APPEND_ENGINE
  [ "$diffdump_engine_rc" -eq 1 ] || exit 1
  LC_ALL=C
  export LC_ALL
  DIFFDUMP_OWNED_APPEND_CODE="${DIFFIROPT_LITERAL_PYTHON}"$'\n'"${DIFFDUMP_OWNED_APPEND_PYTHON}"$'\n'"${DIFFDUMP_OWNED_APPEND_ENGINE}"
  [ "${#DIFFDUMP_OWNED_APPEND_CODE}" -le 65536 ] || exit 1
  exec python3 -I /dev/fd/3 3<<<"${DIFFDUMP_OWNED_APPEND_CODE}"
fi
# Keep the ordinary selfcheck in its existing test file, without a child PID.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  exec /bin/bash "$(dirname -- "${BASH_SOURCE[0]}")/selfhost-ir-signatures-selfcheck.sh" --canon-only
fi
