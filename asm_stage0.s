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
    add     x10, x2, #(FULL_DICT_SIZE + 4 - 3*(FULL_DICT_ENTRIES + 1))  // t24/r24 codes
    add     x3, x2, #(FULL_DICT_SIZE + T24_DICT_SIZE + R24_DICT_SIZE + 4 - 2*(FULL_DICT_ENTRIES + T24_DICT_ENTRIES + R24_DICT_ENTRIES + 1)) // t16 codes
    add     x11, x2, #(FULL_DICT_SIZE + T24_DICT_SIZE + R24_DICT_SIZE + T16_DICT_SIZE + 4 - (FULL_DICT_ENTRIES + T24_DICT_ENTRIES + R24_DICT_ENTRIES + T16_DICT_ENTRIES + 1)) // t8 codes
    add     x0, x2, #(DICT_SIZE + 4)    // stream
    add     x1, x7, #0                  // output dest
    mov     w14, #24                    // ROR24 below restores R24 words

    // ── decompress ────────────────────────────────────────────────────────
3:  ldrb    w4, [x0], #1
    cbz     w4, _decomp_copy_rodata
    ldr     w5, [x2, x4, lsl #2]       // speculative full dict (harmless otherwise)
    cmp     w4, #FULL_DICT_ENTRIES
    b.ls    6f                          // full dict hit
    cmp     w4, #(FULL_DICT_ENTRIES + T24_DICT_ENTRIES + R24_DICT_ENTRIES)
    b.hi    5f
    // t24/r24: 3-byte packed entry (top 24 bits) + 1 literal byte.
    // Codes with bit 7 set hold ROR8 words, making original byte 1 literal;
    // rotate the reconstructed word left by 8 before storing it.
    add     x5, x4, x4, lsl #1         // code * 3
    ldr     w5, [x10, x5]
    ldrb    w9, [x0], #1
    orr     w5, w9, w5, lsl #8
    tbz     w4, #7, 6f
    ror     w5, w5, w14
    b       6f
5:  cmp     w4, #(FULL_DICT_ENTRIES + T24_DICT_ENTRIES + R24_DICT_ENTRIES + T16_DICT_ENTRIES)
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

// full instruction dictionary (45 entries)
    .word 0x13020a96
    .word 0x14000002
    .word 0x14000004
    .word 0x1a890149
    .word 0x2a0016c0
    .word 0x2a004339
    .word 0x321b012a
    .word 0x381ff27f
    .word 0x381ffd4e
    .word 0x3840166b
    .word 0x38401c09
    .word 0x39400a6a
    .word 0x52a26000
    .word 0x52aa501a
    .word 0x54000061
    .word 0x54ffffa1
    .word 0x6b09015f
    .word 0x7100255f
    .word 0x71008d3f
    .word 0x7100b13f
    .word 0x7101753f
    .word 0x7940026a
    .word 0x8b0a20eb
    .word 0x91000002
    .word 0x91000013
    .word 0x91000260
    .word 0x91000400
    .word 0x91000802
    .word 0x92800c60
    .word 0xa90005a0
    .word 0xa90109a3
    .word 0xa90157f4
    .word 0xa9bc4ffe
    .word 0xa9bf53fe
    .word 0xb7ffed80
    .word 0xd100056b
    .word 0xd37ced7a
    .word 0xd4000001
    .word 0xd5120699
    .word 0xd61f0200
    .word 0xd65f03c0
    .word 0xf83a6b8a
    .word 0xf87a6b8a
    .word 0xf9001ffe
    .word 0xf9002389

// packed prefix dictionaries: t24=82*3, r24=28*3, t16=63*2 bytes
    .word 0x00000cd5
    .word 0x00051100
    .word 0x14000011
    .word 0xfd140001
    .word 0xfffe17ff
    .word 0x17ffff17
    .word 0x261fce2d
    .word 0x05542881
    .word 0x2a160029
    .word 0x06330305
    .word 0xfffd3303
    .word 0x35ffff35
    .word 0x01370000
    .word 0x10003700
    .word 0x37180137
    .word 0x1437181b
    .word 0x6b693800
    .word 0x39400038
    .word 0x0e394004
    .word 0x000e3940
    .word 0x5100c151
    .word 0x00510185
    .word 0x80015280
    .word 0x53010552
    .word 0x00531705
    .word 0x00015400
    .word 0x54000254
    .word 0xff540003
    .word 0x0a0154ff
    .word 0x8a36028a
    .word 0x008b0100
    .word 0x14018b09
    .word 0x8b15008b
    .word 0x158b1602
    .word 0x1a478b17
    .word 0x8b1d038b
    .word 0x008fd5d5
    .word 0x00019100
    .word 0x91000291
    .word 0x04910003
    .word 0x01c19100
    .word 0x9101c391
    .word 0x009342fc
    .word 0xfffb9400
    .word 0x97fffc97
    .word 0xfe97fffd
    .word 0xffff97ff
    .word 0x9b137c97
    .word 0x00b3607c
    .word 0x0000b400
    .word 0xb84045b5
    .word 0xc0b94001
    .word 0x8003d101
    .word 0xd28007d2
    .word 0x09d2a002
    .word 0x4cfcd342
    .word 0xd61f01d3
    .word 0xd5dac011
    .word 0x755cded5
    .word 0xf268cce6
    .word 0x03f9001b
    .word 0x2a0af940
    .word 0x002a1800
    .word 0x1b002a1a
    .word 0x52a70053
    .word 0x0952ba09
    .word 0x40097940
    .word 0x52a20a39
    .word 0x17331b0a
    .word 0xa3195285
    .word 0x2a001972
    .word 0x20540020
    .word 0x013f7100
    .word 0x33163f71
    .word 0x49384040
    .word 0x015f7100
    .word 0x39405f71
    .word 0x739ac069
    .word 0x407f7100
    .word 0xf90089f9
    .word 0x9f71008a
    .word 0x40ca3600
    .word 0x1000fef9
    .word 0x12001100
    .word 0x2a091ace
    .word 0x2a172a16
    .word 0x2a192a18
    .word 0x34ff3400
    .word 0x36183608
    .word 0x37083700
    .word 0x39403710
    .word 0x51015000
    .word 0x52805200
    .word 0x52845281
    .word 0x52a15287
    .word 0x52a652a5
    .word 0x53045303
    .word 0x54ff5400
    .word 0x71017000
    .word 0x8a0072ba
    .word 0x8b0b8b0a
    .word 0x91008b13
    .word 0x9a9f9240
    .word 0xa8819b0d
    .word 0xa941a905
    .word 0xaa13a9ff
    .word 0xb4ffb400
    .word 0xb900b7f8
    .word 0xcb01cb00
    .word 0xcb0acb09
    .word 0xcb14cb0d
    .word 0xdac0d100
    .word 0xf100eb14
    .word 0xf940f900

// top-8-bit dictionary (36 entries, packed as words)
    .word 0xa9643a83
    .word 0x53eb1ad3
    .word 0x3870cb52
    .word 0x9ab52a8b
    .word 0x3332100b
    .word 0x4b4a3736
    .word 0x9178726b
    .word 0xb2aaa892
    .word 0xf8d6d1b8
