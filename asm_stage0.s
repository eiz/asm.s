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
    .word 0                          // e_ident padding
    .word 0
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
    b       _decomp_stub_start
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
    ldp     w7, w8, [x6, #(STUB_DATA_DECOMP_DEST - CODE_START)]
    ldr     w12, [x6, #(STUB_DATA_RELOC_COUNT - CODE_START)]
    add     x7, x6, x7                  // x7 = stub_base + offset

    // set up dict/stream pointers (right after stub in file)
    add     x2, x6, #(STUB_SIZE - 4)    // full_dict - 4 (codes 1..FULL)
    add     x10, x2, #(FULL_DICT_SIZE + 4 - 3*(FULL_DICT_ENTRIES + 1))  // t24 codes
    add     x3, x2, #(FULL_DICT_SIZE + T24_DICT_SIZE + 4 - 2*(FULL_DICT_ENTRIES + T24_DICT_ENTRIES + 1)) // t16 codes
    add     x11, x2, #(FULL_DICT_SIZE + T24_DICT_SIZE + T16_DICT_SIZE + 4 - (FULL_DICT_ENTRIES + T24_DICT_ENTRIES + T16_DICT_ENTRIES + 1)) // t8 codes
    add     x0, x2, #(DICT_SIZE + 4)    // stream
    mov     x1, x7                      // output dest

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
7:  cmp     w4, #0xFF
    b.eq    4f
    ldrb    w9, [x11, x4]              // t8: top 8 bits
    ldr     w5, [x0], #3               // 3 literal bytes (over-read 1, in-file)
    bfi     w5, w9, #24, #8
    b       6f
4:  ldr     w5, [x0], #4               // raw escape
6:  str     w5, [x1], #4
    b       3b

    // ── copy rodata ───────────────────────────────────────────────────────
_decomp_copy_rodata:
    mov     x14, x1                     // rodata base (start of copied rodata)
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

// full instruction dictionary (76 entries)
    .word 0xd65f03c0
    .word 0xd4000001
    .word 0x6b09015f
    .word 0x1a890149
    .word 0x71008d3f
    .word 0x7101853f
    .word 0x7101b95f
    .word 0x7101c95f
    .word 0x8b1d076b
    .word 0xf9001bfe
    .word 0xf9400f8b
    .word 0x91000400
    .word 0x2a160000
    .word 0x2a170000
    .word 0x38401409
    .word 0x39400009
    .word 0x39400a6a
    .word 0x7100255f
    .word 0x7100b13f
    .word 0x7101753f
    .word 0x7101cd3f
    .word 0xf9401bfe
    .word 0x92800c60
    .word 0xa90157f4
    .word 0xa9025ff6
    .word 0xa9bc4ffe
    .word 0xd2ac0016
    .word 0x2a090000
    .word 0x38401c09
    .word 0x5100c12a
    .word 0x54000061
    .word 0x7101b13f
    .word 0x7101c93f
    .word 0x7101e95f
    .word 0xf1000e9f
    .word 0x54000041
    .word 0x91000013
    .word 0x14000002
    .word 0x2a160129
    .word 0x381ffd4e
    .word 0x39400a69
    .word 0x54000060
    .word 0x7100b93f
    .word 0x7101913f
    .word 0x7101915f
    .word 0x7101b15f
    .word 0x7101b93f
    .word 0x7101bd5f
    .word 0x7101d13f
    .word 0x8b0a216b
    .word 0x8b17156b
    .word 0x91000260
    .word 0xa9bf53fe
    .word 0xcb09014a
    .word 0xd2a40016
    .word 0xd2a80016
    .word 0xd37ced7a
    .word 0xf1000a9f
    .word 0xf82b6b8a
    .word 0xf9001ffe
    .word 0x54000080
    .word 0x540000a1
    .word 0x11000329
    .word 0x12004800
    .word 0x14000005
    .word 0x14000006
    .word 0x288125d4
    .word 0x2905542b
    .word 0x2a002929
    .word 0x2a0a2800
    .word 0x2a166000
    .word 0x2a181529
    .word 0x2a190000
    .word 0x2a191400
    .word 0x2a1916e9
    .word 0x321b012a

// top-24-bit dictionary (80 entries, 3 bytes each, packed)
    .word 0xfe17ffff
    .word 0xffff97ff
    .word 0x14000097
    .word 0xfb97fffd
    .word 0xfffc97ff
    .word 0x94000097
    .word 0x0017fffe
    .word 0x80009100
    .word 0x540001d2
    .word 0xfd140001
    .word 0x000017ff
    .word 0x17fffc54
    .word 0x01940001
    .word 0x00029100
    .word 0x52800091
    .word 0x05910283
    .word 0x0002d100
    .word 0xf86b6b14
    .word 0xff540003
    .word 0x000454ff
    .word 0x38001491
    .word 0xff9a9f17
    .word 0x0004b5ff
    .word 0xd28003d1
    .word 0x47d34cfc
    .word 0x0002f900
    .word 0x91000654
    .word 0x89b40000
    .word 0x0a017101
    .word 0x9100088b
    .word 0x0ecb1400
    .word 0x8007d100
    .word 0xd2a002d2
    .word 0x042a0016
    .word 0x00053940
    .word 0x54001c54
    .word 0x03d28001
    .word 0x401ff940
    .word 0x386069f9
    .word 0x0139400e
    .word 0x03115280
    .word 0x54000453
    .word 0x027101b5
    .word 0x0a017940
    .word 0x8b15008a
    .word 0x058b1d03
    .word 0x01c19100
    .word 0xb4000191
    .word 0x00eb0001
    .word 0x00013500
    .word 0x39400239
    .word 0x0e394006
    .word 0x00125400
    .word 0x6b0b0254
    .word 0xd5710195
    .word 0x01e17101
    .word 0x8b090071
    .word 0xfc910003
    .word 0xfffa9342
    .word 0xb3607c97

// top-16-bit dictionary (64 entries, packed as words)
    .word 0x71015400
    .word 0xf9407100
    .word 0xf100f900
    .word 0x110054ff
    .word 0x12001000
    .word 0xdac03940
    .word 0x51003400
    .word 0x9100b7f8
    .word 0x700034ff
    .word 0xb940b400
    .word 0x2a00d280
    .word 0x2a172a0a
    .word 0x36082a18
    .word 0x51015000
    .word 0x924052a2
    .word 0x2a09b900
    .word 0x52845280
    .word 0xcb008b09
    .word 0x35ff2a19
    .word 0x52aa3840
    .word 0x72a352ba
    .word 0x8b0072ba
    .word 0xb4ff9ac0
    .word 0x321b2a1a
    .word 0x52a15200
    .word 0x52a652a5
    .word 0xa9418b0b
    .word 0xcb01aa09
    .word 0x2a011ace
    .word 0x52812a16
    .word 0x52875285
    .word 0x530252a7

// top-8-bit dictionary (32 entries, packed as words)
    .word 0x9a528ba9
    .word 0x918a38cb
    .word 0xaa53ebd3
    .word 0xa81ad1b8
    .word 0x4a2a0bf8
    .word 0xb29b724b
    .word 0x373332b5
    .word 0xead29279
