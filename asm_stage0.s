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

// tier descriptor table (38 bytes) + packed per-tier dictionaries:
// f0=35, p0=22, p1=11, p5=22, p7=4, p10=12, p12=5, p13=4, p17=9, p31=8, h0=11, h5=10, h27=5, h29=7, h30=11, b0=16, b3=3, b31=9
    .word 0x20160023
    .word 0x3b163f0b
    .word 0x360c3904
    .word 0x33043405
    .word 0x21082f09
    .word 0x5b0a400b
    .word 0x43074505
    .word 0x6010420b
    .word 0x61097d03
    .word 0x00028001
    .word 0x00041400
    .word 0x01491400
    .word 0x542b1a89
    .word 0x012a2905
    .word 0xf27f321b
    .word 0xfd4e381f
    .word 0x1c09381f
    .word 0x0a6a3840
    .word 0xc12a3940
    .word 0x854a5100
    .word 0x00615101
    .word 0xffa15400
    .word 0x255f54ff
    .word 0x8d3f7100
    .word 0xb13f7100
    .word 0x00027100
    .word 0x00139100
    .word 0x00199100
    .word 0x04009100
    .word 0x08029100
    .word 0x0c609100
    .word 0x05a09280
    .word 0x09a3a900
    .word 0x57f4a901
    .word 0x056ba901
    .word 0xed7ad100
    .word 0x0001d37c
    .word 0x01c0d400
    .word 0x0200d61f
    .word 0x03c0d61f
    .word 0x6b8ad65f
    .word 0x6b8af83a
    .word 0x1ffef87a
    .word 0x1ffef900
    .word 0x0001f940
    .word 0x17ffff14
    .word 0x0135ffff
    .word 0x80003700
    .word 0x54ffff52
    .word 0x016b0901
    .word 0x09008a0a
    .word 0x8b14018b
    .word 0x018b1a47
    .word 0x00029100
    .word 0x91000391
    .word 0xc3910004
    .word 0xfffb9101
    .word 0x97ffff97
    .word 0x03b50000
    .word 0x4cfcd280
    .word 0xdac011d3
    .word 0x00150c8b
    .word 0xfffe2940
    .word 0x6880024b
    .word 0x216b1f80
    .word 0x000a9500
    .word 0x9c35b49c
    .word 0xfeaa0000
    .word 0x7febcbff
    .word 0x015000da
    .word 0x00019818
    .word 0xa00002a0
    .word 0x0aa7fe0a
    .word 0x000aa7ff
    .word 0x94000da0
    .word 0x42a00042
    .word 0x00469400
    .word 0xc20049a0
    .word 0x49ca0049
    .word 0xff4a95d5
    .word 0xca004aa7
    .word 0x51b8004f
    .word 0x0051b8c0
    .word 0xc20051ca
    .word 0x5a980859
    .word 0x80a1b800
    .word 0x66360124
    .word 0x3ee2002e
    .word 0x82c0e575
    .word 0x0a85000a
    .word 0x000a8600
    .word 0x400254a9
    .word 0xdc404ad4
    .word 0x5294c04f
    .word 0x4057dc40
    .word 0xbe405fdc
    .word 0xe2be50e2
    .word 0x28f814a1
    .word 0xa52a0195
    .word 0x43f71001
    .word 0x90559531
    .word 0x0295f9fa
    .word 0x00039500
    .word 0x9309ff58
    .word 0x94c51ad5
    .word 0x0139c500
    .word 0x5415f2d4
    .word 0x94e927ff
    .word 0x9604cd7f
    .word 0x54a20ca9
    .word 0x0cb9a9ff
    .word 0x220000ac
    .word 0x01280000
    .word 0xfffc2800
    .word 0x2ffffd2f
    .word 0x04680001
    .word 0x8412a540
    .word 0xff1000a6
    .word 0x00120010
    .word 0x03528050
    .word 0x00530453
    .word 0x0572a354
    .word 0x50a941a9
    .word 0x98019001
    .word 0x50029801
    .word 0x584a9849
    .word 0xc251b04c
    .word 0x80d15051
    .word 0xc0400020
    .word 0x80602042
    .word 0x58580062
    .word 0x06880058
    .word 0x00880e88
    .word 0x24b88092
    .word 0x342c282c
    .word 0x002c642c
    .word 0x20d0006b
    .word 0xe0dc80dc
    .word 0x00e400df
    .word 0x643a83e5
    .word 0xe810d3a9
    .word 0x70cdf24a
    .word 0x25289b36
    .word 0xfc4a2692
    .word 0x35262216
    .word 0xa5706654
    .byte 0xf0
