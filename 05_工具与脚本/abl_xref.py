import struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM, CS_OP_IMM, CS_OP_REG, CS_OP_MEM

P = sys.argv[1] if len(sys.argv) > 1 else 'abl_payload.bin'
d = open(P, 'rb').read()

MOD = 0xb8
pe = MOD + struct.unpack('<I', d[MOD + 0x3c:MOD + 0x40])[0]
optsz = struct.unpack('<H', d[pe + 20:pe + 22])[0]
base = struct.unpack('<I', d[pe + 24 + 28:pe + 24 + 32])[0]
nsec = struct.unpack('<H', d[pe + 6:pe + 8])[0]

TEXT_VA = 0x1000
TEXT_SIZE = 0x95000
TEXT_OFF = MOD + 0x10b8

targets = {
    0x8b9ce: 'ANDROID-BOOT!',
    0x8b9dc: 'Device Magic does not match',
    0x8b9ad: 'Unable to Write Device Info',
    0x8b96a: 'RWDeviceState err msg',
}

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
        # literal pool: base=PC, disp absolute
        if ops[1].mem.base == 0 and ops[1].mem.disp in targets:
            xref.append((ins.address, ops[1].mem.disp, m))

print('xrefs:')
for a, t, m in xref:
    print('  %08x -> %s (%s)' % (a, targets[t], m))

# disassemble around xrefs
for a, t, m in xref:
    if targets[t] != 'ANDROID-BOOT!':
        continue
    print('\n=== context around xref to ANDROID-BOOT! at %08x ===' % a)
    start = a - 0x120
    end = a + 0x160
    for ins in insns:
        if start <= ins.address < end:
            print('  %08x  %-8s %s' % (ins.address, ins.mnemonic, ins.op_str))
