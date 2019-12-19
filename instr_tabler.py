# Hacky script that parses an instruction table and outputs some Zig code to handle the instructions

# TODO There's a bug in the zig compiler that makes it impossible to call
# non-async function pointers from inside of an async function.
# Until that's fixed, things like AHX/SHA will have incredibly ugly implementation,
# and pretty much all read-write operations will have needlessly long implementations.
# https://github.com/ziglang/zig/issues/3656
# ^ NOTE on above -- I patched the compiler to allow this to happen, but I still
# haven't gone back and fixed the ugly code that was necessary to work around the bug.

import bs4 as bs

html = """
<table>
<tbody>
<tr valign="top">

<td style="background:#FCC">BRK<br></td>
<td style="background:#CFC">ORA<br>(d,x)</td>
<td style="background:#CCF"><b>STP</b><br></td>
<td style="background:#DDD"><b>SLO</b><br>(d,x)</td>
<td style="background:#FCC"><b>NOP</b><br>d</td>
<td style="background:#CFC">ORA<br>d</td>
<td style="background:#CCF">ASL<br>d</td>
<td style="background:#DDD"><b>SLO</b><br>d</td>
<td style="background:#FCC">PHP<br></td>
<td style="background:#CFC">ORA<br>#i</td>
<td style="background:#CCF">ASL<br></td>
<td style="background:#DDD"><b>ANC</b><br>#i</td>
<td style="background:#FCC"><b>NOP</b><br>a</td>
<td style="background:#CFC">ORA<br>a</td>
<td style="background:#CCF">ASL<br>a</td>
<td style="background:#DDD"><b>SLO</b><br>a</td>
<td style="background:#FCC">BPL<br>*+d</td>
<td style="background:#CFC">ORA<br>(d),y</td>
<td style="background:#CCF"><b>STP</b><br></td>
<td style="background:#DDD"><b>SLO</b><br>(d),y</td>
<td style="background:#FCC"><b>NOP</b><br>d,x</td>
<td style="background:#CFC">ORA<br>d,x</td>
<td style="background:#CCF">ASL<br>d,x</td>
<td style="background:#DDD"><b>SLO</b><br>d,x</td>
<td style="background:#FCC">CLC<br></td>
<td style="background:#CFC">ORA<br>a,y</td>
<td style="background:#CCF"><b>NOP</b><br></td>
<td style="background:#DDD"><b>SLO</b><br>a,y</td>
<td style="background:#FCC"><b>NOP</b><br>a,x</td>
<td style="background:#CFC">ORA<br>a,x</td>
<td style="background:#CCF">ASL<br>a,x</td>
<td style="background:#DDD"><b>SLO</b><br>a,x
</td></tr>
<tr valign="top">

<td style="background:#FCC">JSR<br>a</td>
<td style="background:#CFC">AND<br>(d,x)</td>
<td style="background:#CCF"><b>STP</b><br></td>
<td style="background:#DDD"><b>RLA</b><br>(d,x)</td>
<td style="background:#FCC">BIT<br>d</td>
<td style="background:#CFC">AND<br>d</td>
<td style="background:#CCF">ROL<br>d</td>
<td style="background:#DDD"><b>RLA</b><br>d</td>
<td style="background:#FCC">PLP<br></td>
<td style="background:#CFC">AND<br>#i</td>
<td style="background:#CCF">ROL<br></td>
<td style="background:#DDD"><b>ANC</b><br>#i</td>
<td style="background:#FCC">BIT<br>a</td>
<td style="background:#CFC">AND<br>a</td>
<td style="background:#CCF">ROL<br>a</td>
<td style="background:#DDD"><b>RLA</b><br>a</td>
<td style="background:#FCC">BMI<br>*+d</td>
<td style="background:#CFC">AND<br>(d),y</td>
<td style="background:#CCF"><b>STP</b><br></td>
<td style="background:#DDD"><b>RLA</b><br>(d),y</td>
<td style="background:#FCC"><b>NOP</b><br>d,x</td>
<td style="background:#CFC">AND<br>d,x</td>
<td style="background:#CCF">ROL<br>d,x</td>
<td style="background:#DDD"><b>RLA</b><br>d,x</td>
<td style="background:#FCC">SEC<br></td>
<td style="background:#CFC">AND<br>a,y</td>
<td style="background:#CCF"><b>NOP</b><br></td>
<td style="background:#DDD"><b>RLA</b><br>a,y</td>
<td style="background:#FCC"><b>NOP</b><br>a,x</td>
<td style="background:#CFC">AND<br>a,x</td>
<td style="background:#CCF">ROL<br>a,x</td>
<td style="background:#DDD"><b>RLA</b><br>a,x
</td></tr>
<tr valign="top">

<td style="background:#FCC">RTI<br></td>
<td style="background:#CFC">EOR<br>(d,x)</td>
<td style="background:#CCF"><b>STP</b><br></td>
<td style="background:#DDD"><b>SRE</b><br>(d,x)</td>
<td style="background:#FCC"><b>NOP</b><br>d</td>
<td style="background:#CFC">EOR<br>d</td>
<td style="background:#CCF">LSR<br>d</td>
<td style="background:#DDD"><b>SRE</b><br>d</td>
<td style="background:#FCC">PHA<br></td>
<td style="background:#CFC">EOR<br>#i</td>
<td style="background:#CCF">LSR<br></td>
<td style="background:#DDD"><b>ALR</b><br>#i</td>
<td style="background:#FCC">JMP<br>a</td>
<td style="background:#CFC">EOR<br>a</td>
<td style="background:#CCF">LSR<br>a</td>
<td style="background:#DDD"><b>SRE</b><br>a</td>
<td style="background:#FCC">BVC<br>*+d</td>
<td style="background:#CFC">EOR<br>(d),y</td>
<td style="background:#CCF"><b>STP</b><br></td>
<td style="background:#DDD"><b>SRE</b><br>(d),y</td>
<td style="background:#FCC"><b>NOP</b><br>d,x</td>
<td style="background:#CFC">EOR<br>d,x</td>
<td style="background:#CCF">LSR<br>d,x</td>
<td style="background:#DDD"><b>SRE</b><br>d,x</td>
<td style="background:#FCC">CLI<br></td>
<td style="background:#CFC">EOR<br>a,y</td>
<td style="background:#CCF"><b>NOP</b><br></td>
<td style="background:#DDD"><b>SRE</b><br>a,y</td>
<td style="background:#FCC"><b>NOP</b><br>a,x</td>
<td style="background:#CFC">EOR<br>a,x</td>
<td style="background:#CCF">LSR<br>a,x</td>
<td style="background:#DDD"><b>SRE</b><br>a,x
</td></tr>
<tr valign="top">

<td style="background:#FCC">RTS<br></td>
<td style="background:#CFC">ADC<br>(d,x)</td>
<td style="background:#CCF"><b>STP</b><br></td>
<td style="background:#DDD"><b>RRA</b><br>(d,x)</td>
<td style="background:#FCC"><b>NOP</b><br>d</td>
<td style="background:#CFC">ADC<br>d</td>
<td style="background:#CCF">ROR<br>d</td>
<td style="background:#DDD"><b>RRA</b><br>d</td>
<td style="background:#FCC">PLA<br></td>
<td style="background:#CFC">ADC<br>#i</td>
<td style="background:#CCF">ROR<br></td>
<td style="background:#DDD"><b>ARR</b><br>#i</td>
<td style="background:#FCC">JMP<br>(a)</td>
<td style="background:#CFC">ADC<br>a</td>
<td style="background:#CCF">ROR<br>a</td>
<td style="background:#DDD"><b>RRA</b><br>a</td>
<td style="background:#FCC">BVS<br>*+d</td>
<td style="background:#CFC">ADC<br>(d),y</td>
<td style="background:#CCF"><b>STP</b><br></td>
<td style="background:#DDD"><b>RRA</b><br>(d),y</td>
<td style="background:#FCC"><b>NOP</b><br>d,x</td>
<td style="background:#CFC">ADC<br>d,x</td>
<td style="background:#CCF">ROR<br>d,x</td>
<td style="background:#DDD"><b>RRA</b><br>d,x</td>
<td style="background:#FCC">SEI<br></td>
<td style="background:#CFC">ADC<br>a,y</td>
<td style="background:#CCF"><b>NOP</b><br></td>
<td style="background:#DDD"><b>RRA</b><br>a,y</td>
<td style="background:#FCC"><b>NOP</b><br>a,x</td>
<td style="background:#CFC">ADC<br>a,x</td>
<td style="background:#CCF">ROR<br>a,x</td>
<td style="background:#DDD"><b>RRA</b><br>a,x
</td></tr>
<tr valign="top">

<td style="background:#FCC"><b>NOP</b><br>#i</td>
<td style="background:#CFC">STA<br>(d,x)</td>
<td style="background:#CCF"><b>NOP</b><br>#i</td>
<td style="background:#DDD"><b>SAX</b><br>(d,x)</td>
<td style="background:#FCC">STY<br>d</td>
<td style="background:#CFC">STA<br>d</td>
<td style="background:#CCF">STX<br>d</td>
<td style="background:#DDD"><b>SAX</b><br>d</td>
<td style="background:#FCC">DEY<br></td>
<td style="background:#CFC"><b>NOP</b><br>#i</td>
<td style="background:#CCF">TXA<br></td>
<td style="background:#DDD"><b>XAA</b><br>#i</td>
<td style="background:#FCC">STY<br>a</td>
<td style="background:#CFC">STA<br>a</td>
<td style="background:#CCF">STX<br>a</td>
<td style="background:#DDD"><b>SAX</b><br>a</td>
<td style="background:#FCC">BCC<br>*+d</td>
<td style="background:#CFC">STA<br>(d),y</td>
<td style="background:#CCF"><b>STP</b><br></td>
<td style="background:#DDD"><b>AHX</b><br>(d),y</td>
<td style="background:#FCC">STY<br>d,x</td>
<td style="background:#CFC">STA<br>d,x</td>
<td style="background:#CCF">STX<br>d,y</td>
<td style="background:#DDD"><b>SAX</b><br>d,y</td>
<td style="background:#FCC">TYA<br></td>
<td style="background:#CFC">STA<br>a,y</td>
<td style="background:#CCF">TXS<br></td>
<td style="background:#DDD"><b>TAS</b><br>a,y</td>
<td style="background:#FCC"><b>SHY</b><br>a,x</td>
<td style="background:#CFC">STA<br>a,x</td>
<td style="background:#CCF"><b>SHX</b><br>a,y</td>
<td style="background:#DDD"><b>AHX</b><br>a,y
</td></tr>
<tr valign="top">

<td style="background:#FCC">LDY<br>#i</td>
<td style="background:#CFC">LDA<br>(d,x)</td>
<td style="background:#CCF">LDX<br>#i</td>
<td style="background:#DDD"><b>LAX</b><br>(d,x)</td>
<td style="background:#FCC">LDY<br>d</td>
<td style="background:#CFC">LDA<br>d</td>
<td style="background:#CCF">LDX<br>d</td>
<td style="background:#DDD"><b>LAX</b><br>d</td>
<td style="background:#FCC">TAY<br></td>
<td style="background:#CFC">LDA<br>#i</td>
<td style="background:#CCF">TAX<br></td>
<td style="background:#DDD"><b>LAX</b><br>#i</td>
<td style="background:#FCC">LDY<br>a</td>
<td style="background:#CFC">LDA<br>a</td>
<td style="background:#CCF">LDX<br>a</td>
<td style="background:#DDD"><b>LAX</b><br>a</td>
<td style="background:#FCC">BCS<br>*+d</td>
<td style="background:#CFC">LDA<br>(d),y</td>
<td style="background:#CCF"><b>STP</b><br></td>
<td style="background:#DDD"><b>LAX</b><br>(d),y</td>
<td style="background:#FCC">LDY<br>d,x</td>
<td style="background:#CFC">LDA<br>d,x</td>
<td style="background:#CCF">LDX<br>d,y</td>
<td style="background:#DDD"><b>LAX</b><br>d,y</td>
<td style="background:#FCC">CLV<br></td>
<td style="background:#CFC">LDA<br>a,y</td>
<td style="background:#CCF">TSX<br></td>
<td style="background:#DDD"><b>LAS</b><br>a,y</td>
<td style="background:#FCC">LDY<br>a,x</td>
<td style="background:#CFC">LDA<br>a,x</td>
<td style="background:#CCF">LDX<br>a,y</td>
<td style="background:#DDD"><b>LAX</b><br>a,y
</td></tr>
<tr valign="top">

<td style="background:#FCC">CPY<br>#i</td>
<td style="background:#CFC">CMP<br>(d,x)</td>
<td style="background:#CCF"><b>NOP</b><br>#i</td>
<td style="background:#DDD"><b>DCP</b><br>(d,x)</td>
<td style="background:#FCC">CPY<br>d</td>
<td style="background:#CFC">CMP<br>d</td>
<td style="background:#CCF">DEC<br>d</td>
<td style="background:#DDD"><b>DCP</b><br>d</td>
<td style="background:#FCC">INY<br></td>
<td style="background:#CFC">CMP<br>#i</td>
<td style="background:#CCF">DEX<br></td>
<td style="background:#DDD"><b>AXS</b><br>#i</td>
<td style="background:#FCC">CPY<br>a</td>
<td style="background:#CFC">CMP<br>a</td>
<td style="background:#CCF">DEC<br>a</td>
<td style="background:#DDD"><b>DCP</b><br>a</td>
<td style="background:#FCC">BNE<br>*+d</td>
<td style="background:#CFC">CMP<br>(d),y</td>
<td style="background:#CCF"><b>STP</b><br></td>
<td style="background:#DDD"><b>DCP</b><br>(d),y</td>
<td style="background:#FCC"><b>NOP</b><br>d,x</td>
<td style="background:#CFC">CMP<br>d,x</td>
<td style="background:#CCF">DEC<br>d,x</td>
<td style="background:#DDD"><b>DCP</b><br>d,x</td>
<td style="background:#FCC">CLD<br></td>
<td style="background:#CFC">CMP<br>a,y</td>
<td style="background:#CCF"><b>NOP</b><br></td>
<td style="background:#DDD"><b>DCP</b><br>a,y</td>
<td style="background:#FCC"><b>NOP</b><br>a,x</td>
<td style="background:#CFC">CMP<br>a,x</td>
<td style="background:#CCF">DEC<br>a,x</td>
<td style="background:#DDD"><b>DCP</b><br>a,x
</td></tr>
<tr valign="top">

<td style="background:#FCC">CPX<br>#i</td>
<td style="background:#CFC">SBC<br>(d,x)</td>
<td style="background:#CCF"><b>NOP</b><br>#i</td>
<td style="background:#DDD"><b>ISC</b><br>(d,x)</td>
<td style="background:#FCC">CPX<br>d</td>
<td style="background:#CFC">SBC<br>d</td>
<td style="background:#CCF">INC<br>d</td>
<td style="background:#DDD"><b>ISC</b><br>d</td>
<td style="background:#FCC">INX<br></td>
<td style="background:#CFC">SBC<br>#i</td>
<td style="background:#CCF">NOP<br></td>
<td style="background:#DDD"><b>SBC</b><br>#i</td>
<td style="background:#FCC">CPX<br>a</td>
<td style="background:#CFC">SBC<br>a</td>
<td style="background:#CCF">INC<br>a</td>
<td style="background:#DDD"><b>ISC</b><br>a</td>
<td style="background:#FCC">BEQ<br>*+d</td>
<td style="background:#CFC">SBC<br>(d),y</td>
<td style="background:#CCF"><b>STP</b><br></td>
<td style="background:#DDD"><b>ISC</b><br>(d),y</td>
<td style="background:#FCC"><b>NOP</b><br>d,x</td>
<td style="background:#CFC">SBC<br>d,x</td>
<td style="background:#CCF">INC<br>d,x</td>
<td style="background:#DDD"><b>ISC</b><br>d,x</td>
<td style="background:#FCC">SED<br></td>
<td style="background:#CFC">SBC<br>a,y</td>
<td style="background:#CCF"><b>NOP</b><br></td>
<td style="background:#DDD"><b>ISC</b><br>a,y</td>
<td style="background:#FCC"><b>NOP</b><br>a,x</td>
<td style="background:#CFC">SBC<br>a,x</td>
<td style="background:#CCF">INC<br>a,x</td>
<td style="background:#DDD"><b>ISC</b><br>a,x
</td></tr></tbody></table>
"""

