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
    // w11 = (nlit<<5)|ror descriptor, x9 = nlit, x10 = nlit - 4.
    // Clobbers x3, x13, w12. The descriptor table at STUB_SIZE holds one
    // byte pair per tier: its entry count and (nlit<<5)|ror-count. The raw
    // escape is an ordinary final tier with nlit=4 and entry size 0.
_locate:
    add     x3, x6, #STUB_SIZE              // tier descriptor table
    add     x13, x3, #TIER_TBL_SIZE         // dict cursor
    sub     w4, w4, #1                      // 0-based entry index
1:  ldrb    w12, [x3], #2                   // tier entry count
    ldrb    w11, [x3, #-1]                  // tier's (nlit<<5)|ror
    lsr     x9, x11, #5                     // nlit
    sub     x10, x9, #4                     // -(entry size)
    cmp     w4, w12
    b.lo    2f                              // index falls in this tier
    sub     w4, w4, w12
    msub    x13, x12, x10, x13              // dict cursor += count * entsize
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
    bl      _locate                         // x4 = entry, w11 desc, x9 nlit
    // Assemble (entry << 8*nlit) | literals in the output buffer: store the
    // literal word, then let the entry's valid low bytes overwrite the
    // literal over-read at [x1, nlit). Both over-reads and the entry's own
    // over-read spill only into [x1+4, x1+8), which the next word (or the
    // zero store below) overwrites.
    ldr     w3, [x0]                        // literal bytes (over-read)
    add     x0, x0, x9
    str     w3, [x1]
    ldr     w5, [x4]                        // entry (over-read is discarded)
    str     w5, [x1, x9]
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

// ── compression dictionaries (auto-generated by gen_dict.py) ─────────
// Do not edit below this line

// tier descriptor table (38 bytes) + packed per-tier dictionaries:
// f0=36, p0=18, p1=13, p4=7, p5=16, p10=20, p12=5, p14=4, p17=5, p31=8, h0=13, h5=13, h26=4, h29=10, h30=9, b0=17, b3=2, b31=10
    .word 0x20120024
    .word 0x3c073f0d
    .word 0x36143b10
    .word 0x32043405
    .word 0x21082f05
    .word 0x5b0d400d
    .word 0x430a4604
    .word 0x60114209
    .word 0x610a7d02
    .word 0x00008001
    .word 0x00020000
    .word 0x00041400
    .word 0xfff51400
    .word 0x014917ff
    .word 0x012a1a89
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
    .word 0x0005f940
    .word 0x14000011
    .word 0xff140001
    .word 0x800017ff
    .word 0x54ffff52
    .word 0x018b0900
    .word 0x00049100
    .word 0x9101c391
    .word 0xfb940000
    .word 0xffff97ff
    .word 0xb5000097
    .word 0x03cb0100
    .word 0x4209d280
    .word 0xd34cfcd3
    .word 0x00294000
    .word 0x80014505
    .word 0x4bfffe48
    .word 0x21688002
    .word 0xffff9500
    .word 0x9c000a9a
    .word 0x009c35b4
    .word 0x8480aa00
    .word 0xc88001b5
    .word 0xf0cbfffe
    .word 0x40000d63
    .word 0x154fff15
    .word 0x00852800
    .word 0x71009f94
    .word 0xb38401a3
    .word 0x00015000
    .word 0xa7fe02a0
    .word 0x0da0000a
    .word 0x0042a000
    .word 0xca0049a0
    .word 0x4a95d549
    .word 0x004aa7ff
    .word 0xb8c051b8
    .word 0x51ca0051
    .word 0x0856d600
    .word 0xb8005a98
    .word 0xfb8800a1
    .word 0x85000a82
    .word 0x0a86000a
    .word 0x00249000
    .word 0xc60254a9
    .word 0x5ca805cc
    .word 0x124e1006
    .word 0xc5334e5f
    .word 0xd4404a62
    .word 0x4fdc404a
    .word 0x405294c0
    .word 0xdc4057dc
    .word 0xd6ac9f5f
    .word 0x50e2be40
    .word 0xea40e2be
    .word 0xf814a1e7
    .word 0x2a019528
    .word 0x952a01a5
    .word 0x55953141
    .word 0xacc099ac
    .word 0xab2c04ff
    .word 0x80014a0f
    .word 0xc5fca74d
    .word 0x39c50094
    .word 0x15f2d401
    .word 0x5427ff54
    .word 0x2802a9ff
    .word 0x16348e16
    .word 0xfc220000
    .word 0xfffd2fff
    .word 0x54322d2f
    .word 0xad680001
    .word 0x100069ff
    .word 0x120010ff
    .word 0x50003708
    .word 0x53035280
    .word 0x910c5304
    .word 0xa9059ad4
    .word 0xb7f8a941
    .word 0x01900150
    .word 0x02980198
    .word 0x49500395
    .word 0x4c584a98
    .word 0x51b151b0
    .word 0xc95051c2
    .word 0x4100d150
    .word 0xc0008000
    .word 0x5858c500
    .word 0x88005868
    .word 0x880e8806
    .word 0x92009000
    .word 0xa001a000
    .word 0x2c04b900
    .word 0x2c282c24
    .word 0x6a7c2c64
    .word 0xdc406b00
    .word 0xe500e400
    .word 0xa9643a83
    .word 0x4ae810d3
    .word 0x3670cdf2
    .word 0x9225289b
    .word 0x164a2672
    .word 0x54352622
    .word 0xc1a57066
    .byte 0xf0
