import sys
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

TARGET_STRINGS = [
    b'ANDROID-BOOT!',
    b'Device Magic does not match',
    b'Unable to Write Device Info',
    b'VBRwDeviceState',
    b'RWDeviceState',
    b'Device unlocked',
    b'Device critical unlocked',
    b'Device is unlocked, Skipping boot verification',
]

targets = {}
for s in TARGET_STRINGS:
    start = 0
    while True:
        i = d.find(s, start)
        if i < 0:
            break
        va = file_to_va(info, i)
        if va is not None:
            targets[va] = s.decode('latin1')
        start = i + 1

print('\ntargets:')
for va in sorted(targets):
    print('  %08x %s' % (va, targets[va]))

md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True
code = d[TEXT_OFF:TEXT_OFF + TEXT_SIZE]
insns = list(md.disasm(code, TEXT_VA))

page = {}
xref = []
for ins in insns:
    m = ins.mnemonic
    ops = ins.operands
    if m == 'adrp' and len(ops) == 2 and ops[0].type == CS_OP_REG and ops[1].type == CS_OP_IMM:
        page[ops[0].reg] = ops[1].imm
    elif m in ('add', 'sub') and len(ops) == 3 and ops[0].type == CS_OP_REG and ops[1].type == CS_OP_REG and ops[2].type == CS_OP_IMM:
        if ops[1].reg in page:
            tgt = page[ops[1].reg] + (ops[2].imm if m == 'add' else -ops[2].imm)
            if tgt in targets:
                xref.append((ins.address, tgt, m))
    elif m in ('ldr', 'ldrb', 'str', 'strb') and len(ops) == 2 and ops[1].type == CS_OP_MEM:
        # Literal pool: base=PC, disp is absolute VA.
        if ops[1].mem.base == 0 and ops[1].mem.disp in targets:
            xref.append((ins.address, ops[1].mem.disp, m))

print('\nxrefs:')
for a, t, m in xref:
    print('  %08x -> %08x %s (%s)' % (a, t, targets[t], m))

for a, t, m in xref:
    if targets[t] != 'ANDROID-BOOT!':
        continue
    print('\n=== context around xref to ANDROID-BOOT! at %08x ===' % a)
    start = a - 0x120
    end = a + 0x160
    for ins in insns:
        if start <= ins.address < end:
            print('  %08x  %-8s %s' % (ins.address, ins.mnemonic, ins.op_str))
