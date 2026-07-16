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
    // compute decompression destination; preload supplied rodata_size
    // (the data words live in ELF-header holes, behind the stub base)
    add     x7, x6, x7                  // x7 = stub_base + offset

    // set up dict/stream pointers (right after stub in file)
    add     x2, x6, #(STUB_SIZE - 4)    // full_dict - 4 (codes 1..FULL)
    add     x10, x2, #(FULL_DICT_SIZE + 4 - 3*(FULL_DICT_ENTRIES + 1))  // 3-byte prefix codes
    add     x3, x2, #(FULL_DICT_SIZE + T24_DICT_SIZE + R24_DICT_SIZE + R5_DICT_SIZE + 4 - 2*(FULL_DICT_ENTRIES + T24_DICT_ENTRIES + R24_DICT_ENTRIES + R5_DICT_ENTRIES + 1)) // t16 codes
    add     x11, x2, #(FULL_DICT_SIZE + T24_DICT_SIZE + R24_DICT_SIZE + R5_DICT_SIZE + T16_DICT_SIZE + 4 - (FULL_DICT_ENTRIES + T24_DICT_ENTRIES + R24_DICT_ENTRIES + R5_DICT_ENTRIES + T16_DICT_ENTRIES + 1)) // t8 codes
    add     x0, x2, #(DICT_SIZE + 4)    // stream
    add     x1, x7, #0                  // output dest
    // Supported loaders page-align the image. The tier layout makes
    // x3's low five bits also supply RORV's inverse-rotation count 22
    // while x3 remains the stable t16 dictionary pointer.

    // ── decompress ────────────────────────────────────────────────────────
