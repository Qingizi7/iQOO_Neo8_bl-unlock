import struct, re, sys
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

md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
md.detail = True
code = d[TEXT_OFF:TEXT_OFF + TEXT_SIZE]
insns = list(md.disasm(code, TEXT_VA))
byaddr = {i.address: i for i in insns}

def find_str(s):
    return [m.start() for m in re.finditer(re.escape(s), d)]

def f2va(fo):
    # sections parsed fresh
    secs = []
    for i in range(nsec):
        o = pe + 24 + optsz + i * 40
        vs, va, rs, pr = struct.unpack('<IIII', d[o + 8:o + 24])
        secs.append((va, rs, pr))
    for va, rs, pr in secs:
        if MOD + pr <= fo < MOD + pr + rs:
            return base + va + (fo - (MOD + pr))
    return None

for s in [b'androidboot.vbmeta.device_state', b'orange', b'verifiedbootstate', b'VBRwDeviceState', b'Unable to set the Value', b'get_unlock_abi']:
    hits = find_str(s)
    print('%s -> %s' % (s.decode(), [(hex(h), hex(f2va(h))) for h in hits[:4]] if hits else 'none'))

print('\n--- ldrb with disp 0xd/0xe ---')
for i, ins in enumerate(insns):
    if ins.mnemonic in ('ldrb', 'ldur', 'ldurb') and ins.operands:
        ops = ins.operands
        if len(ops) == 2 and ops[1].type == CS_OP_MEM and ops[1].mem.disp in (0xd, 0xe):
            # look back for adrp/add forming devinfo struct base (0xaa000e38)
            src = ins.op_str.split('[')[1].split(']')[0]
            base_reg = src.split(',')[0].strip()
            ctx = []
            found = False
            for k in range(max(0, i - 40), i + 12):
                j = insns[k]
                ctx.append(j)
                if j.mnemonic == 'add' and j.op_str.replace(' ', '').startswith(base_reg + ',' + base_reg + ',') and '#0xe38' in j.op_str:
                    found = True
            print('\n@%08x %s  (base %s, structref=%s)' % (ins.address, ins.op_str, base_reg, found))
            if found:
                for j in ctx:
                    print('   %08x  %-8s %s' % (j.address, j.mnemonic, j.op_str))
