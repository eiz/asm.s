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
    .word 0x464c457f                        // ELF magic
    .word 0x00010102                        // 64-bit, little-endian, version 1
    // e_ident ABI-version/padding: preload two stub data words, then chain
_decomp_stub_preload:
    ldp     w7, w8, [x6, #(STUB_DATA_DECOMP_DEST - CODE_START)]
    b       _decomp_stub_body
    .word 0x00b70003                        // e_type=DYN(3), e_machine=AArch64
    .word 1                                 // e_version
    .word 80                                // e_entry = p_paddr field
    .word 0
    .word 56                                // e_phoff
    .word 0
    .word 0                                 // e_shoff lo (kernel-ignored hole):
                                            //   decomp_dest, patched at output time
    .word 0                                 // e_shoff hi: rodata_size (patched)
    .word 0                                 // e_flags: reloc_count (patched)
    .word 0x00380040                        // e_ehsize=64, e_phentsize=56
    .word 1                                 // p_type=LOAD (overlaps e_phnum=1)
    .word 7                                 // p_flags=RWX
    .word 0                                 // p_offset
    .word 0
    .word 0                                 // p_vaddr
    .word 0
    // p_paddr (ignored): entry point — stub head, chains to the stub body
    adr     x6, _decomp_stub_start          // x6 = image base + CODE_START
    b       _decomp_stub_preload
    .word 0                                 // p_filesz (patched)
    .word 0
    .word 0                                 // p_memsz (patched)
    .word 0
    .word 0x10000                           // p_align
    .word 0

// ── decompressor stub ────────────────────────────────────────────────────
// Runs at the ELF entry point (chained from the p_paddr hole above).
// Decompresses .text to a page-aligned address, copies rodata, flushes
// icache, jumps to decompressed code.
// GNU as recognizes cvau/ivau as architectural operation names; asm resolves
// the same tokens as generic SYS field expressions through these aliases.
.equ cvau, (3 << 16) | (7 << 12) | (11 << 8) | (1 << 5)
.equ ivau, (3 << 16) | (7 << 12) | (5 << 8) | (1 << 5)

_decomp_stub_start:
    // ── _locate: resolve a code byte to its dictionary entry ──────────────
    // Pinned at the stub base so the assembler's compressor can call it in
    // the output template via blr x6 and share the tier walk (the template
    // is assembled into .text, so it is executable in every bootstrap
    // environment). In: w4 = code (1-based). Out: x4 = entry address,
    // w11 = (nlit<<5)|ror descriptor, x12 = nlit, x10 = nlit - 4.
    // Clobbers x3, x13, w9. The descriptor table at STUB_SIZE holds one
    // byte pair per tier: its entry count and (nlit<<5)|ror-count. The raw
    // escape is an ordinary final tier with nlit=4 and entry size 0.
_locate:
    add     x3, x6, #STUB_SIZE              // tier descriptor table
    add     x13, x3, #TIER_TBL_SIZE         // dict cursor
    sub     w4, w4, #1                      // 0-based entry index
1:  ldrb    w9, [x3], #2                    // tier entry count
    ldrb    w11, [x3, #-1]                  // tier's (nlit<<5)|ror
    lsr     x12, x11, #5                    // nlit
    sub     x10, x12, #4                    // -(entry size)
    cmp     w4, w9
    b.lo    2f                              // index falls in this tier
    sub     w4, w4, w9
    msub    x13, x9, x10, x13               // dict cursor += count * entsize
    b       1b
2:  msub    x4, x4, x10, x13                // entry address
    ret

_decomp_stub_body:
    // Preserve the caller's link register across the _locate calls: the host
    // elf2img tool patches the final blr below into ret and calls this stub
    // in-process, so x30 must survive to that (patched) return.
    add     x15, x30, #0
    // compute decompression destination; preload supplied rodata_size
    // (the data words live in ELF-header holes, behind the stub base)
    add     x7, x6, x7                      // x7 = stub_base + offset

    // stream follows the descriptor table + dictionaries in the file
    add     x0, x6, #(STUB_SIZE + DICT_SIZE)
    add     x1, x7, #0                      // output dest

    // ── decompress ────────────────────────────────────────────────────────
    // Resolve each code with _locate, then reassemble
    // (entry << 8*nlit) | literals and undo the tier rotation.
3:  ldrb    w4, [x0], #1                    // code byte
    cbz     w4, _decomp_copy_rodata
    bl      _locate                         // x4 = entry, w11 desc, x12 nlit
    // Assemble (entry << 8*nlit) | literals in the output buffer: store the
    // literal word, then let the entry's valid low bytes overwrite the
    // literal over-read at [x1, nlit). Both over-reads and the entry's own
    // over-read spill only into [x1+4, x1+8), which the next word (or the
    // zero store below) overwrites.
    ldr     w9, [x0]                        // literal bytes (over-read)
    add     x0, x0, x12
    str     w9, [x1]
    ldr     w5, [x4]                        // entry (over-read is discarded)
    str     w5, [x1, x12]
    ldr     w5, [x1]                        // assembled rotated word
    ror     w5, w5, w11                     // undo rotation (RORV reduces mod 32)
    str     w5, [x1], #4
    b       3b

    // ── copy rodata ───────────────────────────────────────────────────────
_decomp_copy_rodata:
    str     wzr, [x1]                       // re-zero the last word's spill
    // Slot offsets are biased by one; zero beyond p_filesz terminates the table.
    sub     x14, x1, #1                     // biased rodata base
    cbz     x8, _decomp_apply_reloc
7:  ldrb    w3, [x0], #1
    strb    w3, [x1], #1
    sub     x8, x8, #1
    cbnz    x8, 7b

    // ── apply .dword relocations in rodata ────────────────────────────────
_decomp_apply_reloc:
8:  ldp     w4, w5, [x0], #8                // biased slot_off (u32), target_off (u32)
    cbz     w4, _decomp_flush               // zero-backed end marker past p_filesz
    // plain register add/offset: the ldp w-form zero-extends into x4/x5,
    // and text/rodata target offsets are nonnegative. The extended-register
    // form (w4, uxtw) is outside asm's dialect — this stub must
    // be assemblable by asm itself for the seeded (no system as) bootstrap.
    add     x10, x7, x5                     // runtime pointer target
    str     x10, [x14, x4]                  // store into rodata slot
    b       8b

    // ── icache flush (x7=start, x1=end) ───────────────────────────────────
    // The start is aligned down to a line boundary: with a misaligned start
    // and a 64-byte stride, the final line of the range is never visited
    // (found the hard way: the first line-tail function a module called at
    // init faulted as UNDEF on real silicon with caches enabled).
_decomp_flush:
    and     x0, x7, #0xffffffffffffffc0
7:  dc      cvau, x0
    dsb     #11                             // ISH
    ic      ivau, x0
    add     x0, x0, #64
    cmp     x0, x1
    b.lo    7b
    dsb     #11                             // ISH
    isb
    // jump to decompressed entry (blr so x30 points to stub end); the
    // restore just before matters only when elf2img has patched blr to ret
    add     x30, x15, #0
    blr     x7
_decomp_stub_end:

// ── compression dictionaries (auto-generated by gen_dict.py) ─────────
// Do not edit below this line

// tier descriptor table (36 bytes) + packed per-tier dictionaries:
// f0=35, p0=21, p1=11, p5=16, p7=8, p10=11, p12=2, p13=6, p17=6, p31=9, h0=8, h5=10, h27=10, h30=13, h31=11, b0=19, b31=14
    .word 0x20150023
    .word 0x3b103f0b
    .word 0x360b3908
    .word 0x33063402
    .word 0x21092f06
    .word 0x5b0a4008
    .word 0x420d450a
    .word 0x6013410b
    .word 0x8001610e
    .word 0x14000002
    .word 0x14000004
    .word 0x1a890149
    .word 0x2a0016c0
    .word 0x321b012a
    .word 0x381ff27f
    .word 0x381ffd4e
    .word 0x3840166b
    .word 0x38401c09
    .word 0x5100c12a
    .word 0x5101854a
    .word 0x54000061
    .word 0x54ffffa1
    .word 0x6b09015f
    .word 0x7100255f
    .word 0x71008d3f
    .word 0x7100b13f
    .word 0x91000013
    .word 0x91000400
    .word 0x91000802
    .word 0x91000a73
    .word 0x9101c381
    .word 0x92800c60
    .word 0xa90005a0
    .word 0xa90109a3
    .word 0xa90157f4
    .word 0xd100056b
    .word 0xd37ced7a
    .word 0xd4000001
    .word 0xd61f0200
    .word 0xd65f03c0
    .word 0xf83a6b8a
    .word 0xf87a6b8a
    .word 0xf9001ffe
    .word 0xf9401ffe
    .word 0x01140000
    .word 0xfffe1400
    .word 0x35ffff17
    .word 0x05370001
    .word 0xffff5317
    .word 0x8b090054
    .word 0x018b1a47
    .word 0x00049100
    .word 0x9101c391
    .word 0xfc940000
    .word 0xfffd97ff
    .word 0x97fffe97
    .word 0x03b50000
    .word 0x8007d280
    .word 0xd34209d2
    .word 0x00d61f01
    .word 0x40001b88
    .word 0x45050029
    .word 0x02488001
    .word 0x00216880
    .word 0x9c000a95
    .word 0x00a94000
    .word 0x8e81aa00
    .word 0xc88001c5
    .word 0x00019818
    .word 0xb1f802a0
    .word 0x0aa00006
    .word 0xff0aa7fe
    .word 0xa0000aa7
    .word 0x4294000d
    .word 0x0042a000
    .word 0xca0049a0
    .word 0x4aa7ff49
    .word 0xc051b800
    .word 0xca0051b8
    .word 0xa1b80051
    .word 0x0000a636
    .word 0x663615f2
    .word 0x3ee2002e
    .word 0x80405400
    .word 0x72ff9270
    .word 0xc0e5759a
    .word 0x85000a82
    .word 0x0a86000a
    .word 0x0254a900
    .word 0x40065ca8
    .word 0xdc404ad4
    .word 0x5294c04f
    .word 0x4057dc40
    .word 0x14a15fdc
    .word 0x01a52af8
    .word 0x95f9fa90
    .word 0x03950002
    .word 0x00529500
    .word 0x5800ca94
    .word 0xd59309ff
    .word 0x0094c51a
    .word 0x540139c5
    .word 0x04cd27ff
    .word 0xa79fb896
    .word 0x00a9ff54
    .word 0xfff72200
    .word 0x2ffffe2f
    .word 0x012fffff
    .word 0x40046800
    .word 0xa699f8a5
    .word 0x07b58022
    .word 0x1000f280
    .word 0x120010ff
    .word 0x53035000
    .word 0xa9417101
    .word 0x0150b7f8
    .word 0x01980190
    .word 0x4a954950
    .word 0x51b04c58
    .word 0x595051c2
    .word 0x0d6dca95
    .word 0x40002080
    .word 0x602042c0
    .word 0x61206060
    .word 0x62606160
    .word 0x2c286280
    .word 0x2c342c30
    .word 0x44002c64
    .word 0x44074403
    .word 0xd3ff6b00
    .word 0xe100dc80
    .word 0xe500e400
    .word 0x520a2480
    .word 0x68005412
    .word 0x6e206e10
    .word 0xa5009600
    .word 0xa800a608
    .word 0x3a83e200
    .word 0x1ad3a964
    .word 0xcb5253eb
    .word 0x2a8b3870
    .word 0x37369ab5
    .word 0x222000aa
    .word 0x64362624
    .word 0x9a947066
    .byte 0xc1
    .byte 0xe5
    .byte 0xf0
