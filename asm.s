// asm.s — self-hosting aarch64 assembler
//
// reads an aarch64 assembly source file (GAS-compatible subset),
// emits a static PIE ELF binary directly. no linker required.
//
// usage: asm <input.s> <output>
//
// this file was created solely by AI agents: Claude (Opus 4.6, Sonnet 4.6,
// and Fable 5) and Codex (GPT-5.6 Sol). It is in the public domain (or CC0
// 1.0, if you prefer).
//
// to bootstrap: as -o asm.o asm.s asm_stage0.s && ld -o asm0 asm.o && ./asm0 asm.s asm
// or, seeded by any earlier asm binary (no system toolchain):
//   cat asm.s asm_stage0.s > s0.s && ./asm_seed s0.s asm0 && ./asm0 asm.s asm
//
// current binary size: 3881 bytes
//
// ── supported instructions ────────────────────────────────────────────────
//
//  arithmetic/logic:
//    add   Rd, Rn, #imm12 | Rm [, lsl #N]     sub (same forms)
//    adds  Rd, Rn, #imm12 | Rm [, lsl #N]     subs (same forms)
//    cmp   Rn, #imm12 | Rm [, lsl #N]         cmn (same forms)
//    and   Rd, Rn, #bitmask | Rm [, lsl #N]   orr, eor (same forms)
//    ands  Rd, Rn, #bitmask | Rm [, lsl #N]   (flag-setting AND)
//    tst   Rn, #bitmask | Rm                  (ANDS alias, Rd=XZR)
//    bic   Rd, Rn, Rm
//    neg   Rd, Rm                             mvn Rd, Rm
//    mul   Rd, Rn, Rm                         msub Rd, Rn, Rm, Ra
//    madd  Rd, Rn, Rm, Ra                     (Rd = Ra + Rn*Rm)
//    udiv  Rd, Rn, Rm                         sdiv Rd, Rn, Rm
//    nop
//
//  moves:
//    mov   Rd, Rm | #imm (MOVZ/MOVN-encodable) | SP
//    movz  Rd, #imm16 [, lsl #N]              movn, movk (same forms)
//
//  shifts:
//    lsl   Rd, Rn, Rm | #N                    lsr, asr (same forms)
//    ror   Rd, Rn, Rm
//
//  bitfield:
//    ubfm  Rd, Rn, #immr, #imms            sbfm, bfm (same forms)
//    ubfx  Rd, Rn, #lsb, #width            sbfx (same form)
//    ubfiz Rd, Rn, #lsb, #width            sbfiz, bfi (same form)
//    bfxil Rd, Rn, #lsb, #width
//    sxtb  Rd, Wn    sxth Rd, Wn    sxtw Rd, Wn
//    uxtb  Wd, Wn    uxth Wd, Wn
//
//  bit manipulation:
//    clz   Rd, Rn                             rbit Rd, Rn
//
//  branches:
//    b     label       bl label       br Xn      blr Xn     ret
//    b.cc  label       (eq ne hs lo mi pl vs vc hi ls ge lt gt le al cs cc)
//    cbz   Rt, label   cbnz Rt, label
//    tbz   Rt, #bit, label            tbnz Rt, #bit, label
//
//  conditional:
//    csel  Rd, Rn, Rm, cc             csinc Rd, Rn, Rm, cc
//    cset  Rd, cc
//
//  address:
//    adr   Rd, expr                   adrp Rd, symbol
//
//  load/store (single):
//    ldr   Rt, [Rn {, #imm | :lo12:sym}]      str (same forms)
//    ldr   Rt, [Rn, Rm {, lsl #N}]            str (same forms)
//    ldr   Rt, [Rn, #simm9]!                  str (pre-index)
//    ldr   Rt, [Rn], #simm9                   str (post-index)
//    ldr   Rt, label                           (PC-relative literal)
//    ldr   Rt, =label                          (pseudo: adrp + add :lo12:)
//    ldrb  (same addressing modes)             strb
//    ldrh  (same addressing modes)             strh
//    ldrsb Rt, [Rn {, ...}]                   ldrsh, ldrsw
//
//  load/store (pair):
//    ldp   Rt1, Rt2, [Rn {, #imm}]            stp (same forms)
//    ldp   Rt1, Rt2, [Rn, #imm]!              stp (pre-index)
//    ldp   Rt1, Rt2, [Rn], #imm               stp (post-index)
//
//  system:
//    svc/hvc #imm16    eret   ret   nop
//    mrs   Rt, sysexpr        msr sysexpr, Rt    msr daifset/daifclr, #imm
//    isb   wfi   wfe          dsb/dmb #imm(CRm)
//    dc/ic/tlbi/at fieldexpr, Xt   (use xzr for architecturally operandless forms)
//
// ── registers ─────────────────────────────────────────────────────────────
//    x0-x30, w0-w30, xzr, wzr, sp   (no fp/lr aliases)
//
// ── directives ────────────────────────────────────────────────────────────
//    .text  .bss  .section .rodata  .global name  .equ name, expr
//    .word expr   .dword expr       .ascii "str"      .asciz "str"
//    .dword label[+const|-const]    (.rodata only; pointer relocated at runtime)
//    .align N     .skip N            .include "path"   (path relative to CWD)
//
// ── expressions ───────────────────────────────────────────────────────────
//    operators: | & + - * << >>   unary: ~ -   grouping: ( )
//    atoms: 123  0xFF  'A'  '\n'  .  label  :lo12:expr
//    labels: name:  N: (numeric 0-9, ref as Nf/Nb)
//    comments: //
//
// ── output ────────────────────────────────────────────────────────────────
//    ELF64 static PIE, single LOAD segment (RWX), no section headers.
//    .text is dictionary-compressed; the entry stub decompresses it and
//    applies .dword label-pointer relocations in .rodata.
//

// ── syscall numbers ───────────────────────────────────────────────────────
.equ SYS_exit,       93
.equ SYS_read,       63
.equ SYS_write,      64
.equ SYS_openat,     56
.equ SYS_close,      57

// ── file constants ────────────────────────────────────────────────────────
.equ AT_FDCWD,             -100
.equ O_RDONLY,             0
.equ O_WRONLY_CREAT_TRUNC, 577              // O_WRONLY|O_CREAT|O_TRUNC = 1|64|512
.equ STDERR,               2

// ── ELF constants ─────────────────────────────────────────────────────────
.equ ELF_HEADER_SIZE, 64
.equ PHDR_SIZE,       56
.equ CODE_START,      112                   // ehdr + phdr, phdr overlaps last 8 ehdr bytes

// ── compression constants ─────────────────────────────────────────────────
// stub bytes from CODE_START to the tier table; four more stub instructions
// live in ELF-header holes (e_ident padding + p_paddr, entry point at 80)
.equ STUB_SIZE,              212
// stub data words live in zero ELF-header holes the kernel ignores
// (e_shoff and e_flags), patched at output time
.equ STUB_DATA_DECOMP_DEST, 40              // image offset of decomp_dest word (e_shoff)
.equ STUB_DATA_RODATA_SIZE, 44              // image offset of rodata_size word
.equ STUB_DATA_RELOC_COUNT, 48              // image offset of reloc_count word (e_flags)
// Table-driven tier compression: code 0 ends the stream; codes 1..N are
// dictionary tiers described by the descriptor table at STUB_SIZE (one byte
// pair per tier: its entry count, then (nlit<<5)|ror-count);
// the single code N+1 is the raw escape (a normal table entry with nlit=4).
// A word matches a tier entry when ror32(word, rot) >> (8*nlit) equals the
// entry; the literal bytes carry the low bits of the rotated word.
// gen_dict.py owns the tier menu and asserts these three constants.
.equ TIER_TBL_SIZE,      38                 // (18 tiers + raw escape) * 2 bytes
.equ DICT_SIZE,         585                 // table + packed dicts (exact, unpadded)
.equ COND_DICT_OFF,     557                 // ('b',0) dict offset within the blob
.equ RAW_CODE,          205                 // 1 + total dictionary codes

// ── section IDs ───────────────────────────────────────────────────────────
.equ SEC_TEXT,       0                      // pre-multiplied by 8 for direct state block indexing
.equ SEC_RODATA,     8
.equ SEC_BSS,        16

// ── state block offsets (all u64) ─────────────────────────────────────────
.equ ST_TEXT_POS,    0                      // current offset within .text
.equ ST_RODATA_POS,  8                      // current offset within .rodata
.equ ST_BSS_POS,     16                     // current offset within .bss
.equ ST_CUR_SEC,     24                     // current section (SEC_TEXT/RODATA/BSS)
.equ ST_TEXT_BASE,   32                     // virtual address of .text start
.equ ST_RODATA_BASE, 40                     // virtual address of .rodata start
.equ ST_BSS_BASE,    48                     // virtual address of .bss start
.equ ST_PASS,        56                     // zero .equ base; ST_TEXT_BASE 0 marks pass 1
.equ ST_INPUT_LEN,   64                     // input buffer content length (grows as
                                            // .include files are appended during a pass)
.equ ST_MAIN_LEN,    72                     // main input file length (append-cursor reset)
.equ ST_INPUT_NAME,  80                     // pointer to input filename string
.equ ST_OUTPUT_NAME, 88                     // pointer to output filename string
.equ ST_ALIGN_MASK,  96                     // OR of all (2^N-1) masks seen in .align directives
.equ ST_SIZE,        112                    // keep the following input buffer 16-aligned

// ── symbol table entry layout (32 bytes) ──────────────────────────────────
// name_ptr  u64 @ 0   pointer to name in input buffer (0 = empty slot)
// name_len  u32 @ 8   length of name
// base_sel  u64 @ 16  offset from ST_TEXT_BASE (SYMF_EQU selects ST_PASS)
// value     u64 @ 24  address or .equ value
.equ SYM_ENT_SIZE,   32
.equ SYM_NAME_PTR,   0
.equ SYM_NAME_LEN,   8
.equ SYM_FLAGS,      16
.equ SYM_VALUE,      24
.equ SYM_TBL_SLOTS,  1024                   // maximum named symbols

// ── symbol flags ──────────────────────────────────────────────────────────
.equ SYMF_EQU,       ST_PASS - ST_TEXT_BASE
.equ SYMF_SEC_SHIFT, 3                      // section (pre-multiplied by 8) in bits 4:3

// ── buffer sizes ──────────────────────────────────────────────────────────
.equ INPUT_BUF_SIZE,  1048576               // 1 MB
.equ TEXT_BUF_SIZE,   1048576               // 1 MB
.equ RODATA_BUF_SIZE, 1048576               // 1 MB
.equ SYM_TBL_BYTES,   32768                 // SYM_TBL_SLOTS * SYM_ENT_SIZE
.equ RELOC_MAX_ENTRIES, 32768
.equ RELOC_TBL_BYTES,   262144

// ── BSS offsets from x28 (state block pointer) ────────────────────────────
.equ INPUT_BUF_OFF,   ST_SIZE

// ── numeric labels ────────────────────────────────────────────────────────
// each digit owns a 64-slot block of u32 .text offsets:
// slot 0 = def count/cursor, defs at 1..63
.equ NUMLAB_MAX_DEFS, 64
.equ NUMLAB_DIGITS,   10                    // digits 0-9

// ══════════════════════════════════════════════════════════════════════════
//  BSS
// ══════════════════════════════════════════════════════════════════════════
.bss
.align 4
// Keep the direct-addressed tables before state: state-relative buffer offsets
// stay unchanged while both tables remain close enough to address with ADR.
numlab_defs:  .skip NUMLAB_DIGITS * NUMLAB_MAX_DEFS * 4
reloc_table:  .skip RELOC_TBL_BYTES
sym_table:    .skip SYM_TBL_BYTES
state:        .skip ST_SIZE
input_buf:    .skip INPUT_BUF_SIZE
text_buf:     .skip TEXT_BUF_SIZE
rodata_buf:   .skip RODATA_BUF_SIZE

// ══════════════════════════════════════════════════════════════════════════
//  Read-only data
// ══════════════════════════════════════════════════════════════════════════
.section .rodata

// Diagnostics use a 5-bit alphabet: a-z=0..25, then ". \n:<>": newline=28.
// Each message is byte-aligned and ends at newline; die_msg expands it before
// calling the ordinary write helper.  The exact decoded text remains part of
// the assembler's tested interface.
msg_badins:
    .byte   0xb4, 0xa9, 0xe6, 0x6c, 0xdb, 0xa8, 0xc9, 0x19, 0xa9, 0x98
    .byte   0xc8, 0xb5
// badins' four terminal bits share the first punctuation byte.
msg_punct:
    .byte   '.', ' ', '\n', ':', '<', '>'
msg_usage:
    .byte   0x54, 0x02, 0x43, 0xfa, 0x06, 0x92, 0x6d, 0x8f, 0xda, 0xa3
    .byte   0x53, 0xcb, 0xbf, 0xbd, 0xa3, 0xf3, 0xd1, 0xf9, 0x39
msg_open:
    .byte   0x02, 0xb4, 0xe6, 0xe6, 0x76, 0x8f, 0xb4, 0x8d, 0xda, 0xa3
    .byte   0x73, 0x17, 0xb4, 0x08, 0x07
msg_syntax:
    .byte   0x12, 0xb7, 0x09, 0xee, 0x26, 0x31, 0xba, 0xc8
// Syntax shares its terminal bit with badreg; badreg in turn shares its
// terminal bit with overflow.
msg_badreg:
    .byte   0x01, 0x8c, 0x1d, 0x89, 0x41, 0x72, 0x92, 0xc8
msg_overflow:
    .byte   0x81, 0x96
    .byte   0x42, 0xe2, 0x76, 0x95, 0xc4, 0xb2, 0x9c, 0xe5
msg_create:
    .byte   0x02, 0xb4, 0xe6, 0xe6, 0x16, 0x91, 0x80, 0x49, 0xb6, 0xa3
    .byte   0xf3, 0xd1, 0xb9, 0x0b, 0x5a, 0xa4, 0x03
