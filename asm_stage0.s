// asm_stage0.s — appended data for stage 0 builds (system as+ld)
// Contains ELF header template + decompressor stub + compression
// dictionaries. Self-hosted builds read these from the file image instead.

// ── ELF header template (112 bytes = ehdr + phdr, phdr overlaps ehdr tail) ──
// Mostly data: this is the header of every emitted binary; p_filesz and
// p_memsz are patched at output time. It sits immediately before the stub
// so [header|stub|dicts] forms one contiguous template, mirroring the
// self-hosted file image layout. The entry point is offset 80: the stub's
// first two instructions hide in the phdr's p_paddr field, which the
// kernel and qemu ignore (and which lies beyond the binfmt_misc magic).
_hdr_template:
    .word 0x464c457f                    // ELF magic
    .word 0x00010102                    // 64-bit, little-endian, version 1
    // e_ident ABI-version/padding: preload two stub data words, then chain
_decomp_stub_preload:
    ldp     w7, w8, [x6, #(STUB_DATA_DECOMP_DEST - CODE_START)]
    b       _decomp_stub_start
    .word 0x00b70003                    // e_type=DYN(3), e_machine=AArch64
    .word 1                             // e_version
    .word 80                         // e_entry = p_paddr field
    .word 0
    .word 56                         // e_phoff
    .word 0
    .word 0                          // e_shoff lo (kernel-ignored hole):
                                     //   decomp_dest, patched at output time
    .word 0                          // e_shoff hi: rodata_size (patched)
    .word 0                             // e_flags: reloc_count (patched)
    .word 0x00380040                    // e_ehsize=64, e_phentsize=56
    .word 1                             // p_type=LOAD (overlaps e_phnum=1)
    .word 7                             // p_flags=RWX
    .word 0                          // p_offset
    .word 0
    .word 0                          // p_vaddr
    .word 0
    // p_paddr (ignored): entry point — stub head, chains to the stub body
    adr     x6, _decomp_stub_start      // x6 = image base + CODE_START
    b       _decomp_stub_preload
    .word 0                          // p_filesz (patched)
    .word 0
    .word 0                          // p_memsz (patched)
    .word 0
    .word 0x10000                    // p_align
    .word 0

// ── decompressor stub ────────────────────────────────────────────────────
// Runs at the ELF entry point (chained from the p_paddr hole above).
// Decompresses .text to a page-aligned address, copies rodata, flushes
// icache, jumps to decompressed code.
// Unsupported instructions encoded as .word constants:
//   dc cvau, ic ivau, dsb ish, isb

_decomp_stub_start:
    // compute decompression destination + preload rodata_size/reloc_count
    // (the data words live in ELF-header holes, behind the stub base)
    ldr     w12, [x6, #(STUB_DATA_RELOC_COUNT - CODE_START)]
    add     x7, x6, x7                  // x7 = stub_base + offset

    // set up dict/stream pointers (right after stub in file)
    add     x2, x6, #(STUB_SIZE - 4)    // full_dict - 4 (codes 1..FULL)
    add     x10, x2, #(FULL_DICT_SIZE + 4 - 3*(FULL_DICT_ENTRIES + 1))  // t24 codes
    add     x3, x2, #(FULL_DICT_SIZE + T24_DICT_SIZE + 4 - 2*(FULL_DICT_ENTRIES + T24_DICT_ENTRIES + 1)) // t16 codes
    add     x11, x2, #(FULL_DICT_SIZE + T24_DICT_SIZE + T16_DICT_SIZE + 4 - (FULL_DICT_ENTRIES + T24_DICT_ENTRIES + T16_DICT_ENTRIES + 1)) // t8 codes
    add     x0, x2, #(DICT_SIZE + 4)    // stream
    add     x1, x7, #0                  // output dest

    // ── decompress ────────────────────────────────────────────────────────
3:  ldrb    w4, [x0], #1
    cbz     w4, _decomp_copy_rodata
    ldr     w5, [x2, x4, lsl #2]       // speculative full dict (harmless otherwise)
    cmp     w4, #FULL_DICT_ENTRIES
    b.ls    6f                          // full dict hit
    cmp     w4, #(FULL_DICT_ENTRIES + T24_DICT_ENTRIES)
    b.hi    5f
    // t24: 3-byte packed entry (top 24 bits) + 1 literal byte
    add     x5, x4, x4, lsl #1         // code * 3
    ldr     w5, [x10, x5]
    ldrb    w9, [x0], #1
    orr     w5, w9, w5, lsl #8
    b       6f
5:  cmp     w4, #(FULL_DICT_ENTRIES + T24_DICT_ENTRIES + T16_DICT_ENTRIES)
    b.hi    7f
    ldrh    w5, [x3, x4, lsl #1]       // t16: upper 16 bits
    ldrh    w9, [x0], #2
    orr     w5, w9, w5, lsl #16
    b       6f
7:  ldrb    w9, [x11, x4]              // t8: top 8 bits; raw reads stream byte
    ldr     w5, [x0], #3               // first 3 literal bytes (over-read 1)
    cmp     w4, #RAW_CODE
    b.ne    4f
    ldrb    w9, [x0], #1               // raw escape: fourth literal byte
4:  bfi     w5, w9, #24, #8
6:  str     w5, [x1], #4
    b       3b

    // ── copy rodata ───────────────────────────────────────────────────────
_decomp_copy_rodata:
    add     x14, x1, #0                 // rodata base (start of copied rodata)
    cbz     x8, _decomp_apply_reloc
7:  ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    sub     x8, x8, #1
    cbnz    x8, 7b

    // ── apply .dword relocations in rodata ────────────────────────────────
_decomp_apply_reloc:
    cbz     x12, _decomp_flush
8:  ldp     w4, w5, [x0], #8           // slot_off_rodata (u32), target_off (u32)
    // plain register add/offset: the ldp w-form zero-extends into x4/x5,
    // and .dword targets are rodata-only so target_off >= 0. The extended-
    // register form (w4, uxtw) is outside asm's dialect — this stub must
    // be assemblable by asm itself for the seeded (no system as) bootstrap.
    add     x10, x7, x5                // runtime pointer target
    str     x10, [x14, x4]             // store into rodata slot
    subs    x12, x12, #1
    b.ne    8b

    // ── icache flush (x7=start, x1=end) ───────────────────────────────────
    // The start is aligned down to a line boundary: with a misaligned start
    // and a 64-byte stride, the final line of the range is never visited
    // (found the hard way: the first line-tail function a module called at
    // init faulted as UNDEF on real silicon with caches enabled).
_decomp_flush:
    and     x0, x7, #0xffffffffffffffc0
7:  .word 0xd50b7b20                    // dc cvau, x0
    .word 0xd5033b9f                    // dsb ish
    .word 0xd50b7520                    // ic ivau, x0
    add     x0, x0, #64
    cmp     x0, x1
    b.lo    7b
    .word 0xd5033b9f                    // dsb ish
    .word 0xd5033fdf                    // isb
    // jump to decompressed entry (blr so x30 points to stub end)
    blr     x7
_decomp_stub_end:

// ── compression dictionaries (auto-generated by gen_dict.py) ─────────
// Do not edit below this line

// full instruction dictionary (80 entries)
    .word 0xd65f03c0
    .word 0xd61f0200
    .word 0xd4000001
    .word 0x6b09015f
    .word 0x38401c09
    .word 0xd2ac0016
    .word 0xf87a6b8a
    .word 0x7100255f
    .word 0x71008d3f
    .word 0x7100b13f
    .word 0x7101753f
    .word 0x1a890149
    .word 0x54000061
    .word 0xa90157f4
    .word 0xa9bc4ffe
    .word 0x2a160000
    .word 0x39400a6a
    .word 0x5100c12a
    .word 0x7101853f
    .word 0x7940026a
    .word 0x91000400
    .word 0x91000802
    .word 0xf1000e9f
    .word 0x321b012a
    .word 0x33030540
    .word 0x39400a69
    .word 0x52a26000
    .word 0x52aa501a
    .word 0x7100b93f
    .word 0x7101c95f
    .word 0x72a36019
    .word 0x8b0a20eb
    .word 0x8b17156b
    .word 0x91000013
    .word 0x9101c339
    .word 0x92800c60
    .word 0xa900040f
    .word 0xa9010803
    .word 0xa9bf53fe
    .word 0xd37ced7a
    .word 0xeb00013f
    .word 0xf83a6b8a
    .word 0xf9001ffe
    .word 0x14000002
    .word 0x54ffffa1
    .word 0x91000260
    .word 0x00cdb010
    .word 0x12004800
    .word 0x14000005
    .word 0x17fffff7
    .word 0x28812654
    .word 0x2905542b
    .word 0x2a090000
    .word 0x2a166000
    .word 0x2a190000
    .word 0x381ffd4e
    .word 0x38401449
    .word 0x38401c49
    .word 0x5200054a
    .word 0x540000a1
    .word 0x7101713f
    .word 0x71017d3f
    .word 0x7101913f
    .word 0x7101b13f
    .word 0x7101b93f
    .word 0x7101c93f
    .word 0x7101cd3f
    .word 0x7101d13f
    .word 0x7101e95f
    .word 0x79400009
    .word 0x91000002
    .word 0x91028381
    .word 0x9342fc00
    .word 0x9b007e73
    .word 0xb00e067c
    .word 0xb3607c00
    .word 0xb9b0b0b2
    .word 0xc1573b15
    .word 0xd2800808
    .word 0xd2a40016

// top-24-bit dictionary (72 entries, 3 bytes each, packed)
    .word 0xfe97ffff
    .word 0xffff97ff
    .word 0x14000017
    .word 0xfc97fffd
    .word 0x000097ff
    .word 0x14000194
    .word 0x00d28000
    .word 0x00009100
    .word 0x17fffe54
    .word 0xfd97fffb
    .word 0x000117ff
    .word 0xd61f0154
    .word 0x02910001
    .word 0x01851400
    .word 0x91000251
    .word 0x02910004
    .word 0x8003d2a0
    .word 0xd34cfcd2
    .word 0x00910003
    .word 0x1801b400
    .word 0x386b6937
    .word 0x02530411
    .word 0x09005400
    .word 0x9102838b
    .word 0x01b5ffff
    .word 0x0005b940
    .word 0xf94003d1
    .word 0xff2a0016
    .word 0x800154ff
    .word 0xd28007d2
    .word 0x04380014
    .word 0x400e3940
    .word 0x52800039
    .word 0x05528001
    .word 0x17055301
    .word 0x54000353
    .word 0x01540004
    .word 0x36028a0a
    .word 0x8b09028a
    .word 0x008b0903
    .word 0x16028b15
    .word 0x8b1a478b
    .word 0xc18b1d03
    .word 0x00009101
    .word 0xd34209b5
    .word 0xefdac011
    .word 0x19160fa9
    .word 0x3700012a
    .word 0x08394000
    .word 0x00063940
    .word 0xd2a80091
    .word 0x2cd63f01
    .word 0x001bf240
    .word 0xf9400ff9

// top-16-bit dictionary (66 entries, packed as words)
    .word 0x71015400
    .word 0xf9407100
    .word 0x54ff1100
    .word 0xf900b400
    .word 0xf1003940
    .word 0xd2801200
    .word 0x34001000
    .word 0xb7f89100
    .word 0x510034ff
    .word 0x2a172a00
    .word 0x35ff2a18
    .word 0x50003710
    .word 0xdac0b900
    .word 0xcb009240
    .word 0x2a162a0a
    .word 0x52ba5280
    .word 0x70005303
    .word 0x9b0d72ba
    .word 0xcb09b4ff
    .word 0x2a19d100
    .word 0x36003316
    .word 0x38403708
    .word 0x52815200
    .word 0x52855284
    .word 0x8b0052a1
    .word 0x9ac09a9f
    .word 0xd101a941
    .word 0x1ace10ff
    .word 0x2a092a01
    .word 0x2a1a2a0b
    .word 0x36183608
    .word 0x37003620
    .word 0x4b09381f

// top-8-bit dictionary (36 entries, packed as words)
    .word 0xa9643a83
    .word 0x53eb1ad3
    .word 0x3870cb52
    .word 0x9ab52a8b
    .word 0xb87237aa
    .word 0x330b32f8
    .word 0x36a88a4a
    .word 0x10b29291
    .word 0xd1786b4b