instr_format = "{} => {{ {}(state, {}); }},"


# Operations that read from memory but don't write anything back
read_ops = {
    "ADC",
    "AND",
    "BIT",
    "CMP",
    "CPX",
    "CPY",
    "EOR",
    "LAX",
    "LDA",
    "LDX",
    "LDY",
    "NOP",
    "ORA",
    "SBC",
}

# Operations that read from memory and then write a result back
modify_ops = {
    "ASL",
    "DCP",
    "DEC",
    "INC",
    "ISC",
    "LSR",
    "RLA",
    "ROL",
    "ROR",
    "RRA",
    "SLO",
    "SRE",
    "TAS",
}

# Operations that write to memory without reading anything from memory
write_ops = {"AHX", "SAX", "SHX", "SHY", "STA", "STX", "STY"}

addr_mode_map = {
    "(d,x)": "indexed_indirect",
    "d": "zero_page",
    "a": "absolute",
    "(d),y": "indirect_indexed",
    "#i": "immediate",
    "a,y": "indexed_abs_y",
    "a,x": "indexed_abs_x",
    "d,y": "indexed_zp_y",
    "d,x": "indexed_zp_x",
    "*+d": "branch_relative",
    "(a)": "jmp_through",
}


soup = bs.BeautifulSoup(html)
table = soup.table
cells = table.find_all("td")
opcode = 0
for cell in cells:
    lines = cell.get_text("\n", strip=True).splitlines()
    operation = lines[0]
    addr_mode = operation if len(lines) == 1 else lines[1]
    if addr_mode != operation:
        addr_mode = addr_mode_map[addr_mode]
        if operation in read_ops:
            addr_mode += "_read"
        elif operation in modify_ops:
            addr_mode += "_modify"
        elif operation in write_ops:
            addr_mode += "_write"
        elif addr_mode not in {"immediate", "branch_relative"}:
            addr_mode += "_UNKNOWN"

    print(
        instr_format.format(
            hex(opcode), addr_mode, operation.lower().replace("and", "and_op")
        )
    )
    opcode += 1
