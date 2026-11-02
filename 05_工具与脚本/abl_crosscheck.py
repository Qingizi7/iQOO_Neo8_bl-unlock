import struct, re, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM, CS_OP_IMM, CS_OP_REG, CS_OP_MEM

P = sys.argv[1] if len(sys.argv) > 1 else 'abl_payload.bin'
d = open(P, 'rb').read()
MOD = 0xb8
pe = MOD + struct.unpack('<I', d[MOD + 0x3c:MOD + 0x40])[0]
optsz = struct.unpack('<H', d[pe + 20:pe + 22])[0]
base = struct.unpack('<I', d[pe + 24 + 28:pe + 24 + 32])[0]
nsec = struct.unpack('<H', d[pe + 6:pe + 8])[0]
secs = []
for i in range(nsec):
    o = pe + 24 + optsz + i * 40
    vs, va, rs, pr = struct.unpack('<IIII', d[o + 8:o + 24])
    secs.append((base + va, rs, MOD + pr))

TEXT_VA, TEXT_SIZE, TEXT_OFF = 0x1000, 0x95000, MOD + 0x10b8
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True
insns = list(md.disasm(d[TEXT_OFF:TEXT_OFF + TEXT_SIZE], TEXT_VA))

def f2va(fo):
    for va, rs, pr in secs:
        if pr <= fo < pr + rs:
            return va + (fo - pr)
    return None

print('--- strings containing unlock / verifiedboot / device_state ---')
targets = {}
for m in re.finditer(rb'[ -~]{5,}', d):
    s = m.group().decode('latin1')
    if any(k in s.lower() for k in ('unlocked', 'unlock_critical', 'verifiedboot', 'device_state', 'orange', 'green')):
        va = f2va(m.start())
        if va:
            print('  %08x %08x %s' % (m.start(), va, s[:90]))
            targets[va] = s[:60]

print('\n--- xrefs and context ---')
page = {}
xrefs = []
for ins in insns:
    m = ins.mnemonic; ops = ins.operands
    if m == 'adrp' and len(ops) == 2 and ops[0].type == CS_OP_REG and ops[1].type == CS_OP_IMM:
        page[ops[0].reg] = ops[1].imm
    elif m in ('add', 'sub') and len(ops) == 3 and ops[1].type == CS_OP_REG and ops[2].type == CS_OP_IMM and ops[1].reg in page:
        t = page[ops[1].reg] + (ops[2].imm if m == 'add' else -ops[2].imm)
        if t in targets:
            xrefs.append((ins.address, t))
    elif m in ('ldr', 'ldrb') and len(ops) == 2 and ops[1].type == CS_OP_MEM and ops[1].mem.base == 0 and ops[1].mem.disp in targets:
        xrefs.append((ins.address, ops[1].mem.disp))

for a, t in xrefs:
    print('\n@%08x -> %08x %s' % (a, t, targets[t]))
    lo, hi = a - 0x90, a + 0x70
    for i in insns:
        if lo <= i.address <= hi:
            mark = ' <== ' if i.address == a else '   '
            print('   %08x  %-8s %s%s' % (i.address, i.mnemonic, i.op_str, mark))