msg_badimm:
    .byte   0xa8, 0x55, 0xb0, 0xd0, 0xd8, 0x88, 0x31, 0x32, 0x10, 0x98
    .byte   0x84
// badimm's two terminal bits share trailing's first byte.
msg_trailing:
    .byte   0x33, 0x02, 0xb4, 0x50, 0x33, 0xdb, 0x3d, 0x12, 0x41, 0x1b
    .byte   0x92, 0x03
msg_undef:
    .byte   0xb4, 0x0d, 0x52, 0x50, 0x23, 0x63, 0x4b, 0xcc, 0x82, 0x5b

// operator table for expression parser: 2-byte entries (char, packed)
// packed = (prec<<4)|opcode: | →0x10 & →0x21 + →0x32 - →0x33 * →0x44 < →0x85 > →0x86
// opcodes ≥ 5 are doubled-char operators (<< >>). The zero-backed alignment
// gap before .bss supplies the sentinel immediately after this final table;
// its first '|' byte also supplies undef's final five significant bits.
op_table:
    .byte '|', 0x10, '+', 0x32
    .byte '&', 0x21, '-', 0x33
    .byte '*', 0x44, '<', 0x85
    .byte '>', 0x86

// ══════════════════════════════════════════════════════════════════════════
//  Code
// ══════════════════════════════════════════════════════════════════════════
.text
.global _start

