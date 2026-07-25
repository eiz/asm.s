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
    .word 0                                 // p_memsz (patched, includes 4-byte stub scratch)
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
    // byte pair per tier: its entry count and (nlit<<5)|ror-count. Return is
    // through pinned x15 so callers can preserve x30 without a save. The raw
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
    br      x15

_decomp_stub_body:
    // _locate returns here through x15 without changing x30. The host elf2img
    // tool patches the final blr below into ret and calls this stub in-process,
    // so preserving the caller's link register matters on that path.
    adr     x15, _decomp_located
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
    b       _locate                         // x4 = entry, w11 desc, x9 nlit
_decomp_located:
    // Assemble (entry << 8*nlit) | literals in the output buffer: store the
    // literal word, then let the entry's valid low bytes overwrite the
    // literal over-read at [x1, nlit). Both over-reads and the entry's own
    // over-read spill only into [x1+4, x1+8), which the next word (or the
    // zero store below) overwrites. p_memsz reserves four scratch bytes for
    // the final spill when no following rodata or bss exists.
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
    str     wzr, [x1]                       // re-zero the reserved final spill
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
    // x30 still holds the elf2img caller when that blr has been patched to ret.
    blr     x7

// ── compression dictionaries (auto-generated by gen_dict.py) ─────────
// Do not edit below this line

// tier descriptor table (36 bytes) + packed per-tier dictionaries:
// f0=36, p0=23, p1=16, p4=7, p5=17, p10=13, p12=3, p13=5, p17=6, p31=3, h0=9, h5=12, h27=6, h29=8, h30=10, b0=20, b31=9
    .word 0x20170024
    .word 0x3c073f10
    .word 0x360d3b11
    .word 0x33053403
    .word 0x21032f06
    .word 0x5b0c4009
    .word 0x43084506
    .word 0x6014420a
    .word 0x80016109
    .word 0x00000000
    .word 0x14000002
    .word 0x14000004
    .word 0x1a890149
    .word 0x321b012a
    .word 0x381ff25f
    .word 0x38401c09
    .word 0x39400a4a
    .word 0x5100c12a
    .word 0x5101854a
    .word 0x54000061
    .word 0x540000a1
    .word 0x54ffffa1
    .word 0x7100255f
    .word 0x71008d3f
    .word 0x7100b13f
    .word 0x7101853f
    .word 0x91000400
    .word 0x92800c60
    .word 0xa90005a0
    .word 0xa90109a3
    .word 0xa90157f4
    .word 0xaa0003e2
    .word 0xd1000012
    .word 0xd100056b
    .word 0xd37ced7a
    .word 0xd4000001
    .word 0xd61f0220
    .word 0xd61f02c0
    .word 0xd63f00e0
    .word 0xd63f03a0
    .word 0xd65f03c0
    .word 0xf83a6b8a
    .word 0xf87a6b8a
    .word 0xf9001ffe
    .word 0xf9401ffe
    .word 0x00110005
    .word 0xfffe1400
    .word 0x17ffff17
    .word 0xff330305
    .word 0x800035ff
    .word 0x53170552
    .word 0x0154ffff
    .word 0x09006b09
    .word 0x9100018b
    .word 0x04910002
    .word 0x01c39100
    .word 0x94000091
    .word 0xfd97fffc
    .word 0x000097ff
    .word 0xd10003b5
    .word 0x09d28003
    .word 0x4cfcd342
    .word 0x294000d3
    .word 0x00450500
    .word 0x8d234580
    .word 0x4bffff45
    .word 0x80658001
    .word 0x80026580
    .word 0x6b1f8068
    .word 0x0a950021
    .word 0x35b49c00
    .word 0xa989029c
    .word 0xffaa0000
    .word 0x8000cbff
    .word 0x291000e5
    .word 0x00852800
    .word 0x94009370
    .word 0xa371009f
    .word 0x00b38401
    .word 0x5000f710
    .word 0x02a00001
    .word 0xff0aa000
    .word 0xa0000aa7
    .word 0x42a0000d
    .word 0x0049a000
    .word 0xca0049c2
    .word 0x4a95d549
    .word 0x004aa7ff
    .word 0xb8c051b8
    .word 0x51ca0051
    .word 0x0856d600
    .word 0xb8005a98
    .word 0x000a82a1
    .word 0x90000a86
    .word 0x54a90024
    .word 0x065ca802
    .word 0x404ad440
    .word 0x94c04fdc
    .word 0x57dc4052
    .word 0x405fdc40
    .word 0xbe50e2be
    .word 0xf814a1e2
    .word 0x2701a52a
    .word 0xfa9035ab
    .word 0x000295f9
    .word 0x5800ca94
    .word 0xca9509ff
    .word 0xf94e9a20
    .word 0x450094c5
    .word 0xf2d40129
    .word 0x25ff5415
    .word 0x549604cd
    .word 0x0000a9ff
    .word 0x64d80722
    .word 0x00680001
    .word 0x20120010
    .word 0x80500037
    .word 0x00530352
    .word 0x41a9059b
    .word 0x900150a9
    .word 0x98019801
    .word 0x50039502
    .word 0x584a9849
    .word 0xc251b04c
    .word 0x50b99851
    .word 0x8019b9d1
    .word 0x82400020
    .word 0x80616060
    .word 0x00586862
    .word 0x0e880688
    .word 0x00920088
    .word 0x40a001a0
    .word 0x282c24b8
    .word 0xff2c642c
    .word 0x406b0043
    .word 0x7fdfe0dc
    .word 0x00e400e0
    .word 0x643a83e5
    .word 0xe810d34a
    .word 0x70cd5237
    .word 0x3528cba9
    .word 0x72363292
    .word 0x262216b4
    .word 0x66605435
    .byte 0x70
    .byte 0xf0
