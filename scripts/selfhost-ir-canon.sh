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
# Retained public046/candidate and public/current whole captures with their own O0 objects (#5909).
# This is compressed fixture DATA, never a compiler or IR generator.
THREAD_AUTHENTIC_CASES = (
    b"eNrsvdt26rqyLvwu47av/cc2h8BqbV3IB4ghhphwMv/FamDAIUBIQhIDu+1336qSLNlGQPphzDXnnvTRRsDIOleVSqqqT/////7rZbye/fWff812i+3H4iX66z/+CjefLx9//afxH3/NF7PVdPvXf/7vvzarKX1p9NL/DPbmZjzsPEzWu1LT6sXthfkRDEll"
    b"3A20e8t8CNabH/cWWXndTQS/NR/N19azH83i10XwTDaNLim7df0ptHfw+9Z1qovxc3HrWr0dLQt+e21Hm4g+711bi8KXzjwwatuJBfWY89DYfU2taOVZcdToOq9ufWm0CL5/gPcDo/oZFjrz8aCkYZpFYmtB6Lt+9EDbEhh6PCy0XkaP5mJiVKHePbY3xjJ0"
    b"VZ3TdW07NGoa9BffXSyjrtF4Y+UGUO7zxCgdprXq53gQN136TmtPqm599Tyh+SfrXhSsq18T+P0R2h3Qd8xFuID3YprmHmjZevMRv++a1rLJP8tQR/DiQvu3br2x8BbRKx1nOpYeHcveq7Vmv/Ex23kW1Dt9HkL769Vn9671Olv3qm3LjKd3jcND/2OKYw7v"
    b"11/1yZAk9dO8WC/7/rzBPja7G9lWC9tHx2GJbWk9Rlh/y5L1t7D+0etosFsOjelqirTQmHg1DekB+hOu+xq+S4AmehtWB7yXGcvXyYuPeVxL22XyRa9VWuV6Oig9u/XS19Spvl9p8d+FFmE+vXQ/2djVR0+Tu9aKjYOjwdiNB62PsFZdhXJ8NUYPnuizx/sC"
    b"NMz60qN9cfZNH2jE/xXaTMooUhoCGhTj0X5U8caTkjfaforG7xqrYNAxRy+dVbig9GZvosmgFj8gTcU4Ng8LpMEyo7Mla9vdFsYw/hZvJP1c0DbeNbSh0Xqa1GOsh9LodlLwgV+QNzgfsfeRtlpfk5cWzbP6nFqMxzzGB+l5OIwMSXsettdj9PmoqpPOZ636"
    b"JPnLfRW0YvWMNH9N1qstm/dQ8pVRWtF5/ZoYkLcH7TYk/YYJ/dK6mSzzuCyDTz5fJahjZLTmwWC3nRheFBqr8qirFd07UwtfvOpA1wTvjV/6HyHSj0vHaZnwAh1fOifQ7gXjH6Ctc7Ihw1/7hCZh7J0dmy+Xlb3Py1zFHPgZvtKQl5DnHS2hb/rd4HSKc9s6"
    b"5OihG8GYrseD/nZUq76Mhj7kNwYHc5qSd5y2a8sRr5u+U2DtjYDX9jxfyXqhzViP9Mnai6b12vvokdEz8rdKPmfHTtEWU8k/6XpQfjqNr2k9+pbMZ/Nh3uI4W9/iN94+F9q3p/LhGWgG66F0T2WflNePS9HWRlaOSZliE8YXlpTbIZUXkp5daO+BldFT1WnQ"
    b"7/NgKHh2T8cW5piVu0jTS+l1wuawkOLVz9SapEO7WyijG3t4717QeY/Tp7Nh9OQIecno4adl/56OU4mV5SLNZ2Qoq19L1hy+RnG6TtYLQSu4Bo/Wq9Wk3pmPDEYXXn8bD9Pyi63FijlweDqO79Oonsh7Wsae8VBG7kt+KhzJfaVONFXLfZKW+y1tUmis/HV/"
    b"DZ/fkeP4na6Xj/XqdlTv739B50F6od/dibFbjoZu0o/DT+pA2nkdqHdKBzogvREp5y/qQPu0DhQqdaC2dUIHQj4OhT7QZjou0KFxSgei/Yx/fW1w4hR977P0zWmk0GI0sgJape0GmpP0rx/T/xHt60raX6VpX8hk/UiHP7Gm33eddL4CyFi6YXyZxdfN4d+p"
    b"kGv/WptDmr442iCCoM0v5koibdXOEOnjrxFpoghM1lWta2yvSsAfUwJ6Z5SADF3sk0MDqriC0t3kv/2mQPVSAtU7Fqi4WKf7ycZuRHk2NHppBYBvGvo7Ob64EO6Q91mfd4oDEKGQZwTo4lu0aXCaBiU5zxslFW+01byRUaqpIvE0cmrrKSz+Vxn8p2Tw/pwM"
    b"phs+qOMl0Kt0A7v7ouvgYTx8XT3QzVN419mHBypKBe+Zb9OBHicb0LbgBUpr3fxBh3tGNmT46yBoEmWtw2h3caQYnFLKdlm+Sm84/ZQMDzid4twWcvRwQtEdZRTdhLaDQWfJ66bvhIy+gE7uGjzfsjn3N02uV2jB4CNRgJG/VfI5M3aqwxY1/6TrQfnp03Vi"
    b"bF0PWv6VD1rOHaQk60XuQDF/yLHLH3KcPWiB9ONDkAPnIZXCDXSfl/tFpU6kK+m2mJH7hc4Xlf3WaDCin71f2uj9vM6D9EL78PRF27sKRT+8n9SB/PM60OMpHcjDQ92UnL+kAx0yOtBeqQMVT+hABupAUh8oyoOQ4ORBiNclv7w20Lwp+nYztJLQSMhoZI+0"
    b"StsNOpCk/94R/R/Tfk9F+/sM7QuZ3Gty/Seh18KJ9eQDeULkC0HG/hfdLG5W083kme4XDzfvHzdRTAhxCP7z4Y9L/7dj9l38G8EfI3nv3D+HeMlXF8uCfyaxxQsh/LnDX0Ud5nxY6Kxmd9lKh3q11+k/9U5V9SUbGdH/WHl10qZ/10mHonymWnU+qte0IFMV"
    b"rV/rmH0n2z85CHYkvrZpDYR1Z0kq0LWT/2j7GT/l6u87/aCfedOKzKShjWKqfvjRuzzm0H6j8Ur57iWIM/U7fr9j5ubnLvk6kPMTWT5WCP2Bb42TVdH2B+sV5dXOYhSfH781HSHev42YiPvoPhm/AbTMqpzuVoRNg9d9h7bqIcbhoENnVkh8Is9DxSbTu+os"
    b"br/ehB5Zzltd0nzRB3H9tVqoWG9zj0q0d53Ezbcq8cy3r55J7v0Gce3HPq3jo7m0/IeXiMTrt7uYdMt7xyS1THo9ld4rG7TPta5BdoM3GMMaSUbP6sDf1UMI9R1IZJeqJCA/5r0meXih78/eYKSXFs3fcPpQfi22iPZJ7NrbBvL3qlSzeEs9V+IWze/f0fp1"
    b"S6PlRVX6HHbpc3Wm0f7GnrkMiT2sTm5IfNe5GW7tt3nBJo27Qy+2Xqv9rfk2nz6Tt5cD1fjfqr5nvX35Nhlj+UjhS5x92h9Md8gHncOo1aBjbmlvdBh+zIhtjTdzYj68uzS9n0kfpdK778Bjfdr/2ngDI9JjPAPlO9ifH3Qy357ofDwse2Zsl2r+Fvpj15vv"
    b"QxivIvEGb1+eTfunmdBf/4OmBw/0ueDQ5x/mlD7rt375hfa33olJa65/3dikBfPffL0J5PzP6fxXYjaeTpmNJ50/Upk/Fl5K70/QX1pf9y3C/uP4hDT946EH7zeh/cDHH3N8Bh7qOTBfUX6+OX3t2m81ymwfTQL0dCDQfgLt7d2z+aLtq9D24XwFVFhaj/n5"
    b"vRl+UHq9gfkjRL8ZwPsa7S+dv2oUW52KTvsz79+QMZtP2X5/TnlmV72fzdefDrQngvbI9r0eYL7o/NP36ViYHY0+6+w5BEHaBXrMzxeO3xf2v0d8S6e/keXR/ND5eHu5iWn7cD7evtP/CX3fBnql/TUkvQ4rJudX2X7K+uThTvso/RgX/ex8YvteqLy87+L4"
    b"m3T+aqZH6dPN03dC/zhelH6x/1ge5Tna/wj6j8/Y/uUTTb8vory40N/IIUw+1N/+Rnr8Fv21BP0tqVin9HKBvja0oB/zC/070Z9B0h+QJ29H86VfmC/jW/MV0fF4DSwqL3RKf1qsbC/Kh2/xF5OfF+YvOlZwzv/TLizVF9LJ5kL69kJ6eCG9dyF9eSHdv5Ae"
    b"/Wb7i6ofg19qinL8pT5lnVBgFf/uL5Q6+X7/Mwrm2X9tmd6k+v1+9Ej1yUJjdb+mul699UT3HYd7Y7UfGrjPorqm/hEMqu/0+TUseJ+gp026lAXuGnQ/19lO1lrcqJdWU62/D9fV/bi+0rpGaTsbMAeu9LklOgYM4IxiZ00KnU12b9v/8KzOx2jYOgSD6apx"
    b"5+9bsVD1VYO+Cl8aX+GqpYXr1edIg7ONrAJMPJzMGsyP9nBzc7PziYGfPVLEz4CU8TMkFfiksmMix7FPzJDUIisQ5ZkBPC9Fq0wFCUVM+aQqZpe0bFpopUdaz/DZJ218HpA2Pg/JAz4H5AGfLbmhcal6SFXpu1gQJT7TQmvK+XXJK356xIntiBZ2UyP2Bj99"
    b"O4ZPrvjzdnukJUmrC89B5rn3Dy9//Zvl9y+Ub5/lCpe8/M31v/F5PFV+LbKLvJ6lpDcPdP9EeNn8uUuJkP/En02lKLMuCIOEP8yzL/lq+j4rJ4/2Xwn9nBWuA/gzzm8NoQv1XD9w/2a5uVfHR/1r+hcX1zsoqp6Tr6BfEHOrWoQW+Z5FR+MTiCaeHB94xcwv"
    b"qi+qRQk2CUf9RxFkxqpFfprPHx/1wvuV+Xs5s2Tyfwc8H8j9iHxSV5Vv5pUCXbXS3UP73Vxj7fAEf53VQ25VPXjA9uXLB33KzCtNP1Tz75NfGd+loBCgn4eBz4s2PSRim1ZtGfwUh6azg6UmpK8wfQvpUdL++xl+haQqdtKi4+AccObbEajCvsmbXm0DOwDr"
    b"OHEF2ojpoxjSq7AV3UK6TUWOVehBeoOW8jCNTEafplfAdGifjpP1QN+57/sWH5+PGZz/WHR+bL0C6ZC/66JaVIb0EqTD+FqFIuaH+jsonoHEqjUYPsjvxAGIL2xfENlJ+14gHdtnaJCO7ZtEdtK+L0yH9mkbaDS2rxs7Sfv60CnWvgDSsX01TMf2SX21iKRi"
    b"0XT7WZByGzewcEZHSjjocIZkv+DXLqQjUaP8xw0Jyi97K8472zirKFpucX7geNKOcHznkN7E+YHmlDbQVDfG8k3eqPYnpgcZndZeRYkcb29Jct56W0z0QXuJaVBoe4Ef2D48fwQqtD+xfNj/tX3MG2XLfxIU3b4TSmZxk/xqP2P9MDTtjkgv+YnUtNeCOdsT"
    b"oY+XKvwUlE4XI1X4/0Wks/HD9r9HyfrQ3on0257I/+mL/FWRXsS2maz9Jmd92n4nSd9i2yH/M9I/5u+K9FIo0tcyfSbHz4V0WDrsV1+kbzAdqirjUS+Ml/0u8x9E+bey/E+ZfiPb5+HYwf9PkZXMTxPmx8R0TaQvkf8wfx/nD9u/FOkvMj0S81vGg2w8mX+N"
    b"LX4o3GZyq2Iq9p8PkLbLrbc2sI4rdQg3FvmXQphbG5F/L86HmbzH/HWpnrVFfsokydrl9ER+SwhW81Hkv5drfIB1Fu3M+fedx/JH6fN384bRD01rOvXsTpXq4sQORKcanD7px3sktgMfrH4XShb1M1KE+u17Ub+3EfVbYo2yB6L+Vk/UX4qT+kkkbBkPnqi/"
    b"KFcwB+kH6rejmvzRSep/EfVbjpnU35Nr5AejPw8GXdT/EDm8fnMj6nc2ZlJ/1U/qNyeifpeI+kexqL8kxz8S9a9F/ZYj6ieOsB+sRP1WLOpveqJ+W5xF0AUoqd+T/Y+jpH46fgn9tLai/qIc/y9RvxXdSdXSTfLHIr+pWUl+V47/F+MvWG+2In8H6RvHT9Jf"
    b"jfGfieIyFPYNlh8WWVn/mNUPi6ys/64n8rclUxGRXxrFyCIW+V1xFtEIRP6izP8k8luRsM28kyS/JXX/+5Dl99P2F9tm+XsgOUT+A6u/BlJd5G9tRX5fnEXZLyJ/I2om+SsiP/GtWNhfRP62POu5R3qA/PfyLKUWe0n+QAgVy7MV+xzUH/J62iOjx9wmJFLk"
    b"N19V+UmtCucYMZxJTOu7T/78ORpOa3heEZlzcUbig48S+i6SYSEVDETfwbMSmp4KcqDvZB3Hedm5MxNzPtSri/Gwc5jeNeZerboMhp0nsLGhPe+upYWrSpx73g2NztO07oB9D21xYaGzHx7yzw1u58zVEeWedWWdh9yzpq7Tzz33lXW28s8rZZ1G7rmgrjPM"
    b"PT8p62yT3HNfWWcpP7Yn5mDn5crzujX1+HZle6d3q3jUr+za/cq+VavsaL+/RutRamw7pbDep3lWc++5Qz+DfN59S68UhwdKe8ZoHUp60WZDczU8uAXoP23zZzDQV0flPk/n7VqaftjvLVpf+0QeTEv1ddLP0N9Hhs4MPUNP9N1D9l0/826aDui7RvbdMPNu"
    b"qg3LYD2de/lnP/cc5Z7j7HMrl7+Vy9/K5W/l8kN70O5dAN8t6b9N+wDvzMEfEuhxPCi9DI3W12Tdepqm8xRMSNPS76f8zQi334PvTMafkpD/+i/m4P83+mzUI5XPxubv8NkwVD4bbvTHfDYMlc/GQyR8Nj7/nM9GUeWzYfwdPhu1lM4h56cofDZQMfgzPhux"
    b"ymejTYTPRvR9n42i8NloR1efjavPxk/7bAx+z0buSZ+N4Ds2c7RB98FmTvPX3mipS7v0PZsxJfvGfd7HwbC/78Mx+S0fDhC3iQ9H9B0fDhiPV43nH7xFSyaIv2sjV/t0/Ex/f9Nn5Vs+KgTScf5nUB4uZz043tSwfDa/cFy9+EFl2/j9ko+OSRykb/Nt+z/s"
    b"s/LsU/n3iO2H9XI5/xt9cFD+YH80kL9H8zW5MF/fpse3AciPFsgv7/v0pfZBUvqA5OYvuPp0XH06rj4dV5+OP+LTsf2+z8D3fC9i5itQO7bpa3xKurw/Pd6fPu/PgPfHlszg0HYJIYa+Ck4sdi/MVyEi/SObfCMS6UU+f2U+f8l8uZJvu8T2xXg40P5a5rn/"
    b"0z4P7Cz/76u/ycyCJ8un9PmD19PIzJOPBho5TzDvghht9sx8JMgpm/NJUWs7l+Xg8oj+vi6vY19H/b+/nKmm9LkIVT4Ngapl9egk/Z6R50WVTX+u8pnA+W/kBuvI3STxWTrrE7FW+UQgCR75REQqn5NX1UrdTAzHmfzbEz5PPzl/jD/q5zJ5ceKYk/aZ8FVe"
    b"L1/i0CjtE+Ing5z3CbHyjS2c4K/axfUw3wM7VvmcVFWOQ+CTcOTY45BfGd9XQSFAP7a+THw+uoyI0ecgSvQ523ASUugy+gN3jo9N0n6rsElI82EWc58P06sInxFNQ58B8KvoRmbiU/IgfDYMtDmjT8QE2QV9InT0KQCfiEKQ+Hx0W2iTxvZ1hc+GHgmfjQBt"
    b"WuizsUh8Ppw92qzRZ8MnwmejJnw2tK3w2egS4bPREj4bxhLSWfvQ5oLt0xKfELvQS/J3W5iO7eugIQ/bhzZbbN8QJwbbN018Ppxd0SSifckJTbsu9M1inJCyvRTuNW3m0IU+Gah0OmB3Yg5tIP/ZBgXl1y1J3IlsNqugerQrQp8vos8AqAD2AucHPCvaYxx/"
    b"j5Xvs0bZ75i+5nb7xDocCJ+Ld6GathkNesznIvF5eMX8NeYTkvgk3GL5IGXtFeZ1s+UXhcOc/RSTxCegKei8yPrPfA5Eek9IzZJgTnstfTrm0qfDEz4brzL9jSRFlYvJ+mBvpU+HLn0+liL/l0xnbfNZ+33G+rT9wqfiXvpUVITPxVKmD6XPh/QJeZHjhz4z"
    b"uHSUeyL9DYe5LsYXl66yLH8ryy9Inw9Z/pdMt4XPRjHA82tGHzA/M0hvSZ8OR/h0rKRPx0imS5+QjZzfJfInipsQ03EMHeFTkXfXQ58Kz8+tt+CTYUkdwvJE/pTG9Cbyt30rI++ZT4c8r2VOUZh/IdQXsybyW74QrD1Rv+2JNb7uCp+IT7EGmwfhk9GKRP55"
    b"LHxCpE9CgwifjIrsVCh8MrxArCDvvvDJcIWt4n4pfTJioaY1Rf2WXKN04ZNif4j626Govy19Eg6ifmZf4Eq98MnwRf0mET4RN6J+Kk8Sn4i69Im494VPhCM0LLsofCIiUb/ZlD4ZmozpjIVPRiDqr4eifscPpZKV1H8v+/8kfFLISNTfCET9e+kT8ix9MnxR"
    b"/4ef1G9LnxjPFfW3hYZkS5+UB9n/W+GTYqY0TOYTAfkfpYY1Rf5gPjV16YOa+ISYXZHf8YVPyEzSX0/4VKTsK0Phk2FJn476RvhkWHL7pqfyu1K9F/k3gqncrchfkT4dA5GfSJ+OjZ/kN33hk9GMRf43aZ8pqHw6YpVPhyd9Mhzp0zER+evSp6Mk8zM1l/k0"
    b"KXw67BuZX56lWMKnww6ET4gZ2tKnREzqs8onA/WLvJ7mbFQ+HYEq/9hX5CfmPHNmErHnybpf6Awb+0nBJUPj6XXqVD8nd0v6nZ2dkFp1PxrUlv5gpI2G9J1C52ls9AjD7mBnKPSdw7RO3+s1VqM1/fR52YP+ITRqL6PHjuY9530WTLXvQN7HQO2zsMs979V+"
    b"Em7uuaWuM+eD0lL7P2i5Z11dZy/3PFL7g+R8UFpqH5RC7rmorjPKPa/U/iBHfhon5qBL8n41p/xtdqf9OEYn/DWcEp0XjX4ap3w1hkZ1PXrxTvuBrGsfI/+EHwjJ/94rwe/qPJAWZX05sn4fu6x/hpt9N868q2Xf7WX9PrI+IoXsu7INo3rjZXgguWcn9+zm"
    b"nr3cs5977uWeg9xzmHuO0r4YEjMkTvty8DNP5ivwHAwz/hvMnyzjLyKxV479Pzj2DyH/9df/+Y+/tlTClMoS8H8+LcxmhXA2rmhhKSxNyrNxWCiX5mFxOtXL5dlsUr3VNb0wDqd6ZXpb1WiDKkbFKFQNfTwrTAU4ZHEyLhbLhXJhrN1WtPlEr1Ymhh4WJvNy"
    b"WNGM6Uwrz25nVe12rJeK1elkPA1DbVItzKa0uLBYTgOHlA3ttnQ7G0/GmjaZFGa3Bv2/UpoWC7NwbFTHlVtjMiuXxyW9MitUaKFl/TY0KrdaRa+OyxUt7dAynhanxvh2MqkaZS3UZvPxbDIu397eFsdzo6BPq7PZeDophOPbcWGuFcqhPqsWi/p0ps+K5fFt"
    b"+a//83/+Q9yhsP5cfSxeV7P/FY5fpovp+GO2/c51CofRsPEaDOKfQez5RYRCjtaTQSv8d0Lq8c4g9XA0tUcFWuHiCK1w9xtohbsUWuEhj1aYRZhSoRX2TqAV9hh8N0mhFT4q0AotgRy58/bL76P5dEkWVVMgFy5P0ewe6FFCEudh0N3z6IHdJSvDStOeewFB"
    b"0D2NgvbssvIYiuD+IhJaUn8GSdA9gYbmnkLN3DM0QTeFiOZy5EyAIncTREGDIwoaWVRXl0NdhwnUb7GJZeK7BTlv3i+iZ0IbPI6eid/3CrjtPUcYLAme6BLOO0uJInXwFShSbh5B7cDkgwJBrUt4OSgbPqaDOIHbPjC55em8rwUFQtohC20M5UR52O4Dg3r2"
    b"Cim47UMbryBxYjmWfnySB57TPODHGWTZQe11sohe3bvR13gg0TTF+Fhn0ft251AZTyDKfo6GoUAKRB6jvHIk/1PQ3d+lj9MyHmGykzk+sHFoIbrjw+N5yG5AKWsmSJ7IE14yVgr5nhqfSMr577d/eaL9nqL9T6L9bY7i5yllA0ByRxxNEdEqi3R9MibGapm9"
    b"1gH7TGh/9+NBbZvtc5hGQ2XItKl6pAfvaE+1I6QDjqYs0tIonkfw3noe2l6J7HYYHJ6yqIYMrRbb4Ne1uHHHvIUn9SKsUfzKlF6yZkTTdfV1RM6jMItrIaxU2XetFdVOnyZiHBlKaWu/PEIHTdEP7IxeJ+vpfPRC17o+zider0LHn6eFrL/PRNXfUk4G7ZXI"
    b"oN3VpJ1BKXUz85nZwQMa3zNDVObXaZSytJCsUydogdFPIYPu+exnefxOaPnrcF39YGML9QLf8LT0Wpbvz3Mnh7rK1q4czexbtW0xQzPPDD4f2+CYmQiVZmo9Y2u6n+JhlIsJyl8GEv6q4P7DFNyegPrG9MUJyNXMPQJuolwc8M4DfjeBhId0fg2+co+QrMld"
    b"NQCxmoc6zUARM0XNXNMxOowycKpsrEdDJwfRzO7fYIqSowt4S9YXXUJB47uH4/ucwpP3OXkkC13Jy9u1u6foz43T9HsE4/x8FhJ+12ZMFWcFwnlYeC4wlHDZrM8uh4Z3L0FmJ/Vn4OG9ZzVsNhcQCuhfV2dCQUJn03eR/tqwUXhOYOIDrjwGmY2X98zv4RJQ"
    b"pVxBxnfDlKL5a3CqbZAfBwanyr67CrjgROFeojKcwH1T2cPyQT8O+WsMPNU1Bvuje2YOwal7ZuK0YjsZ9rcCFvuAi+6hxZU4Jbz2IS/ovWN47QMuOIcMvPaBQZh7ErZe8x5Pwda7cUpp1rz03WSUlseD4iZZACUUdjI+5DwdP56FVFZuEuHoXMpuoD3yqlhX"
    b"UrDZ37zy4vSdNQUF5O5BQu768kqFs4qjk8j9lLJwQg7Zburemm+3v3Si/QdF+4uy/cu0rD+SUyNcs3ADjXd6ta2sEugtLip5WWUnvyafUnYAijyr7Jy4X7KVh5jXTyjIWWWHXw1wQtnZMX3C0fmdgZkNy8n1w/bT96YlZad0IFdu2HIbgvbj9zYEMP7ZDYEb"
    b"K6+LyMugZ+eEgvyUVZDPbgjcmB/oML3tMUMLew5Tf4oWkH6yCj87tLms8LuHY4VftcFxtbzCzzY4xwpyTuEvnFf4e+xAh62tWpqHQS7yu5D+XnhrT5o6ZaikTYSp8w+GSsbSrV+GSrbR7eP2T4RKyvJTriJthoIiQiXPuOh+P1QyZcq/K6b8RZd/PlTSk/DW"
    b"Mzk/KXhrtLfX/kSoZFuY0i1XjF8N/TFw/BBoxtx+I1SSBBAqeR+hP1wX8aSia6jkNVRSFSr5rfn/iVCtAEK1DAzViiEUEOGgdQwlxGcM3RqoQrdw/r5o/99e+wAH7ZL6qVAs7M/N8IPOF23/iIVu1SJGD075/YnsHn86VA7cU2ogU++H3w+d+4DQuS6Gzvl+"
    b"nWgRrXD0+cRC6Yi5uPl++wPS/Kn+Av1iKGT5pRpnQz8LQdx8JRiaCFr55ikZbxZKd0S/GgudpO+D6yDwK+1/MfJ6bwsn6X+vRlShrj7MN8Jbg6sS0DMd/wWMv+8n7/s9hL8G+sHyGpZoD5H1W/D+Csb/sQHjR8e3AaGk9P0e0NMC+GUeUH6h9OhbWv59Wn7j"
    b"7alCarPtExWWvXS6mU7//HgCdy1Kjz0RqpodjyK0p0bp5UcnuAN+syi/0feDN/AsbIDrrtXB8aDLLR2fgPdvyEOHCzwUlT/7w2z/m/++/d/k5l/yF+NH1l9Ys7QxyM+5D/IR15MehGLXcT3RYT2pxELeyvdT8jQlb3l6Wt4OubzFUG6lvK0y+HHgB92MIHR7"
    b"g+NfKwMkluVDqO+yg+3v/eZ6VKwp+BsWfGgvGb/z0NSUAnT+X+tC+uJCevNC+qVQx/qF9EuKcfv7hX5Dxz7+170QiqkcX+tCKGYKqdX9flMu6Ku21PesdQuugfpiYZ6lxMVMDwodPVzXtveGrk/uOq9hfbe6h7DMdecVdPfR8HKYZ2LQQKMnpumrsNB6Ghm9"
    b"5dR2CydHus7y9/jeFc5I86EyOx5S7MS2z0MZAx7KGPFQRhbaGCdwy0LJtcGrtgahb41IhlJG9Lkp8OkkInImFI2HMn03VHQX8dA8V84IhDCaAYsTY0SBz/XjqC7+Pq3MR3H63VDRuvSJxZDKSjqkshaJkLUkpHLIQ6CSEMQh7ydh8NX0mb5XlhsyfK75ivFp"
    b"Y4jBz48Pfa+ZCZHMtKeXC5HsSXhd/uyS7HPDT/U/HZqL8NYO3wc5/DmAUJtWQokYKhlS+jCT/SbLF5s9/owhsYPkfR5quePPGPJKn3E+H3wzO46hZOOI15M8Q7/N2Eq12+VihM0T0Ot9ZGXo1fOtM/T6zxfK6cTmpVA73P/eqeLtrXxcJJaTB/lhSN6ReR6a"
    b"wKX07F6CHGiqFiWU10fEH6uC+lvKQfAZ5R1DD5iV3Bw0VGLfZkdF1qX5+alQQogK5qGENRlKuJahhIEIJTRlKOGLCCUEecNDCesylHAkQglh6ngoYU2GEg5EKCGmG0tIb7JQPZOH/nxgqBOIbruAUFmwHnbbfhLK9tHAUKQllI9IlCDK7vvIRxAqVw0Q3nYL"
    b"oXoIHwsi/36O4wcBbx8/knS7gFEPWD47G8Hy7zBUEEIlNQwlhPSHRwwVnED77zEd2k+3ljGjF1q/zQniI8B0hKd2IB37H2J+7P9B5C9g+TC+DzNMr0P6TRKqaGkYnwJEed/B+BMsHw91sHwDMVmx/ABDlbB8jH/h42vy+XsYY3qdwVvzUEarIMufyvJLonwd"
    b"Q5Ww/F5cS8pH+FfWf4R3xfIHmI7lYygQlm94kI7l+4J/eahkKEIlLRkqeS9CJREVgIVK2jJUsiNDJUHE3SKj1CT89ZCV73ChUAoEvLKUle2B4JNynKhu9jOLeGT1u0kooOTBJ6FkcfhqhLfOw1djKF1HpB/BV+NJ6URArzD4akvCV8NQcfhqDBXcivR3DnlA"
    b"0/fYf4Tn7on0T1/kr4r8RVz3MP0J+QdD+RrYd0zXGBwyhmImpNDuY3rEQjGTUNAX/OixUMwkHcO/WKhdPoqbhdrJBFPCN0dSRi1kqGBsZTcNGCqomSnUvCTUKgV/2xChcp5cY/oCPtk0ZahUIELlDBmqthehck5RrECRgE+2JXywWxH1hxI+OBL1ExnqxaJq"
    b"sf6yqP9eE/VL+F+7Iep3e6J+BsqPoVESyo9xBda/iEWoWkHUX0tta0SomvUg4Yd9ESo3Tl+kkoTKNeUK3BahcpYMxnc0ESr3Jsd/KfLfp863RaifLfO7Mv+naL+1EKF2KQ1gy+CXHcwvx89MQs3qYq9lu6x+xEgXi6YWi/ySqFpFkd+VoWavLH8P/gh1tMpC"
    b"HWt4/aSQG44INVtI2KSWCDV7kOps3U9C1SwZamYh/HJ+P8jO0/38ptI9XsdrG0V+812Vfx4p8rtFRX5rpsr/HfjhZJ8HacFg9XmFEf7zMMJXmF7/z4dg/Y+EUB29Dw7aR9C64Huhhu2VNv5/COxuO1LZkjd/hy25oLIlE4Td/SO25KLKlswHiKX/MVtypLIl"
    b"R3+HLbkt18ootVfEtYqRwh+zJQcqWzI72sLxG3/blmwSYUvG+yuutuSrLfkXbMmG9/u25KdQ2JJ/kO/YkiOwJes8f/AWbdlVvMEpWNrTthi0LT9RUde6Z7ZRH2xn5CdhZuNfgNXd9ADiDGF1PwHGdGWSgL5/F5vrsoNX8VLN9f5n+3PJ1vxL8wt7xNb9AujX"
    b"FbZfZis/mh+C/AW2UMLprfv26dq1tK2aLioK2zvaSgOVrXqZs1UzWz+W50fCFi3rz9hWwdbYE7bGPh7YoLwxQN5UieBH+X7KlpjiR2mrFekTyY/Nc/zYA34cID+ShB/TtkYcD5RXdd6/GvdlqHJY6+Q5kWdJ/6N/2/6/mbn57+Z8IdK2ZVh/NOgvs53D/rjz"
    b"aia2+C9PrFep9+V6lFqvUrbqJL0v16v2ufVKw/XKh/XKU61X2H5mew+5PBqn5OV76vkn+fvvvqraumQW/V1Y4+BC+iUs4CuscAZGkR/rHcEKwz74pf88vevvg0H8BfEN0/oqntR7H4FR+xzVV7CPXoV7tFFnziSyMDkN7kO9w7MIFczNqZEesfxd7lcMsSFK"
    b"W9lP2GJtacBHm+kQbC1rObQDeH6V86+AY01sbcG3bd11wmF8IzEjFtq8I7MiiAKfme1TxVWkHpm/ZusOcrbcOG2bHUisVQ4/i3DFVjFjo41tL2OjBpvsg8xXOwk7bON1IL8Aq9zL2cyz7ZH3LyfPuSuVLZJ77kmnYi8932gbNlW2YvvYVuxnbMwh6ct9PVzZ"
    b"bGZs3l6S32fPOK62xik9GcehFBPc1m/6KZszCTm7Y7sXyX4ysYlHVnLbG4e5th35/ik5efmq7N3ldaBxwhfjrM/S/dFVxeaG+1Jc8J05gg12hME0LXp9lV9PwH7K1nF3wleicXZpi1QOQltCju8D91SSGm0vR4OwVLUPfaPmuTmwfNWyUmH5owvzQy7PD7rb"
    b"MEsFyL3qKLFFOzsGS4uwsMJNq/qUjK+zx/4DbOv9WCzyH2VuhiB2YZvYort4HzOz5aKPB9q6tWJii+7asbAlv6ItGmzJBqajLXmK6WhLLia2aOeAto4GuwrZ4qTx8Yi2aLzKeJvYkh+GxEpsxVNMR1u4B8MDV2nfd3w7Kb8O04jlxyHC0mL5aAveImphkm7r"
    b"TmKL7jqRsFWPhK1aL+LwI2wt2qLhatGPIuaH/jNbM/a/LfMzosDxcRJbcdeMEtjbj0ZiQLQ0ZuyLxFXIH8wXwOflM1szlt/E/Fh+LMovyPJbsvySKL8gy/dRpf1g/eslvgqbxBbdraOtGct/wi0A1u8mtuhuA9Ox/Dc8aoqYPZvzr/0UJfzZ9gR/lNzE14Pb"
    b"avGq5pmg/zKDtYX8b/Kq5j1JWJPB8uJVzU+RuCp4IGBfL121XET6w+so1ygnHKKA1UXYVQari7bcPKyuLWF1MT0Pq4uwvGtpa55LW7MnbMmvMv1dpsuroLfyqmZdpDNYXUvC6jaZvU3YmnvC1ryQtuaWtDVLW/VK2qoDActbQlJCWOCXWKT/9lXDEhZWXitm"
    b"RSK/Js+ni8JWW5ey/VHAuqZgRWs9YasNJKzpWthqU7CioYB1NT/FCuTKq4YdsW2wHkT9DVk/01bRVrwRttamvGp4HQlba1XU70hb8V7Yyq2VvOpWXjU8kLbqtai/Ka+qrQpbuSkvbiDyqt13YeslPXnVr7SVu/KqYbkC20thq95IWNSWsDV7EhZ1JPP78vw9"
    b"fVWvGD+ZvyXbvxFXBaeu+r13ha24SFLjl9iabQmruieJrdlKYRV7KVu1uOp2JvI70tZcVtmaH3qmwtZsClvzvVS3bWFrJilY06WwVcdyr7tS2XpbKluxE6tszWNV/nGsyH+ntDW3VflfVPV/Bxa1wONH4V3wNY6u8KZ/Ht70Ch8q3q13FiM9Zctmz7vc8z73"
    b"fMg9Z+y7KdCqtC1YxDhDrH4AV62mbcLIE77Cdrz7UtiZE1yZo/eBlxRXvq6yV8MqYu9PwIFWirPpbaWgh6WZXpropel8WpoU5sZ4Xpga8+qsPJ5USrc6fQrL5aJuVAvzealYDouT6jws6zMBDKSFYTkcG8VKtaxXKtVxGN4at7PKfFqd34aTeUG/nd4WysXQ"
    b"uC1XCgVjAoCcxdtQC4u349m8Wk0HWmv6vFouVWk5ejEszPRxoTiZhrOiMdent9VbY1acatXCpDSjjSuU9LAyKYSzGX0qF25nRjjPwIGWKvNCpVKeluh/RmVSKY9pd8vFaSEMK4Ze1svVEiWgIn2lSMstjWeVsTaeFek4lPVqqZqBA52Mw+VsGs0kBqh+EgOU"
    b"kkc17t01voJ1738SJukETEcK1kdgSDoCZojjSO6aVk+nbaKkRyoM9xFhWH5gyP+zxIJsHeT3NseITOBd2hl4pZ0m4WUihJGQUC0c2mgh4WJOQBedgt3ROURSGjZifx5f0jmcxJfkWGZeGsfzDL4khzDaZSB3GF7bMeQOg6lQQO4IbDYJo9MNJNZn139NcE8T"
    b"zNEM5A5AVsG7VjKGPcR7O4ZKWv4S5A7HB30VWKE5DFAO3XQQsEAMbqcg5yaFtZeBDBLwSOfxJhOom2eP42X29q3TEE5GmrfSNOo9RzlecUvn8RoZHmcGguc5YjwLsDb1VzpgJOI8k8NUY1A9HsMDLaYwPvcncSn9NKyPCxhsTS5X8Ki8mcC1SBmRQP7EF+j9"
    b"FGQRmwMV3A2lz+k+IyMA1upIJqRkzjfpitLDCQxNBoPG4T0Qboe2DbEQ6fvnIdnS0DY7LsvScCan8HD3rMwMxEtOhssys3Any29B3xxDvDgqiJc8tuFOhW3Y7udhb9yzsDd87rDtOXiXXQbehc7ZpGD6tN2L0WMGGzMH9/NNbMOudwz3o8RqzENeOSpsw90R"
    b"tmE3PA/3w2Qy48Oun4P7+d5cZ/GK//WxLFPQNhlMx6vCclVY/qzCsvjXU1hA4fiO0gLYVTmg970Sx+w5i2PG8fb2LcIwELmSoqRXqjikeaWY4btulmY5huLphf3g5MGz9wwj0ouzAOLOJqe47NsMrHuXgIrLOr2TeJtpQG4vvmIL/mOxBc8t5sfYfd/EqDte"
    b"0LqqBW2VX8h3aiUnC1h9Hp/OYXPH2p4DZnYywMx0zr7Cmknb3Vgl4Myt/TFQd142ngTq3h8pbfoJxSRW4BDmF3vtCKh7f7bfHKcwYKDaOYzGb851FoP2m8oqVY6OQKk9S62Y5ECpdydwC3Og1GcV1j2/1IJjKi5PgVL/vdh8jgqbz/xbsPn6qniKOtoytT8R"
    b"TzFQxVPcRQKbj/yxeAo7EPakO+ln8gNb/4fjKWrSnjaQ8xMLbL46XuH6R+IpUtfkBWL8PIy3sVlAbEXhiqKMp9gkF7aSOmDz2ftrPMU1nkLtb1/l8//4euPT8Zg/4PwbMP8/IJ5iOafjr+p/D/xHfjB/fOz/3Z7YeqcSkepwTp6G7+XIJ/22EiuvoMLKw/69"
    b"oBNJiewWjD7uQnBawWcg7WN6iYBeMH0FWF0Wgf4fsP8E+t+D/hvQ/+oO+h9N6HPpjsUrOG/zqohX0KOALGdLmn/5ejO9ccfzr5sPrK87Qh9BKteWXx7Qk4b05AM9BUBPhRqOL9S3nDP6ouOpfZe+6CxTembxDG4Oq4wosPDelVh47hUL7xgLbnnFAqTvX7Hw"
    b"fg8L71v++PaF9NoFf3jrgmv9JWw460L9lwD9bFX9ZvQrRalV3UvYdf4vxGOk4kut7zfFvpB+m4JFYjEJBuLifSZ+FNNBS5sOG08Tq7oIBq330aDzwvHyzsUipM4/+9d4hN+JRyDo53cHful7Ho+g8XgEg8cjFHk8QpnHI7C4hCWPS6C6STouoZ7BmAukB7PH"
    b"ns0lKaTfh70dYpNF6vbdx7+Ifef+JPZdOk5BMAOPO7ADOZ4S2846wrYjvSy2Hdmkse3uc9h2a1W8ghcdxSvouXiFcjpe4SGRIdju8Ajbzo2z2HaN6F8L2y6hz0vxUUeLhp8AOGV3odyp+Ug0e/nBAH6xPVW8QvHSehFZiHlmXQ7qygvlFjtfUKwnDeX49nJz"
    b"8MB+VMQbtHxTsfL0/l+MN3gT8QYFX8QbzLD/iE1nCmw6zZXYdMgnmB/PJ9Df34i5rzxg5wnsuy+BfXcgAvtuivk/IX8Fl2Uoo6BhfuhfP8Gmo7u6JF7A2UUiHmGYYNOR6hzZD8fHx3TIP8J4AxyfLaZD+YaG2HgY75Bg05HqXRIv4MQoTHi8g5OU/5DECzg7"
    b"HBQsvx8nTuQfIaa7GO9g8lAXjl03YPEaSfmHpSh/HovySRIv4MQ9UNGx/EfkvQ2POeBqa5HBJMaIDZfQX/tR6CvMnx5Y236JEvpuI+WbiC23SfQh7i8PrNNGuYzrXZFh07F4AJP7p6f8/UtBIirsd6H6tJskOfUp4fyaWZ2u7Qj+LYZJJnsh4w3awpW95Ij0"
    b"lSw/EBxVkthzLzIe4FnGA4Qi/U2mf8l4ABlP8CGx6xj/IHadJtIjGQ9Qk/ECSxEv8CzTOzJeoCfiBdYyXiAU8QJlIuIFNn8uXqAh8luejBfYivyP8vz1VvjLt6S/e1f465uBjBeQ2HaGL/zdX4W//p08e5wKf317LbHVJLbdQp7PPor6HzRR/0b461syXqEp"
    b"se1MiS1HRP33Ml7hQJL6yaOMF5DYdjJegiE2Yv2m9Lf/IbDt7I086w5EvMCdjBcYprDhZLyAwLaji6+IF4iFv39dxgv4wt/fTsULiPyZu1/M43gHS+Z3ZPtfJTaePJ++7wl//x5JjV/i79+U9e8FNl1qDW4FIv9MYts9ifwNufbdkiRewNqItf0hEvECmtRt"
    b"HIlNFzXkjwKbTu5FGQYx5q/LZX+j8tdv+6p4gYoqXmCqyv+kwrZrqLDxLGX9n6p4AU+FjWePfxXbLm37u+LbXfHt/q3x7QrmF8YdGK3NaEA/69Ut+v3cdVaTl84rLWMOzqzAN7+MiQf3A6z78cRQYuv9c2Pl1ZS2Xf/vsO0GKtvu3Z+z7QYq264r711z/pxt"
    b"N1LZdsnfgZVXk2tvIOenKGy7d3/Otvupsu22pG13/X3bblHYdu+utt2rbfecbfcHn//B601PZdt9eSf0/UYMthawvfRs8gbYeXVmq20TaA/aJnH8n6Rtt0l1x9+y7cbCtlu+YNvFdB1sTw9Lu/62iYgG7YX++vcw/zaMxxPQQzgE204dxqMD9LB5ZvRA+18U"
    b"9DAwI6tT9un7jy+UDaLXHzc/UEauWnM8jyUuYPf9cvlXW+/V1nu19f773ns2vJD+u/eeNS56FF6AXVP9eL337NK9Z42nwPhYjepThk+X8aMtZc8J1ik/2QH4opcU5wOnRsJcYRkrvhfTwA88Z9vwfLa7+K5tkfLaRJpv+hy7K3UPFmB3WUsxPyrsLrANkV/C"
    b"UrOktd0F8+WA3MXC1oXPiE2mGgu4nZWd6TqxVeS2ZcJtyy63Lfvcthxw2zLanOs+sznXI2ZzNiVGFto0x5JEu1C/7Dx7rkd0n9dO3xsGSYgFVlTr58x29gvj8/iTWHObdD8mmX5QOsj0g9tmybFttpazzTbTtlkrzmLJNSIVlpx7hCUnbHUcS64dpWy8Yh+N"
    b"7R4eY8l5WSw5Sp//UlhyBPd1ZnxRHhVVQvYxLwV8bqDK7cIVBmPcw+oqIduOvmHbdskFTE9PtShhK44AF4sqq3KDCavcPUAxk2DH7bPztmEu7NwLtmsu7M/Z9lHEsdMFvLdq4HPbr+mN+dYcoOcT2/oDOxjBe6tQl2T3VkXJIn4/i5LzoOptYvt1DrGwHXd9"
    b"M7E9thPbrxNXBFbcGPkMseI0tP1u2L1fPseC831hu7WE7Tb2hO12gGYCxILDeUzuFUuw5sJIYM0dBNZcAc/O75nt0+Kmhg+cZhDxli6w4B4G8l6yibiXzHDEvWSBvJfsRdxLZmwQyw7GZyLvPYtF+ZrAgnt4lPeS3Yt7yXSBBffQk/eSDcW9ZPpG3Es2lPeS"
    b"oUEEyy9sRPmzWJRfEeVrAgvuwZf3krniXjJt+694L9njP+W9ZDL9IG2/QWKGtj8lVtyZe8kwf0PeK6aJ9KW07faFbbgkbcPsXjKHSUKHC9WyJ9KRvJhtNq/fs3vHZEJdYMGlzj8ZrCvmX0v59C7y13xxdsiwjtE2K883mUMk2hbl+Spb7NC22HaEWj4WWHJm"
    b"UZwV30ksudtIqHN1YZttyLPLpcCSIzWxRjUlltybPN/9EvWTyl3G6ye5t0vEpkgsubrAkrOnov6WtA2XhW2aPIv6HySWXEWeX9eFbdUK76TvrMBic8X4WRJLri3v9KwI27AltzU9orDt1kOR/1HeW/ZD5K/L/EuZvyvHr6fAorN0YZtNnS/HEgtO2qa9rbDt"
    b"WtK2OxD5XYklV/RF/kisfe1Y2Hbl+bJdFPeWtaVuYwrbLnGlbZcI2+5SYsmFwjZsybt+mirbrL1U2XYfVLbVoco27Poq225flf9NVf+90rbbVOU3fhVLzkjt5fwrntwVT+7fGk8unjCb7PO43l+C/XdSBwy5jjYalLTxoPo5NGrL0Z37Oxh0h2AwWoX1qhLL"
    b"7k9j002mYbFanMwrM708H1fHldvCbbFc1g19qulacVLQbwuzmW5MS7fzgqEVquVSZayFs0kYFm/1SUUAnBhGeU5/nU6McD4pGZVxSQuLeimsVktzWlhhounlcbFaMMbF20pVLxpV3TCmM2MaluflcslIBxqXaL7JuDqbFoqFctmo3pYn5YoxKWjVWWE60auz"
    b"uVYZT2e3hcKsUA0rxTJtYljSSpOpXprfVjLYdLfTsla4nc0qYWgYIe1g0ZgUZ/q0NC/cTuf6+DaszvXJpGDotBr6dVagDde1iVaca+PyWMtg083m81n4Mf9c/a/nzeJFItRpJxHqVqP1aBUUOjJo/LugLU7rawoB8iygO5rFAAxBfgY0xp4U+p/TLPDLKZAU"
    b"DtyQBknxz4JEtDIALtMUWIm3vYAelRA99CUBX5BoVfs0+ETpdcIC8YspQJbP0aO5mBhVyIsgGgzJqrGH9xIgFFo3BztxOCiKkwFFaTEAkn3T4gAz+whAYpr8t3IGWEEKjyg0VuVRVyu6d6YWvnjVga7hHGYBPqB+Z5eAsQCAQg7IZKcEMlnlAQ565wFH2Pim"
    b"AUd2jH4cXQGOsZfgGI4hgVl6R+AwJ4Bh8kALByVqXBfHUJdjyMAKLiKwPTtXBLY/jMB2iW59KoTp2ABPJHN7YHM7RcCJh0daLiuvlAYAGQ2oVBu0tMuobQx97TKS1/IIwUyN0GXmgU/2KiAM7wjBzDuP3MZAmhjIFQDXZBDM/LNgMAmP8rKP5f1CAjjlxsb4"
    b"JsqZfgwKE6r40cij2rWVYCKjHMqZUzqLcsZAmXYMoMgxssAwrgpdr6BEW7sMBLP3jtD7XNX87r1+Tk6eRLXMAMFw8KhTQDAum/9nj6O6pfgJZBQBgKXEae66wF8X+OsCf13grwv8dYG/LvD/ry3wfy/imaW6QZ78LTfI36m84p3oj3nFuzKiTZ44O9IrvozW"
    b"OO3PesW73t/rFV+XVotHMT+WK7zia3/OK34r/W6K0iueCK/4GXrFb77jFe8Kr3gHveKjq1f81Ste7RV/Y5MWzH/z9SbIzj/zgvfBC17esM682nWVVzu+/wI3OPMbl8GLHayy90N8BktfTXrhpsePjS/c0L4heMO6SekBvby7QG+UhJfgFauaT9qft5ebOLY6"
    b"yQ3KUeP+QBDxDPrbA691w2Zer5Seb2B+0csVEMk0mt9svlRhPCo6bf+8PyHjl0JAx+PHsGKzG9ZddkN69PfesI5e1Jtl9ob1hbxhnfFHT9ygneI/Q96gDeP9yG7QjuEG7bP8OrjAr0POr8XT/LqE9tD67VIrDmG+7mn76fvrY36F8Xta8hu0F2+pqAb57Dhp"
    b"L+9k/LD/cNlWevzTN4bnvNilFzbzYj9IL3b5vtqLXd5ArvBi737Ti72r8mLH9n/Li/0R6V3eOH71WkdEwc4H8nun+XLj/6NuUDcvpP/2DeqX0q83qGfBds648v+SV3zvgld8/BNe8f31aN1/ntZH+sTS3yBK97J3PM/Do+jRo2JN36/rqxCifY3ecmq7hZMj"
    b"Xe/v6d5z3+P7KDib4vt8hX74b4SIxlySEemryKMCyjwqoMKjAn7waIBGzmu8LekNn51Y3Ghus2dVP3F8EYnJhHweH1+Pj2+Lj2+Lj2+be72z8R7x8X6UoR/o/V7JebsHJ7zfk5vVndyzK9uNiGd98uBLHzD0Xu8BMlNAxfWRV3sdRsDP5KeT6Ge94R3pHV8D"
    b"L/t76R1f49EDdF43shyfecc/+Ol8Q/p+6qZ1Mz5CQGuSLAJaMz6HgGZdEBZJ1MhZr3YlIthFr+rKCfr3L0YpTVRe73cqr3crVHm9Z/rX8r93g7qtWo+OQgxwEZiqvN6bqhvUSay6QT1UIZo95BDNGMlv/hGIZujVfAbRDPJzRDPQTc8hmiEi1hlEM0zfoFf7"
    b"liF++WyRvJ9G4gb1grxBPSKJ1/XA5x7p5GMiEM/0WCCe3WE6lr9Er/YilI/RInA89DBCPpnCQr7BdIC0MzA6Bz3fQ+QrINGPhrgBXduIG9AtiVjWSRDNbN1NvN67NUxHr/0xerXjDe8VccN6gDe4f7HxEzesb0X5D0SUb8kb1j1xAzqDZ8TymVc8lK9VBKLZ"
    b"mAhEs1eBaLaXXvGM6HB+dwIx7YAwQji/M3QlfSP/BIhmiCSJ7rAXb0B3xQ3oz+Sf5gb0NyEq2A3oDqRv5Q3n37sBHb3aJWLZQnq1t6RXuyO81lfSqz0QXu2l7Z/zag9F/gepVn6I/KY8+3vwVV7tReHVLc9HzbHSq10gjpGUV3uo8mp3hVd5TdbPwOnQq/w+"
    b"5ZUt6h9Lr/adqN/sSa9sgThmpbzai6J+VyJ2zaVXfcqrXXj1k3fp1S69+rdS13alV7v0qq8LxDDbNWVUgfBK96VXu/RKb8v+swAZ9Ep3pVf7UuSXiGNsfvNe8UuZfyLHLzRlVIIY/4Jof60o2n8gAvFMzn8rFl7tYzl+L8Kr3ZNrdyUSiGeB2Gs9aCJ/KBdF"
    b"l3mlY+iURCyLBWJZLHQXsyK82g0Z8fYuvNpTEdgtkd8MZBCmJ/LLvaraqz1QeaXfBSqvdkeVf6Xyim9GqvxFVf49+VWv9uwe7IpkdkUyO4NkxusJ4tOe8JB2vVn9b71Z/e9GK7vaZa922atd9mqXvdplr3bZq132ape92mWvdtmrXfZql73aZa922atd9mqX"
    b"vdplr3bZq132ape92mWvdtmrXfZql73aZa922atd9mqX/Xe3yypQxcZheVrQCrel28lsUh2PSxVdL2paITTms0mhMK2WNE2/Ld9WyuFYK1VDrTqe62VtMr4Nb6fFmS5ANv5AQRJVrFgxwoJeKY/D2+pt2ZiUJ/p0Yhi34YRmn1bLt9OqUZrMwmKxODPot9t5"
    b"mb45rs5oaXPDSBugf7usNKrY++fLf6/Hr/8dbtbr8Wb53+vFdvvfh9n75v+bLD4kyJhxEmTsZTqo7Uf1/hJwPtoLhmmQxFknuAYs9n0TMawDiINOfT9sRFx2KhZdhUmSpJ3DJUm+AyZG8n6C66DlYuIlvSKtuwlmCMM8WKTj6Xvn8UoWp/BKsC06KyP8Dl6J"
    b"lsYraVtKvJLSCbySArS7TQReSUnilYTn8UoWCryS/RFeyf4E7sO+ZZkxHevDQ3+7SmL50xgV3klMC8dIY0Y0OUYNjG3TV+BXdFsCO6J1Ir19Nr0x8bqjBKfkoMBV2adwVYoZXBU2pgYbR3/TZBgvehMwZvKYJs9EhaFQ/NPYBQlGSZLmWm7ZjXjZexU+wxOO"
    b"T64s7URZC56un8KSSNaFFmBRPDsM2wAxKdwD43PGl63j9hsq7IXWEfaCCovC1TPYCwLjJWB17bF+HTBdWLuWZYH/sRd4RbG6z42PMdXz+BgelDghhzxOiLc/gReD6eEa+3ZgOCAew4E4kDQezeek0HkY71P4TaK9ZzCcxHcv3T8xzu7dFvg3/iNyuZvCmslj"
    b"2xRa2wkfQ4n1hG18TdG6fh5TB3FoXgNDh/JeUjKNYZv4EncmL7+n69p2SGkwqRtoLcFManSjtNz+HA9iJldT+FKTdY/ycfVrghgq0O5IyMU24/EDLbvA+X1H5WGTf5YlzlHA5OYiwTliMhdxhRYCV2iH2ED16fMQ2l+vPtN5e52te1XKJwLbh9aPa1BrpaX6"
    b"4RxOyN5da5HI3o+paz2x9Q/HdqnA3uG4Sij/eifSn86l7wcHkO2IIbTzEGPoVZ8MSTJOtI84Pvi9TekZ+pDDekrmg81xffQ0uWut0pgvfG1bhTksLsB/SuaGytgjbCmOD7ZrsznSUjhR+2/wu1pmPjdy/J6Vlyf4nZaFPMD5yuW4VVQ+PUu+YmlhGfWZhWhr"
    b"USkb9bxsXGb1iTuFjmyB/Ivy+EcHL61XJLr1nizaC447dHBUcreAtJEva6EuS8jQ/ak1juZZt56mNmI8lbhc3B7LSveo/Up8s0MrL5d1xTgePD2N32TuWd88LvN6rP4Y8Hhe19NB6RnWl2DQMUcvnVW4uMrof1IZvT8no89g7X1Dd3X/kO7auKC7Ni7orrW0"
    b"7rrP6q5uChMQvxfymIDtEzw/GawO4d7N7wUOyV6gBTIEx9wpMFqM2Lq2F+va/pQ8GddXGsoBuUYADTDdkGF/gW7LZTX9fiQbPS4bmSxV7On2DCtSIX/uomoi19n+LC/X8/LCLXwPM801jjDTnjM0LPawLm3vw2OY6NElJd4Yk0fZ8g7kRHlhNKn3Px8eM3L6"
    b"MKF8MupXt6NBEetJ66WX++Ptjvpz8E71R5N1+6o14sD1gw3HNQQ5+3pOHrdquXXtEHxvXTv0jteFvZoW7q2kzdHPtlk1Z4d2DgOwZZNvtvkIi1A7vQfMrI9c9vfSe5wi+01R5uI7Zfq7zJqLPOYx3jwEx2Xuz67zWn7dOVEnX9OR9zWGh+ljnS3bO6qzpdh/"
    b"texOjm991V5Sa9VU67yvs7pwr6i1SHqdb20mhZCdNzF97NQ6nZGrJ/TKouATlezJ0/z+e+cAeT5tWadkn1dt7N0Ulu5R/Ucyp3VCj2vsJc+39sqycK9ytP5xXN0L+I2l78mo6BjD07rA612VDmuyNfRonyTW+fyZTR7ncffNuYJ9UO7Mw9G+dY7yKHGOkVbx"
    b"+YgfdyfXvQQD+FsygGGHthlGKdML+R6q9XjU/oIKD7V1hCscncAPVZzZ5PA/rRc6dOuRPll7DDPUaXxN69EfOQOW+rfA+/0Tunw5hWetxL/GuVlksH/3zfTa8ajG7+XYuEZqP3wYGSk9GMvrSb480vnpvrpWfcJ1h8nZVxyzSPJmIrcm69WW9WMpdXyjlDrH"
    b"xnkqyvOOZXLeAefE7Psj1wsfU+cdj7983rH/Q+cd+wvnHfsL5x27zHlHVpfdM3zf5Jyc9uGQPu9Q69PtlD6dnDWfOB+Retf66ZXyyyJ9RpJg6obG0xdiS3fD16OzZcSj3c2n4KuMugKVf/2MzrsXZdWqhUmhscS8te3+SCd99pT7NJhLNc0IzNvUmY2fO7MJ"
    b"jvHAnwOVjrbPn52ztYjtD0dDR/BFcg7sSTsI6kscN5zVv2C02pK0um8/qs9+snjG3qnzqT2Toe5O8ogXsz6GiP/L96YG35sacm/qfcuugutWeg3I7w8Pcn/pPRMFLXspWmftzGG4H7wVW8tZGbgnfJsO9BjHDGjs4LJxw++h6ly9eGmNw3NBtsYVjvcdKix4"
    b"L2830Tzl+c9TZq6Sc3dWl8/WtkMEY19sQhm5vSbVP3PncL529syQ6xktO4PRfRjXqwUsP4PHzXTUHJ9prf52l91HhKKsYWH6Fa6Zzjo4NPLnbtoJ26B28tzEZjp3yj6o8bOTkrD7dRP74FLwY0upR/l5PU73Fmp+bLE1T2NnGliv7jGZuPOEHHDEmU0Kh19X"
    b"nfO17GmOJ9m5lYIndbZG+un7CHReH8hrTaxdot9O6szoJM79T/FlK4V3T2lFwZe9guRL1tYcX+otXfIlnccMX1K9dQNl8PZDv4w0bYt5fPZO7VFBpj8zG7TPdM7nozNXQzkXR2cogWqPb6jPXANeF+5pjeyZa0ujPLLy1/01fP6J81HG45vosV7djur9/d/k"
    b"a8B4bGG6E2O3HA1dQcu/7nsQnPc92J/yPWDjmjpjveR7oGd8Dx6V8oXvu47lC9PhU/aZLhE6Yts6oyP+U9nEggs2seBnbWL7lE1sf2wTy5fVkWt46oyb6y+5M9nEzqa+CyW1Xm3GQ3/xC3ceKGjOS/Fv7k4DrseB7V15Tru4dP580t6fv3ti3z5150nGH4Cd"
    b"LzO6dDN7S4yvW0TJXRyC/4UOap3dk526c2bHx1jFa5+jIeiBjuRxa6nee3K72Ym5fHJTvky/Ys84td9U3RfDzmaRrtM+TMf7kxdnoVi3NMk3oUKmpMY1SssWhSygMlDefXN8Tpurd+fJdu9OpBd5eknd7hQ/k9SdSsd2tRXurxfyzCZ7h4mjX5jHndI20e3n"
    b"76IpZO7IKfSfwnVnNRJ1O4a06eGdLvnzmJxO6VCdo5a9z0W1XwTdZXXkLxSrzw6Y/FH4pXF9342lHubuhD+a8LHI2+zcg+q8qX0kq9L7z/4utf9M7ExH+8+0n0ZiMzu//3RKR/e9nN9/7trH+0++9xE+dkd2tPa3zkuQn1P7pvwa4pZSd3EVVHd10TFM6J+3"
    b"M7eXfF6lbY2lrK0RZXypKeS9p7LLHU6eTwpbTHDirCPxO/MKSntR/rzxEKX3X2l/1LStYSfsGnIOD0qap/vI7BmJHyv2bmADOjojadmO8oykZbsnzkjYvrSFd4fxtd522Rr/mNBoyGm0J/dktsr25sf5fXL6Hr3MnszmemtqL9iS5xNbvt9ne33pv6Spzv9b"
    b"tpnbj/nFE/sxjdmtvJKUAz6/Uw/OeP2Yy4IClwWF1F4s/jN7MVPqV4dItReL5ZrlqdYGPbF3sL0YyezF4Gyv1SU4bux7T3FG0jPO+1v2Ct+yExzYHDL7QI/ZtboB2/ce2R6Uthg971PUUt7Fx/enkq4M7+xdV70ia8uStSV7d5zhnZALQWJjelbZYYJdjrYN"
    b"bo/kbSh9TZ3qe8LztAx5Z9yzk+Z5Q97TJXke97H9431sjudhH3vM88+BmueZLqvg+YDN1XMgeR50VaCfx6PzkJLkgUBlizbyPrMt5jugWA+DEqtXnse2DnyP1iXJOrwTe7Su1IfBQ04xJ3qOLgreiTWR5se9aEvKm4K35/WBDeG5d3wOJPeIhdYfWRdDPbXP"
    b"Oyh4u9CS6yJva05+HPqpdTHQs+sinr3QtvL2w77XJgr+j07s09yI64TFUz51AffPa9uqO+mi/Bl5MXsnXZZHaBmCR9p2xg+s2FKsi22wu2d4JFKdaRZbinWxbYdqHy87OsEjkcHaJXU3+i6nVU/QakvQqrShtLsq3/sov4cseSfWxjY7CymmaLXkJfXJ80o9"
    b"odOWPK8sqfxH23b+TsSldmJ9LDG7UKSn7Gwar4+uy7RNi+S8MrlH1Undhbo0/sQa2e6OxBrZtlX3dy4NuUZGqrtgS62UHaFtB7nzygDu5DR4+w08H7EdBZ848QXfUprv4pkm+NwWmf0z2vE7OJPP5E7O/fEdmERT3v1p5887nVjpX9ElhyO/ATs4f08o08no"
    b"Z49/erm7Qknh0l7Ss5W29/jId7hLMvdyhuv+08ipradwLprozV1STO0p49z9ojvPUu0XSSm/r+R+GPn9Z0z3IMc2Rm73PX1fKGF+wsJXwdnl9tu7U35Kiez0uB/G0dx2j+Z2J+UglZ95P2C2707uRGZz1vVes30PVH3f5e0+Xnp/L2XpDs8BjvbfTuLLeUL/"
    b"gnbztiVtzOpgu9N2ZmeR2N+VNjbcB2fvgfWenTRd46e/rmpjeTax9zJjtMyOEdP38mMEZ5K5MXIPyjF6rqnG6MJ9rLR8fi+vaGN+jJ57F/anjtqvFOOT8mMUXhwjPldbXndujJRnOBATkB+jknqMVOc4zsG7MEZsv+bwM1T6+ZgbI+Z/evau6kaXjoXz9EV5"
    b"bRUmcupwyqfa1YRP9Z7tI3C9kn4ru5xvaupsWn22z+4952d5By+JRzx1Lsfi5458r9O2c+fAfd1peeGZc3LMVzwXK4J3tz/+oTPPwyplO/AKp95py3eK6neyMZJtpS+6t0udMR2S81t+LnGOZzT1eulreZ5pZdfLw7RO15heYzVaA+6evPuay7otr3/L6fI1"
    b"W5bKrk7zrvL84xdV/NOiOpyCfzSlz0gyNimabSl1Upo/f5bZPWlb0JPzZKYT1ZYjfnaOvzH+1D3lXPnp80BdzFX27nHpz5O1p2fOcVs2t8N1/ZSdT9jUC9KPYJnop6kzHEdX+o/SMT+a+250Yg8LZfB5lzG58D6vNxJ7g7bYG0Qp/6ogVvow2k/5e8uNU/sD"
    b"KIPJJb8g9XR4n8WhoF8h7dNxO5bpdhz+iM8PLSc1t3xMVO88yXdOliNtHnSeszo72sZpH3lMOOtjUFSc++5azyd0i0Xiv+YU1LqFgm8Ojsq3hv5Osvx9UOoQhWMdIlTqEK2DUocotNQ+NvT93ol9q1NIfPtS+0d4n9GntHfsxfm/iMXH9ql9bI9i25xC2zpF"
    b"nyGP0wlTvmjwPq9X2D6EzWWfjlFt20pZVcj6cKBdaXdiHwtlbPm8pORExG0+zA7SOnjH7din2+F9R0fAfWZ63vLrWdtupdbFcHfqHbkuhvuT5ch1sZC386NNvhtxLABu67Ej1b622L7gu83PMC7taymvcXn8vOTjHvHP5PkoNoSW7SjtW0cxCd3lXml/6+bP"
    b"+51S9iz2SI8scV27xNfsEti+hR6ZHsPUus50TqSjmI8p9rkNZ+rnfHS6QWrMWX3glyt8grrLIvfdkbSW3Q+l9Dgn9rifDZWBad/Pw+TOT/HckvPcMmXbcGOP81xL8lyJ9YHbCJNYOvCDldgRp2KV30Wc8ulzj2y8EW3Xcawa0b7ho0nrcLe8rjwN0d96Kj+N"
    b"+CiW65kocR48u5OjIZo3Q0NTPRg2lqOBj/TT4vZj8bngn9YyU0ZbdSbxTPK2blr/UrFeuHBOovB7duJvxY4r+crdHfHVs7M/vydwd+o4dCdma/RR+07O52hYY+NwB3gEMMYxHyfmq8xjgDFWBWk5ZbP2utxWDvZHvma1GU3pnNaTmPyE9oucTwtpn6SM30/a"
    b"58NPxg1186dRnfMc4wtGe93c2SHaCRN6oJ9cnvB+7RLMGmzns1M66zP47MY5v709zZOO+dgnvoSSN93DBd8ffu6Q1s9dftZAP2OFvKPtTNrDPxPMAI5FgzKDtiUv12j+w1H7iudodTT0REzs9/EDXIUMYX7wF2XIM5/H4xjF/QmMgcMxv3hqn7VDfh1yD+fX"
    b"IZfjCriHBKMmsw6B3xjGA/7XfwkMsCvI1b8KyJV/Bbn6G0CuIF0FdIWLSDYQdq8ES3rOgyW53wxKd3fN8wFIcmP5vFmkgVmOBIUi2PXk4W5iJHgOvqOAq8GumJDRj9v/M86t+XEcqYJbcoHgQQIyc4DAxnwAABe4isM5/TUseItMMFIeNCV/UHXyEDYDqsId"
    b"sDwWYO6nHPylMfoqT/8p5akAU7oCX12Br67AV1fgqyvw1RX46gp8dQW+ugJfXYGvrsBXV+CrK/DVFfjqCnx1Bb66Al9dga+uwFdX4Ksr8NUV+OoKfHUFvroCX12Br67AV1fgqyvw1RX46gp8dQW+ugJfXYGvrsBXV+CrK/DVFfjqCnx1Bb66Al9dga+uwFdX"
    b"4Ksr8NUV+OoKfHUFvroCX12Br67AV1fgqyvw1RX46gp8dQW+ugJfXYGvrsBXV+CrK/DVFfjqCnx1Bb66Al9dga+uwFf/OOCrzWq6mTz/9Z9/HW7eP26imBDiEPznwx+X/m/H7Lv4N4I/RvLeuX8uWcqvLv9mkYZ4IYQ/d/DHFHWY82Ghs5rdZSsd6tVep//U"
    b"O1WVbiblk4j+x8prkjVW7bMORflMtep8VK9pQaYqWr/WMftOtn+GKN8MzOTHhwjaY8PXolWkXYtODsWQ6TSHaa7+vtMP+tlX41qcfJVV9UwYSu/ymEP7jcYrpfeXIM7U7/j9jpl51Y6C5OtAjI4Z1OFrjFMV4yie+kfbH6xXVN51FqP4/PgtLVFpTJJ378ki"
    b"Gb8Q/jr+6W5Bm0z4Y/ke/ZhhVaQMf8z4RJ6HG5u07qqzuPl6E3hkOW91SfNFH8T110rskbevnk3e3jUS19+wjfCnAe22etWIpn/QHdzDS8+M7JLub8gPn6Y1yBNN79R8upB9Erv2tpHvp54rcYv8mPt3/sOLbml2qRpV6bN+67+93MSx1YlJa65/VWwyhfa1"
    b"X2/CbPuqhYr1Nget7F0ncfOtSjzzDbqPzGN14O/qIaDpWB8O3BL+NroFEltvldiF+usE6of2w/MM2vd+INAeMqXpvXvaPsOG512Lta/8ckPHg7evytv3+Hrje2amfYZH27d6J+WXA9RH+2+fHU8cbx/GU4fxrEYwnksStRpDmq6V/QZtn2Nb402DuPZjn87p"
    b"R3tZp+1bkHj9ZsF4r6i8uO++Wku79IN4jbenkOa/j8iujfWtzAqd87vCR+nHuE5gfhwYP5n+ENHnV2BU7YfvBW9PKHgCqC/fXlo+OR7vDYw3tu/R95L2N8zYLtWjLR2/pV1vvg1NWr5L6Hh2qChqueOkfFb/xoT5culcLbsbSh9LG56BV5d0furN9yWJ22/F"
    b"yBuz+rtFGF/Wf/rDPR0oOl9F6H+E9QfQH8uf8vF7X5Dd4k1Nf2GXPhdr9PlH54M+b+b0uTrT6PxqdH5DYg+rgQXt8WlVSyrd/IeVaTp26dfLm9z48V3nZrh13uaaTUZ3h15svVb7W/NtPn0mby+lMaV/xo+Unsvn6D2E+dQI0A+dth/zoEkelml6sWj9T3l6"
    b"MSm90PFMxovT2yvNHwG9DSE/Hc8uq8+fU5G0q97O5usnmL/7Jxh/mc7mA+TPxwPM9wa4rof0dtTeSMWfZTGfSzr3vP2PfkjpZXNP+aME81ej/Prh0zWnYcJ8dHwq5370HIf27wz/RkP6XKrDfDwxedNpvtDx5/y8IDalty7UV4to/U95+vRy9Oln6bOzFPxW"
    b"IpTfP1271kzkHfALjm8XxneM/EwEP/dgfurIzzg/dD66b18ebc+LZkL7faCf4IE+Fxxovwn9W07oc/mOPt8MPyj9VIF+6GJ/M7ipeKZG+2e+vVQj2r9KldY/H07I+KVQpPL+x2xrv82/Dibt/z3lzxvavh9MnhrAX1Wfyq8v3yZjtfysEpCfPZCfBsjPND0R"
    b"oCc/T08j2l83L7+awB/Q31rM1gunzMbrjqZX5rPCS2mD8oeWh+tHko7y5wX4vYv0AFKpZuJ85duL9HgkvyIxHw0S8/Yvl3eU3sYWfUb5l6LXKbR3jvQKBfRkeXdYvgPzf0fXw4YTAf0x+tkk7elVob2gnjUsnURWpxXR+evQ8WrYBXh2gV6ZvCRMXnUSeRUl"
    b"6wWXrxPo34zO1/KRSruHpUkclHdcHnQrjH9Ap6BpjbtX6B/lFlifKX8sR5yfk/dLnH+Dt08f1r9nshsA/fXe6PqQGe8nH/oz4Pnx/bsmvP/J5DF9v5Z+n44x5c9nGL86jkfM+WMh+KM+fn+C8UrJA6SPAcgPSkiUPiIpr5h8B35A+oL8zfcD8gf0b94D/jAc"
    b"5Hfgjwj4owT88WMB/L99oc+VJuOX+tv8RvKLxvml+VKF9b2iA7/0kV8C4JcB8Avyfw/GfwXK+4B+eViy+QX6fApgPgcwn9N4hOsbpZ+Ajm8nIK+oH7H+JPO5hPLGUN6AjhUtrwnzCeuJw/mB8x+TH6A/wfpHx68Ye0OUL290/Oh8sfJ6nD4tH5buZSdZ/wfw"
    b"fhfHC99fp99n/Ejp5aOJ60NqvGlX7x/Z+sDHuzZ+/3X5+nXD9aUx6JtUX3pAfckAfekH6EsvoC/dVkCf2ldofqr/PfzT6U+voD+VQb/p/M+tf2WfjvdgWaP8APoNVWQp/XQ2vL3rlLx4r4C+8CM+qS+UQV/4EYO+EIO+EEr+lvxcletXajyJajyT9WtI1y/Q"
    b"hzTUh3yghwD0oQLqQybw6xL0obILz3ugp/id6UeUPipC34L10g/per+kXETlT9K+ER9vjdOHhfQx3oxU+qqSPrA8Nr+Uvoe8vILUJ1PrGVGtZ4k+OaP6JLTfB37QkR+egB9C4Ici8kMH+r95ps+3DZA/1gfjD9zvJPzxg/PH4PWmd3I/cTun/MH0wdA2L6/X"
    b"SI81AvTag/VtYCXrXVpf9lX6slyvuTyG/pVgftn+Ib9eL2C9HinXa3h+WcJ4loE+2Xq9VK3XJeV6LenvVazXa1yvb3G9jig9fG3o/C6LVP5qsB9eOqAf1gisjz6sp/Pv61M/9my/1xm/3ETJ/ES/q29unxl90/ktSv0/Zvo/XY8Mrv/XQf+3UP8vg/7/+Pqj"
    b"4NXeUB6y9aZIqDyg+i8dvwjG2/UT+dI9sPmm/W/4Fh+/9PjqTF7R99+Ixctj6WNSzzyz9w14vwnlb5f0/RXSwx72FxPcXwzE/oCtD3R9eWTyh8j1P/DpeA1c0D/62f3EEf9+S99M9U/q3wNYX1cLWD9R/0rRH67PXxGsH4Zq/UD6fO7B+BqwX20Tul/1U/oL"
    b"p/daWew/Rygfm78mH+t4PuIK+QpnPss61Fd7AnoNog7qh5n158Hn+nkT+P27+z+pr/jK+Rjk5gPpg65/Fu43j+cD+bMF6183AP4rAv/J9jsBL28I+iHdry6A36k86P2afOXyJErks6+e79z+AfVtaP8b7Je/qS+I8X6E+R3g/I7PzU/wJ+Yn2V/3jvQ58q35"
    b"+jX+4eNF9Uk6P2OYn/7Z8Y3+3vHF8o/Gy1fpR0ifLhVVPyO/xkJ+rXPya92H+VDPby+93+ni/qiZlifhaXnC9nsgTwYgT2rxNtFH+foK60Mvv76CvmTk9zugP6G+GcB+Y20Cv7gRrD9uj9ZH1yM+n0+n97811FeBX19eYb2yfNqezhLGG/i5s46YvKrz81lc"
    b"b79i6F/59PxuYX7LML83ZJORl3dcXqbO64Yw3/Vxen+YG4+UvEyNx5M8H4D9HudH1Kcd6C/KG9aeCOh/7pKH/k3Zfaj0Ni6pUUFCx6NN2wbnh2J/ys+jcf+5e3vLn18O6NB/OLj/TJ2X0bz3Hbb/hPMy5AfY/76l9nPvt6hvRyr+p+PZfBuB/rKO6Po92t5n"
    b"6RXHI4TxWOB4yP3KEMbDxfFI7Vdi2J8hffxA/c2j/Lp0gF/r0ROOJ4H+0fYUYf/06VF9kY+fGZOeATaG4RPsJ4D+a2BratzhfqZK9wPLGdS3fL2Z3riPsD8kCT3V376+bm5qO5zvA+x3azAfT8gvKK/Zfn+b1teDtLxi/JRaPyU99Fj/c+sn6396f5GsJwfc"
    b"XxDQr3qwvzBqqH+BfhfB/qKE+4sF6Gdb2F9U7hX7fwLylY0Xe87/8y+YlXzyW//MSy/Ev5d+qXwz+s36L/U/+s32XUr/3fn5J083L4y/fSG/eyG/dWF+rPj32ndpfiz/9+bfIr/Z/gv57ejbTGP+Cv87ccor4Nv0sb3QKZleP+GAoOrqhabe/l5PT5iiya/0"
    b"P7gwaZqc/+dX9H1BLHrAhEds5ARHHbCNd8WHxzCa2jrgJEUMj8h8An/W2fpD+M0E4Ef1WH0GPLL7deN1Wm89hUb/cF9o6JNVFfG86Dsfk0Hta6xXMd+w8LoK15VP8AXIxLKttbhRL62mWn8fQjxDgufCY3TT8XiI74mYMztrUuhswkLni6Zbo8EIPj+CweoT"
    b"yp4M+ofQqL2MHjua9xxK+lKNT53V2+P+QUfjn5pfwCQ6JtoknifHincRq9L0SPHh5uZm55MyfvZIBT+p7g2fVGe7l+tDn5gB6cnnATwP5fwPVPQ7Y94flH9sn5Z4UyN2gJ++HeFnZG/wM7Zj+KTlxqKdZo/UIlPSPT7LKrPrl6UBDVI50yWeTUuq9Ij3DJ99"
    b"0sLnAWnh85C08TkgbXwekQd8HpMHfL6TwsQDvqf9DMFpIllnu9DvOrFC2S4P2hWQ+1gMBssXkbpvJ04vNfGeuYHfK2Lq2e8jeL/BKYF+ZfX4/P0T8iHG9yMYX8LH1+Xj6/PxDfj44njXCRtvWj+Odz2yi/BJ14dirj903+vnxiEiL8fjkO8Hbe+SHOS6wt8j"
    b"Y/jdTygd++uRSfKM5flpOZubXziMxHWwS5rPbH7vbTa/989sftm8D/m8B3zeR3zex3zeJ3zeQz7vnvTbkfO9PO7n5mi+vUg134F6vuli4Cf5lzAePfqHE3ePz7MP74/JXWwm8jPzO52kjaSPzO91n84DK/8OEmvgEkXrvSOMropJPj95H/JHlF/cpJ/4Xv20"
    b"fuj9If6qyRXMhXHrQydS49iH8a/7ZlHSFeX7mNHLStIVfw/mp0c+pUjE92qQfkoVgcMM8Auj771x+bfl8u+Ty78YP0Oyx8+IaPi5JAZ+brjc3HK5GTO5GW9JJ0c3dF/sH9FNMz7iq4Nsf8IvlG6T93qSvpBvfDObf0nltJPlN5+EMD7d49+H8Hss/SShHjOZ"
    b"D+T7h9RzfCRvYf0wcedM+7P9v+29bXPiyq4o/F/W1zn1jDEmgVN1PvgNYohtnECCqXrqFK8OgYRkYMbAqf3fb0v9Zjc2ZK3Z69Te93pWrSRGVkvdLanVarVg4/eTjV/Kxu/Ixk9j46ez8TPY+N2w8aPjNhTuA+8/oRtLpzgSeknkfK3YmxH0/6DYGyovW7Mm"
    b"XcHM5zuzk5zJ9xp8ZLQv90y+75l8+0y+fSbfAZPvgMl3yOSbyvuUyfuMyfsvSBnkLLupNZTrG8iplbe7sI72orx++GYGX9gXaadNOV8uzJfN5SOiz2iXLD7IdNxwHGBdE/Z4AM9bKRdkHBJLtYu3yvsWsx903mZUbp3IztNfE3rUfot+pzbfc1rw/CbtENeb"
    b"Zu59so5l32+evW8OmefA3jd5nia+/8gHUbxPhCD3vu1l39+eve+4+fedPD3TWbNnOi8m2J/EzYzDkPkznpWdfzI5VlaeTTpfR5ws19wyP4ziJ2Yz93kkPify7OEeLrJxnad6EMF8oB0I0XPjeEOBh3rWSdrY7x7KLec/NruFn0/MXu5zV3xO9E3P0eF8bwnf"
    b"wwK+d7BYxbhN43ybjG9Yp7yok6HDxsvWLCEHEdH7mMvjEJ6b/DkCgi6YWtvsJ1Z+K5pe3qpS/9j6U/vhhOnxpX2ycJXk+rdHfbq4uR7Ajxs1dRl+hEo/0LQQPpTU87P++di3iwnwHWg6TAqCCI66qcWU8J7S3F1a7L9djGPZfn5TyFKv4cd35cNuRBvN48d0"
    b"BvL939DxyvPXK/FvLs9fejZ/z2iHoquRuW/Kh35UsEN38GxgqzSnlay/7UtEQ2XTTttfF43vTRF/KFqOMr5nqB5xAmZM7kqDHFaRWkB+rlzn+PIG82+7+Zctl17ayIcdHuCd+zQfVnJj6izlpsnC+xlT5e7BI52EfCzFRVFb5zttoaiok/IINO4j9zxIZG3z"
    b"sTQroPTzYzRI0FPPz6EL9sH2FHx8miixlGGESto5NwpWmtcxa0CVNI8/SDHoqOAPz+bXKY9O8H8fIijhaiAjOIgDwt8Ag5YY5Nr3eTzMqQlVGtDxgmOLPQYPOpDars9MlsDZn/D+W/4HN0q2vuPt96d8fC1/L+DaDKYK4Y+gXxSO+2qE1/A+0BSOZmKQbzRq"
    b"e/R72kRGHB02qSbk+w56CEf+dwiPAI5xBthcDO4l/Abgd5DaV8f2Id7bX6IfhvS/4xg2qQ4leIvEHFiwFllHwJ/ACIKoO7UdwGFLOggQDvLTqgEcxtc9oR8EXb9/BPm1ftHx9elNJLuG8g/8958Sh86/5Y8ATvuPfgrw339G+BDgUwHXI4AD/f4Y9eMB4Aa2"
    b"j/3bAhz7t0gd3r8W6hf0r24gHPpnpi7v3zsMCsqHjkYF5aMH+kPHD/2aThPmD+V/hv0DiUb5bXVBImB+3BT1C/s/QDiISitAONBIDQF/Qj8FtmStEcBhfN3DzoqoqvZHqDE4PguED2H8mwCHpgZeCu3D1mK/QfgM+I8RjvKB+HCfrPWB8DXMD0rsjPx/P0P6"
    b"wErrhPAdwGcCvojabP1s3SBcQ8ZAfxH+APpJxw+26+adB/PnWUx++kPU3z7wPxHw+hbgsP6S+QH4ks5PzOevCXDgvx+hxIwAbsOI2yB/mg8aAaGfgZXe8f5TO4/6vQU4XG8bOBL+DHDKX2Kx+e8/R3ecv6WAw9fCMP18QKFH+WmDUFP5xM056uco9bh+bgBO"
    b"9RMueFD97CIc5ecD4aifW4CjfvYkvIbBI8CvIz5sLQchXFDAOdy3UOk0lF/O36Av8e/ADelowF8TfD/wP/oxnh5vgP81uilwNKqvbW5/JkmX9+8H4kP/6j7ApzC/z+CGUP0ekxWG6vdha3P9nkY9rt8ngKN+19cAR/1eJD2u37cAp+1rAEf9XiJ8SO0Ph2tr"
    b"sL0o/4/JPZf/Mdhman+2NtP/gQ9wC0IT+zrAYdKBPoF3KX3Af6f0d2x+6qnN7M+gH93z8bPAKMDW3YGvxKBLP7F/PtffNh5wo2LGDlOa+yEkLFiwYOwfER/0r+YDHOgPOmh0YLr2MzRaMH81zeHzdwcJ7pT+K+LD+qOjUeuh/ED7eGzeekM4jP9x57Dz0Ptp"
    b"6vP5SXn77skV/M2hffSyWnV0OpoAR/oQcyf2OWBr5L4Hbhzyr+3AdiL/LthOXGL3Q4BT/ocOk59BOwk4/1PEx/UzBTjyf4ftI/8LhCP/Pp41gv6M04Dzv+Xtu8e1w+3jFNqn/P9CNxP5R/rIfxSFnH8bwsOUfx/C48i/jW4mLGx7H+B0/dcAjvw7Scj5H/Hw"
    b"MtFvB9tG+xBS/sH+GtRLtHWP4/fjNOT6swY4XZ80Hp4n/IdU/oB/xp97ihy2z7hfmCHvf4Pz5562DtevKOUe8t41m3T8HG0Ituue+i99djS3D3FsEN7EtS3C+evz/o3NJu/fDuBPdH0BONrXOcCpfUN81N8Y4ah/LwKuU/oAHyP9XwCHHTSzb2sn5fYtEfSP"
    b"gv+6L/gPER+sxv6b4L8u+ccBp/h4U5fK39rl+tNJBBwXbao/eDOW6g86xWg/twJfl/g9if8LnWr0D1BgkIcA4bi+2RbzMW1tB7YH9kf9Aa7dB+h/aHH/qua53H6Okgeu/ytc25G+73L96aLvQtcHgKN907cAx3f6gG/puL7B/eg7TO1JXSIfPoz/IIJtwgno"
    b"PyEc6a8BjvTHdBvBdBB3CaZpxPyQ1nkVW7HwUez2GvTwDdbw94S7uuGaXl2G7diWnweznTZ4waEu9t+3uLuBEIWT4KxAI6EHo2rDcmbg/h8WJmeDFOEOeThBeEK3e2A/AP8D8YFKiP4t3AE3b/G+Oe7EfyI+zE/4DeBoWAy8iB4A/gqXakAKI1jKHWC9gf4p"
    b"CJ7zjnMDW8twhf4rbjfxfjvs/5wfgI8TH2oIh/7fbgH+SM/0Hbb/Iv3z2f6qgSeEAxw/hAOpEON1bWjqBk31EPkDihaoSoib+3bM2GXb2Y3Yg4dbcbRK+Gf2k4yvzexb2MMRGdLj9ZTaF+cHwkC/wiHCYHwb2GlY4zM5CaEr9t8G7m+CCMdP0EdDixPecAV8"
    b"I1InwljsvxsoFXA04LyjKNQBjqLmQNM3MwHHBCwUxRDPR/DI8dYV8H0k8BsC/1YT8ETEiQj/oF8u5T9i8BXGnRG/j/IB+A1fwDcSPpVwlE/wgZ0t7p+Qv42AE/mIxPgCHOxL+EvAb2X7e9n+rYTT9sX84f4/bKN8AtzAOBTiv2KcGvEfBLwxFPA3HHsQinCG"
    b"8gnz12gK+DYV+O8C/2Yn4D8k/CTgtzMB/ynh3yV/PsgXwl9wf4Xwe5A/Cm8K+FrCRwLe2An4u4S/CvjNTMA/JfyXgN9iHBzld4/7w3sqHwAHGTcsWgXBLchvaloYfxShhy2NQkWmmYl8vgr8XiTiN71E4Mv4C9Kj+EcZv7gV+AHuL2Q8CPHNnciVansC/0Pk"
    b"4lixwPcTbr/RyJK+Obn6FXdrip9k62fYbZpvBOPhitjqhvJvY8ucfs+j9p+057/wdAH7ROkDLBlw/F+poH8U9ANT0PcsHr/CSWL0Y0H/NuL0TUOcoWPuKqUfPsxk6DNi9NumoN/Gowqk3xT07ZnF6U8EfbIeRoy+K2PLDzS+AXdv5Bl+m9o2oP8g+m+9CPpd"
    b"2f9pxOlbXTn+hqC/E/TtnqS/FfTfBX3HE/R7a0F/YInxvxX0Q9n/oynoR3L8t4L+Nzn+74J+OxL0sbYGHf9IBvVwq4n0n+X4xzT+A3vhZCjj2R6nPxH0nZnN6UciKEjWy4TT3wn6T3D3CelbsaDf8QX9kei/VRP07zLpPImgPxf0u5GgvxL07RdJ3xD0dymn"
    b"byeCvm9K+geRLvMo6N/L/tdTQf9N0O+7gr4m6DvfBP07fyRPRn0+/1tB38KtGNLfCPkj/nTK9U/mCGD8DOkT/sVxLeoD0u+IGLc1pb4Beb8nx38acfrEfnBW77aC/k7qvy/ou4mg/xYJ+nVBv7cT9GN5bGwI+r7Uv2PC6VuGoB/MBP2DmH/nQ9Dvyv63Ek7f"
    b"8WX9HjQKSP9TxvifLG5/gpmg300jPv6moO+gUiB9Xcy/1bG4/Qtk/4eIj/Sl/e2kgn4ze2zO6fcTaX8FfiaXsmcIfN/KHJtzfEsuKrrETwR+Pxb4M4FPmuL2417mvN1FQ46/7chFsS3svwjKW/cCvy/xRxQfjZDAp+eyIfC7kvgnxIetUyDrHy0Tjm9HHZE+"
    b"sBb4kcXTl+yhwO/gNpjaz5TjO0ZHyN9W4N+IBGK7JvC9ZC4PuTi+ZYiTGn9H8aNc/aQRxYe764nwkA1Kvw0QgR82BX5oc3/DuRX4XZmWZ6Uxwzc9TwyV3+H4vi1aXaJvCfheshKiIvDJzCTC/gr8Z3Hgazn0vDp/CPKEoqSck3S2nfNzZMsown+NCvB7ZgG+"
    b"XYh/Sgvw+3EBPjFl6Tl+O5md49vGXdE5+EjP1Wyjz5k8WbPdEt/vRv7+Oa0/9Ceptczmy5LPsU6wyeraYZ1901rm82aHpO3ay+SZ06htZvXgZawP13PHA1xaKwxq1m2a6Uh/eJl3XKgVhnW9oK7e6GQqz21WM81aks9Xk9ED1MRb+urzprWORw8vCo2j8nwq"
    b"pukrzw+FNANTeX4qpFlTnvVimrHyPC+mmeafw3YhTUN5bhTTXCvPbskcEI8s397BL+7r4WweBt3i+Rp4Ko2SuXBPKo2guM8HdT78wVMJ7aFKo2ROXP2MRq2EdqrSeCmhnag0SubGbaiy6xf3++ir/X4t0ZFXlYZ3LKbtHc9o1Epoq/1+fSihHak0aiW0VX05"
    b"BiW6HCQqjXkJ7ZlKwyihrerNMSyW82Oo0jhZxbTP7Jd/KLE5B9U2ldiwky/7rS1G1gZl6ORpVI5bb+N3ab/md5t0/NQ8hE9kvNpETs9wvfro9LIksvVr/DbO6NpDY9Z5wjEN22CbGy/T56Ha7jGoNY2sjWaf1xg94wJPyjuF7efeUXkLXi2iT7GKo/tP8L61"
    b"nOrjt1mq9jc+sP7+jJ9rm/M229jfzJjvc2uQXsutNdOn3Jqyz60d5N2sTSLv1vLvxvl309y7Rv5daavHne57lif67CrPnvLsK8+R8jxUnmPleaY8J8oz4Y/W/Txi7U9eT570CWt01ruyBrusr57Fod/TZWbe1/E7vU/TToviJmcwnfgeS6UdWZf5vftr+oR1"
    b"xgvh4ns+oyyP1i+otzvTg+34mfzutOA7DF6IfGym7w8fhO9l/PywLuAFvns8SwfvKkFdezKPMKdLbJfdBYLv26A1sR9OObjefhuPrF/gm5km1sh9X6RVjdyqRm5VI1ckk1Y1cqsauVWN3KpGblUjt6qRW9XIrWrkVjVyzapGblUjt6qRW9XIrWrkVjVyqxq5"
    b"VY3cqkZuVSO3qpFb1citauRWNXKrGrlVjdyv/Ktq5P4mvKqRe/mouaqR+1vtVzVyzdwdor/e05KjaPOv9L+qkVvVyKXXgKsauVWN3KpGLsevauRy+a1q5FY1cqsauRn5qGrkVjVyqxq5VY3cjGtvmlWN3KpG7tn6W9XIrWrkVjVyqxq5VY3cqkZuVSO3qpFb"
    b"1citauRWNXKrGrlVjdyqRm5VI7eqkVvVyK1q5FY1cqsauVWN3KpGblUjt6qRy8evqpFrVjVyqxq5VY3c3NFPVSO3qpFb1citauRWNXKrGrlVjdyqRm5VI/f/jhq5//iPP3YvE71x88d//s8f2838j//840a7rS11bbao3dTmxnTZqk0ny5q2nEw0rWFMFrXJ"
    b"vDG5nTf1aW1eu11M5lpTXyyMpVFb3M6aiwWtu0sauq035re32q1xc9Oa1xaacbMwyGeL2vRGu1ne1JqLWUtfzOfzpbYkrbVmt5NJS681b3Ty6qTWJA0RjmgB38lksWjVbie300l9aky0WeumVZ/PFlpj0phPG0Z9uZg3bpaz1my6MCY39cVto7FskZeWjXrz"
    b"VtOzxYB/u61//OM//ueP98nbgjT24+f7f79NPv57tn17m2zX//3xY7FbvO//+/3nZvP/TVd7Qni2/fm+/+M/jf/4Y7labOY7OdTj96ef8dHaTfXWj+gx2fjONpk+t9N+Z60HdppEA2Pn2cNDuLI+gtfow8PPrVv7rbvy7evvh8k2Ic9Hz9ESmH4ijrupbTHR"
    b"OfyaQxsErztwadsmvn+C90F8iTgtQVQoXTO1VyZ5N0r6j9ZHrNdSojbv40drRfgHusd729z4KbZRK6I5f2vvRkQlevYwxXdX6ySK8H09S3P6ttlRWjNJS29svA5ROR34HQI9Hd6J3z14b0dgK/+YbILHNf37MfnAcSK/cRw63SPB0e5taxW/etveY5rEb96J"
    b"8FLrRR/0s8G25wFfAxPoSjNztE6T0cemP0iS2d3DcXaqTUePlgX0J+9P+xm26W/JOKa0Lfz7SObBom1aq9nK3MAcEZqk/5THgPEY2AmfqwMZ55bXGX+Mnw/rkT7fzJGf7tRva8lkEGtAk2yBNHzXBFrDDN8x8E1LMbfRNCGOZ2uHHF7y0SIk3+bPjVeP9G+q"
    b"7wfzO4/wbN54HWJunAMzY2RcXfcbztVgi23h36+Zv0/bhJud3iPKXbJIgS/z99tj/cIxuQNTCFcoU5R5Ins7snVEkyfk6RFkw8vKcu2yLMdlsoy8BFQ261+R5cAWsmwUy/K6RJZnQM+QsryWsny8KMt6gSzXz2XZ+6uyfMzIsnYmy6szWd74x3WPfXZD++yi"
    b"Xo/fNptph7juOpO/9i4dUVmB9o7jUYTvoi5AO4Pkxrtjy/lRtNUomcu9D+N+12W6su4to20va1uHnfbHbHVuL3vsN8he70/a2ku4/w52N8f/v5UNJjJ1Z2mzd7/1XNPO+8FtZz1g8mCh7ew/sjEqgIc5+AdRCJPzdfBtlGn8OyAykKP3SGWT9j+iekAMK+0f"
    b"scvYp0i1z2+T56fdmLixTO6155M1z8jBITgWrQEPyCdfAwgetTPEXWRyAu2jHAZpVh8S4L8mddJLv6RHr+a5HukvL7POMGvXQd53XjvYEjnb9Fco0ze0vbWw497dDnhIQf6IjhCZNJvU3luDSaedjv8N9YeNBV2fVjBfwa/pe0DWqMbH1JTrxuQ52KP7LunV"
    b"cL2Q+lC/FzZ3yGTHZbLjbgv8hyO3uUzXeuwzbidxfsd6sITQ6VT3k5m+uRkPtEOwslKyDp/6T7sNyJLsg5DJE5PJFGWStNMd+CXwlyz8c/5cSzlPRHep3uPf0Q2Xj4u+0LHAF1oV64Gf14P65XmnesLmYTOT83AIqLzWpQ67htBdapv0HtX/Uv0RMm53a8Rm"
    b"ah6TXf+xgPdXS+HdO5bwnvXzjsyvoXJK9JLxxfnRStZYQ66xgDfM+obcH0u8t+Bj9hbsxo/mirWnKzpQtOXdAl3i7/F2GA1cK2B7imF7sYbLLTng1Wg/4g8Bp7p3DIt839e5OmaNgv4eg1q2v9yn8AxKa416HqBfOpP2+OSWjEntY1b32Xj4xwJ6J/8p68NA"
    b"W36x7+1k+fHpHJ78HbYRZf3w8XGq16wZWZdmZHzJ2OpTfbOWtpPPd9m6aGb9OZvJPudJH4+6mudCGOxpTWgz3UDfkIaudDIPb81k3Nmc4pOm+3ahn1gT/T3mffLJ8/gl1p+W8Qj9RRzvHvMrme3lY/Nz8pxSu4k6snmdEhs7fRsSfWv9mmLbIO/RX7Gtp2Lb"
    b"Cnsbv8S2mpsQ+Zi/jkDeO61XIpcfi7dhK7S5vdzPyb4lb+eIPxkK20v8BLKfiR6FDT5esUlla9WBwbWidWj69lRHWtRuneg+CvY7mbWY7K9YG7Xi9fNJQ1/GzrZB1tG78a/Jc5T1U6Qed0QIaitxUIYPsBaiXyz8dYxDsHZmJfq1W2VtcymPzD4X87guabt9"
    b"IvjHuW29TPVdS9hjZQ8pQ2Wod0sqe7ieChjTkUOxvfcSIiu/Jidtlbfl2A8TYZqLeyc2Xllf5ajqj8oPyEQP3lud8aOV8gNljyQ/ZXvfY9bOl/L7OszxG3yR3+CcX6NsPREhUtzzURtN/TrvQHnwqd22z9psXGuzh+sJtlU/W6dOprJO0eNqxCHzP39rfYyZ"
    b"T0nXcWZ/eIj5aK5w7XrVcmtEgU/wg8nfyS/y6U9dZW3ztbM5qRE6sHelvv2J2kamg6dcrOOE9vT6HJ3Ox9PXy2QK/s7LlV8v6avB+1q4jp/UddxvXOtrmLVRp1m2r9o1feZ9Dc/0OSrT5x7jX/NXZW0TOXgLXuYO7IF8KqMn3AefqK2KaCzIcVXfRjvTdywj"
    b"Bv5QdORrPff57HfC+tuY+JN+Qn2u7iaux9d8ggLfw6XyrshFTPx+LHf2vN+IPQ2RCfz89WD1i/dfr2Sv9pO0sZsSHwXsc5ZvMh7KmkF8/ucGpHW8zmFOH0V8TCtstw59HC+JzYZ+4npO2x0W+w6rS77DUI1TwRp9Yj79gfn0Bzl+yV+IkYFPweIbKLNkT+y6"
    b"Yu+SsxvEtyLrEcZGfbbH91cl8IjBjwUxT72xmeOeymVrL+oHzEN2T83n71ASN93g/lms39hGmp9L98ra4erlcxhvcV/uukU+gJg/n455QVzJ1el6ORNzSN7lsRWwDR98v8zjk8Kff/0rcXvck6Q8VgPruIx14hpU5AvBPjjjCw3p2rXKrR1HGss/XzuoTljH"
    b"rH9yzXYL/+R8LSy13fO7+a/+o5fdm5XbiFecD9pHN3MmNWBr8HF9tgf7wh7RKFl7z/22lUVs67Al1ssy/eFwqj84VhE9w7DQN0b99w+9871Z0b70bfbW2tP2E7qe5u32qWwOiRzAHlHwG5Txy9u5zG8tz+/si/ye7aHZ2nvOr71icnBaX9uj19CPo74T36uj"
    b"DIQYh/BTdU4Dx/xKmyeGz9bziK6btP/GeZtumY+mwVol9AzilebZPnpAfA9ii6J/hzWzgAez/NyLrwE4biaOYYn9V/d/JzomDzwuCHFc6VMpcfEA4xuEPmkfeOXxjxmNf9Rk/I+OV6j6Y/rTbvwcwHxRGUJ5yu2BGiVxOUPEY+keviH27Y8iZqis3+6hIEZD"
    b"eHT1kYhB5Pfk8nyD7sULYgkHGndzj5n44EnGamHdFfFYNQZbK4nBGtmzC/SHlPMGFs+lf59yMQXjSsygcWEvzfagCY17HjP6I+mDjmr5MwsZ74A9WiBioWStez3LPRBxe7rXKVj3mEzQM+fM2mdf9IWOzLaqtvNIfReMQ2binPHXbCfsb5X4Y3D8kq0/hvbF"
    b"tekYXubXyNt684v8rs9sfdneVNp670u2ntoSj/pdrzO6z7TFOqqs336ZXT7l/J9iuxzFzxvQE/qePF/lspNekfHCPQaRwx/jR34mBDYNPjeayhkt5X9VaNdfyf7zhG0o+/+rfq79QuNu9Myr0G4zGkci+5Cu+AP6j/5cQY6CtEtxiX+M/lhN2qR4x+ORflm+"
    b"gJKTcB6PXP9TzlpDuWYYBWtGQ64ZyeVY6qn4nJXHRS/EVWtX5Ee/FFdlMVG6Xg2ifFw1P8/fsmdPV+KXNRH/y8Uvk5K13yuKb2bgfnavU3LeAHD3n3N+/tqW5+eDdcFZoHeQ8+ql2RjllXFhZzNKXLfsnOrdepmMvGTx1voh9zTXbD3qDMRY/oStz69NzNZn"
    b"bTmzYXJ+8+vP+ov2PDm356V7jZePuSPib4fzuBmOzVbunZNcXLA8npWPlflnsTL/9LVYc1HcUuVp/XfHKntiL3b8Svwuv7eh+xCvQfcmZvG+6npMsM7isplYrU/pFO3VHstigrgfuhITZGfq/0trKcsV+JY5NzzDjfXDr5k+pOtiVqeP5esh2xPRPJB/u/hg"
    b"xpYeh3D+nO1H49JapayNhsy3KLKxLyJHKczvGYBvg+dOwf4kXDEe/hXWTJ4XlGTymkrjkSx3ie65Tko80rgSjywb61M2Z+NyTsx+zvktmJ+j3xa+zSEoXCczeWSD9Vdih3pmT3bMxTQuxQ6pHirr4PCvr4OrkjXHzscNs3FBmQfG+5A/K5Rr5mE5h69c4Xkc"
    b"T+d5HChT7VZ9Wu+uWR7HcXQ5ZihjyDR/o8BHFnZcxpBPLs+ZUvLzMvFjurdR8vO8hpKfx2KC1LaMR660LScWK5Wxi9MXcr5PhXlOrxsl38+vl8RL2NmTl8kh9lneA+xRvAaza7XzXCZ6BlegF0T+ZK6YPxjPc3Kjyv5pI33E11mB/fIzvr9XtDc4kb3DIdjw"
    b"Ntb52APsbU5rOm7k78CJCvKDo1qZr8LP9QpisMxWSvsT2tk4d1QvkFEt2OwO2dyfwJGxc3rtBvoc6c+n7lw9BwwfC/NZar5dvF6RtjEfndp9lKmaT2WqzmUq5DJ1FDJV8wtkKnBelDPY4alEpmo0VhFl8nuHLPaV8Dhcg8mTIeWJ7mWVOJwWKrloQW5v+3TI"
    b"5BTT3EhHnv0EfH87gPsEkaHQbmRoG/8MWQ4GL0KWAycukGVYq7ksR/Wi2Cjpr5BlMn/5vS72g6/ZLuTE6oV3Hl6jknMSnqcX1wrOz5lPKPYmjezeJKD7JUVO49rzqZ21bzrbG+Xsd/D6NPVJn/K+eFxy1yFulMRUdepnxxlbFfP47kHktQ742Z6b8cFmRTFe"
    b"nawXuTy8gMa8CmRrhuf1wWvG9wM/HemJXPSDz/JQ8TM+F6eoYF2I6ygHctzq2Xy27LoQ0LMOPZuXFjB6cKYZvM54btqJ+56+1OU6nY/z/DSfyAg/14S1OL9uqnI7q0sfM64VyG2d5lCij8N4VXQDcjhAf2gb9fw5qgv7NcIr5R/6FTpegZ1OTlf2b0bwpb2W"
    b"x/OU6JpL7RW9t+OcxXaN8v1mts2E4tO8I536tgnmbIaOf97mqmz/ltQu7d+I3/sxXSV8jyTuSwk/JBdzKM4LzeZ3Mt8Mfb0hzbfI779WZ+2dnY9lz6Ny7dG7M7n2gnP++DqaeQ9zXrN3CPBKdPcu0vl9muix9I6APH8viXHH3Pct8p3U3NzjhfMFft9hJWKr"
    b"h9xcvbX38HV8watL7z24mTPiY/5+ULQSe66S3ERvldk/K/akreZHXTifFPnNIueV5hL/13+J67fV5dJ/7uXSwP53uVyKSbnqZoNexMgkKAWP1y9XiAujkXrRdPa1i6ZpddH0X/2iKcr1v8VFUwg2FV02JZ+/5g7K64UXYjaFl07r8tLpusBZ+Y3LctWl0/+1"
    b"S6d/v23+l790isFX9eIpbArClblliUEoJ4oNVy+j6upl1MJk7sFYvYzaOL+MOqPyaeYvZyuX6Q5f0y+3uoz6v3oZNfp/9DJqZo05Zn2nWMH7s/pTnggelgQNcvpD5+YQykDujgVGP9j6JZOvSjZMxAf7mIugftEGBA7yc7wfyzZOQVanXz16gEEPUA8sSCv4"
    b"KfYzVftRlsTcfZ2Muq/TzjARyWJfvYj0+OcvIvVEIKHg0hA92FfHzFAPB/zCS6wvuf7yi708oZb6pnhRv54JzpddKsLvpf9rF4suXjTmB9bMP/ayNheDARGhCxdJrx06F+h7mkt8ZHsQztP8DS/shRAgwMMiU9pcWneN7DHexr+8zsPHTPdbwatZmFA5z2+e"
    b"Mwdvm7f4OdgQu4lrqrI/1Ip9kOGlBCwt49efHz4fLx0+x9LuHL9y+Lz+i5dT1pnLKW7+csrqyuWU4+XLKRcTk2lQgiW2u8fSyymPlw6Do2wbStL05QPp3AU5eTk2ty8sKhxQcGnvENpfOLAu5rFR0vYLC+QRXyl7gGt+8QD3PGm19IKikshUdmGCXwTOJzF9"
    b"8cLEq3d+oPy1CxPH4PIFj2NwkV9PSbr64oWJsqIDVwPDboMVX9hlCjJQGXs9P1QPrwWbaQKYuFijJDilinzT2oUiCTgT2C0rYLCCtcuTl2lKDvknR+/Cwbd/LD74zh+g0ngOSwQ4+Rm99Y/5ROfhFy+1ROeXcFYXLuG+KRdxShL7Ftz3OSVFfa2rfS1I4lb6"
    b"mmT7Ws8dtDlfTOo+rc8vil5J6g6cLyV1n6iMiuSzHb00i4ckh/PLNn75ZZvrSd2PNJHrfycRLfq7ErnZhcV/1eTtP3mZRE0Myx+q5A8ozi4esVhe+eWogX+pQMSBrb3sEs1aPUdgbURfuFjJ2sgnRx2urB2HYHU14dAq8gEyl4KMsktB5UWDaLxFxpd4DCcf"
    b"S/yT80iLQNgi1okXb2Ss0ztdSrRmvhBLdPWUROuSBIN31AmyJ/ibE8zuHupTWayiftlGeEZJsQq2Bs/yCWhfSy4+hnbx2luY8Ez0WIzHyb2cvE+TEMou02KidWZvdvraZVpcT5XEuLIkEQv3iJLf4eXLBKf4Ir9Bnt/6F/nVz/lNivlNtqtsQtrVYiF4IQN8"
    b"yOzFpTW7uHRW8CH9Upun9e58DzxjhSiKi0gU+Whk7b90CE4P1cXlyH/9NfNKDLNkDUC5oXGNY7H9P0vIYGPCk1wgvil9KjXm93Qxvh48iUSWQyaBO2u/NtPO0yvO12PuIq3w4cricrQoiS/28KHct4sCkMr6fSgqBhewhMcoKtqTi7gt24sXxBJ4EQgZu0V7"
    b"L84Q+HnIShSpUM5+/2TBK9zbDzOx1FkuphBevsR5CC/s99ke1GCFH7L6U3QBVRSYlfGOIa494izv1btRi2IpBR0K1j0uE9T+ybUvulI4YVhsO1lcNMgllH65uF6tpLjedVv/euViGY1jlvKbT4D10y/y2zi39e41W3/8mq33MwleHrtgY4p1tOjCUuHe+eRd"
    b"t8v5ZKeyxKxSGS++/F97meClGOQZbBp+3i+8UPjPvliTP/srttuZQj0b4lcd4fIY+nOZIn1ndkm/WIAvOs8duFiA7/IZSeNLlzfOLuKqa4ZMUg/NwsurRvbyanks1b9RaCnF28vjqqX7lqh435KPq0bZCzJaPq6an+d/lQs3ZecN/Nz39+eUnVnRQhSNwos7"
    b"cl6PfvZyzZVxYcXjlLiuV3LJoJvCpVDv7iNbEPCarUedwaILX7f1ytp0XrRH5J2I+f3bC/dsJ6NILdxz6cKsUgDB+2KszD2/MHv8YnGe65d4G393rFIWZZh9rQDP41lRhtICPGxfdTUmyIrt5IrQUjpFe7V1aaGH8AsFeJSE4L93Lc1fNPynF67L5Vf8+8QH"
    b"L+RY8P1NyVqlro3y8mOj+PLqS/byar6wg50v7MB4+BdYM0W+Tzaf48plzSGL+efjkVcKwhzCy8XBaHHaogseRE4yZ7zycnHB5VNZpKEoh8bL5MjQdfJa7DBfpMH8YuyQ6qGyDtb++joYX7kE5dW/cAlKOSssuqzn1ZVLUJkiPsol1rNLUPmYodRxWqihwEcW"
    b"djxzYfMgihrmL2tm4sd0b6MWPg/PCpFHJRegfB4rzVyK/cKXVpzikkuxL/mzwWPZpVhWPM7MXIo98uL6WHA3n6su7dqprDD3n7v45Dekj+jVSy6fCh+xaG+AF1zFxSevkd8fwPmR36DjBn9HkMPM+eF90YLHyxetAyf+wkXrXGEPrfCinjNWLlpHRskl1rOL"
    b"1oGzLs5noXmxBetVZNALV+vMhU1T5M9RmVozmZKF94PCCzCRmktV80tkKqDnQlomb7HGYl+Geik2lDHVWlEuGlyKzeei5fa2uUuxdB2JMmc/fH+LFzm1UKUtZbkW2v8MWc4WiqCXcwsun3JZ1oKyC65CliNlr4v9qIX8EiJeTvQL8uJj7cpla72gaNv5Zevc"
    b"3iTWC+RUhzhp7oJnpiBB/hLr2WVrPb8uy9hFWPLFAwH1s/WMrdJ5fBf8rbNLmnJ+64Ux3rMvr5gdS2SrTs/r44zvNzsyeseCi7GZHNuZVnIxNn/p+jQsuxjLLj1m8tKgqDXSA98nrp9fjvUzl2NnJflpnpYpjoKx7uy6WXD5NBWXT6Piy6c8Z57xWnDBFfSH"
    b"tZHPq6cXbU8zxj9e0jwW2GmjbE/J92+hE/3VAqoa/Sw6i+2GzvArbRoUP6YxNnoGZtCLi8npvM24bP9mBI+X9m/4nepXC6dmL4me5YWa2fxO6psVFTLPxDzzl07V87HceVS2PVpkKt9eVNAeXUcvXsoVFz3ZfTLXLb/o+Xjtoqf7N1/05HOF32u8njvxgd1n"
    b"sDNykL8f53piz1USw1p5mf2zen9KzY+6dD7J85vvRc4r3t/4r+xXup6+/9h/T1LTNF0T/0XwwyP/Oyn9W/wbww+dv3fpn2O+8j89bAv/pV7K/5zBjzv4YQka1nJUf9gs7vJER7XW8OHpZVhGKjAN/mdC/qPttc0NYeKFdyhRkdot9j3e2Q8Jfe3BenLz/QtF"
    b"+1YkeG0nEfaS/Hu2Sadso3QoRtR2nOYK/Sf3KX7KvWl7Lh+f9s7in35a0HX/+pgD//R7id/jNEffjZ4erHynEjGeqRwdr53iB4Rcsic/+6Wk2vQ7oUf6w2qcXh6/T0sT/RPj5ydLPn4RjF3nQreAPQt/mD7Bf0twUm7Iz0c7KsHpf3fM4K61SHsf32PfXC+J"
    b"N9x7rz2nnY9m6pufv4aO+flDM9POJ7y+hh9d4NsethIC3/u22X8fWonTqEVb81tEYF2TyJP90I5sU/tpOu3PrXw/89xMA/PbMrqL+u81W3MaraRFnmu30ef79zS1H1IzWNZ+NR1zDvyFH99nef5a9ab9ufQds/ejZqa9z5bpW5/Q5y6O4QP83PRjAkd6OAJr"
    b"+Nkd1M3U/mymHtDvmEAf+IfnBfD342QCP+acwIf3hD/dgedDQPm7ef9OxoPxd2X8SH/dG9rfOzL/zeVj/b3x4wXoG6Y/oPwOavA8J7ztCb/tyRb0fYjjd9afIfRXNw/PnwGxL3ufdKz/Xsjv99GejA/hr0uaq31/Jm2Y61++Q+CaBe9He/J+3CfPrYVG+G8S"
    b"/memM2pNv0fp3cP30c79XGqOOb47DVP7o/W0sz6X81fz872xJPNB5YOM782l8Z8Bv5qZAL0Y6PXM/rpres7jExmPfbgG/sl4vH3a0N8NsXf3gw9r7TSMxO9+JmszCboj0p52E30Q/MSxJ9sR4Mvxi4iOOIfW7WL59kJMW3Cvjq8BzwsTxnftdHp0fDtm0fgm"
    b"wG/DPKw+NykZX9t0ysaXykMyIs+NDh1vMl4tGK9r4113yfM3C9pbT+n4P35813yLj3+aOjD+ZP50mL/M+KO8J+YhRH3cWE2iw3favvFtYkR5eWvB8/sQxhPlBcxvm9jIJPBUfUD5w/H/XNt8fj7pfBF5/NCI8dFSMlDfZl4n6oMV6N1/SX/J+Cbd+y/J5/fU"
    b"tzSCb968twC/WSP8L5+m5uS9viT69Rv6dH9Zn0h7pL9bsv5+IzhJ0EvAnhF79fT5HrXJ+JGBchop6FtExq5r2YAfETv7bei7VH7Dz+LxmA3o/BL7lYr5NUG+24TW+n5oC3vK+teekP4cFp9Sf7aqviSl+vLTBXu9Avyv8xNDf6KIjM2aiEvU31iW6zT+BD4u"
    b"JSC/MH9W770F9jE7fzGZv2+jpvMZqePvU/sA8gzjYcP64Q6Yfg/ZfGown+/EPjeX/t17g8gjsQdEvgl8Bu7GEN4/W59Mun61e1ubwsl4rVyQf/H+ph/B+L4Iej89kBfENxN4H+TBe5Hv43piwXh5wC9dL1agX1QfyQB27RrBfcjII6434LOs73yY75d8/yKk"
    b"9w34fVnD+DTI+w8RXz/p+jVsC3tFx4PgP33+jJzO5Mcr2Csy/wOY/zbXf5Anag8TkAcjEuOJ/GB70D57P8OfA/0D32j97II8rEAe2ml+Pc+M3xO8D7qxJjaH6McrzG8cEf149lyU18OEjU/M7Q/1B8A97MKks/H66YvxzPCL/W0n+fG4IJ9GG+zrwx7t0UPv"
    b"naxnfL3+xvyJ54/vQyK/WX9C94k92vwg9ud2mT5+eFJeGL28/cnML/KH/QOHvd2n9sdk9oetN+3C9SZi6/njJ8pbIuVNnW9PyAOMT3Y87+V6gPr0cUL9AHmg+jEo0g++fpP+DHLy//lhCXm3cD5PIM9i/CcZf+5FyrunyGvGfsUgHx0i3+uhy/h95OMF/QN5"
    b"/+yA/WlvyXrQVvVD1dcptLcg/IP+uTc/1ij/qT+i+gv2k40P1VfuLzyjvtyAvjyCvkxAXzq5/kQw/mPxPh3/L63/315A/nav1D4S+TK+sJ4/qvZFWd/JmoTyR+BepMiDlI8alT9Yv8mP/tsJ1i9TzpdsPySL1v1zYpP1Ikb5xPUPdhXDQv8e7OcnxZf6l7V3"
    b"Uj6Qvxf0L56L7Bv6Iy+Eatd5hvev2TfYiK3ByHbvcDzI/DL5hPll9Cn/Q0bv6dJ8nfkbBluvJu+tqGi9et45n8v9d6u3TpTxPyn+hqJ/TP6t1Bx+j6Q+RvD+7rI+Un/3A/xlXN/f1rg/wfYV++CmeX64/hF9yK1HZf7eRPh7b9LfW0j8SPQ3kvZ9IeeL6wvR"
    b"/2FW/7l9vKz/4Vf0n/v3g7x+5PWf6Hte/3tf0f+wRP/9v0n/cT/VQf0n+ykN9H8O/vwS91M3ZD/17btP9g/NX2S+yf7SafyJ9eekrD+oP7OU6jd5H/1fKS+q/0X931j4v13q/6K8KvaHjo/kZyXn00i4/hF5KfLHQP9X1L8G+WbyB/It8deyv9I/vpPrBZ3P"
    b"Icw/2Mb1oyJPdL/ZgP3ot8L96Bb0cQTj+0yG6tvT+p7sd2B/GbWIf0nlU8x/bv/4LSX+wa+1Y07O4glNgL8R+f42Xt8RfZraKegv+LNri/D/AfRiHL+dwu8a+L0Ffsl4FvAL+9HtGPDdlPD7sAN+B0B/Bvw+8PaePxsmyL/vdNB/egT/icuvTvWL+2+gL2hP"
    b"Y9AX3L8cjtnxjaH/d2be32umIP8RyH8N5f8F5H8G8m+g/D+A/G9B/m+7YG9t5n/hfpD7Xy0WL7E/vhN5oOMXSXthymdir03cT/P4BfiTRN/NyQ/6DPbChf1Y2zSJfxpFD2R/Wr6f4fvR/L9rMdroCnz2m/jX6O+uwOPfhA+vwNe/yf/6N+lfg6d/M/3tb/b/"
    b"d+HaZbAd/yb/u98cn2vyn/zm/Gx/s/3t38zfNf02fpN+8nWlvsZK4VGIPC+xvy6f91danX69f1/nv/97PS1RP/eKJhZ+2r7S6re/xMu1/kd/pf9X9NeR8mm/P/2cjB5E/Sr8wiR9r9R/4fn8/A4Xq9uRqWuxuMvex7a0ud5seZ3Wz/Ggxr7QM0ow7/FUy95B"
    b"SCadjdYf5fIxCU3CS727udeDX7O34U84S4v19mk88n/NCL+QXz1rw7lhbQ/8jepw/hxspu8Py+n7025qN1akT3vffqD3qjqHn9OBuYbaOw+j7pG0Te+TPfN6GV15J+EtkwP0nC1q/SALV79li1M/yDtZb5mc8mfIT2gAD3vC2yl+nkNR6WOgi7PwNFO0uXR+"
    b"x5TfActFtVT9ojkDTzbLHSgwJRZONkEcmKHz/fv35tAMX+H3k9nH52ezj8+OaafiVJr44c9S4slzAs+p0I/2uYrb5l1C9YTYF61PmjxEpo6/h6aBv2PzBn/PzCb8Jr6sL03Gk2nFchBS+twuXOo9ZuEj002dhLT0vW06W/wdOSn+ThwDfmcOcC3gK5D0BibZ"
    b"Jz9Jevh81i84NSdMWQD32fj5bPwCNn4BPo/Y+MZsfMdsfF3T4Y36hF8yjtbMfMnRjc2Oac9EdgDhk/ARm/epUH2Kl5gdVUoS+0/Mr7RvpD1x8Iz0ImuYow/zr85vG8j8mfkd0m0N7cJAjoMH9J/kYPv0mYxDqoxLO3UiwTQdlxGMX5FXZPZTC/MmyHsp4+/I"
    b"+NMYfzrjj/KbMH7XlF/yXi/LrxtJ+Qej2kmzz2S/m2T1hXQ2zT/3UtE/fCb9OeTkOyL9cTLjHtH+hRk8k8pLUwgxbYfoRQzKzZnl73XgIeLjxd4j7d6zNc2KxHtD+B3xzxE/gvdHbJ653o/Mu8iSek/sScTlhrQPcpt/Xstn7J/Lnnn/hmaQac8s1m+aR7Mm"
    b"cmFTfTZtg+m3yfTbw99EPuB3x3Ri/B1Re9BJqD3opMweSKcX7UCYm2czK5dD003yz500K6c4/itVTs/1l8x/ouD55lHiDel7zlrqIY6XkX8W82mL8YsUebFTS5UXX84rl5cx6de5vEDWTl5extDuXJUXJr8b2e6Y0X8m/bRK14XExDypL9inQLFPufnq5+x2"
    b"ZD4qzxPleSX1ZcD4fDJ7kTIfQ2lvoH9+lNfvQNH3MMrrtxlZef0m64fME3s6s08B6lUX+rNj9uknszsps09HZp80Zp90Zp+ovdoye7Vj9sqXTnnOvsL4WWbWvpNnLzueU2UdfMutw775Q3n+pbxvKM/N3HNMiLq5Z4c/C7turqUcM7tuS/nk62QHhjhS7f+a"
    b"zH/WbqF8DoieWtz/5e9hO14q2sX3gH5iJ6xdC55V+/OIeXlbsD9bZn+oHYmYHUqYHUqpHSL2J2L2J2b2J2H2B/HvTGqHMusuzkOUs0M5uzOQxhHnU1mv7UQ+D4FPLf/suPn3na3ybOSec3YGn7fKuBN934JxzPsticXfa7P3Jqa1I4uwPVTwJ+BE/cjZlS0k"
    b"OU7BrzHOP4/pvHh8nmfwHtobK7Iv+KGIcy+yEjN+tUymzKbUza5shjPQ9DLcin4PTv1n6+JLUbF/f3F3aDdL/edr+/mR8uGdMnh0XLWiwVue9c/Gvl0MfmEOrB8VdNrxlFcxbNxSPuympf7xhfGBpcbaFQXJVE/zHmPXydXxpXpyMQ5yKmof9ydKjq+JLqKl"
    b"EtGLInlBxJnM4s8oqfzHkCOadX4kfm78nCbg2dfjCerIf4cf86Jwh5cWxGNsZSgsu6h/UZF8oJ+e03R4bp+vv4nFRbjs36PIXM62vy0I6ln3Rf0bFPZPK+ofuqANFT8t8Z8umZ62XxC0pPs5NWj3FBVoYDsusCx0UfxQ8UGke8qr7e2Z/GtI5FKc2FqYBZnb"
    b"I+ino+gN2htb4drCLfS7GiRF/pTB6vgFjVrrM/lwE/uafKCfecbfusDCWHi29qripwXjh/sLWwn6W3uhpFmjfO5f75Sl7fzfnVdg7K1TUVAT5dlSiNwNC0yVpZesjxdNbe/MvrBgZfRn4uke4/viUvJocu8BgkiOtubr2QBdJ9vDVBjOsVMTLQ7wooENoYs9"
    b"BkE8It+2PuPy2UchsJYQSEf9gDiAre94+31cOSFIYfl7AdfQ2VsR/PtHoGiDUO5DoNhxgT+0s3DnYuAiHPn7BXDkv45jhPz7kYC70EMPUyO3sNyAvN0PYS5QP1oPAIf23YMHcNgX3c9SOCsF07A3EB/uaNQNgIP+9JcAt1b0oMDn/fNgepH/cepw/vcAh7ij"
    b"oxsAHwP/9whH/hoAh62HU98CHFzcgZW6LEjd8tC4kf/ddA3T8JpAaitcKKDj/4LwGNr3MPgE+AHALVD9lg7wDhlq9zQDOPZvkbi8/7cIh/6fDGwf+H9I2hx+B2wgPE2ADcQfpG1mD/dDgEMug11DOAjR/TPg43lMawpw0Bf3YCCc/H8/Anw0FS0Ub+LPmu4R"
    b"73esoX9jFF+Qp9YG4TAwR2wf5uB+EgF9WB/2PxBuQP9TgIOLSMa3zRyu/QHgngHzR/mD/i0RH8fPAjZRfjUP2PTwTCHtUEqW7wIcAI42hF8dqh8dtgru7xEf2tc0xAf5GCAc5aNvxnSoiP4AHIgO2qbAfxb4ZPwSql/956hDNd7yFwDv+ihfAF9B/+fAH+YG"
    b"7G8QDqkf9RTgG4Avgb4NqrBvwzBS/YlhGFF/rPSOy18IcGDKrvkAx/l5SgAOqr2fCfyaJvDvEoG/QXyYfx3bB9evP4b2Ycts+Z8I9wCeAryH+h/d0UNIy09xmgFedwGO8j1DfFgfWhrA7S2V35TN/wLWIDr/NwDH+a/vAI7z3wf+6PwjAp0fz2b2i8yvx8e3"
    b"C3Ac35oLcJSPpwQYAlb3nwgHB0/XAL6B8ZlBwjuVfw3hCY4/wN8AHiVdrj8OaATVn8jm+vOYdlkuy94HuI32VwP4PdrXpMv5HwCcysfQZvLdf0L4Avgfo8YBO7UdwHH8RlGXrRitBcBxV3H0bS7/Y6Tfo/ZnzfpH+I9Y/5bQPp1/nKYuzIE2s7n9e4RppPav"
    b"C3C0fzXccVP9j3q8f1OAd8C+1VKOP7hDOMrPG7aP8oPt3ye4fgBvP6n8bIX8APyOyk+P2geQny3tKpEfgDP56TF/m8jPlmoakR+AW2j/oH0uP1shP9g+lZ8eE5U9ethcflIhP/dSfnZSflIhP/d8fH8hHPlDfBzfOUwzHV8d4TC+dc1m60N/CfjWBtr/jvRx"
    b"fdw6zIkl9tfn4/sA3QT/yql5AJ/g+ohwj+pvyu2zBnAfxneUwNp0hPYThOP4Ij7sr/ox4EMcxvLfcBjBvuhIH9fvCcDp+r0DOPJXdwX+LBH4usCvS/yFxG8KfM2FkwzEh68mYvh3GA4CfG3nsPW9P4DXKH4AcCp/HsBxfoZpwOdnAnBmPx0p/wGfHwPbBxtd"
    b"XztsH0HWx4C5RvtbhK9RPwCOMhqlIdtftlzwvZwY10dwewHQf4xC6pTxRALYmhox34o5r2IrFD6KrUgjEa7YO/4J92VDdMpw640Jjrj1dXYifhDqwvW/TfnWyklwHwf7/9CDEcGtlYHnEuBfOhtUAwhhhhOEa9STBtkE/A/Eh6OYcAdwB7pxi64I7H+dn4hf"
    b"B/g3hAOXBl6UhaMZZ4X7BAg9hBEMowP9b8QAjwD/Hf0vEIdwBXAX+n+D928fAP8H4Ftgw0IN4dDhW/TfBhFuLwiuBa5pCPmzZhv6b6QgSkPAXycAh/hyGCMc+t9A/+s5wv4BfErHD+AabZ/ARwny7zInP3xD/8jH8bfYpDg/EQ4h4bCH/lGS88GdDQ/JmeHW"
    b"5F42nR+g4bwlPM4T/jS5q2fgSSy6GlvgD01dSA+TEko/Yq7ET/QvQH7DEGE77J/NnArnAwmCDIe4fiFvGf5eRD5GiJs5DH0aIuTlvCZ8mxI+CHgj4kfrzpuIP4ToyjvQtUaT56M425QLffgu4FR+TTq/gI/9Pwj47VDg/4wEfkvADZOdkwD/5JfVofy7HL4D"
    b"OOK/Yjwb8QcC3oi5K03HH+P94VzAb1yB/xEJ/A8J1wR8J+E1Ab9dC/gvZBP5w7nH+Ijhw9gh/AVdBcS/R/1A/psCvpbwkYA3dgL+LuGoP+hD3aB+gVFxPiMB3wv8W1fg7yW8IeGagCeRw+EuRiBQhnCpGKB+pALeBzjlzwc44m8kfCrhTQHfSvgbtr+m8pFS"
    b"TXB+SPoHgX87FPg/Jbwl4IZrcfl5gf0PhaPRQh/BQKEYJigfrpSPiPM3E/hvEr4U8BtfwD8kHC/oof7d4P7picqHK+UjEvIh8H9JuAU9pvxjfQDU3xXsf6xnKh9Drp+4f4I1iNi3Nos/hU8Cv4H7G1iDiH0F+ITyL9q3qCrlYwI0e6BpUSeIhy62VBUj08wE"
    b"VV8EflfGMOgRLuDbMpOENor4ExnB+i7w7xPBxGMq8DURVmkPBf6rTE+R9O/Tbi5eRPF9kZ5zFwv8mjxOamb6L4636VIM+KYvwlZdie8Ju0nPk5wE9/sDEQSn4wf6ZAj8e43SgHjAA++/E1L6HgSVBH0dcQyIBwSifkO4o/QTGD9OHwIcjD7c/ZBBOUbflmE3"
    b"C+0T0n+TuYwbKoqQG54I+j6KItIfC/quZ3H6O1m/IkR8oN+T9Ecpp+94gn5nJ+jD3REx/px+KPu/MgX9VNDvrgX9b3L8N4L+/VDQ3yecvhk5Ig3BE/R/CfrOUNC3E3Fcbsj+fxf0+76gH2U1IGH0fTn/LmwVkb4VC/oW8oP0T2L+iT+VMPp38ri+j/hAH+4u"
    b"iUxKm9NfycyWuaAfGIL+NOX07UTQv0sF/caB07dDQf9e9v8tFfR3gn5PE/Q1Qd++EfT78UAe0nD6zlbQD9aCfkvQd34I+plo5jdT0DcEfRO3Cki/I6OlI/QdkP56IOOlPp9/admc2OH0rRdOysL4HNJ3k0jG+31G39yJWG9nJujHVuYQj9N3YpFI+JJw+pYh"
    b"6Hd9QT96iKT8cvpd2f9dwulbnbZUSkH/U9B3HgR9VxP0jZTTd2S0t28K+k+Cvmlb3P4Esv9OGnH6C0HfxgMnpN+U4//T4vanI+u/0EMlHH9PpIO5msvpz0Tg3VoK+rb5IA9RBf0bQf/OEPRDSxzT3wv6nifov0ecvhUJ+r2toL86iPFvCvqdRNA/Rpy+3Rf0"
    b"g52gnwj6zlbQ78rx/5Zw+nYs6JuzNqf/Icd/bHH7cy/738WhpPZP0HeabU7/KOhbA0vYPzn+E4HvZNJRXYFvi7QWW+L7O4H/iR4Xjp8n0ivuE4G/EvhOV+AHMoHaiAT9WNDvrzP8i2Np3xL2S46fF8VSfrj+O26Hj19d6u+dlQj9FfqP8VMT5MXZSv31O9S3"
    b"gh+clPWT0odFPRG5R4tI4Mdtkb4UCfyhyH2x+wK/J3M/3xKOb8YiF7c3FPgz4dTYqcD3k7FQqpTj21FHpMPFAl8Tx+7Oo8C35bFqXdC3EnEsHm4F/kKkxTi6wO9mjmUTjA1APHwrj9UN3HvCfGsC35xYaH+GsGjNpfxyfCu6E/6fJ/A/pVv5TeBnch8eJf34"
    b"Tqx/scD3xcG6tRL490kiz/sEfdPj/N9tBf5RHIvadwK/LdMTMX5N6RsiXbXnCnzDFvrzU/KfvMr5m52fs/kYv1bO+RzkXz3Ha5oF+CZc4Ds7JxzaBeeAPbjQp+K7RfjWYxF+nBTg33kF+PZ9Ef62CP8+KsB37orw9SL+Q6Oo/w5G3NVz0HYrd4+BPf8cj+bt"
    b"2Xv31yyxlux75syRLr7/k/+N3x9AcLJ1ek32/XLsXkPEn/H7Mcm7udqG4hnuNxBatJ4hva8BvJD2OU/5ew4p1CwVtQoJDVkDEOqjYS02uD+yaaYj/eFl3nGhFhvWTYNaf6OTqTy3WU06a0k+h/sdUD9w6avPm9Y6Hj28KDSOyvOpmKavPD8U0gxM5fmpkGZN"
    b"edaLacbK87yYZpp/DtuFNA3luVFMc608uyVzQFasfHsHv7ivh7N5GHSL52vgqTRK5sI9qTSC4j4f1PnwB08ltIcqjZI5cfUzGrUS2qlK46WEdqLSKJkbt6HKrl/c76Ov9vu1REdeVRresZi2dzyjUSuhrfb79aGEdqTSqJXQVvXlGJTocpCoNOYltGcqDaOE"
    b"tqo3x7BYzo+hSuNkFdM+s1/+ocTmqPbwVGLDTr7a71NQQlu1Y75WQltTaZTYslNwRmNcQlu1Z369hHZd0nhozDpPREc2KEf+YLyc6uO3mZQxbUHWG9SZk6fl9ZPhEhkI27CWtN7G77L/87tNOn4iMlNrGqMTW5MitV2vPjq9LDP6xD6PU/i8GAdgiUpHD56I"
    b"TUjO3qW2Btoq7FcGXkyLwc/p+U/QZ1xbC2HqOAWvXTq+F+hk5n6fW4f1Wm69nT7l1tV9bv0k72btMnm3ln83zr+b5t418u+u8zwMFJ4GrvLsKc++8ixt0rjTfc/2kT67yrOnPPvKs9reUHmOleeZ8pwoz2uVHzmPnYfVuJZbb9fx2zzXZ4ZzUnFgPrAubR2+"
    b"h0bW+CfvQTtL+O4T+R3Ewa/pW/Ayz+LUaW3u7PvsO8l20zr4kVhfF2p543e0zN/aO0Kj5H1Kq5i2/P7jLHzyPH6J9adlPPLPaMHd3gI6mzz/hd8HnW3r/Lsdo+yYZb6/tuBz9v2H2fay399e8jnYul2OB3avmH9PUgEsMv/4jz/eF2lVo7qqUV3VqBbJ71WN"
    b"6qpGdVWjuqpRXdWormpUVzWqqxrVVY3qqkZ1VaO6qlFd1aiualRXNaqrGtVVjeqqRnVVo/qL+FWN6t+DVzWqf4//qkb17/FX1agu+FfVqP4r/6oa1VWN6qpGdVWjuqpRXdWormpUi/GralRXNaqz81XVqK5qVFc1qrPrdVWjuqpRbVY1qpUPqxrVZlWjmuJX"
    b"NarNqkY1xa9qVJtVjeqqRnVVo7qqUW1WNaqrGtVVjeqqRnVVo7qqUV3VqK5qVFc1qqsa1VWN6qpGdVWjWuBXNaqrGtUiHlnVqK5qVFc1qqsa1VWN6qpGNZe/qka1WdWormpU5z3tqkZ1AX5Vo7qqUV3VqK5qVFc1qqsa1VWN6qpGdVWjuqpRXdWormpU/3aN"
    b"6n/8xx+7l4neuPnjP//nj+1m/sd//nEzu72ta/XFsq7PFvq8Pp9PWsubm5tFa7GcT5a3LaOla4ubaX02W97Mb43J9LY2uzUW9UldnxuNJq17DQ3pDX0+aRoLgnxTby6MuaHPpouaoU1ua41afWa0tMZsPp1OplPNmN/qxoS83dIWt8vpbNGakIYIR7SAtq7p"
    b"s1prOpsvlovGvN6c35Lm6rXFbDKt1+o388mspRvzxk2zbsyWy5tGQ5sumovJoknmf1pbtLLFuH+7rX/84///P31+BVA="
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
    # Synthetic typed graphs isolate boxed and exploded returns from ABI selection.
    for prefix in [b'', b'%1, %3, ']:
        case = dict(cases[0], name='physical string return', count=1)
        for key in ['old', 'new']:
            raw = case[key].split(b'\n\n', 1)[0] + b'\n'
            raw = raw.replace(b') i64 {', b') string {', 1)
            raw = re.sub(rb'(field_get %[0-9]+\[0\]) i64', rb'\1 string', raw)
            raw = raw.replace(b'const_int i64 -1', b'field_get %0[16] string')
            case[key] = raw.replace(b'ret %', b'ret ' + prefix + b'%')
        cases.append(case)
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
    case = cases[4]  # Authentic whole string-keyed input and its own object witnesses.
    changes = [
        ('string slot arity', b'map_slot_str(%0, %1, %2)', b'map_slot_str(%0, %1)'),
        ('string slot pointer type', b'%1: i64', b'%1: bool'),
        ('string slot length type', b'%2: i64', b'%2: bool'),
        ('string slot map type', b'map<string, Obj>', b'map<i64, Obj>'),
        ('string slot map source', b'map_slot_str(%0, %1, %2)', b'map_slot_str(%3, %1, %2)'),
        ('string slot symbol', b'map_slot_str(', b'map_slot_other('),
        ('string slot result type', b'map_slot_str(%0, %1, %2) i64', b'map_slot_str(%0, %1, %2) bool'),
        ('string slot zero', b'const_int i64 0', b'const_int i64 1'),
    ]
    for label, old, new in changes:
        altered = dict(case, name=label)
        for key in ['old', 'new']:
            assert old in case[key], (label, key)
            altered[key] = case[key].replace(old, new)
        protocol_refuses(wire(thread_fixture_envelope(altered, case['queries'])))
        answer = thread_fixture_parent(altered)
        assert (answer.returncode, answer.stdout, answer.stderr) == (1, b'', b''), label
    altered = dict(case, name='string slot guard order')
    for key in ['old', 'new']:
        raw = thread_refs(case[key], lambda v: {6: 7, 7: 6}.get(v, v))
        guard = b'  %7 = icmp_sge bool %4, %5\n  %6 = rt_call map_val_at(%0, %4) Obj'
        assert guard in raw
        altered[key] = raw.replace(guard, b'  %6 = rt_call map_val_at(%0, %4) Obj\n  %7 = icmp_sge bool %4, %5')
    protocol_refuses(wire(thread_fixture_envelope(altered, case['queries'])))
    answer = thread_fixture_parent(altered)
    assert (answer.returncode, answer.stdout, answer.stderr) == (1, b'', b''), altered['name']

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
    case = cases[-1]
    changes = [
        ('missing return word', b'ret %1, %3, ', b'ret %1, '),
        ('extra return word', b'ret %1, %3, ', b'ret %1, %3, %3, '),
        ('reordered return words', b'ret %1, %3, ', b'ret %3, %1, '),
        ('different same-typed return value', b'ret %1, %3, ', b'ret %1, %1, '),
        ('wrong return word type', b'ret %1, %3, ', b'ret %0, %3, '),
        ('undefined return word', b'ret %1, %3, ', b'ret %999, %3, '),
        ('changed return value type', b'field_get %14[0] string', b'field_get %14[0] i64'),
        ('changed return terminator', b'ret %1, %3, %15', b'unreachable'),
    ]
    for change in changes:
        altered = thread_fixture_change(case, *change)
        protocol_refuses(wire(thread_fixture_envelope(altered, case['queries'])))
        answer = thread_fixture_parent(altered)
        assert (answer.returncode, answer.stdout, answer.stderr) == (1, b'', b''), altered['name']
    case = cases[0]
    thread_fixture_packets(thread_fixture_envelope(case, case['queries']))
    thread_fixture_interactions(cases)
    thread_fixture_literals(case, case['queries'])
    thread_fixture_driver()
    print('nonnull map guard proof: 6 authentic pairs, 11 heads, physical returns, string slots, strict mutations and protocol passed')

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
