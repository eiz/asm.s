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
5:  cmp     w4, #0xFF
    b.eq    4f
    ldrh    w5, [x3, x4, lsl #1]       // t16: upper 16 bits
    ldrh    w9, [x0], #2
    orr     w5, w9, w5, lsl #16
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
_decomp_flush:
    mov     x0, x7
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

// full instruction dictionary (112 entries)
    .word 0xd65f03c0
    .word 0xd4000001
    .word 0xf9400f8b
    .word 0x91000400
    .word 0x39400009
    .word 0x7101b95f
    .word 0xa90157f4
    .word 0xa9025ff6
    .word 0xa9bc4ffe
    .word 0xd2ac0016
    .word 0xf9001bfe
    .word 0x2a160000
    .word 0x38401409
    .word 0x39400a6a
    .word 0x71008d3f
    .word 0xf9401bfe
    .word 0x381ffd4e
    .word 0x6b09015f
    .word 0x7100255f
    .word 0x7100b13f
    .word 0x7101753f
    .word 0x7101853f
    .word 0x7101895f
    .word 0x7101cd3f
    .word 0x7101e95f
    .word 0xa9bf53fe
    .word 0xd2a40016
    .word 0xd2a80016
    .word 0xf82a6920
    .word 0x54000060
    .word 0x91000013
    .word 0x91000018
    .word 0x2a160129
    .word 0x2a170000
    .word 0x7100b93f
    .word 0x7101915f
    .word 0x7101b13f
    .word 0x7101b93f
    .word 0x7101bd5f
    .word 0x7101c95f
    .word 0x7101d13f
    .word 0x7101e15f
    .word 0x91000260
    .word 0xf1000e9f
    .word 0xf9001ffe
    .word 0xf9004780
    .word 0xf9401389
    .word 0xf9401f89
    .word 0x54000041
    .word 0x54000061
    .word 0x540000a1
    .word 0x91000019
    .word 0x0b0a7400
    .word 0x0b0c098d
    .word 0x0b0d056c
    .word 0x11000329
    .word 0x12004800
    .word 0x1400021e
    .word 0x1a890149
    .word 0x1aca2800
    .word 0x1acb218b
    .word 0x288131ca
    .word 0x2a002929
    .word 0x2a090000
    .word 0x2a0a3000
    .word 0x2a0b2800
    .word 0x2a157d6b
    .word 0x2a166000
    .word 0x2a181529
    .word 0x2a191400
    .word 0x2a1916e9
    .word 0x32000000
    .word 0x32050800
    .word 0x32150329
    .word 0x330d1300
    .word 0x3311180b
    .word 0x371000e9
    .word 0x375fce19
    .word 0x3840144a
    .word 0x385ff155
    .word 0x3861680a
    .word 0x3862682a
    .word 0x386a6961
    .word 0x386b6a6b
    .word 0x39400269
    .word 0x39400a69
    .word 0x39400e6a
    .word 0x4a0700c6
    .word 0x4b0b014a
    .word 0x4b1a7800
    .word 0x5280801a
    .word 0x52820019
    .word 0x5287460b
    .word 0x528d0009
    .word 0x528f8009
    .word 0x52a30009
    .word 0x52a72009
    .word 0x52a96019
    .word 0x52ae5016
    .word 0x52bac3e9
    .word 0x53057f09
    .word 0x53087d2a
    .word 0x531d71ae
    .word 0x6b09017f
    .word 0x6b0b021f
    .word 0x7100257f
    .word 0x7100813f
    .word 0x71009d3f
    .word 0x7100bd3f
    .word 0x7101713f
    .word 0x7101893f
    .word 0x7101953f

// top-24-bit dictionary (48 entries, 3 bytes each, packed)
    .word 0xff140000
    .word 0xfffe17ff
    .word 0x97ffff97
    .word 0xfc97fffd
    .word 0xfffe97ff
    .word 0x97fffb17
    .word 0xfdd28000
    .word 0x000017ff
    .word 0x14000191
    .word 0x6b540001
    .word 0x0000f86b
    .word 0x94000054
    .word 0x02910243
    .word 0x80009100
    .word 0x91000152
    .word 0xff540002
    .word 0x800354ff
    .word 0xd28001d2
    .word 0x045100c1
    .word 0x00069100
    .word 0x91000891
    .word 0x00aa2003
    .word 0x0018cb14
    .word 0xd2a002d0
    .word 0x03eb0001
    .word 0x0016f940
    .word 0x3940042a
    .word 0x03540004
    .word 0x9f179100
    .word 0xb400009a
    .word 0x47d10005
    .word 0x0800f900
    .word 0x54000336
    .word 0x0154000a
    .word 0x1d078b0a
    .word 0xf9401f8b

// top-16-bit dictionary (94 entries, packed as words)
    .word 0x71015400
    .word 0xf9407100
    .word 0xf9003940
    .word 0x9100d280
    .word 0xb400f100
    .word 0x54ff1100
    .word 0x12001000
    .word 0xd1009240
    .word 0x52802a18
    .word 0x8b0952a2
    .word 0xb9008b0b
    .word 0x2a00cb00
    .word 0x2a0a2a09
    .word 0x38402a17
    .word 0xdac0b7f8
    .word 0x34002a19
    .word 0x52aa5284
    .word 0x70005303
    .word 0x8b0a72a3
    .word 0xb940b5ff
    .word 0x35ffcb01
    .word 0x38603800
    .word 0x51005000
    .word 0x52005101
    .word 0x52a552a1
    .word 0x72ba52a6
    .word 0x8b178a0a
    .word 0x92809274
    .word 0x9ac09400
    .word 0xaa09a941
    .word 0xb500b4ff
    .word 0x1acecb09
    .word 0x2a162a01
    .word 0x321b2a1a
    .word 0x360f34ff
    .word 0x38203708
    .word 0x52854a09
    .word 0x531b5302
    .word 0x8a007940
    .word 0x8b018b00
    .word 0x8b1d8b15
    .word 0x9a9f9105
    .word 0x9b0d9acd
    .word 0xaa00a900
    .word 0xcb0daa0c
    .word 0xd101cb19
    .word 0x1a89d343