// ──────────────────────────────────────────────────────────────────────────
//  _start — entry point
// ──────────────────────────────────────────────────────────────────────────
_start:
    // grab argc / argv from the stack
    ldr     x0, [sp]                        // argc
    // Set up the state base before the argc check so fatal diagnostics can use
    // the input buffer as one-shot decode scratch even on the usage path.
    adr     x28, state
    adr     x1, msg_usage
    cmp     x0, #3
    b.lt    die_msg

    // x28 is callee-saved and remains the state block pointer forever
    // pin x29 = 0x100000 (1 MB stride between section buffers)
    movz    x29, #0x10, lsl #16
    // pin x27 = text_buf (x28 + INPUT_BUF_OFF + INPUT_BUF_SIZE = x28 + 0x100120)
    add     x27, x28, x29
    add     x27, x27, #INPUT_BUF_OFF

    // set up stub and dict base pointers: in both stage 0 and self-hosted
    // layouts, the ELF header template immediately precedes the
    // stub, and the dict follows it: [header|stub|dicts] is contiguous
    // Discriminate by the ELF magic at _appended_data: present in a stage 0
    // build (system as, or a seed assembler fed asm.s + asm_stage0.s
    // concatenated), absent in a plain self-hosted build, whose .rodata
    // follows .text there. A self-hosted entry inherits x6 = its stub base
    // from the decompressor; a seed-minted stage 0 is stub-entered too, but
    // the magic selects its appended (new) stub instead of inherited x6.
    // Keep the selected stub base pinned in x6: parse_cond also uses the first
    // 16 bytes of its ('b',0) dictionary as a packed condition-code lookup table.
    adr     x9, _appended_data
    ldrb    w10, [x9], #CODE_START          // appended header; advance to stage-0 stub
    cmp     w10, #0x7F                      // ELF magic first byte
    csel    x6, x9, x6, eq                  // pin appended stub (stage 0) or inherited stub

    // store input/output filenames
    ldp     x1, x0, [sp, #16]               // x1=argv[1] (input), x0=argv[2] (output)
    stp     x1, x0, [x28, #ST_INPUT_NAME]

    // ── open and read the input file ──────────────────────────────────────
    // x1 already holds input filename from ldp above
    bl      open_ro

    svc     #0
    tbnz    x0, #63, err_open
    stp     x0, x0, [x28, #ST_INPUT_LEN]    // content length + main length

    // ── pass 1: collect symbols and measure sections ──────────────────────
    mov     w17, #0                         // pinned text base: zero in pass 1
    bl      run_pass

    // ── compute section base addresses ────────────────────────────────────
    ldp     x19, x21, [x28, #ST_TEXT_POS]   // text_pos, rodata_pos (survive pass 2)
    // Pad text and rodata sizes up to 16 so rodata_base and bss_base are
    // 16-aligned (text_base = CODE_START = 112 already is, and the runtime
    // decompress dest is page-aligned). Without this, .align inside .rodata
    // or .bss aligns only the section-relative offset, leaving the absolute
    // address misaligned. The pad bytes are zero (buffers are zero-init and
    // never written past their content), so .text trailing zeros decompress
    // harmlessly and the reloc table still follows the rodata copy in the
    // stream. x21 retains the raw rodata size for the file copy and runtime
    // stub; the padded in-memory span is used only to place bss. x19 retains
    // the padded pass-1 text span because pass 2 resets ST_TEXT_POS.
    // pad text/rodata sizes to 2^max(max_align,4) so each section base keeps the
    // residue the .align math assumed (≥16 to keep rodata/bss bases 16-aligned)
    ldr     x22, [x28, #ST_ALIGN_MASK]
    orr     x22, x22, #15                   //      = 2^max(align,4) - 1
    add     x19, x19, x22
    bic     x19, x19, x22
    add     x9, x21, x22                    // keep x21 = raw rodata bytes for the file
    bic     x9, x9, x22                     // x9 = padded in-memory rodata span
    mov     w17, #CODE_START                // pinned text base: nonzero in pass 2
    add     x1, x17, x19                    // rodata_base = text_base + text size
    stp     x17, x1, [x28, #ST_TEXT_BASE]

    add     x2, x1, x9                      // bss_base = rodata_base + padded rodata span
    str     x2, [x28, #ST_BSS_BASE]

    ldr     x9, [x28, #ST_BSS_POS]
    add     x20, x2, x9                     // mem_size = bss_base + bss_size
                                            // (x19-x21 survive run_pass; x22-x26 do NOT)

    // Pass 1 emits no relocations, so the scratch cursor is only needed now.
    // Keep the table separate: narrow data directives deliberately use an
    // eight-byte over-store within their section buffer.
    adr     x18, reloc_table

    // ── pass 2: encode instructions and emit data ─────────────────────────
    // (section bases are added to label values at lookup time — sym_value)
    bl      run_pass

    // ── compress .text section (inline) ───────────────────────────────────
    // compress text_buf into input_buf using the dictionary, including the
    // dead alignment words through the padded rodata_base computed above.
    // Uses input_buf as scratch (safe — input already consumed).
    // Pass 2 has consumed input_buf, so copy the fixed output template first
    // and let compression write the stream directly after it.
    sub     x9, x6, #CODE_START             // header before pinned stub
    add     x2, x28, #INPUT_BUF_OFF
    mov     w10, #(CODE_START + STUB_SIZE + DICT_SIZE)
    bl      copy_bytes
    add     x22, x27, #0                    // src = text_buf
    // Probe candidate codes in ascending (cheapest-first) order through the
    // stub's own _locate helper, pinned at the stub base: blr x6 resolves a
    // code to its dict entry, whose rotated prefix is compared against the
    // word. The first hit wins; reaching RAW_CODE emits the word verbatim.
    cbz     x19, ct_done
ct_loop:
    ldr     w24, [x22], #4                  // next word
    mov     w1, #1                          // candidate code
ct_probe:
    add     w4, w1, #0                      // _locate input: candidate code
    blr     x6                              // x4 = entry, w11 = (nlit<<5)|ror,
                                            // x12 = nlit
    neg     w16, w11                        // RORV reduces mod 32: nlit bits vanish
    ror     w8, w24, w16                    // apply the tier rotation
    lsl     w0, w12, #3                     // s = 8 * nlit
    lsr     x7, x8, x0                     // prefix under test
    ldr     w5, [x4]                        // entry (may over-read)
    eor     w5, w5, w7
    lsl     w5, w5, w0                     // discard over-read bits
    cbz     w5, ct_hit
    add     w1, w1, #1
    cmp     w1, #RAW_CODE
    b.ne    ct_probe
    add     w8, w24, #0                     // raw escape: verbatim literals
    mov     x12, #4
ct_hit:
    strb    w1, [x2], #1                    // code byte
    str     w8, [x2]                        // low literal bytes (overwrite-safe)
    add     x2, x2, x12
    subs    x19, x19, #4
    b.ne    ct_loop

ct_done:
    strb    wzr, [x2], #1                   // end marker

    // ── assemble the whole output image in input_buf ──────────────────────
    // [0,1072) = header+stub+dict template (contiguous in both layouts),
    // followed by the stream just emitted at its final image offset.
    // x21 = raw rodata size (captured before pass 2); the zero-backed gap up
    // to bss_base does not need to occupy bytes in the file.

    // Append raw .rodata, then its separately buffered relocation table.
    add     x9, x27, x29                    // rodata_buf
    add     x10, x21, #0                    // raw rodata bytes
    bl      copy_bytes
    adr     x9, reloc_table
    sub     x10, x18, x9                    // relocation bytes
    lsr     w5, w10, #3                     // compatibility relocation count
    bl      copy_bytes

    // p_filesz = image end - image start (copy_bytes advances x2 exactly)
    add     x1, x28, #INPUT_BUF_OFF
    sub     x12, x2, x1

    // DECOMP_DEST_OFF = ceil_page(p_filesz) — offset from stub base
    add     x11, x12, #0xFFF
    and     x11, x11, #0xFFFFFFFFFFFFF000   // ceil to page

    // p_memsz = ceil_page(p_filesz) + total_mem_size
    add     x13, x11, x20

    // ── open output file ──────────────────────────────────────────────────
    mov     x0, #AT_FDCWD
    ldr     x1, [x28, #ST_OUTPUT_NAME]
    mov     w2, #O_WRONLY_CREAT_TRUNC
    mov     w3, #493                        // 0755 octal
    mov     x8, #SYS_openat
    svc     #0
    adr     x1, msg_create
    tbnz    x0, #63, die_msg

    // patch p_filesz/p_memsz and the stub data block, then write the image
    // (x0 = fd survives: the patching stores touch only x1/x2/x8)
    add     x1, x28, #INPUT_BUF_OFF
    stp     x12, x13, [x1, #88]
    // Patch decomp_dest at 40 and raw rodata_size at 44 as one pair.
    stp     w11, w21, [x1, #STUB_DATA_DECOMP_DEST]
    str     w5, [x1, #STUB_DATA_RELOC_COUNT]
    add     x2, x12, #0                     // p_filesz = whole image
    mov     w8, #SYS_write
    svc     #0

    // exec mode came from the openat mode argument (0755, umask-trimmed)
    mov     w0, #0
    b       exit_common

// parse_ident — parse an identifier [a-zA-Z_][a-zA-Z0-9_]*
// x0 = pointer; returns x1 = length and x2 = pointer past the identifier
parse_ident:
    add     x2, x0, #0                      // working pointer (x0 = start, preserved)
    ldrb    w9, [x2]
    b       pi_check_first
1:  ldrb    w9, [x2, #1]!
    // loop: accept digits (not valid for first char)
    sub     w10, w9, #'0'                   // (same words as the other digit checks)
    cmp     w10, #9
    b.ls    1b
pi_check_first:
    // accept underscore and letters
    cmp     w9, #'_'
    b.eq    1b
    orr     w10, w9, #0x20                  // (same words as pe_atom_num's hex fold)
    sub     w10, w10, #'a'
    cmp     w10, #25
    b.ls    1b
    // end of identifier (or not an identifier if x2 == x0)
    sub     x1, x2, x0                      // length (0 if no ident)
    ret

// ──────────────────────────────────────────────────────────────────────────
//  decode_escape — decode a backslash escape character
//  w9 = character after the backslash; returns w9 = decoded character
// ──────────────────────────────────────────────────────────────────────────
decode_escape:
    cmp     w9, #'n'
    mov     w10, #10
    csel    w9, w10, w9, eq
    cmp     w9, #'t'
    mov     w10, #9
    csel    w9, w10, w9, eq
    cmp     w9, #'r'
    mov     w10, #13
    csel    w9, w10, w9, eq
    subs    w10, w9, #'0'                   // '0' decodes to w10 = 0 exactly
    csel    w9, w10, w9, eq
    ret

// ──────────────────────────────────────────────────────────────────────────
//  copy_bytes — copy x10 bytes from x9 to x2; leaf, advances x2 exactly
// ──────────────────────────────────────────────────────────────────────────
copy_bytes:
    cbz     x10, 2f
1:  ldrb    w11, [x9], #1
    strb    w11, [x2], #1
    subs    x10, x10, #1
    b.ne    1b
2:
    ret

// terminate_line — advance x19 past the next NUL or newline, replacing a
// newline with NUL so x0's saved line start is ready for process_line.
// Leaf; preserves x0 and clobbers only w11.
terminate_line:
1:  ldrb    w11, [x19], #1
    cbz     w11, 2f
    cmp     w11, #'\n'
    b.ne    1b
    strb    wzr, [x19, #-1]
2:  ret

// open_ro — open path x1 read-only, returning its fd in x0 and preloading the
// shared input-buffer/read arguments in x1/x2/x8. Errors branch to err_open.
open_ro:
    mov     x0, #AT_FDCWD
    mov     w2, #O_RDONLY
    mov     x8, #SYS_openat
    svc     #0
    tbnz    x0, #63, err_open
    add     x1, x28, #INPUT_BUF_OFF
    mov     x2, #INPUT_BUF_SIZE
    mov     x8, #SYS_read
    ret

// mov_x25_skip / mov_x24_skip — save x0 (Rn/Rm/Rt2) in a callee-saved
// register, then skip the trailing comma and whitespace. mov_x24_skip falls
// through to the shared ws_x2_skip1 tail.
mov_x25_skip:
    add     x25, x0, #0
    b       ws_x2_skip1
mov_x24_skip:
    add     x24, x0, #0
ws_x2_skip1:
    // sources never put whitespace before ',' — x2 is at the comma
    add     x0, x2, #0
skip1_ws:
1:  ldrb    w9, [x0, #1]!
    cmp     w9, #' '
    b.hi    2f
    cbnz    w9, 1b
2:  ret
ws_x19:
    add     x0, x19, #0
    b       skip_ws

ws_x2:
    add     x0, x2, #0
    b       skip_ws

ws_x21:
    add     x0, x21, #0

// skip_ws — advance x0 past nonzero ASCII whitespace, returning x0 at the
// first non-whitespace byte and preloading that byte in w9.
skip_ws:
    sub     x0, x0, #1
    b       skip1_ws

// ──────────────────────────────────────────────────────────────────────────
//  sym_lookup — find a symbol in the contiguous symbol table
//  x0 = name pointer, x1 = name length
//  returns x13 = entry pointer and x12 = stored name pointer, or zero at the
//  first empty slot; x0 remains the queried name pointer
//
//  sym_table is kept within ADR range of this code.
// ──────────────────────────────────────────────────────────────────────────
sym_lookup:
    // leaf function — no frame needed, uses scratch registers only
    // Entries are append-only: insertion always uses the first empty slot, so
    // a linear scan can stop at the first zero name pointer.
    adr     x13, sym_table - SYM_ENT_SIZE

sym_lookup_probe:
    // Load name pointer + length together, then check for the empty sentinel.
    ldp     x12, x11, [x13, #SYM_ENT_SIZE]!
    cbz     x12, sym_lookup_empty

    // compare name_len
    cmp     w1, w11
    b.ne    sym_lookup_probe

    // compare name bytes (x12 = direct pointer into input buffer)
1:  sub     x11, x11, #1                    // matched name length doubles as counter
    ldrb    w9, [x0, x11]
    ldrb    w15, [x12, x11]
    cmp     w15, w9
    b.ne    sym_lookup_probe
    cbnz    w11, 1b

sym_lookup_empty:
sym_lookup_ret:
    ret

// ══════════════════════════════════════════════════════════════════════════
//  Pass driver and line processing
// ══════════════════════════════════════════════════════════════════════════

// ──────────────────────────────────────────────────────────────────────────
//  run_pass — iterate over the main source and all included files
// ──────────────────────────────────────────────────────────────────────────
run_pass:
    stp     x30, x19, [sp, #-64]!
    stp     x20, x21, [sp, #16]

    // reset section positions and current section
    stp     xzr, xzr, [x28, #ST_TEXT_POS]
    stp     xzr, xzr, [x28, #ST_BSS_POS]

    // reset the zero-based line cursor (x5 is protected throughout the pass tree)
    mov     w5, #0

    // Pin pass-local tables in otherwise-unused caller-saved registers. Every
    // callee in the pass tree is audited to preserve x4/x5/x7.
    // Reset numeric label counts/cursors (slot 0 of each digit block).
    adr     x7, numlab_defs                 // pin numeric-label table during the pass
    mov     w25, #(NUMLAB_DIGITS * NUMLAB_MAX_DEFS * 4)
1:  sub     x25, x25, #(NUMLAB_MAX_DEFS * 4)
    str     wzr, [x7, x25]
    cbnz    w25, 1b

    // set up input pointers; include files are re-read every pass, so reset
    // the append cursor to the main file length
    add     x19, x28, #INPUT_BUF_OFF        // input_buf
    ldr     x10, [x28, #ST_MAIN_LEN]
    str     x10, [x28, #ST_INPUT_LEN]
    add     x20, x19, x10                   // x20 = end of current file
    mov     w4, #0                          // include depth

run_pass_loop:
    cmp     x19, x20
    b.lt    1f
    // An include retains its process_line frame while traversing the child.
    // At child EOF, restore its line/name context and unwind that frame; the
    // ordinary process_line epilogue restores the parent cursor and end.
    cbz     x4, pl_done
    sub     x4, x4, #1
    ldp     x5, x10, [sp, #32]
    str     x10, [x28, #ST_INPUT_NAME]
    b       pl_done

    // Terminate and parse the next line. Includes tail-enter this loop from
    // their directive handler, retaining the parent process_line frame.
1:
    add     x5, x5, #1                      // parent resumes on the next line
    // Terminate the line in place before parsing. The BSS zero after the input
    // terminates a final unterminated line.
    add     x0, x19, #0
    bl      terminate_line
    bl      process_line

    b       run_pass_loop

// ──────────────────────────────────────────────────────────────────────────
//  process_line — handle one null-terminated source line
//  x0 = line start (null-terminated)
// ──────────────────────────────────────────────────────────────────────────
process_line:
    stp     x30, x19, [sp, #-64]!
    stp     x20, x21, [sp, #16]

    bl      skip_ws

pl_check_content:
    add     x19, x0, #0
    // empty line? (w9 pre-loaded by skip_ws / ws_x19)
    cbz     w9, pl_done
    // note: a // comment needs no check here — it fails the numeric-label
    // test below, isn't '.', and parse_ident returns length 0 → pl_done

    // ── check for numeric label (digit followed by ':') ───────────────────
    sub     w10, w9, #'0'
    cmp     w10, #9
    b.hi    pl_not_numlab
    ldrb    w11, [x19, #1]
    cmp     w11, #':'
    b.ne    pl_not_numlab                   // digit w/o ':' fails the ident parse too

    // ── numeric label (digit 0-9 stays in x10) — record definition ────────
    // slot 0 of the digit block is the def count in pass 1, the cursor in
    // pass 2 (run_pass zeroes it at the start of each pass); defs are
    // 1-indexed so the incremented count doubles as the store index
    add     x11, x7, x10, lsl #8            // numlab_defs + digit * 64 * 4
    ldr     w12, [x11]                      // count/cursor
    add     w12, w12, #1
    str     w12, [x11]
    // record def address (numeric labels are always in .text); pass 2
    // rewrites the identical offset, so no pass check is needed
    ldr     x10, [x28, #ST_TEXT_POS]
    str     w10, [x11, x12, lsl #2]
    add     x19, x19, #2
    b       pl_after_label

pl_not_numlab:
    // ── check for named label or mnemonic ─────────────────────────────────
    cmp     w9, #'.'
    b.eq    pl_directive

    bl      parse_ident
    cbz     x1, pl_done                     // no identifier → skip

    // is it a label (followed by ':')?
    ldrb    w9, [x2]
    cmp     w9, #':'
    b.ne    pl_instruction

    // ── named label ───────────────────────────────────────────────────────
    add     x19, x2, #1                     // past ':'

    // defining in pass 2 too is harmless: offsets are identical across
    // passes (values stay section-relative; sym_value adds the base)

    // value = current section offset
    ldr     x3, [x28, #ST_CUR_SEC]
    ldr     x2, [x28, x3]
    // flags = cur_section << SEC_SHIFT; x3 = sec*8 = sec << 3
    // Definitions repeat identically in pass 2, so overwrite the append-only
    // entry unconditionally after lookup (x2/x3 survive the leaf helper).
    bl      sym_lookup
    stp     x0, x1, [x13]
    stp     x3, x2, [x13, #SYM_FLAGS]

pl_after_label:
    bl      ws_x19
    b       pl_check_content

    // ── directive (starts with '.') ───────────────────────────────────────
pl_directive:
    // x0 still equals x19 here (set at pl_check_content, untouched since)
    add     x0, x0, #1                      // skip '.'
    bl      parse_ident
    // x0 = name start, x1 = name length, x2 = end pointer
    add     x19, x2, #0                     // position after directive name
    ldr     x26, [x28, #ST_CUR_SEC]         // pin current section for handlers

    // dispatch on directive name — check first char then length
    ldrb    w9, [x0]

    cmp     w9, #'b'
    b.ne    1f
    tbnz    x1, #2, dir_byte                // ".byte" len 4 vs ".bss" len 3
    mov     w10, #SEC_BSS                   // doesn't affect flags
    b       dir_sec_set
1:
    cmp     w9, #'h'                        // .hword → 2-byte data
    b.ne    2f
    mov     w22, #2
    b       dir_data_common
2:  cmp     w9, #'i'
    b.ne    3f

// .include "path" — retain this process_line frame as the parent context,
// append/read the child, and tail-enter the shared source traversal loop.
dir_include:
    add     x19, x19, #2                    // skip the single space and opening quote
    add     x1, x19, #0                     // path start for open + diagnostics
1:  ldrb    w11, [x19], #1                  // find closing quote (pass 2 sees its NUL)
    cmp     w11, #'"'
    b.eq    2f
    cbnz    w11, 1b
2:  strb    wzr, [x19, #-1]
    // In pass 2 the injected path NUL stopped the outer line scan early.
    // Advance through the already-terminated remainder and patch the cursor
    // saved by the process_line prologue.
    bl      terminate_line
    str     x19, [sp, #8]

    // Sixteen retained process_line frames are the supported include depth.
    tbnz    x4, #4, err_overflow
    ldr     x10, [x28, #ST_INPUT_NAME]
    stp     x5, x10, [sp, #32]
    str     x1, [x28, #ST_INPUT_NAME]

    // Read the child at the input buffer append cursor.
    bl      open_ro
    add     x25, x0, #0                     // save fd (x25 free here; matches common movs)
    ldr     x9, [x28, #ST_INPUT_LEN]
    add     x1, x1, x9                      // dest = append cursor
    svc     #0
    tbnz    x0, #63, err_overflow           // reject read errors before length math
    add     x19, x1, #0                     // cursor = start of included content
    add     x20, x0, x1                     // end of included content
    add     x9, x0, x9                      // grow the content length, bounded by
    tbnz    x9, #20, err_overflow           // bit 20 crosses the 1 MB input bound
    str     x9, [x28, #ST_INPUT_LEN]
    add     x0, x25, #0                     // close fd before descending
    mov     x8, #SYS_close
    svc     #0
    mov     w5, #0
    add     x4, x4, #1
    b       run_pass_loop

3:
    cmp     w9, #'s'
    b.ne    5f
    mov     w10, #SEC_RODATA                // doesn't affect flags
    tbnz    x1, #1, dir_sec_set             // ".section" len 7 vs ".skip" len 4
    bl      parse_expr0_x19                 // .skip: inline
    b       advance_sec_pos

5:  cmp     w9, #'a'
    b.ne    6f
    ldrb    w10, [x0, #4]
    tbnz    w10, #2, dir_align              // align 'n' vs ascii/asciz 'i'/'z'

// .ascii/.asciz "string" — w10 still holds directive[4] ('i' or 'z')
dir_str_common:
    ubfx    w21, w10, #1, #1                // suffix 'i'/'z' bit 1 = null flag
    bl      ws_x19                          // x0 = pointer to '"'
    // always compute dest buffer (pass 1 writes are harmless, overwritten in pass 2)
    add     x20, x27, x26, lsl #17          // text_buf + sec * 1MB
    ldr     x10, [x28, x26]
    add     x20, x10, x20
    // parse the quoted string (inline), emitting bytes to x20
    // (x30 is dead inside process_line's frame, so bl decode_escape is safe)
    add     x12, x20, #0                    // working dest pointer
    add     x2, x0, #1                      // skip opening '"'
ps_loop:
    ldrb    w9, [x2], #1                    // load + advance
    cbz     w9, pe_atom_err                 // unterminated string
    cmp     w9, #'"'
    b.eq    ps_done                         // closing quote (x2 already past it)
    cmp     w9, #'\\'
    b.ne    ps_store
    ldrb    w9, [x2], #1                    // load escape char, advance (past backslash)
    bl      decode_escape
ps_store:
    strb    w9, [x12], #1
    b       ps_loop
ps_done:
    sub     x0, x12, x20                    // byte count
    strb    wzr, [x12], #1                  // null terminator (harmless for .ascii:
    add     x0, x21, x0                     // not counted, overwritten by next emit)
advance_sec_pos:
    ldr     x10, [x28, x26]
    add     x10, x0, x10
    str     x10, [x28, x26]
    b       expect_eol_done                 // cursor returned by the last primitive

6:  cmp     w9, #'e'
    b.ne    7f
    // inline dir_equ: define first (placeholder value), patch after parsing
    bl      ws_x19
    bl      parse_ident
    cbz     x1, pl_done
    mov     x3, #SYMF_EQU
    bl      sym_lookup
    stp     x0, x1, [x13]
    stp     x3, x2, [x13, #SYM_FLAGS]       // x2 (= end ptr) stored as placeholder
    add     x20, x13, #0                    // entry pointer (x2 preserved: at ',')
    bl      ws_x2_skip1
    bl      parse_expr0
    str     x0, [x20, #SYM_VALUE]
    b       expect_eol_done                 // .equ name, expr — nothing more

7:  cmp     w9, #'d'
    b.ne    dir_word
    bl      ws_x19
    tbnz    w9, #6, dir_dword_ident         // identifier starts have ASCII bit 6 set

dir_dword_lit:
    mov     w22, #8
    b       dir_data_common

dir_dword_ident:
    // Labels need load-time relocation; .equ identifiers are absolute data.
    // An unresolved pass-1 entry reads as a zero-based label, which is enough
    // to reserve the slot before pass 2 resolves its actual kind.
    bl      parse_ident
    bl      sym_lookup
    ldr     x9, [x13, #SYM_FLAGS]
    cmp     w9, #SYMF_EQU
    b.eq    dir_dword_lit

dir_dword_reloc:
    // relocatable .dword form: label[+const|-const], only valid in .rodata
    tbz     x26, #3, pe_atom_err            // only SEC_RODATA has bit 3 set
    bl      parse_expr0                     // x0 = target value (sym + addend)

    // the slot's file bytes are dead: the stub overwrites every reloc slot with
    // the relocated pointer at load time, so no provisional value need be written
    // pass 2: emit relocation table entry {slot_off_rodata, target_off_from_text}
    cbz     x17, dir_dword_emit_done
    sub     x9, x0, #CODE_START
    // a real label target is >= CODE_START; label-difference exprs are not
    tbnz    x9, #63, pe_atom_err

    // Slot offset within .rodata: the expression parse leaves the section
    // position untouched, so load it here (x26 survives, as dir_data_common
    // already relies on).
    ldr     x10, [x28, x26]
    // Bias slot offsets by one. A zero first word is then an unambiguous
    // end marker supplied by the zero-filled mapping immediately past p_filesz.
    add     w10, w10, #1
    stp     w10, w9, [x18], #8

dir_dword_emit_done:
    mov     w0, #8
    b       advance_sec_pos

// strlen_write2 — write null-terminated string in x1 to stderr
strlen_write2:
    mov     w2, #0
1:  ldrb    w9, [x1, x2]
    cbz     w9, write2
    add     x2, x2, #1
    b       1b

dir_byte:
    mov     w22, #1
    b       dir_data_common

dir_word:
    cmp     w9, #'w'
    b.ne    dir_text
    mov     w22, #4
dir_data_common:
    // .byte/.hword/.word/.dword <expr>[, <expr>…] — emit each at width x22
    // (x22 + x27 preserved across parse_expr)
1:  bl      parse_expr0_x19
    ldr     x10, [x28, x26]                 // current pos
    add     x12, x27, x26, lsl #17          // text_buf + sec * 1MB
    str     x0, [x12, x10]                  // store 8 bytes (extra bytes harmless)
    add     x10, x22, x10
    str     x10, [x28, x26]                 // pos += width
    cmp     w9, #','
    b.ne    expect_eol_done
    add     x19, x2, #1                     // past the comma → next value
    b       1b

// ──────────────────────────────────────────────────────────────────────────
//  expect_eol_done — error unless only whitespace or a // comment remains
//  after x2; otherwise finish the line through pl_done
// ──────────────────────────────────────────────────────────────────────────
expect_eol_done:
    bl      ws_x2
    cbz     w9, pl_done
    ldrh    w10, [x0]                       // comments are exactly "//": a lone '/'
    sub     w10, w10, w9, lsl #8            // low byte is w9; == '/' iff both are '/'
    cmp     w10, #'/'                       // (a lone '/' is trailing garbage)
    b.eq    pl_done
    adr     x0, msg_trailing
    // falls through to error_at

// ──────────────────────────────────────────────────────────────────────────
//  error_at — print "filename:line: msg\n" to stderr and exit(1)
//  x0 = packed message pointer (5-bit codes terminated by newline code 28)
//
//  uses the state filename and the protected pass line cursor
// ──────────────────────────────────────────────────────────────────────────
error_at:
    add     x19, x0, #0                     // msg ptr

    // write filename
    ldr     x1, [x28, #ST_INPUT_NAME]
    bl      strlen_write2

    // build ":[linenum]: " in frame buffer and write it
    add     x11, sp, #48
    sub     x10, x11, #2
    mov     w0, #10
3:  udiv    x12, x5, x0
    msub    x14, x12, x0, x5
    add     w14, w14, #'0'
    strb    w14, [x10, #-1]!
    add     x5, x12, #0
    cbnz    w5, 3b
    movz    w14, #0x203A
    strb    w14, [x10, #-1]!
    strh    w14, [x11, #-2]
    add     x1, x10, #0
    sub     x2, x11, x10
    bl      write2

    // write message (includes \n) and exit
    add     x1, x19, #0
    b       die_msg

// Simple fatal-error entries select a packed message, then share die_msg.
err_open:
    adr     x1, msg_open
    b       die_msg
err_overflow:
    adr     x1, msg_overflow
die_msg:
    // Decode into the input buffer: every caller exits immediately afterward,
    // so clobbering source/output scratch on an error path is harmless.
    add     x3, x28, #INPUT_BUF_OFF
    mov     w4, #0                          // bit offset within the current input byte
1:  ldrh    w5, [x1]                        // two bytes cover every 5-bit extraction
    lsr     w5, w5, w4
    and     w11, w5, #31
    add     w4, w4, #5
    lsr     w9, w4, #3                      // advance input by floor(bit_offset / 8)
    and     w4, w4, #7
    add     x1, x1, x9
    add     w7, w11, #'a'
    cmp     w11, #26
    b.lo    2f
    adr     x8, msg_punct - 26
    ldrb    w7, [x8, x11]
2:  strb    w7, [x3], #1
    cmp     w11, #28
    b.ne    1b
    add     x1, x28, #INPUT_BUF_OFF
    sub     x2, x3, x1
    bl      write2
    mov     w0, #1
exit_common:
    mov     w8, #SYS_exit
    svc     #0

write2:
    mov     w0, #STDERR
    mov     w8, #SYS_write
    svc     #0
    ret

// .text, .section .rodata, and .bss converge here with x10 holding the
// pre-multiplied section ID. Unknown directives are ignored through pl_done.
dir_text:
    subs    w10, w9, #'t'                   // valid '.text' also yields SEC_TEXT
    b.ne    pl_done
dir_sec_set:
    str     x10, [x28, #ST_CUR_SEC]

pl_done:
    ldp     x20, x21, [sp, #16]
    ldp     x30, x19, [sp], #64
    ret

// ──────────────────────────────────────────────────────────────────────────
//  parse_label_ref — parse a named branch target or Nf/Nb numeric label
//  x0 = pointer; returns x0 = target address and x2 = pointer past the target
// ──────────────────────────────────────────────────────────────────────────
parse_label_ref:
    stp     x30, x20, [sp, #-16]!

    bl      skip_ws

    // numeric label ref? digit followed by 'f' or 'b'
    sub     w10, w9, #'0'
    cmp     w10, #9
    b.hi    plr_named

    ldrb    w11, [x0, #1]
    orr     w9, w11, #4                     // only 'b' and 'f' fold to 'f'
    cmp     w9, #'f'
    b.ne    plr_named
    ubfx    x9, x11, #2, #1                 // x9=0 backward, 1 forward
plr_numlab_common:
    add     x2, x0, #2                      // pointer past "Nf"/"Nb"
    add     x11, x7, x10, lsl #8            // digit block (w10 = digit)
    ldr     w0, [x11]                       // cursor (defs consumed so far)
    add     x0, x0, x9                      // 1-indexed: fwd = cursor+1, back = cursor
    ldr     w0, [x11, x0, lsl #2]
    // defs are stored as .text offsets; add the text base (refs are pass-2 only)
    mov     w9, #0                          // section = .text for pea_sec_base
    b       pea_sec_base

plr_named:
    // shares the expression atom's symbol path (same frame shape; undefined
    // symbols get 0 in pass 1 — forward refs are fixed up in pass 2)
    bl      parse_ident
    cbz     x1, err_undef
    b       pe_atom_ident

// .align N — align the current section address to a 2^N boundary and retain
// the largest mask so later section bases preserve the assumed residue.
dir_align:
    bl      parse_expr0_x19
    // x0 = N. Align the ADDRESS, not just the section offset: fold in CODE_START
    // (every section sits at CODE_START + padded-prior-sizes, and output sizing
    // pads those sizes to the largest alignment mask).
    mov     w8, #1
    lsl     x8, x8, x0
    sub     x8, x8, #1                      // current (2^N - 1) mask
    ldr     x10, [x28, #ST_ALIGN_MASK]
    orr     x10, x10, x8                    // power-of-two masks nest, so OR tracks max N
    str     x10, [x28, #ST_ALIGN_MASK]
    ldr     x10, [x28, x26]                 // current position
    add     x10, x10, #CODE_START           // → address residue
    neg     x10, x10
    and     x0, x8, x10                     // delta = -address & ((1 << N) - 1)
    b       advance_sec_pos

// ──────────────────────────────────────────────────────────────────────────
//  parse_label_pc_rel — parse a label reference and compute its PC-relative
//  offset in instruction units; x14 preserves the caller across the parser
// ──────────────────────────────────────────────────────────────────────────
parse_label_pc_rel:
    add     x14, x30, #0
    bl      parse_label_ref
    ldr     x9, [x28, #ST_TEXT_POS]
    add     x9, x9, #CODE_START
    sub     x0, x0, x9
    asr     x0, x0, #2
    br      x14

// adr_page_word — encode ADR word with imm21 = page(x0) - page(x25), Rd = w23
// adr_word — encode ADR word from imm21 in x10, Rd = w23 (base 0x10000000;
// caller sets bit 31 for ADRP via sf or orr)
adr_page_word:
    lsr     x10, x0, #12
    lsr     x9, x25, #12
    sub     x10, x10, x9
adr_word:
    orr     w0, w23, #0x10000000            // ADR base opcode | Rd
    bfi     w0, w10, #29, #2                // immlo
    ubfx    w10, w10, #2, #19               // immhi
    orr     w0, w0, w10, lsl #5
    ret

// ──────────────────────────────────────────────────────────────────────────
//  parse_cond — parse a two-letter condition code
//  x0 = first character; returns x0 past the code and x1 = condition 0..14
//
//  The first 16 bytes of the ('b',0) compression dictionary double as a packed
//  lookup table. gen_dict.py preserves the supported condition nibbles while
//  using the spare nibbles as T8 prefixes.
// ──────────────────────────────────────────────────────────────────────────
parse_cond:
    ldrh    w10, [x0], #2
    add     x2, x0, #0
    eor     w10, w10, w10, lsr #8           // char0 ^ char1 in the low byte
    add     x9, x6, #(STUB_SIZE + COND_DICT_OFF)
    ubfx    w11, w10, #1, #4                // packed-byte index
    ldrb    w1, [x9, x11]
    ubfiz   w9, w10, #2, #1                 // nibble shift: 0 or 4
    lsr     w1, w1, w9
    and     w1, w1, #15
    ret

// Decimal/hex numeric atom (inline parse_int). The caller has already proved
// the first character is a digit; returns its value in x0 and end pointer in x2.
pe_atom_num:
    // hex prefix? first char is a digit (caller guarantees), so any 'x'
    // second char means "0x" in real sources
    mov     w8, #10                         // radix
    sub     x2, x0, #1                      // pre-increment scan pointer
    mov     w0, #0                          // accumulator (shared by dec+hex)
    ldrb    w10, [x2, #2]
    cmp     w10, #'x'
    b.ne    2f
    add     x2, x2, #2                      // skip "0x"
    mov     w8, #16

2:  ldrb    w9, [x2, #1]!
    sub     w10, w9, #'0'
    cmp     w10, #9
    b.ls    4f
    tbz     x8, #4, parse_int_ret           // a-f digits only in radix 16
    orr     w10, w9, #0x20                  // fold uppercase to lowercase
    sub     w10, w10, #'a'
    cmp     w10, #5
    b.hi    parse_int_ret
    add     w10, w10, #10
4:  madd    x0, x0, x8, x10                 // acc = acc*radix + digit
    b       2b

// skip_lsl — consume ", <shift> #N" through the '#', decode lsl/lsr/asr/ror,
// and OR the shift type into bits [23:22] of w26. For mov-wide, lsl decodes to
// zero and leaves the opcode in w26 unchanged. The shared tail parses N.
skip_lsl:
1:  ldrb    w9, [x0, #1]!
    cbz     w9, pe_atom_err                 // hit end of line without finding a mnemonic
    cmp     w9, #'a'
    b.lo    1b                              // separators (space/comma) < 'a'
    ldrb    w10, [x0, #2]
    ubfx    w10, w10, #1, #1                // third 'l'/'r' contributes 0/1
    and     w11, w9, #3                     // first 'l'/'a'/'r' contributes 0/1/2
    add     w10, w10, w11                   // lsl=0, lsr=1, asr=2, ror=3
3:  ldrb    w9, [x0, #1]!                   // scan the rest of the mnemonic for '#'
    cbz     w9, pe_atom_err
    cmp     w9, #'#'
    b.ne    3b
    orr     w26, w26, w10, lsl #22
    // falls through to parse_hash_imm

// ──────────────────────────────────────────────────────────────────────────
//  parse_hash_imm — parse #expr or #:lo12:expr
//  x0 = pointer (at '#' or ':'), w9 = first character
//  returns x0 = value, x2 = pointer past
// ──────────────────────────────────────────────────────────────────────────
parse_hash_imm:
    // first char is always '#' or ':' (callers preload and guarantee this)
    tbnz    w9, #0, phi_hash                // '#' is odd; ':' is even

    // ':' prefix — verify :lo12: by checking second char is 'l'
    ldrb    w9, [x0, #1]
    cmp     w9, #'l'
    b.ne    parse_expr0                     // not :lo12:, parse from ':' — will give syntax error
    add     x0, x0, #6                      // skip ':lo12:'
    add     x14, x30, #0
    bl      parse_expr0
    and     x0, x0, #0xFFF
    br      x14

phi_hash:
    add     x0, x0, #1
    b       parse_expr0

// ══════════════════════════════════════════════════════════════════════════
//  Expression evaluator
//
//  x0 enters as a pointer and returns as the value; x2 returns just past the
//  expression. Precedence, low to high: |, &, +/-, *, <</>>, unary, atom.
// ══════════════════════════════════════════════════════════════════════════

// parse_expr0_x19 / parse_expr0 select the input pointer and minimum
// precedence before entering the Pratt parser.
parse_expr0_x19:
    add     x0, x19, #0
parse_expr0:
    mov     w1, #0

// parse_expr — Pratt binary-expression parser. x1 is the minimum precedence.
parse_expr:
    stp     x30, x19, [sp, #-64]!
    stp     x20, x21, [sp, #16]
    add     x21, x1, #0                     // min_prec
    bl      parse_expr_unary
    add     x19, x0, #0                     // lhs value

// Operator dispatch: w10 encodes (prec<<4)|opcode
// | → 0x10  & → 0x21  + → 0x32  - → 0x33  * → 0x44  << → 0x85  >> → 0x86
pe_loop:
    bl      ws_x2
    adr     x11, op_table
1:  ldrb    w10, [x11], #2
    cbz     w10, pe_done
    cmp     w10, w9                         // (same word as the other char compares)
    b.ne    1b
    ldrb    w10, [x11, #-1]
    // opcode ≥ 5: doubled-char operator (<< >>), verify and consume 2nd char
    tbz     w10, #7, pe_check_prec
    ldrb    w12, [x0, #1]
    cmp     w12, w9
    b.ne    pe_done
    add     x0, x0, #1

pe_check_prec:
    lsr     w9, w10, #4                     // prec = packed >> 4
    and     x20, x10, #0xF                  // opcode (callee-saved across recursion)
    cmp     x9, x21                         // op_prec vs min_prec
    b.lt    pe_done                         // op_prec < min_prec: not ours
    add     x0, x0, #1                      // skip operator char
    add     w1, w9, #1                      // recurse with prec+1
    bl      parse_expr
    adr     x9, pe_ops
    add     x9, x9, x20, lsl #3
    blr     x9
    b       pe_loop
pe_ops:
    orr     x19, x19, x0                    // opcode 0: |
    ret
    and     x19, x19, x0                    // opcode 1: &
    ret
    add     x19, x19, x0                    // opcode 2: +
    ret
    sub     x19, x19, x0                    // opcode 3: -
    ret
    mul     x19, x19, x0                    // opcode 4: *
    ret
    lsl     x19, x19, x0                    // opcode 5: <<
    ret
    lsr     x19, x19, x0                    // opcode 6: >>
    ret

pe_done:
    add     x2, x0, #0
    add     x0, x19, #0
    b       pl_done

// ──────────────────────────────────────────────────────────────────────────
//  parse_expr_unary — handles '~', unary '-', then falls through to atom
// ──────────────────────────────────────────────────────────────────────────
parse_expr_unary:
    stp     x30, x20, [sp, #-16]!

    bl      skip_ws

    cmp     w9, #'~'
    cset    x20, eq                         // 1 for NOT, 0 for NEG; survives recursion
    b.eq    pe_unary_op
    cmp     w9, #'-'
    b.eq    pe_unary_op

    // not unary, fall through to parse atom (skip_ws already done)

    // '(' — grouped expression
    cmp     w9, #'('
    b.eq    pe_atom_paren

    // '.' — current location counter
    cmp     w9, #'.'
    b.eq    pe_atom_dot

    // digit or '\'' — numeric literal
    sub     w10, w9, #'0'
    cmp     w10, #9
    b.ls    pe_atom_num
    cmp     w9, #'\''
    b.eq    parse_int_char

    // identifier — symbol reference
    bl      parse_ident
    cbz     x1, pe_atom_err
pe_atom_ident:
    // look up symbol
    bl      sym_lookup
    cbnz    x12, 1f
    cbnz    x17, err_undef                  // pass 1 reads the zeroed empty entry

    // Resolve the entry's value (inline sym_value) by adding its selected
    // state slot. Labels select their section base; .equ selects ST_PASS,
    // which is permanently zero, so it needs no special-case branch.
1:
    ldp     x9, x0, [x13, #SYM_FLAGS]       // flags, value
    // pass 1 needs no special case: bases are still 0 (BSS), so add is a no-op
    // (shared tail: '.'-atom and numeric labels enter with x9 = sec*8, x0 = off)
pea_sec_base:
    add     x9, x9, x28
    ldr     x9, [x9, #ST_TEXT_BASE]
    add     x0, x0, x9
    b       pea_ret_x2

err_undef:
    adr     x0, msg_undef
    bl      error_at

pe_atom_paren:
    add     x0, x0, #1                      // skip '('
    bl      parse_expr0
    cmp     w9, #')'
    b.ne    pe_atom_err
    add     x2, x2, #1                      // pointer past ')'
parse_int_ret:
pea_ret_x2:
pea_ret:
    ldp     x30, x20, [sp], #16
    ret

pe_atom_dot:
    add     x2, x0, #1                      // return pointer past '.'
    ldr     x9, [x28, #ST_CUR_SEC]          // x9 = sec*8: pea_sec_base's ubfx
    ldr     x0, [x28, x9]                   // section offset
    b       pea_sec_base                    // add section base (0 in pass 1)

// Character-literal atom (inline parse_int): 'A' or an escaped byte like '\n'.
// x0 points at the opening quote; returns the value in x0 and end pointer in x2.
parse_int_char:
    ldrb    w9, [x0, #1]!                   // skip opening quote and load char
    cmp     w9, #'\\'
    b.ne    1f
    // escape (x30 is dead — frame pops at pea_ret)
    ldrb    w9, [x0, #1]!                   // load escape char
    bl      decode_escape
1:  add     x2, x0, #2                      // pointer past closing quote
    add     x0, x9, #0                      // decoded character value
    b       pea_ret

pe_atom_err:
    adr     x0, msg_syntax
    bl      error_at

pe_unary_op:
    add     x0, x0, #1
    bl      parse_expr_unary                // recursive
    neg     x0, x0                          // both: negate first
    sub     x0, x0, x20                     // NOT: -x-1 = ~x; NEG: -x-0 = -x
    b       pea_ret

// ══════════════════════════════════════════════════════════════════════════
//  Pass 2 infrastructure
// ══════════════════════════════════════════════════════════════════════════

// parse_x22_ws — parse the first register into x22, save sf in x23, then skip
// the comma and whitespace. Shares the x14 LR-save convention with other helpers.
parse_x22_ws:
    add     x14, x30, #0
    bl      parse_x23_ws
    add     x22, x23, #0
    add     x23, x24, #0                    // sf
    br      x14

// parse_zn_reg — validate a z/n suffix, set x22=0/1, then parse first reg
parse_zn_reg:
    ldrb    w9, [x19, #2]
    cmp     w9, #'z'
    cset    x22, ne
    b.eq    1f
    cmp     w9, #'n'
    b.ne    ei_bad

// parse_x23_ws — parse first register into x23, save sf to x24, skip comma+ws
// uses x15 for return address (the called leaf helpers preserve it)
1:
parse_x23_ws:
    add     x15, x30, #0
    bl      ws_x21
    bl      parse_register
    add     x23, x0, #0
    add     x24, x1, #0                     // sf (callers can use x24 directly)
    add     x30, x15, #0
    b       ws_x2_skip1

// ──────────────────────────────────────────────────────────────────────────
//  parse_2reg — parse "Rd, Rn" from operands (x21)
//  returns x22 = Rd, x23 = sf, x0 = Rn
//  NOTE: uses [sp, #56] for return address; called from encode_instruction
// ──────────────────────────────────────────────────────────────────────────
parse_2reg:
    str     x30, [sp, #56]
    bl      parse_x22_ws
    b       p23_tail

// ──────────────────────────────────────────────────────────────────────────
//  parse_3reg — parse "Rd, Rn, Rm" from operands (x21)
//  returns x22 = Rd, x23 = sf, x24 = Rn, x0 = Rm
//  NOTE: uses [sp, #56] for return address; called from encode_instruction
// ──────────────────────────────────────────────────────────────────────────
parse_3reg:
    str     x30, [sp, #56]
    bl      parse_x22_ws
    bl      parse_register
    bl      mov_x24_skip                    // Rn → x24, skip ','
p23_tail:
    ldr     x30, [sp, #56]

// ──────────────────────────────────────────────────────────────────────────
//  parse_register — parse register name
//  x0 = pointer
//  returns x0 = reg number (0-31), x1 = is_64bit, x2 = pointer past
//  on error: report a bad register and exit
// ──────────────────────────────────────────────────────────────────────────
parse_register:
    // w9 pre-loaded by caller (skip_ws sets w9 = first non-ws char)
    // registers appear only where required, so a leading 's' means "sp"
    // and an 'x'/'w' followed by 'z' means xzr/wzr — no full spell check

    cmp     w9, #'s'
    b.ne    1f
    add     x2, x0, #2                      // end pointer past "sp"
    mov     w1, #1
2:  mov     x0, #31
    b       parse_register_ret

1:  sub     w1, w9, #'w'                    // 'w' → 0, 'x' → 1 (sf)
    cmp     w1, #1
    b.hi    parse_reg_fail
parse_reg_xw:
    ldrb    w10, [x0, #1]
    cmp     w10, #'z'
    b.ne    parse_reg_num
    add     x2, x0, #3
    b       2b

parse_reg_num:
    // x1 = is_64bit from the x/w prefix; not modified by this code
    sub     w12, w10, #'0'                  // first digit (loaded by parse_reg_xw)
    cmp     w12, #9
    b.hi    parse_reg_fail
    ldrb    w9, [x0, #2]
    sub     w11, w9, #'0'
    cmp     w11, #9
    add     x2, x0, #2                      // end pointer (single digit); flags unaffected
    b.hi    1f                              // single digit
    add     w13, w12, w12, lsl #2           // first * 5
    add     w12, w11, w13, lsl #1           // second + first * 10
    add     x2, x2, #1
1:  cmp     w12, #30
    b.hi    parse_reg_fail                  // x31/w31 and beyond: not a register
    add     x0, x12, #0
parse_register_ret:
    ret

// ──────────────────────────────────────────────────────────────────────────
//  encode_logical_imm — encode a logical-instruction bitmask immediate
//  x0 = value, x1 = is_32bit; returns (N << 12) | (immr << 6) | imms
//  Invalid values branch to ei_logical_bad during pass 2.
// ──────────────────────────────────────────────────────────────────────────
encode_logical_imm:
    // leaf function — no frame needed, uses scratch registers only
    // pass 1: the value may be a forward-ref placeholder (resolves to 0, not a
    // valid bitmask). The instruction is one word regardless, so skip validation
    // and return immediately; pass 2 encodes (and validates) the real value.
    cbz     x17, eli_ret
    // for 32-bit, replicate low 32 bits
    cbz     x1, eli_start
    bfi     x0, x0, #32, #32

eli_start:
    // x0 = val (left intact until the final encode)

    // Reject all-zeros/all-ones while forming val+1 for the rotation below:
    // unsigned (val + 1) <= 1 exactly for those two invalid values.
    add     x9, x0, #1
    cmp     x9, #1
    b.ls    ei_logical_bad
    // rotation = ctz(val & (val + 1))
    and     x9, x9, x0
    rbit    x10, x9
    clz     x1, x10                         // rotation (x1 arg is dead by now)

    // normalized = ror(val, rotation)
    ror     x9, x0, x1

    // zeroes = clz(normalized)
    clz     x10, x9

    // ones = ctz(~normalized) = clz(rbit(~normalized))
    mvn     x11, x9
    rbit    x11, x11
    clz     x14, x11                        // ones

    // size = zeroes + ones
    add     x13, x14, x10

    // validate: ror(val, size) == val
    ror     x9, x0, x13
    cmp     x9, x0
    b.ne    ei_logical_bad

    // immr = (-rotation) & (size - 1)
    neg     x9, x1
    sub     x10, x13, #1
    and     x9, x9, x10                     // immr

    // imms = ones - 2*size - 1 (the non-overlapping OR form, added)
    sub     x11, x14, x13, lsl #1
    sub     x11, x11, #1
    and     x11, x11, #0x3F                 // imms

    // result = (N << 12) | (immr << 6) | imms  where N = size >> 6
    lsr     x12, x13, #6
    orr     w0, w11, w9, lsl #6
    orr     x0, x0, x12, lsl #12
eli_ret:
    ret

// ──────────────────────────────────────────────────────────────────────────
//  encode_instruction — dispatch a mnemonic, parse its operands, and emit
//  x0 = mnemonic start, x1 = mnemonic length, x2 = operands start
// ──────────────────────────────────────────────────────────────────────────
pl_instruction:
    // Both passes run the full encoder. Word count is value-independent
    // (only ldr =label expands, to a fixed 2 words), so pass-1 sizes are exact
    // even with forward refs resolving to 0. The one hazard — a forward-ref
    // symbolic logical immediate resolving to 0 (not a valid bitmask) — is
    // handled in encode_logical_imm, which returns a placeholder in pass 1.
encode_instruction:
    // x19 already equals x0 (set by process_line before parse_ident)
    add     x20, x1, #0                     // no-operand forms (ret/nop) never parse
    add     x21, x2, #0
    // Every returning encoder helper preserves x16, so pin the common emit
    // continuation and make all direct emit branches share one instruction word.
    adr     x16, emit_inst_done

    // dispatch on first character of mnemonic
    ldrb    w9, [x19]
    ldrb    w10, [x19, #1]

    // Direct offset dispatch table for the dense a..w range. Keep w9/w10
    // intact: several shared encoders derive opcode bits from the first char.
    sub     w11, w9, #'a'
    cmp     w11, #('w' - 'a')
    b.hi    ei_bad
    adr     x12, ei_dispatch
    ldrb    w11, [x12, x11]
    add     x14, x12, x11, lsl #2
    br      x14
ei_dispatch:
    .byte   (ei_a - ei_dispatch) >> 2, (ei_b - ei_dispatch) >> 2
    .byte   (ei_c - ei_dispatch) >> 2, (ei_d - ei_dispatch) >> 2
    .byte   (ei_e - ei_dispatch) >> 2, (ei_bad - ei_dispatch) >> 2
    .byte   (ei_bad - ei_dispatch) >> 2, (ei_h - ei_dispatch) >> 2
    .byte   (ei_d - ei_dispatch) >> 2, (ei_bad - ei_dispatch) >> 2
    .byte   (ei_bad - ei_dispatch) >> 2, (ei_l - ei_dispatch) >> 2
    .byte   (ei_m - ei_dispatch) >> 2, (ei_n_entry - ei_dispatch) >> 2
    .byte   (ei_o_entry - ei_dispatch) >> 2, (ei_bad - ei_dispatch) >> 2
    .byte   (ei_bad - ei_dispatch) >> 2, (ei_r - ei_dispatch) >> 2
    .byte   (ei_s - ei_dispatch) >> 2, (ei_t_entry - ei_dispatch) >> 2
    .byte   (ei_u - ei_dispatch) >> 2, (ei_bad - ei_dispatch) >> 2
    .byte   (ei_nop - ei_dispatch) >> 2
    .align  2
ei_n_entry:
ei_n:
    cmp     w10, #'o'
    b.eq    ei_nop
ei_neg:
    movz    w25, #0x4B00, lsl #16
ei_neg_mvn_common:
    bl      parse_2reg
ei_zr_rn_tail:
    mov     x24, #31
    b       emit_3reg_w25_tail
ei_nop:
    ldrb    w9, [x19, #2]
    add     w9, w9, w9, lsr #2              // p/e/i select NOP/WFE/WFI field 0/2/3
    movz    w0, #0x201F
    bfi     w0, w9, #5, #2
ei_sysfixed_tail:
    movk    w0, #0xD503, lsl #16
    br      x16
ei_a:
    tbnz    w10, #0, ei_a_asr               // 's' is the only odd second character
    tbnz    w10, #4, ei_sysop               // 't' selects the SYS-class form
    tbz     w10, #3, ei_a_d                 // 'd' has bit 3 clear; 'n' has it set
    sbfx    w22, w20, #2, #1                // AND=0; ANDS=-1 (low opc bits = 3)
    b       ei_logical
ei_o_entry:
ei_o:
    mov     w22, #1                         // ORR opc
ei_logical:
    bl      parse_x23_ws
    bl      parse_register
    bl      mov_x25_skip                    // Rn → x25, skip ','
ei_logical_operand:
    cmp     w9, #'#'
    b.eq    ei_logical_imm

    // register form: sf opc 01010 sh 0 Rm imm6 Rn Rd
    movz    w26, #0x0A00, lsl #16           // logical register-form base
    b       ei_reg_operand

parse_reg_fail:
    adr     x0, msg_badreg
    b       error_at

ei_logical_imm:
    bl      parse_hash_imm
    eor     w1, w24, #1                     // is_32bit = !sf (w-form: x1 zero-extended)
    bl      encode_logical_imm
    // x0 = (N<<12)|(immr<<6)|imms
    movz    w26, #0x1200, lsl #16           // logical-immediate base
    b       ei_imm_pack

    // ── 'c' mnemonics: cmp, cbz, cbnz, clz, cset ──────────────────────────
ei_c:
    tbnz    w10, #0, 2f                     // 'm'/'s' are odd; 'b'/'l' are even
    tbnz    w10, #2, ei_clz                 // 'l' has bit 2; 'b' falls through
    bl      parse_zn_reg
    bl      parse_label_pc_rel
    bfi     w23, w0, #5, #19
    orr     w9, w23, w22, lsl #24
    movz    w26, #0x3400, lsl #16
    b       ei_addsub_sf_emit
2:  tbz     w10, #1, ei_c_cm                // odd 'm' has bit 1 clear; 's' has it set
    ldrb    w10, [x19, #3]
    ubfiz   w26, w10, #9, #2                // 'n' → CSINC bit, 'l' → CSEL
    tbnz    w10, #3, ei_csel_common         // 'l'/'n' vs cset's 't'
// cset Rd, cond — alias for CSINC Rd, xzr, xzr, invert(cond)
ei_cset:
    bl      parse_x22_ws                    // x22 = Rd, x23 = sf
    bl      parse_cond                      // x1 = cond code
    eor     w1, w1, #1                      // invert condition (flip bit 0)
    movz    w26, #0x0400                    // CSINC bit
    mov     x24, #31                        // Rn = xzr
    mov     x0, #31                         // Rm = xzr
    b       ei_csel_tail

ei_t_entry:
ei_t:
    tbnz    w10, #0, ei_tst                 // 's' is odd; 'b'/'l' are even
    tbnz    w10, #3, ei_sysop               // 'l' has bit 3; 'b' falls through
    bl      parse_zn_reg                    // x22=0 for tbz, 1 for tbnz
    bl      parse_hash_imm
    bfi     w23, w0, #19, #5                // pack bit number while the target parser
    lsr     w9, w0, #5                      // preserves the partial instruction
    orr     w23, w23, w9, lsl #31
    add     x0, x2, #1                      // skip ',' (expr parse left x2 there)
    bl      parse_label_pc_rel
    bfi     w23, w0, #5, #14
    orr     w0, w23, w22, lsl #24
    movz    w9, #0x3600, lsl #16
orr_w9_emit:
    orr     w0, w9, w0
    br      x16

// udiv Rd, Rn, Rm / ubfx / ubfm / ubfiz / uxtb / uxth
ei_u:
    mov     w25, #0x800
// ei_bfm_or_xt — route w10 to the bitfield (b) or sign/zero-extend (x) handler;
// otherwise fall through to the div encoder. Shared by 's' and 'u' prefixes.
ei_bfm_or_xt:
    tbnz    w10, #1, ei_bfm_unified         // 'b' selects bitfield; 'd'/'x' do not
    tbnz    w10, #3, ei_sxt_uxt             // 'x' selects extend; 'd' falls through
ei_div_common:
    bl      parse_3reg
// Shared three-register emit tails live here so div falls through directly.
emit_3reg_1AC0_tail:
    movk    w25, #0x1AC0, lsl #16
emit_3reg_w25_tail:
emit_3reg_sf_tail:
    orr     w25, w25, w0, lsl #16
emit_3reg_prepacked_tail:
    orr     w25, w25, w22
    orr     w0, w25, w24, lsl #5
    b       emit_with_sf

// asr selects ASRV or SBFM through the shared variable/immediate shift encoder.
ei_a_asr:
    movz    w25, #0x2800                    // ASRV opcode
    b       ei_shift_common
// sxtb/sxth/sxtw/uxtb/uxth Rd, Rn — SBFM/UBFM Rd, Rn, #0, #imms
ei_sxt_uxt:
    bl      parse_2reg
    add     x24, x0, #0
    mov     w10, #0                         // immr = 0
    ldrb    w9, [x19, #3]                   // suffix: 'b', 'h', or 'w'
    sub     w11, w9, #91                    // b/h/w → 7/13/28
    orr     w11, w11, #3                    //       → 7/15/31
    tbz     w25, #10, ei_ubfm_emit          // uxt's 0x800 vs sxt's 0xC00
ei_asr_sbfm:
    movz    w0, #0x1300, lsl #16            // 32-bit SBFM base (sf+N applied later)
    b       ei_bfm_apply_n_sf

ei_a_d:
    ldrb    w10, [x19, #2]
    cmp     w10, #'d'
    b.eq    ei_add
    cmp     w10, #'r'
    b.ne    ei_bad
    // adr/adrp shared: parse Rd, skip comma, precompute PC
    bl      parse_x23_ws
    ldr     x25, [x28, #ST_TEXT_POS]
    add     x25, x25, #CODE_START           // x25 = PC
    tbnz    x20, #0, ei_adr_body            // ADR length 3 vs ADRP length 4
    // adrp: page-relative offset
    bl      parse_label_ref
    bl      adr_page_word
    b       ei_adr_encode
ei_adr_body:
    bl      parse_expr0
    sub     x10, x0, x25                    // imm21 = target - PC
    bl      adr_word
ei_adr_encode:
    sub     w23, w20, #3                    // sf: 0=ADR(len3), 1=ADRP(len4)
    b       emit_with_sf

    // ── 'b' mnemonics: b, bl, b.cond, bic, bfm, bfi, bfxil ────────────────
ei_b:
    cmp     w10, #'f'
    b.eq    ei_bfm_unified
    cmp     w20, #3
    b.eq    ei_b3
    b.hi    ei_bad
    cmp     w10, #'r'
    b.eq    ei_br
    // Start from BL's six-bit opcode; len=1 toggles it to B, while len=2
    // only affects the ignored bit above the six-bit field.
    mov     w22, #37
    eor     w22, w22, w20, lsl #5
    bl      ws_x21
    cmp     w9, #'.'
    b.eq    ei_bcond
    // B/BL: parse label, compute pc-relative offset
    bl      parse_label_pc_rel
    bfi     w0, w22, #26, #6
    br      x16
// 3-char 'b' mnemonics: blr or bic
ei_b3:
    tbnz    w10, #2, ei_blr                 // mnemonic[1]: 'l' vs 'i'
// bic Rd, Rn, Rm — AND Rd, Rn, ~Rm
// sf 00 01010 sh 1 Rm imm6 Rn Rd
ei_bic:
    bl      parse_3reg
    movz    w25, #0x0A20, lsl #16           // 32-bit BIC
    b       emit_3reg_sf_tail
// The 's' dispatcher covers sub/str/svc/sbf*/sxt*; later handlers share the
// same second-character classification.
ei_s:
    tbnz    w10, #0, ei_su                  // 'u' is odd; all other valid seconds even
    cmp     w10, #'t'
    b.eq    ei_st
    cmp     w10, #'v'
    b.eq    ei_svc
    mov     w25, #0xC00
    b       ei_bfm_or_xt

// br Xn / blr Xn — branch (with link) to a register. Mnemonic length selects
// bit 21 because x20 is 2 for br and 3 for blr.
ei_br:
ei_blr:
    bl      ws_x21
    bl      parse_register
    movz    w9, #0xD61F, lsl #16
    bfi     w9, w20, #21, #1                // bit 0 of length selects br/blr
    orr     w0, w9, w0, lsl #5
    br      x16

// clz/rbit, ret, and ror share the 'r' dispatcher ('c' enters at ei_clz).
ei_clz:
ei_r:
    tbz     w10, #0, ei_rbit                // rbit/clz have an even second character
    tbnz    w10, #3, ei_ror                 // odd 'o' has bit 3; 'e' falls through
ei_ret:
    movz    w0, #0x03C0
    movk    w0, #0xD65F, lsl #16
    br      x16

// csel/csinc Rd, Rn, Rm, cond
// encoding: sf 00 11010100 Rm cond 00 Rn Rd (64-bit base 0x9A800000)
ei_csel_common:
    bl      parse_3reg                      // x22=Rd, x23=sf, x24=Rn, x0=Rm
    bl      mov_x25_skip                    // save Rm → x25, skip ','
    bl      parse_cond                      // x1 = cond
    add     x0, x25, #0                     // Rm for emit_3reg_sf_tail
ei_csel_tail:
    movk    w26, #0x1A80, lsl #16           // CSEL/CSINC base (clobbers w26)
    orr     w25, w26, w1, lsl #12           // | (cond << 12)
    b       emit_3reg_sf_tail

// The 'm' dispatcher covers madd/msub, mov*, mul, mrs/msr, and mvn.
ei_m:
    tbz     w10, #0, ei_m_even              // even: mrs/mvn; odd: the other forms
    tbz     w10, #4, ei_m_ao                // low bit4: madd/mov
    tbz     w10, #1, ei_mul                 // high bit4: mul/msr/msub
    tbnz    x20, #0, ei_msr                 // MSR length 3 vs MSUB length 4
    b       ei_madd_msub_select
ei_m_ao:
    tbnz    w10, #1, ei_mo                  // 'o' has bit 1; 'a' falls through
ei_m_madd:
ei_madd_msub_select:
    // 'a' contributes bit14, overwritten by Ra; 's' also contributes MSUB bit15
    ubfiz   w25, w10, #14, #2
// madd/msub Rd, Rn, Rm, Ra — 0x1B000000 (32) / 0x9B000000 (64)
ei_madd_msub_common:
    bl      parse_3reg                      // x22=Rd, x23=sf, x24=Rn, x0=Rm
    movk    w25, #0x1B00, lsl #16           // 32-bit base
    orr     w25, w25, w0, lsl #16           // prepack Rm across the Ra parse
    bl      ws_x2_skip1                     // skip ','
    bl      parse_register                  // Ra
    bfi     w25, w0, #10, #5                // Ra overwrites the speculative bit14
    b       emit_3reg_prepacked_tail
ei_m_even:
    tbz     w10, #2, ei_mrs                 // 'r' has bit 2 clear; 'v' falls through
// mvn Rd, Rm — alias for orn Rd, xzr, Rm
ei_mvn:
    movz    w25, #0x2A20, lsl #16           // 32-bit ORN base
    b       ei_neg_mvn_common

ei_mo:
    // mov (3 chars) vs movz/movn/movk (4 chars)
    tbnz    x20, #0, ei_mov
    ldrb    w10, [x19, #3]
    cmp     w10, #'z'
    movz    w26, #0x5280, lsl #16           // MOVZ base (speculative)
    b.eq    ei_movwide
    cmp     w10, #'n'
    movz    w26, #0x1280, lsl #16           // MOVN base (speculative)
    b.eq    ei_movwide
    cmp     w10, #'k'
    b.ne    ei_bad
    movz    w26, #0x7280, lsl #16           // MOVK base

// movz/movn/movk Rd, #imm16 [, lsl #N]
ei_movwide:
    bl      parse_x22_ws
    bl      parse_hash_imm                  // #imm16
    and     w25, w0, #0xFFFF                // imm16 (callee-saved)

    // check for optional ", lsl #N"
    bl      ws_x2
    cmp     w9, #','
    mov     w10, #0                         // hw = 0 default (doesn't affect flags)
    b.ne    ei_movwide_emit
    bl      skip_lsl                        // skip ", lsl" + parse_hash_imm
    add     w10, w0, #0                     // raw shift amount

ei_mov_found:
ei_movwide_emit:
    orr     w0, w26, w23, lsl #31           // base | sf
    orr     w0, w0, w22                     // | Rd
    orr     w0, w0, w25, lsl #5             // | imm16
    orr     w0, w0, w10, lsl #17            // | hw (shift<<17 = hw<<21)
    br      x16

    // ── mrs Rt, sysexpr  /  msr sysexpr, Rt ─────────────────────────────────
    // The system register is an expression evaluating to its op0/op1/CRn/CRm/
    // op2 fields already placed at bits [19:5] (kernel keeps a named .equ
    // table). mrs/msr differ only by the L bit (21): 0xD5300000 / 0xD5100000.
ei_mrs:
    bl      parse_x23_ws                    // x23 = Rt; cursor past ',' at the sysexpr
    bl      parse_expr0                     // x0 = sysreg field; x2 = trailing cursor
    movz    w9, #0xD530, lsl #16            // MRS base
    orr     w9, w9, w23                     // base | Rt at [4:0]
    b       orr_w9_emit
ei_msr:
    bl      ws_x21                          // x0 at the sysexpr (first operand)
    cmp     w9, #'d'                        // "daifset"/"daifclr" → PSTATE immediate form
    b.eq    ei_daif
    bl      parse_field_reg                 // x25 = field, x0 = Rt
    movz    w9, #0xD510, lsl #16            // MSR base
    b       ei_sysfield_emit

ei_bad:
    adr     x0, msg_badins
    bl      error_at

    // 'e' mnemonics: eret (no operands) versus eor (logical)
ei_e:
    cmp     w10, #'r'
    b.eq    ei_eret
    mov     w22, #2                         // EOR opc
    b       ei_logical

// ldr/ldrb/ldrh/ldrs*, lsl, and lsr share the 'l' dispatcher.
ei_l:
    tbz     w10, #0, ei_ld                  // 'd' is even; shift mnemonics use 's'
// lsl/lsr — immediate (UBFM alias) or register (LSLV/LSRV)
ei_ls_shift:
    ldrb    w10, [x19, #2]
    ubfiz   w25, w10, #9, #2                // 'l' low2=0, 'r' low2=2 → LSLV/LSRV bit
    orr     w25, w25, #0x2000
ei_shift_common:
    bl      parse_2reg                      // x22=Rd, x23=sf, x0=Rn, x2=ptr past
    bl      mov_x24_skip                    // Rn → x24, skip ','
    cmp     w9, #'#'
    b.eq    ei_shift_imm_dispatch
    // register form
    bl      parse_register                  // Rm
    b       emit_3reg_1AC0_tail

// eret has no operands and enters the common fixed-instruction emit path.
ei_eret:
    movz    w0, #0x03E0
    movk    w0, #0xD69F, lsl #16
    br      x16

// hvc #imm is encoded like svc, with exception field 2 instead of 1.
ei_h:
ei_svc:
    ubfx    w25, w9, #3, #1                 // 'h' bit 3 = 1, 's' bit 3 = 0
    add     w25, w25, #1                    // exception field: hvc=2, svc=1
    bl      ws_x21
    bl      parse_hash_imm                  // x0 = imm16 value
    ubfiz   w0, w0, #5, #16                 // imm16 << 5, masked
    orr     w0, w25, w0                     // exception entry (1=svc, 2=hvc)
    movk    w0, #0xD400, lsl #16            // exception-generating opcode
    br      x16

// ── system instructions (table-free: barrier/SYS fields are #imm/exprs, like
//    mrs/msr — the kernel keeps any named .equ table). ────────────────────────
ei_d:
    cmp     w20, #2                         // "dc" → SYS-class; "dsb"/"dmb" → barrier
    b.eq    ei_sysop
    tbnz    w9, #0, ei_isb                  // 'i' is odd; 'd' falls through
    ubfx    w25, w10, #4, #1                // 's' bit 4: DMB → DSB
    bl      ws_x21
    bl      parse_hash_imm                  // x0 = CRm (barrier domain/type)
    movz    w9, #0x30BF                     // DMB base
    sub     w9, w9, w25, lsl #5
    orr     w0, w9, w0, lsl #8              // | CRm<<8
    b       ei_sysfixed_tail
ei_isb:
    movz    w0, #0x3FDF
    b       ei_sysfixed_tail
// tst Rn, #imm / Rm — alias for ANDS XZR, Rn, operand
ei_tst:
    mov     w22, #3                         // ANDS opc
    adr     x14, ei_logical_operand
    b       ei_rn_xzr_rd

// parse_field_reg — parse "<field_expr>, Rt": field -> x25 and x0 -> Rt.
// Shared by msr and the dc/ic/tlbi/at SYS class. Uses [sp, #56] (never
// live across this call: parse_2reg/parse_3reg/parse_mem reload immediately).
parse_field_reg:
    str     x30, [sp, #56]
    bl      parse_expr0                     // x0 = field, x2 at ','
    add     w25, w0, #0                     // save field across the reg parse
    bl      ws_x2_skip1                     // skip ',' → x0 at Rt
    ldr     x30, [sp, #56]
    b       parse_register                  // x0 = Rt
// ei_sysop: dc/ic/tlbi/at — SYS-class. <mnem> <field_expr>, Xt
//   → 0xD5080000 | field | Rt. field=(op1<<16)|(CRn<<12)|(CRm<<8)|(op2<<5),
//   supplied as an expr (.equ'd by the kernel); no-Rt forms pass xzr.
ei_sysop:
    bl      ws_x21
    bl      parse_field_reg                 // x25 = field, x0 = Rt
    movz    w9, #0xD508, lsl #16            // SYS base 0xD5080000
ei_sysfield_emit:
    // Field exprs place op0/op1/CRn/CRm/op2 at bits [19:5] (the .equ
    // convention encodes op0 as (op0-2)<<19), so no masking is needed.
    orr     w9, w25, w9                     // | field
    b       orr_w9_emit                     // | Rt, then emit
// msr daifset/daifclr, #imm — PSTATE field immediate (op1=3, op2=6/7)
ei_daif:
    ldrb    w9, [x0, #4]                    // 's' (daifset) or 'c' (daifclr)
    movz    w25, #0x41C5
    sub     w25, w25, w9, lsl #1            // 'c' → DAIFClr, 's' → DAIFSet
    add     x0, x0, #7                      // past "daifset"/"daifclr" → at ','
    bl      skip1_ws                        // skip ',' + ws → '#'
    bl      parse_hash_imm                  // x0 = imm
    orr     w0, w25, w0, lsl #8             // | imm<<8
    b       ei_sysfixed_tail

ei_bcond:
    add     x0, x0, #1                      // skip '.'
    movz    w26, #0x5400, lsl #16           // 0x54000000
    bl      parse_cond
    orr     w26, w1, w26                    // base | cond
    bl      parse_label_pc_rel
    // 0x54000000 | (imm19 << 5) | cond
    and     w0, w0, #0x7FFFF
    orr     w0, w26, w0, lsl #5
    br      x16

// ror Rd, Rn, Rm — RORV: 0x1AC02C00 (32-bit) / 0x9AC02C00 (64-bit)
ei_ror:
    movz    w25, #0x2C00
    b       ei_div_common

// add/adds Rd, Rn, #imm / Rm [, lsl #N] / :lo12:sym
ei_add:
// sub/subs Rd, Rn, #imm / Rm
ei_su:
ei_sub:
    // ('a'/'s' + mnemonic length) & 3 = ADD/ADDS/SUB/SUBS opc.
    add     x22, x9, x20
ei_addsub:
    bl      parse_x23_ws
    bl      parse_register
    bl      mov_x25_skip                    // save Rn → x25, skip ','

    // is the third operand a register or immediate?
ei_addsub_operand:
    cmp     w9, #'a'
    b.lo    ei_addsub_imm                   // '#' or ':lo12:' (both < 'a')
    movz    w26, #0x0B00, lsl #16           // add/sub register-form base

    // register form: Rd, Rn, Rm [, lsl #N] — w26=base, x25=Rn, x22=op bits
ei_reg_operand:
    bl      parse_register
    orr     w21, w23, w0, lsl #16           // save Rd | (Rm << 16)
    bl      ws_x2
    // check for optional ", lsl #N"
    cmp     w9, #','
    mov     w9, #0                          // shift amount default 0 (doesn't affect flags)
    b.ne    1f
    bl      skip_lsl                        // skip ", lsl" + parse_hash_imm
    add     x9, x0, #0                      // shift amount
1:  orr     w0, w21, w25, lsl #5            // (Rd|Rm<<16) | (Rn << 5)
    orr     w0, w0, w9, lsl #10             // imm6 (shift amount, ≤ 63)
    bfi     w0, w22, #29, #2                // op|S / opc bits
    orr     w0, w0, w26                     // base opcode
    b       emit_with_sf24

ei_addsub_imm:
    // immediate form: #expr or #:lo12:expr (imm12, optionally <<12)
    bl      parse_hash_imm                  // x0=val, x2=is_lo12
    movz    w26, #0x1100, lsl #16           // unshifted add/sub-immediate base
    lsr     x9, x0, #12
    cbz     x9, 1f                          // fits in 12 bits -> shift = 0
    // Else try LSL #12: low 12 bits must be zero and the value must fit in
    // bits 12..23. This wrapping logical mask checks both conditions at once.
    tst     x0, #0xffffffffff000fff
    b.ne    ei_logical_bad
    lsr     x0, x0, #12                     // imm12 = val >> 12
    movz    w26, #0x1140, lsl #16           // shifted add/sub-immediate base
    // sf op 0 10001 shift imm12 Rn Rd
1:
ei_imm_pack:
    orr     w9, w23, w25, lsl #5            // Rd | (Rn << 5)
    orr     w9, w9, w0, lsl #10             // imm12
    bfi     w9, w22, #29, #2                // op|S bits

// shared tail: w26=base opcode, w9=partial instruction, x24=sf
ei_addsub_sf_emit:
    orr     w0, w26, w9
    b       emit_with_sf24

// cmp/cmn Rn, #imm / cmp/cmn Rn, Rm — reuse addsub with Rd=xzr
ei_c_cm:
    ldrb    w10, [x19, #2]
    eor     w22, w10, #3                    // 'p' low bits 0→3, 'n' 2→1
    adr     x14, ei_addsub_operand
// Shared by tst/cmp/cmn: parse Rn, force Rd=XZR, continue via x14.
ei_rn_xzr_rd:
    bl      parse_x23_ws                    // x23=Rn, x24=sf
    add     x25, x23, #0                    // Rn
    mov     x23, #31                        // Rd = xzr
    br      x14

ei_logical_bad:
    adr     x0, msg_badimm
    bl      error_at

// ldr*/str*/ldp/stp — load/store dispatch for all supported addressing modes
ei_ld:
ei_st:
    ubfx    x22, x9, #2, #1                 // 'l' bit 2 = 1, 's' bit 2 = 0
ei_ldst_dispatch:
    ldrb    w10, [x19, #2]
    cmp     w10, #'p'
    b.eq    ei_ldst_pair
ei_ldst:
    bl      parse_x23_ws                    // x23=Rt, x24=sf
    // x24 already has sf from parse_x23_ws
    sub     w10, w20, #3                    // zero for ldr/str; nonzero for suffixed forms
    // precompute size encoding: 0=byte, 1=half, 2=32bit, 3=64bit
    add     w20, w24, #2                    // 2 or 3
    cbz     x10, 1f                         // len=3: use sf+2
    ldrb    w20, [x19, #3]                  // 'b'=0x62, 'h'=0x68, 's'=0x73
    tbnz    w20, #0, ei_ldrs_size           // sign-extending load (ldrsb/ldrsh/ldrsw)
    ubfx    w20, w20, #3, #2                // 0 for byte, 1 for half
    // Literal-load check: ldr Rt, label has no opening bracket.
1:
    cbz     x22, ei_ldst_bracket            // store: must have [
    cbnz    x10, ei_ldst_bracket            // ldrb/ldrh: must have [
    cmp     w9, #'='
    b.eq    ei_ldr_eq                       // ldr Rt, =label  (pseudo-op)
    cmp     w9, #'['
    b.ne    ei_ldr_literal
ei_ldst_bracket:
    bl      parse_mem                       // x25=Rn, x19=imm/Rm, x26=mode
    tbnz    x26, #2, ei_ldst_reg            // bit 2 marks register offset
    cbz     x26, ei_ldst_uimm_encode        // base / signed offset form
    // pre/post-index: simm9 with mode bits = x26 at [11:10]
    bl      ldst_base_simm9
    orr     w0, w0, w26, lsl #10
    b       ei_ldst_simm9_tail

ei_ldst_reg:
    orr     x24, x26, x19, lsl #7           // prepack mode | (Rm << 7)
    bl      ldst_base
    // x26 = (option<<4)|(S<<3)|4, so x26<<9 lands the mode-4 marker bit on bit
    // 11 (the register-offset [11:10]=10 marker), S on bit 12, option on [15:13]
    orr     w0, w0, w24, lsl #9             // mode | (Rm << 16)
    movz    w9, #0x3820, lsl #16            // 0x38000000 | 0x00200000 (bit 11 from x26)
    b       orr_w9_emit

ei_ldst_uimm_encode:
    tbnz    x19, #63, ei_ldst_unscaled      // negative → LDUR/STUR encoding
    lsr     x10, x19, x20
    lsl     x9, x10, x20
    cmp     x9, x19
    b.ne    ei_ldst_unscaled                // unaligned offset → LDUR/STUR
    bl      ldst_base
    bfi     w0, w10, #10, #12
    movz    w9, #0x3900, lsl #16
    b       orr_w9_emit
ei_ldst_unscaled:
    bl      ldst_base_simm9                 // bits[11:10] = 00 (unscaled)
ei_ldst_simm9_tail:
    bfi     w0, w19, #12, #9                // imm9 at [20:12]
    orr     w0, w0, #0x38000000
    br      x16

// ──────────────────────────────────────────────────────────────────────────
//  parse_mem — parse a load/store address operand
//  entry: x0 at '[' (w9 = '['); uses [sp, #56] for return address
//  returns x25 = Rn, x19 = imm (or Rm), x26 = mode:
//    0 = base / signed offset, 1 = post-index, 3 = pre-index,
//    option<<4 | S<<3 | 4 = register offset (x19 = Rm)
//  clobbers x19
// ──────────────────────────────────────────────────────────────────────────
parse_mem:
    str     x30, [sp, #56]
    bl      skip1_ws                        // skip '['
    bl      parse_register                  // Rn
    cbz     x1, parse_reg_fail              // base must be 64-bit (xN or sp)
    add     x25, x0, #0
    mov     w19, #0                         // imm = 0
    mov     w26, #0                         // mode = offset
    bl      ws_x2
    cmp     w9, #']'
    b.eq    pm_close
    cmp     w9, #','
    b.ne    pe_atom_err
    bl      skip1_ws                        // skip ','
    cmp     w9, #'a'
    b.lo    pm_imm                          // '#' or ':lo12:' (both < 'a')
    // register offset: Rm [, <extend> #N] — extend ∈ lsl/uxtw/sxtw/uxtx/sxtx
    bl      parse_register
    add     x19, x0, #0                     // Rm
    bl      ws_x2                           // x0 at char after Rm, w9 = char
    movz    w11, #3                         // option: default LSL/UXTX = 3
    cmp     w9, #']'
    b.eq    pm_reg_fin                      // [Rn, Rm]
    bl      skip1_ws                        // skip ','; x0 at keyword, w9 = first char
    tbz     w9, #0, pm_reg_shift            // lsl → option 3; uxt*/sxt* are odd
    ldrb    w10, [x0, #3]                   // 4th char: 'w'(odd) / 'x'(even)
    ubfx    w10, w10, #3, #2                // u-prefix: uxtw=2, uxtx=3
    ubfx    w11, w9, #1, #1                 // s-prefix bit
    orr     w11, w10, w11, lsl #2           // s-prefix: sxtw=6, sxtx=7
pm_reg_shift:
    lsl     x26, x11, #4                    // stash option before parse_hash_imm clobbers w11
    // optional " #N" (S bit): scan to '#' or ']'
2:  ldrb    w9, [x0, #1]!
    cmp     w9, #'#'
    b.eq    3f
    cmp     w9, #']'
    b.eq    pm_reg_done
    cbz     w9, pe_atom_err
    b       2b
3:  bl      parse_hash_imm                  // x0 = shift amount (x26 preserved)
    cbz     x0, 4f
    cmp     x0, x20                         // nonzero shift must equal access-size log2
    b.ne    pe_atom_err
    orr     x26, x26, #8                    // S = 1 (bit 3)
4:  bl      ws_x2
    b       pm_reg_done
pm_reg_fin:
    lsl     x26, x11, #4                    // [Rn, Rm]: option<<4, S = 0
pm_reg_done:
    orr     x26, x26, #4                    // mode-4 register marker
    b       pm_rbracket
pm_imm:
    bl      parse_hash_imm                  // x0 = imm
    add     x19, x0, #0
    bl      ws_x2
pm_rbracket:
    cmp     w9, #']'
    b.ne    pe_atom_err                     // unclosed memory operand
    bl      skip1_ws                        // skip ']'
    tbnz    x26, #2, pm_store_done          // register offsets cannot be pre-indexed
    cmp     w9, #'!'
    b.ne    pm_store_done
    add     x0, x0, #1                      // consume '!'
    mov     w26, #3                         // pre-index
pm_store_done:
    add     x2, x0, #0
    b       pm_done
ei_mov:
    bl      parse_x22_ws

    cmp     w9, #'#'
    b.eq    ei_mov_imm

    // ADD Rd, Rm, #0 matches ORR's move semantics for ordinary registers and
    // retains the existing register-31/SP handling in one shared path.
    bl      parse_register
    orr     w0, w22, w0, lsl #5
    movk    w0, #0x1100, lsl #16
    b       emit_with_sf                    // x23 = sf

// Sign-extending ldrsb/ldrsh/ldrsw: derive size and opc from the mnemonic
// suffix and destination-register width before joining the bracket path.
ei_ldrs_size:
    ldrb    w9, [x19, #4]                   // 5th char: 'b','h','w'
    ubfx    w20, w9, #3, #2                 // 'b'→0, 'h'→1, 'w'→2
    eor     w22, w24, #3                    // opc = 3 - sf (Xd→2, Wd→3) = sf^3
    b       ei_ldst_bracket

// ldr Rt, label — PC-relative literal load
// x23=Rt, x24=sf, x0=pointer to label
ei_ldr_literal:
    bl      parse_label_pc_rel              // x0 = (target - PC) / 4
    ubfiz   w0, w0, #5, #19                 // imm19 << 5
    orr     w0, w0, w23                     // Rt
    movz    w26, #0x1800, lsl #16           // 32-bit base (0x18000000)
    orr     w9, w26, w24, lsl #30           // sf=1 → 0x58000000 for 64-bit
    b       orr_w9_emit

// ldr Rt, =sym — pseudo-op for a symbol's ADDRESS: adrp Rt, sym ; add Rt, Rt,
// #:lo12:sym (2 words, identical in both passes). x23 = Rt, x0 = pointer at '='.
// A numeric =immediate form once existed but was strictly worse than movz/movk
// at every width, so it was removed: use movz/movk for a literal constant and
// mov Rd, #NAME for a named .equ.
ei_ldr_eq:
    bl      skip1_ws                        // skip '='; x0 at the symbol operand
    bl      parse_label_ref                 // x0 = resolved target address
    add     x26, x0, #0                     // save target for lo12
    ldr     x25, [x28, #ST_TEXT_POS]
    add     x25, x25, #CODE_START           // PC of the adrp
    bl      adr_page_word                   // x0 still = target
    orr     w0, w0, #0x80000000             // ADR → ADRP
    bl      emit_word_raw
    movz    w0, #0x9100, lsl #16            // ADD (64-bit imm) base 0x91000000
    bfi     w0, w26, #10, #12               // lo12 immediate
    orr     w9, w23, w23, lsl #5            // Rd = Rn = Rt
    b       orr_w9_emit

ei_ldst_pair:
    // x22=L (already set by ei_ld/ei_st)
    bl      parse_x23_ws
    add     w21, w24, #2                    // offset scale: 2 (32-bit) or 3 (64-bit)
    bl      parse_register                  // Rt2
    bl      mov_x24_skip                    // Rt2 → x24, skip ',' → at '['
    bl      parse_mem                       // x25=Rn, x19=imm, x26=mode
    // map mode {0,post=1,pre=3} → LDP/STP XOR bits {0,3,1} at [24:23]
    add     x9, x26, x26, lsl #1            // 3*mode
    and     x9, x9, #3
    asr     w0, w19, w21
    movz    w26, #0x2900, lsl #16           // 32-bit STP/LDP base (signed offset)
    orr     w26, w26, w21, lsl #31          // bit 0 of scale is sf
    eor     w26, w26, w9, lsl #23           // apply addressing mode bits
    orr     w26, w26, w22, lsl #22
    bfi     w26, w0, #15, #7                // imm7 at bits[21:15]
    orr     w26, w26, w24, lsl #10
    orr     w26, w26, w25, lsl #5
    orr     w0, w26, w23
    br      x16

// mul Rd, Rn, Rm — MADD Rd, Rn, Rm, XZR
// 64-bit: 0x9B007C00 | (Rm<<16) | (Rn<<5) | Rd
// 32-bit: 0x1B007C00 | ...
ei_mul:
    bl      parse_3reg
    movz    w25, #0x7C00
    movk    w25, #0x1B00, lsl #16           // 32-bit base
    b       emit_3reg_sf_tail

ei_shift_imm_dispatch:
ei_shift_imm:
    bl      parse_hash_imm
    // x0 = shift amount (no bl before use, safe to use directly)
    mov     x11, #31
    add     x11, x11, x23, lsl #5           // size-1 = 31 or 63 (shared)
    tst     w25, #0xC00
    b.ne    ei_lsr_asr_imm
    // LSL #n: UBFM Rd, Rn, #(-n mod size), #(size-1-n)
    neg     x10, x0
    and     x10, x11, x10                   // immr = (-n) & (size-1)
    sub     x11, x11, x0                    // imms = (size-1) - n
    b       ei_ubfm_emit

ei_lsr_asr_imm:
    add     x10, x0, #0                     // immr = n
    tbnz    w25, #11, ei_asr_sbfm           // bit 11 set in w25 = ASR (0x2800)

ei_ubfm_emit:
    movz    w0, #0x5300, lsl #16            // UBFM base (sf+N applied below)
ei_bfm_apply_n_sf:
    orr     w0, w0, w23, lsl #22            // N bit = sf
ei_ubfm_orr:
    orr     w0, w0, w22
    orr     w0, w0, w24, lsl #5
    orr     w0, w0, w11, lsl #10
    orr     w0, w0, w10, lsl #16
    b       emit_with_sf

// ── unified bitfield handler (ubfx/ubfm/ubfiz/sbfx/sbfm/sbfiz/bfm/bfi/bfxil)
ei_bfm_unified:
    bl      parse_2reg                      // x22=Rd, x23=sf, x0=Rn, x2=ptr past
    bl      mov_x24_skip                    // Rn → x24, skip ','
    bl      parse_hash_imm                  // #op3
    add     x25, x0, #0
    bl      ws_x2_skip1                     // skip ','
    bl      parse_hash_imm                  // #op4
    add     x11, x0, #0                     // op4 in x11
    // determine base opcode from mnemonic first char (x19 preserved)
    ldrb    w12, [x19]
    ubfx    w13, w12, #4, #2                // suffix offset: b*=2, u*/s*=3
    eor     w12, w12, #3                    // b/s/u low bits become opc 1/0/2
    movz    w0, #0x1300, lsl #16            // SBFM base
    bfi     w0, w12, #29, #2
    ldrb    w13, [x19, x13]                 // load distinguishing char
    tbnz    w13, #4, bfm_extract_apply      // 'x'
    tbnz    w13, #2, bfm_raw_apply          // 'm' vs 'i'

// insert: immr=(-lsb) mod size, imms=width-1 (fall-through from dispatch)
bfm_insert_apply:
    mov     x9, #31
    add     x9, x9, x23, lsl #5             // size-1 (same words as ei_shift_imm)
    neg     x10, x25
    and     x10, x9, x10
    sub     x11, x11, #1                    // imms = width-1
    b       ei_bfm_apply_n_sf

// extract: immr=lsb(x25), imms=lsb+width-1 (falls through to raw)
bfm_extract_apply:
    add     x11, x25, x11
    sub     x11, x11, #1
// raw: immr=x25, imms=x11
bfm_raw_apply:
    add     x10, x25, #0
    b       ei_bfm_apply_n_sf

// mov Rd, #imm — select a single-instruction MOVZ or MOVN representation.
ei_mov_imm:
    bl      parse_hash_imm
    // x0 = immediate (no bl in the probe, safe to use directly)
    movz    w26, #0x5280, lsl #16           // phase/opcode: MOVZ, then MOVN
ei_mov_try_phase:
    // A MOV-wide immediate has at most one nonzero 16-bit halfword. Align
    // the least-significant set bit down to its halfword and test that one.
    rbit    x10, x0
    clz     x10, x10                        // ctz(x0), or 64 for zero
    and     x10, x10, #0x30                 // halfword shift: 0/16/32/48
    ror     x25, x0, x10
    lsr     x9, x25, #16
    cbz     x9, ei_mov_found
    // try MOVN phase — complement in the register's width (32 vs 64) so e.g.
    // `mov w1, #0xffffffff` -> movn w1, #0 (a 64-bit ~ would set the top half)
    tbz     w26, #30, ei_logical_bad        // MOVN phase already tried
    mvn     x0, x0
    cbnz    x23, 1f                         // x23 = sf: 0 = W (32-bit complement)
    and     x0, x0, #0xFFFFFFFF
1:  eor     w26, w26, #0x40000000           // MOVZ base → MOVN base
    b       ei_mov_try_phase

// Complete [Rn] and, when present, parse its post-index immediate.
pm_close:
    bl      skip1_ws                        // skip ']'
    cmp     w9, #','
    b.ne    pm_store_done
    bl      skip1_ws                        // skip ','
    bl      parse_hash_imm                  // (cursor stored by parse_expr)
    add     x19, x0, #0
    mov     w26, #1                         // post-index
pm_done:
    ldr     x30, [sp, #56]
    ret

// ldst_base_simm9 is the signed-offset entry to the common partial encoder;
// its callers add the simm9 and addressing-mode fields afterward.
ldst_base_simm9:
// ldst_base: compute size<<30 | opc<<22 | Rn<<5 | Rt for load/store encodings
// reads x20=size, x22=opc, w23=Rt, x25=Rn; returns w0=partial insn
ldst_base:
    orr     w0, w23, w25, lsl #5
    orr     w0, w0, w20, lsl #30
    orr     w0, w0, w22, lsl #22
    ret

// rbit/clz share this block and fall through to the sf-aware emit tail.
ei_rbit:
    ubfiz   w25, w9, #12, #1                // 'c' bit 0 → CLZ's 0x1000; 'r' → RBIT
ei_clz_rbit_common:
    bl      parse_2reg                      // x22=Rd, x23=sf, x0=Rn
    orr     w0, w22, w0, lsl #5             // Rd | (Rn << 5)
    movk    w25, #0x5AC0, lsl #16           // merge base into w25
    orr     w0, w25, w0

// emit_with_sf / emit_with_sf24 — apply sf to bit 31, then fall through to
// emit_inst_done with the completed instruction in w0.
emit_with_sf:
    add     w24, w23, #0
emit_with_sf24:
    orr     w0, w0, w24, lsl #31

// emit_inst_done — arrange the common trailing-text check, then append w0.
// Reached by branch from encode_instruction; synthesize emit_word_raw's return
// in x30, which is dead in the encoder frame.
emit_inst_done:
    adr     x30, expect_eol_done

// emit_word_raw — append instruction word w0 to .text, advance pos by 4.
// Like emit_inst_done but without the trailing-text check, so a pseudo-op can
// emit several words and run the check once at the end. Leaf; preserves x23-x26.
emit_word_raw:
    ldr     x10, [x28, #ST_TEXT_POS]
    str     w0, [x27, x10]
    add     x10, x10, #4
    str     x10, [x28, #ST_TEXT_POS]
    ret

// ── appended data (stage 0: header/stub/dicts; self-hosted: .rodata) ──────
_appended_data:
