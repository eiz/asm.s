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
7:  cmp     w4, #RAW_CODE
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

// full instruction dictionary (77 entries)
    .word 0xd65f03c0
    .word 0xd4000001
    .word 0x6b09015f
    .word 0x38401c09
    .word 0x71008d3f
    .word 0x7101853f
    .word 0x7101c95f
    .word 0xf86b6b8a
    .word 0x39400a6a
    .word 0x7100255f
    .word 0x7100b13f
    .word 0x7101753f
    .word 0x7101b95f
    .word 0xf9001bfe
    .word 0xf9400f8b
    .word 0x1a890149
    .word 0xa90157f4
    .word 0xa9025ff6
    .word 0xa9bc4ffe
    .word 0xd2ac0016
    .word 0x2a090000
    .word 0x2a160000
    .word 0x2a170000
    .word 0x39400009
    .word 0x5100c12a
    .word 0x5101854a
    .word 0x54000061
    .word 0x7101c93f
    .word 0x7101cd3f
    .word 0x7101e95f
    .word 0x7940026a
    .word 0x91000400
    .word 0xf1000e9f
    .word 0xf9401bfe
    .word 0x2a160129
    .word 0x321b012a
    .word 0x39400a69
    .word 0x54000060
    .word 0x7100b93f
    .word 0x7101b93f
    .word 0x7101bd5f
    .word 0x7101d13f
    .word 0x8b0a216b
    .word 0x8b17156b
    .word 0x91000013
    .word 0x9101c339
    .word 0x92800c60
    .word 0xa9bf53fe
    .word 0xd37ced7a
    .word 0xf1000a9f
    .word 0xf82b6b8a
    .word 0xf9001ffe
    .word 0xf9401389
    .word 0x54ffffa1
    .word 0x91000260
    .word 0x12004800
    .word 0x14000005
    .word 0x2905542b
    .word 0x2a002929
    .word 0x2a0a2800
    .word 0x2a166000
    .word 0x2a177f40
    .word 0x2a181529
    .word 0x2a190000
    .word 0x381ffd4e
    .word 0x38401409
    .word 0x39400049
    .word 0x39400269
    .word 0x3940080a
    .word 0x5101d14a
    .word 0x540000a1
    .word 0x540006a0
    .word 0x54001380
    .word 0x7101713f
    .word 0x71017d3f
    .word 0x7101953f
    .word 0x7101a13f

// top-24-bit dictionary (80 entries, 3 bytes each, packed)
    .word 0x0017ffff
    .word 0xfffe1400
    .word 0x97ffff97
    .word 0xfb97fffd
    .word 0xfffc97ff
    .word 0x94000097
    .word 0x0017fffe
    .word 0x80009100
    .word 0x540000d2
    .word 0x0117fffd
    .word 0x00011400
    .word 0x91028354
    .word 0x02910001
    .word 0xfffc9100
    .word 0x94000117
    .word 0x03140002
    .word 0x00005400
    .word 0xb5ffffb4
    .word 0x07380014
    .word 0x00048b1d
    .word 0xd2800391
    .word 0x47d34cfc
    .word 0x4003f900
    .word 0x530411f9
    .word 0x91540002
    .word 0x09007101
    .word 0x8b09028b
    .word 0x05b94001
    .word 0xa002d100
    .word 0xeb0001d2
    .word 0x042a0016
    .word 0x80003940
    .word 0x71018952
    .word 0x067101b1
    .word 0x00089100
    .word 0xd2800191
    .word 0x16d28007
    .word 0x6d692a19
    .word 0x39400e38
    .word 0x04528001
    .word 0x000d5400
    .word 0x54001b54
    .word 0x0154ffff
    .word 0x01008a0a
    .word 0x8b0b478b
    .word 0x038b1500
    .word 0x00038b1d
    .word 0x9101c191
    .word 0xcecb1400
    .word 0xf7e110ff
    .word 0x39400636
    .word 0x1a540009
    .word 0xffe65400
    .word 0x7101b554
    .word 0xe17101d5
    .word 0x40007101
    .word 0x9342fc79
    .word 0x01b3607c
    .word 0x0018b400
    .word 0xdac011d0

// top-16-bit dictionary (64 entries, packed as words)
    .word 0x71015400
    .word 0xf9407100
    .word 0xf1001100
    .word 0x54fff900
    .word 0x12001000
    .word 0x39403400
    .word 0xb4009100
    .word 0x34ffb7f8
    .word 0x70005100
    .word 0xdac0d280
    .word 0x2a0a2a00
    .word 0x35ff2a18
    .word 0x92405000
    .word 0xb900b500
    .word 0x9a9f5284
    .word 0x2a17cb00
    .word 0x38402a19
    .word 0x52805200
    .word 0x52aa52a2
    .word 0x530352ba
    .word 0x72ba72a3
    .word 0x9ac08b00
    .word 0xcb09b4ff
    .word 0xd61fd100
    .word 0x52852a09
    .word 0x52a552a1
    .word 0x8a2952a6
    .word 0xd101a941
    .word 0x2a011ace
    .word 0x2a162a0b
    .word 0x381f2a1a
    .word 0x52814b09

// top-8-bit dictionary (32 entries, packed as words)
    .word 0x8b53a952
    .word 0x38d39acb
    .word 0xebb8aa1a
    .word 0x4a3332f8
    .word 0xd2a89291
    .word 0x8a72370b
    .word 0x4b2ab29b
    .word 0x28d1786b