3:  ldrb    w4, [x0], #1
    cbz     w4, _decomp_copy_rodata
    ldr     w5, [x2, x4, lsl #2]       // speculative full dict (harmless otherwise)
    cmp     w4, #FULL_DICT_ENTRIES
    b.ls    6f                          // full dict hit
    cmp     w4, #(FULL_DICT_ENTRIES + T24_DICT_ENTRIES + R24_DICT_ENTRIES + R5_DICT_ENTRIES)
    b.hi    5f
    // Three-byte packed prefix + one literal byte. High-bit codes use ROR10
    // through code 154, then ROR5; biased pointers double as inverse counts.
    add     x5, x4, x4, lsl #1         // code * 3
    ldr     w5, [x10, x5]
    ldrb    w9, [x0], #1
    orr     w5, w9, w5, lsl #8
    tbz     w4, #7, 6f
    cmp     w4, #(FULL_DICT_ENTRIES + T24_DICT_ENTRIES + R24_DICT_ENTRIES)
    csel    x13, x3, x10, ls
    ror     w5, w5, w13
    b       6f
5:  cmp     w4, #(FULL_DICT_ENTRIES + T24_DICT_ENTRIES + R24_DICT_ENTRIES + R5_DICT_ENTRIES + T16_DICT_ENTRIES)
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
    // Slot offsets are biased by one; zero beyond p_filesz terminates the table.
    sub     x14, x1, #1                 // biased rodata base
    cbz     x8, _decomp_apply_reloc
7:  ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    sub     x8, x8, #1
    cbnz    x8, 7b

    // ── apply .dword relocations in rodata ────────────────────────────────
_decomp_apply_reloc:
8:  ldp     w4, w5, [x0], #8           // biased slot_off (u32), target_off (u32)
    cbz     w4, _decomp_flush           // zero-backed end marker past p_filesz
    // plain register add/offset: the ldp w-form zero-extends into x4/x5,
    // and text/rodata target offsets are nonnegative. The extended-register
    // form (w4, uxtw) is outside asm's dialect — this stub must
    // be assemblable by asm itself for the seeded (no system as) bootstrap.
    add     x10, x7, x5                // runtime pointer target
    str     x10, [x14, x4]             // store into rodata slot
    b       8b

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

// full instruction dictionary (70 entries)
    .word 0x00000000
    .word 0x000ccd47
    .word 0x110184c7
    .word 0x13020a96
    .word 0x14000002
    .word 0x14000004
    .word 0x17fffff5
    .word 0x1a890149
    .word 0x28812654
    .word 0x2905542b
    .word 0x2a004339
    .word 0x321b012a
    .word 0x34ffc229
    .word 0x35fffd6a
    .word 0x371000ba
    .word 0x381ff27f
    .word 0x381ffd4e
    .word 0x3840166b
    .word 0x38401c09
    .word 0x39400a6a
    .word 0x397f8ccd
    .word 0x5100c12a
    .word 0x5101854a
    .word 0x5101dd21
    .word 0x52800808
    .word 0x52a26000
    .word 0x52aa501a
    .word 0x54000061
    .word 0x540000a1
    .word 0x54000361
    .word 0x54ffffa1
    .word 0x6b09015f
    .word 0x7100255f
    .word 0x71008d3f
    .word 0x7100b13f
    .word 0x7101753f
    .word 0x7101853f
    .word 0x7940026a
    .word 0x8b0a20eb
    .word 0x91000002
    .word 0x91000013
    .word 0x91000260
    .word 0x91000400
    .word 0x91000802
    .word 0x91000a73
    .word 0x9101c381
    .word 0x92800c60
    .word 0x9342fc00
    .word 0xa90005a0
    .word 0xa90109a3
    .word 0xa90157f4
    .word 0xa9bc4ffe
    .word 0xa9bf53fe
    .word 0xb2400ed6
    .word 0xb3607c00
    .word 0xcd170698
    .word 0xd100056b
    .word 0xd37ced7a
    .word 0xd4000001
    .word 0xd61f0200
    .word 0xd63f0120
    .word 0xd65f03c0
    .word 0xe0cdcdcf
    .word 0xe8266c12
    .word 0xf268cc1f
    .word 0xf83a6b8a
    .word 0xf87a6b8a
    .word 0xf9001bfe
    .word 0xf9001ffe
    .word 0xf9002389

// packed prefix dictionaries: t24=57*3, r24=27*3, r5=32*3, t16=32*2, t8=36 bytes
    .word 0x05110000
    .word 0x00001100
    .word 0x14000114
    .word 0xff17fffe
    .word 0x191617ff
    .word 0x35ffff2a
    .word 0x01370001
    .word 0x00143710
    .word 0x38001538
    .word 0x0e386b69
    .word 0x00c15100
    .word 0x52800051
    .word 0x05528001
    .word 0x17055301
    .word 0x54000053
    .word 0x0054ffff
    .word 0x0a017940
    .word 0x8b01008a
    .word 0x018b0900
    .word 0x16028b14
    .word 0x8b17158b
    .word 0x038b1a47
    .word 0x00008b1d
    .word 0x91000191
    .word 0x03910002
    .word 0x00049100
    .word 0x9101c191
    .word 0x009101c3
    .word 0xfffb9400
    .word 0x97fffc97
    .word 0xfe97fffd
    .word 0xffff97ff
    .word 0xb4000097
    .word 0x00b4ffd6
    .word 0x4001b500
    .word 0xcb0100b9
    .word 0xc0d10004
    .word 0x8003d101
    .word 0xd28007d2
    .word 0x09d2a002
    .word 0x4cfcd342
    .word 0xf94003d3
    .word 0x82f9400f
    .word 0x0a85000a
    .word 0x000a8600
    .word 0xa90014c6
    .word 0x94a80254
    .word 0x05ccc602
    .word 0xa10654a0
    .word 0x5ca80654
    .word 0x0694a806
    .word 0x40124e10
    .word 0x9c4037dc
    .word 0x4ad4404a
    .word 0xc04fdc40
    .word 0xdc405294
    .word 0x5aca8557
    .word 0x405aca86
    .word 0xdc405fdc
    .word 0x9ce6b067
    .word 0x40d6ac9f
    .word 0xea40e2be
    .word 0xf814a1e7
    .word 0x00008002
    .word 0x98180150
    .word 0x0198b101
    .word 0x0002a000
    .word 0x58a00488
    .word 0x06b0f806
    .word 0x010aa000
    .word 0xa7fe0aa0
    .word 0x0aa7ff0a
    .word 0x000da000
    .word 0xa00042a0
    .word 0x49ca0049
    .word 0xff4a95d5
    .word 0xb0414aa7
    .word 0x51b80051
    .word 0xc051b880
    .word 0xca0051b8
    .word 0x54585051
    .word 0xc8565848
    .word 0x88005658
    .word 0x56d60056
    .word 0x00a1b800
    .word 0x8800f7ca
    .word 0xff58a0fb
    .word 0x11001000
    .word 0x2a001200
    .word 0x2a162a09
    .word 0x30002a17
    .word 0x36003400
    .word 0x37203708
    .word 0x50003940
    .word 0x52805200
    .word 0x53045303
    .word 0x72ba5400
    .word 0x91008b13
    .word 0xa9419240
    .word 0xb7f8b400
    .word 0xcb00b900
    .word 0xf100dac0
    .word 0xf940f900
    .word 0xa9643a83
    .word 0x53eb1ad3
    .word 0x3870cb52
    .word 0x9ab52a8b
    .word 0x3332100b
    .word 0x4b4a3736
    .word 0x8a78726b
    .word 0xa89b9291
    .word 0xf8d1b8aa
