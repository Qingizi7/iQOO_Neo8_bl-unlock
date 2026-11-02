import re, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM, CS_OP_MEM

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
code = d[TEXT_OFF:TEXT_OFF + TEXT_SIZE]
insns = list(md.disasm(code, TEXT_VA))


def find_str(s):
    return [m.start() for m in re.finditer(re.escape(s), d)]


def f2va(fo):
    return file_to_va(info, fo)


for s in [b'androidboot.vbmeta.device_state', b'orange', b'verifiedbootstate',
          b'VBRwDeviceState', b'Unable to set the Value', b'get_unlock_abi']:
    hits = find_str(s)
    print('%s -> %s' % (s.decode(), [(hex(h), hex(f2va(h)) if f2va(h) is not None else None)
                                     for h in hits[:4]] if hits else 'none'))

print('\n--- ldrb/ldur with disp 0xd/0xe ---')
for i, ins in enumerate(insns):
    if ins.mnemonic in ('ldrb', 'ldur', 'ldurb') and ins.operands:
        ops = ins.operands
        if len(ops) == 2 and ops[1].type == CS_OP_MEM and ops[1].mem.disp in (0xd, 0xe):
            # Look back for an adrp/add pair forming the devinfo struct base
            # (0xaa000e38 in the reference build).
            src = ins.op_str.split('[')[1].split(']')[0]
            base_reg = src.split(',')[0].strip()
            ctx = []
            found = False
            for k in range(max(0, i - 80), min(len(insns), i + 16)):
                j = insns[k]
                ctx.append(j)
                if (j.mnemonic == 'add'
                        and j.op_str.replace(' ', '').startswith(base_reg + ',' + base_reg + ',')
                        and '#0xe38' in j.op_str):
                    found = True
            print('\n@%08x %s  (base %s, structref=%s)' % (ins.address, ins.op_str, base_reg, found))
            if found:
                for j in ctx:
                    print('   %08x  %-8s %s' % (j.address, j.mnemonic, j.op_str))
