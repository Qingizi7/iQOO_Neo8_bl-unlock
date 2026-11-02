import re, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM, CS_OP_IMM, CS_OP_REG, CS_OP_MEM

from abl_common import parse_pe, text_section, file_to_va

P = sys.argv[1] if len(sys.argv) > 1 else 'abl_payload.bin'
try:
    d = open(P, 'rb').read()
except OSError as e:
    print('error: %s' % e, file=sys.stderr)
    sys.exit(2)

try:
    info = parse_pe(d)
    text = text_section(d, info)
except ValueError as e:
    print('error: %s' % e, file=sys.stderr)
    sys.exit(2)
TEXT_VA = text['va']
TEXT_SIZE = text['size']
TEXT_OFF = text['offset']

print('payload: %s' % P)
print('PE: mz=0x%x pe=0x%x image_base=0x%x' % (info['mz'], info['pe'], info['image_base']))
print('TEXT: off=0x%x va=0x%x size=0x%x' % (TEXT_OFF, TEXT_VA, TEXT_SIZE))

md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True
insns = list(md.disasm(d[TEXT_OFF:TEXT_OFF + TEXT_SIZE], TEXT_VA))


def f2va(fo):
    return file_to_va(info, fo)


print('\n--- strings containing unlock / verifiedboot / device_state ---')
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
    m = ins.mnemonic
    ops = ins.operands
    if m == 'adrp' and len(ops) == 2 and ops[0].type == CS_OP_REG and ops[1].type == CS_OP_IMM:
        page[ops[0].reg] = ops[1].imm
    elif m in ('add', 'sub') and len(ops) == 3 and ops[0].type == CS_OP_REG and ops[1].type == CS_OP_REG and ops[2].type == CS_OP_IMM and ops[1].reg in page:
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
