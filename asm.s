// asm.s — self-hosting aarch64 assembler
//
// reads an aarch64 assembly source file (GAS-compatible subset),
// emits a static PIE ELF binary directly. no linker required.
//
// usage: asm <input.s> <output>
//
// this file was created solely by Claude (Opus 4.6, Sonnet 4.6, and Fable 5)
// and is in the public domain (or CC0 1.0, if you prefer).
//
// to bootstrap: as -o asm.o asm.s asm_stage0.s && ld -o asm0 asm.o && ./asm0 asm.s asm
// or, seeded by any earlier asm binary (no system toolchain):
//   cat asm.s asm_stage0.s > s0.s && ./asm_seed s0.s asm0 && ./asm0 asm.s asm
//
// current binary size: 4380 bytes
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
//    svc   #imm16
//
// ── registers ─────────────────────────────────────────────────────────────
//    x0-x30, w0-w30, xzr, wzr, sp   (no fp/lr aliases)
//
// ── directives ────────────────────────────────────────────────────────────
//    .text  .bss  .section .rodata  .global name  .equ name, expr
//    .word expr   .dword expr       .ascii "str"      .asciz "str"
//    .dword label[+const|-const]    (.rodata only; pointer relocated at runtime)
//    .align N     .skip N
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
.equ O_WRONLY_CREAT_TRUNC, 577   // O_WRONLY|O_CREAT|O_TRUNC = 1|64|512
.equ STDERR,               2

// ── ELF constants ─────────────────────────────────────────────────────────
.equ ELF_HEADER_SIZE, 64
.equ PHDR_SIZE,       56
.equ CODE_START,      112        // ehdr + phdr, phdr overlaps last 8 ehdr bytes

// ── compression constants ─────────────────────────────────────────────────
// stub bytes from CODE_START to the dicts; four more stub instructions
// live in ELF-header holes (e_ident padding + p_paddr, entry point at 8)
.equ STUB_SIZE,              204
// stub data words live in zero ELF-header holes the kernel ignores
// (e_shoff and e_flags), patched at output time
.equ STUB_DATA_DECOMP_DEST, 40    // image offset of decomp_dest word (e_shoff)
.equ STUB_DATA_RODATA_SIZE, 44    // image offset of rodata_size word
.equ STUB_DATA_RELOC_COUNT, 48    // image offset of reloc_count word (e_flags)
// three-tier dictionary: codes 1..112 = full word, 113..160 = top 24 bits
// (+1 literal byte), 161..254 = top 16 bits (+2 literal bytes), 255 = raw
.equ FULL_DICT_ENTRIES, 112
.equ T24_DICT_ENTRIES,  48
.equ T16_DICT_ENTRIES,  94
.equ FULL_DICT_SIZE,    448        // 112 * 4
.equ T24_DICT_SIZE,     144        // 48 * 3 (packed)
.equ T16_DICT_SIZE,     188        // 94 * 2
// FULL + T24 + T16: keeps CODE_START+STUB_SIZE+DICT_SIZE a multiple
// of 8 so the memcpy8 template copy can't overshoot into the stream
.equ DICT_SIZE,         780

// ── section IDs ───────────────────────────────────────────────────────────
.equ SEC_TEXT,       0          // pre-multiplied by 8 for direct state block indexing
.equ SEC_RODATA,     8
.equ SEC_BSS,        16

// ── state block offsets (all u64) ─────────────────────────────────────────
.equ ST_TEXT_POS,    0          // current offset within .text
.equ ST_RODATA_POS,  8          // current offset within .rodata
.equ ST_BSS_POS,     16         // current offset within .bss
.equ ST_CUR_SEC,     24         // current section (SEC_TEXT/RODATA/BSS)
.equ ST_TEXT_BASE,   32         // virtual address of .text start
.equ ST_RODATA_BASE, 40         // virtual address of .rodata start
.equ ST_BSS_BASE,    48         // virtual address of .bss start
.equ ST_PASS,        56         // current pass (1 or 2)
.equ ST_LINE_NUM,    64         // current source line number
.equ ST_INPUT_LEN,   72         // input file length in bytes
.equ ST_FILE_SIZE,   80         // total output file size
.equ ST_MEM_SIZE,    88         // total memory size (file + bss)
.equ ST_STUB_BASE,   96         // pointer to decompressor stub bytes
.equ ST_DICT_BASE,   104        // pointer to compression dictionaries (file image or linked)
.equ ST_INPUT_NAME,  112        // pointer to input filename string
.equ ST_OUTPUT_NAME, 120        // pointer to output filename string
.equ ST_RELOC_PTR,   128        // write cursor into reloc_table
.equ ST_EOL_CUR,     136        // cursor after last parsed token (trailing-text check)
.equ ST_SIZE,        144

// ── symbol table entry layout (32 bytes) ──────────────────────────────────
// name_ptr  u64 @ 0   pointer to name in input buffer (0 = empty slot)
// name_len  u32 @ 8   length of name
// flags     u64 @ 16  SYMF_* bits
// value     u64 @ 24  address or .equ value
.equ SYM_ENT_SIZE,   32
.equ SYM_NAME_PTR,   0
.equ SYM_NAME_LEN,   8
.equ SYM_FLAGS,      16
.equ SYM_VALUE,      24
.equ SYM_TBL_SLOTS,  1024       // must be power of 2

// ── symbol flags ──────────────────────────────────────────────────────────
.equ SYMF_DEFINED,   1
.equ SYMF_EQU,       4
.equ SYMF_SEC_SHIFT, 3          // section (pre-multiplied by 8) in bits 4:3

// ── buffer sizes ──────────────────────────────────────────────────────────
.equ INPUT_BUF_SIZE,  1048576    // 1 MB
.equ TEXT_BUF_SIZE,   1048576    // 1 MB
.equ RODATA_BUF_SIZE, 1048576    // 1 MB
.equ SYM_TBL_BYTES,   32768      // SYM_TBL_SLOTS * SYM_ENT_SIZE
.equ RELOC_MAX_ENTRIES, 32768
.equ RELOC_TBL_BYTES,   262144

// ── BSS offsets from x28 (state block pointer) ────────────────────────────
.equ INPUT_BUF_OFF,   ST_SIZE

// ── numeric labels ────────────────────────────────────────────────────────
// each digit owns a 64-slot block of u32 .text offsets:
// slot 0 = def count/cursor, defs at 1..63
.equ NUMLAB_MAX_DEFS, 64
.equ NUMLAB_DIGITS,   10         // digits 0-9

// ══════════════════════════════════════════════════════════════════════════
//  BSS
// ══════════════════════════════════════════════════════════════════════════
.bss
.align 4
state:        .skip ST_SIZE
input_buf:    .skip INPUT_BUF_SIZE
text_buf:     .skip TEXT_BUF_SIZE
rodata_buf:   .skip RODATA_BUF_SIZE
// numeric label storage first: numlab_defs = text_buf + 2 MB (one add off
// x27), sym_table follows at an imm12-reachable offset
numlab_defs:  .skip NUMLAB_DIGITS * NUMLAB_MAX_DEFS * 4
sym_table:    .skip SYM_TBL_BYTES
// rodata relocation table: entries are {u32 slot_off_rodata, s32 target_off_from_text}
reloc_table:  .skip RELOC_TBL_BYTES

// ══════════════════════════════════════════════════════════════════════════
//  Read-only data
// ══════════════════════════════════════════════════════════════════════════
.section .rodata

// word tables first: keeps them 4-aligned with no GAS padding, so the
// gen_dict analysis build and the self-hosted layout agree byte-for-byte

// condition code XOR lookup: cond_xor_tbl[(c0^c1) & 0x1F] = cond code (31=invalid)
cond_xor_tbl:
    .word 0x030A0803
    .word 0x1F1F0604
    .word 0x011F0D1F
    .word 0x1F1F0E1F
    .word 0x0C1F1F02
    .word 0x1F1F0700
    .word 0x021F1F0B
    .word 0x091F1F05

// operator table for expression parser: 2-byte entries (char, packed), sentinel=\0
// packed = (prec<<4)|opcode: | →0x10 & →0x21 + →0x32 - →0x33 * →0x44 < →0x55 > →0x56
// opcodes ≥ 5 are doubled-char operators (<< >>)
op_table:
    .word 0x2126107C               // '|',0x10, '&',0x21
    .word 0x332D322B               // '+',0x32, '-',0x33
    .word 0x553C442A               // '*',0x44, '<',0x55
    .word 0x0000563E               // '>',0x56, 0, 0

msg_usage:    .asciz "usage: asm <input.s> <output>\n"
msg_open:     .asciz "cannot open input file\n"
msg_create:   .asciz "cannot create output file\n"
msg_syntax:   .asciz "syntax error\n"
msg_undef:    .asciz "undefined symbol\n"

msg_badins:   .asciz "unknown instruction\n"
msg_trailing: .asciz "trailing operands\n"
msg_badreg:   .asciz "bad register\n"
msg_badimm:   .asciz "invalid immediate\n"

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
    ldr     x0, [sp]                // argc
    cmp     x0, #3
    b.lt    err_usage

    // set up state block pointer (x28 is callee-saved, lives forever)
    adr     x28, state
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
    // follows .text there. x30 can't discriminate: a seed-minted stage 0
    // is stub-entered too, but must emit its appended (new) stub, not the
    // inherited one at its own image head.
    adr     x9, _appended_data
    ldrb    w10, [x9]            // appended block begins with the header template
    add     x9, x9, #CODE_START  // stage 0: stub follows header template
    cmp     w10, #0x7F           // ELF magic first byte (rodata starts 0x03)
    b.eq    1f
    sub     x9, x30, #STUB_SIZE         // self-hosted: stub at CODE_START
1:  str     x9, [x28, #ST_STUB_BASE]

    // store input/output filenames
    ldp     x1, x0, [sp, #16]       // x1=argv[1] (input), x0=argv[2] (output)
    stp     x1, x0, [x28, #ST_INPUT_NAME]

    // ── open and read the input file ──────────────────────────────────────
    // x1 already holds input filename from ldp above
    mov     x0, #AT_FDCWD
    mov     x2, #O_RDONLY
    mov     x8, #SYS_openat
    svc     #0
    tbnz    x0, #63, err_open

    add     x1, x28, #INPUT_BUF_OFF    // input_buf
    mov     x2, #INPUT_BUF_SIZE
    mov     x8, #SYS_read
    svc     #0
    tbnz    x0, #63, err_open
    str     x0, [x28, #ST_INPUT_LEN]

    // pre-terminate lines: zero every newline once (both passes reuse this;
    // x1 = input_buf survives the read syscall)
1:  subs    x0, x0, #1
    b.mi    2f
    ldrb    w9, [x1, x0]
    cmp     w9, #'\n'
    b.ne    1b
    strb    wzr, [x1, x0]
    b       1b
2:

    // ── pass 1: collect symbols and measure sections ──────────────────────
    mov     x0, #1
    bl      run_pass

    // ── compute section base addresses ────────────────────────────────────
    ldp     x1, x21, [x28, #ST_TEXT_POS] // text_pos, rodata_pos (x21 survives pass 2)
    mov     x0, #CODE_START
    add     x1, x0, x1                  // rodata_base = text_base + text_size
    stp     x0, x1, [x28, #ST_TEXT_BASE]

    add     x2, x1, x21                 // bss_base = rodata_base + rodata_size
    str     x2, [x28, #ST_BSS_BASE]

    ldr     x3, [x28, #ST_BSS_POS]
    add     x23, x2, x3                 // mem_size = bss_base + bss_size
                                        // (x19-x23 survive run_pass; x24-x26 do NOT)

    // ── pass 2: encode instructions and emit data ─────────────────────────
    // (section bases are added to label values at lookup time — sym_value)
    mov     x0, #2
    bl      run_pass

    // ── compress .text section ────────────────────────────────────────────
    bl      compress_text             // x20 = compressed stream size

    // ── assemble the whole output image in input_buf ──────────────────────
    // [0,1056) = header+stub+dict template (contiguous in both layouts);
    // compress_text already placed the stream at offset 1056
    // x21 = rodata_size (captured before pass 2)
    ldr     x9, [x28, #ST_STUB_BASE]
    sub     x9, x9, #CODE_START
    add     x2, x28, #INPUT_BUF_OFF
    mov     x10, #(CODE_START + STUB_SIZE + DICT_SIZE)
    bl      memcpy8
    add     x2, x2, x20                // skip compressed stream

    // append .rodata
    add     x9, x27, x29               // rodata_buf
    add     x10, x21, #0
    bl      memcpy8

    // append relocation table (u32 slot_off_rodata + s32 target_off_from_text)
    adrp    x9, reloc_table
    add     x9, x9, :lo12:reloc_table
    ldr     x10, [x28, #ST_RELOC_PTR]
    sub     x10, x10, x9               // table bytes = cursor - base
    bl      memcpy8
    lsr     x22, x10, #3               // x22 = reloc count (callee-saved)

    // p_filesz = image end - image start (memcpy8 advances x2 exactly)
    add     x1, x28, #INPUT_BUF_OFF
    sub     x12, x2, x1

    // DECOMP_DEST_OFF = ceil_page(p_filesz) — offset from stub base
    add     x11, x12, #0xFFF
    and     x11, x11, #0xFFFFFFFFFFFFF000  // ceil to page

    // p_memsz = ceil_page(p_filesz) + total_mem_size
    add     x13, x23, x11

    // ── open output file ──────────────────────────────────────────────────
    mov     x0, #AT_FDCWD
    ldr     x1, [x28, #ST_OUTPUT_NAME]
    mov     x2, #O_WRONLY_CREAT_TRUNC
    mov     w3, #493                  // 0755 octal
    mov     x8, #SYS_openat
    svc     #0
    tbnz    x0, #63, err_create

    // patch p_filesz/p_memsz and the stub data block, then write the image
    // (x0 = fd survives: the patching stores touch only x1/x2/x8)
    add     x1, x28, #INPUT_BUF_OFF
    stp     x12, x13, [x1, #88]
    str     w11, [x1, #STUB_DATA_DECOMP_DEST]
    str     w21, [x1, #STUB_DATA_RODATA_SIZE]
    str     w22, [x1, #STUB_DATA_RELOC_COUNT]
    add     x2, x12, #0                   // p_filesz = whole image
    mov     x8, #SYS_write
    svc     #0

    // exec mode came from the openat mode argument (0755, umask-trimmed)
    mov     x0, #0
    b       exit_common

// memcpy8 — copy x10 bytes (rounded up to a multiple of 8) from x9 to x2
// leaf; advances x2 by exactly x10, clobbers only x12/x13 otherwise
// (always copies at least 8 bytes; harmless overshoot past x2+x10 is
// overwritten by the next append or lies beyond the written image)
memcpy8:
    mov     x13, #0
1:  ldr     x12, [x9, x13]
    str     x12, [x2, x13]
    add     x13, x13, #8
    cmp     x13, x10
    b.lo    1b
    add     x2, x2, x10
    ret

// ──────────────────────────────────────────────────────────────────────────
//  Error exits
// ──────────────────────────────────────────────────────────────────────────
err_usage:
    adr     x1, msg_usage
    b       die_msg
err_open:
    adr     x1, msg_open
    b       die_msg
err_create:
    adr     x1, msg_create
die_msg:
    bl      strlen_write2
    mov     x0, #1
exit_common:
    mov     x8, #SYS_exit
    svc     #0

write2:
    mov     x0, #STDERR
    mov     x8, #SYS_write
    svc     #0
    ret

// strlen_write2 — write null-terminated string in x1 to stderr
strlen_write2:
    mov     x2, #-1
1:  add     x2, x2, #1
    ldrb    w10, [x1, x2]
    cbnz    w10, 1b
    b       write2

// ══════════════════════════════════════════════════════════════════════════
//  Utility functions (spec §8.5)
//
//  Calling convention: args in x0-x7, return in x0 (x1 for pairs).
//  Leaf functions — no stack frame needed.
// ══════════════════════════════════════════════════════════════════════════

// ──────────────────────────────────────────────────────────────────────────
//  skip_ws — advance pointer past spaces and tabs
//  x0 = pointer
//  returns x0 = first non-whitespace position
// ──────────────────────────────────────────────────────────────────────────
skip1_ws:
    add     x0, x0, #1
skip_ws:
1:  ldrb    w9, [x0]
    cmp     w9, #' '
    b.hi    2f
    cbz     w9, 2f
    add     x0, x0, #1
    b       1b
2:  ret

ws_x2_skip1:
    // sources never put whitespace before ',' — x2 is at the comma
    add     x0, x2, #1
    b       skip_ws

ws_x1:
    add     x0, x1, #0
    b       skip_ws

ws_x19:
    add     x0, x19, #0
    b       skip_ws

ws_x2:
    add     x0, x2, #0
    b       skip_ws

ws_x21:
    add     x0, x21, #0
    b       skip_ws

ws_x21_parse_reg:
    add     x16, x30, #0
    bl      ws_x21
    add     x30, x16, #0
    b       parse_register

// ──────────────────────────────────────────────────────────────────────────
//  decode_escape — decode backslash escape character
//  w9 = char after backslash; returns w9 = decoded character
// ──────────────────────────────────────────────────────────────────────────
decode_escape:
    cmp     w9, #'0'
    csel    w9, wzr, w9, eq
    cmp     w9, #'n'
    mov     w10, #10
    csel    w9, w10, w9, eq
    cmp     w9, #'t'
    mov     w10, #9
    csel    w9, w10, w9, eq
    ret

// ──────────────────────────────────────────────────────────────────────────
//  parse_int — parse decimal, hex, or character literal
//  x0 = pointer (at first character of the number)
//  returns x0 = value, x1 = pointer past the parsed number
//
//  formats: 123  0x1F  0xFF  'A'  '\n'   (minus handled by parse_expr_unary)
// ──────────────────────────────────────────────────────────────────────────
parse_int:
    ldrb    w9, [x0]

    // character literal?
    cmp     w9, #'\''
    b.eq    parse_int_char

    // hex prefix? first char is a digit (caller guarantees), so any 'x'
    // second char means "0x" in real sources
    mov     x13, #10                 // radix
    mov     x12, #0                  // accumulator (shared by dec+hex)
    ldrb    w10, [x0, #1]
    cmp     w10, #'x'
    b.ne    2f
    add     x0, x0, #2              // skip "0x"
    mov     x13, #16

2:  ldrb    w9, [x0]
    sub     w10, w9, #'0'
    cmp     w10, #9
    b.ls    4f
    cmp     x13, #16                 // a-f digits only in hex mode
    b.ne    parse_int_done
    orr     w10, w9, #0x20          // fold uppercase to lowercase
    sub     w10, w10, #'a'
    cmp     w10, #5
    b.hi    parse_int_done
    add     w10, w10, #10
4:  madd    x12, x12, x13, x10      // acc = acc*radix + digit
    add     x0, x0, #1
    b       2b

parse_int_done:
parse_int_ret:
    add     x1, x0, #0
    add     x0, x12, #0
    ret

parse_int_char:
    add     x0, x0, #1              // skip opening quote
    ldrb    w9, [x0], #1            // load char, advance past it
    cmp     w9, #'\\'
    b.ne    1f
    // escape: x0 is past backslash already
    ldrb    w9, [x0], #1            // load escape char, advance past it
    add     x16, x30, #0
    bl      decode_escape
    add     x30, x16, #0
1:  add     x12, x9, #0
    add     x0, x0, #1              // skip closing quote
    b       parse_int_ret

// ──────────────────────────────────────────────────────────────────────────
//  parse_ident — parse an identifier [a-zA-Z_][a-zA-Z0-9_]*
//  x0 = pointer
//  returns x0 = start of ident, x1 = length, x2 = pointer past ident
//  if no valid identifier, x1 = 0
// ──────────────────────────────────────────────────────────────────────────
parse_ident:
    add     x2, x0, #0                   // working pointer (x0 = start, preserved)
    ldrb    w10, [x2], #1
    b       pi_check_first
1:  ldrb    w10, [x2], #1
    // loop: accept digits (not valid for first char)
    sub     w11, w10, #'0'
    cmp     w11, #9
    b.ls    1b
pi_check_first:
    // accept underscore and letters
    cmp     w10, #'_'
    b.eq    1b
    orr     w11, w10, #0x20
    sub     w11, w11, #'a'
    cmp     w11, #25
    b.ls    1b
    // end of identifier (or not an identifier if x2 == x0)
    sub     x2, x2, #1             // end pointer (x2 is one past due to post-index)
    sub     x1, x2, x0             // length (0 if no ident)
    ret

// ──────────────────────────────────────────────────────────────────────────
//  parse_register — parse register name
//  x0 = pointer
//  returns x0 = reg number (0-31), x1 = is_64bit, x2 = pointer past
//  on error: x0 = -1
// ──────────────────────────────────────────────────────────────────────────
parse_register:
    // w9 pre-loaded by caller (skip_ws sets w9 = first non-ws char)
    // registers appear only where required, so a leading 's' means "sp"
    // and an 'x'/'w' followed by 'z' means xzr/wzr — no full spell check

    cmp     w9, #'s'
    b.ne    1f
    add     x2, x0, #2              // end pointer past "sp"
    mov     x1, #1
2:  str     x2, [x28, #ST_EOL_CUR]
    mov     x0, #31
    ret

1:  cmp     w9, #'x'
    cset    x1, eq                   // x1=1 if 'x' (64-bit), else 0
    b.eq    parse_reg_xw
    cmp     w9, #'w'
    b.ne    parse_reg_fail
parse_reg_xw:
    ldrb    w10, [x0, #1]
    cmp     w10, #'z'
    b.ne    parse_reg_num
    add     x2, x0, #3
    b       2b

parse_reg_num:
    // x1 = is_64bit from cset above; not modified by this code
    ldrb    w12, [x0, #1]           // first digit
    sub     w12, w12, #'0'
    cmp     w12, #9
    b.hi    parse_reg_fail
    ldrb    w10, [x0, #2]
    sub     w11, w10, #'0'
    cmp     w11, #9
    add     x2, x0, #2              // end pointer (single digit); flags unaffected
    b.hi    1f                       // single digit
    add     w13, w12, w12, lsl #2   // first * 5
    add     w12, w11, w13, lsl #1   // second + first * 10
    add     x2, x2, #1
1:  cmp     w12, #30
    b.hi    parse_reg_fail          // x31/w31 and beyond: not a register
    str     x2, [x28, #ST_EOL_CUR]
    add     x0, x12, #0
    ret


// ──────────────────────────────────────────────────────────────────────────
//  sym_lookup — find a symbol in the hash table
//  x0 = name pointer, x1 = name length
//  returns x0 = pointer to entry, x1 = 1 if found (0 if empty slot)
//
//  uses x28 (state block) to reach sym_table / sym_names
// ──────────────────────────────────────────────────────────────────────────
sym_lookup:
    // leaf function — no frame needed, uses scratch registers only
    add     x15, x0, #0                  // name ptr
    add     x16, x1, #0                  // name len

    // hash the name (djb2 variant; seed 1 encodes smaller than 5381)
    mov     x9, #1
1:  sub     x1, x1, #1
    ldrb    w10, [x0, x1]
    add     x9, x9, x9, lsl #5
    add     x9, x9, x10
    cbnz    x1, 1b
    // slot = hash & (SYM_TBL_SLOTS - 1)
2:  and     x17, x9, #(SYM_TBL_SLOTS - 1)

    add     x14, x27, x29, lsl #1      // numlab_defs = text_buf + 2*1MB
    add     x14, x14, #(NUMLAB_DIGITS * NUMLAB_MAX_DEFS * 4)  // sym_table

sym_lookup_probe:
    // entry = &sym_table[slot * 32]
    add     x13, x14, x17, lsl #5  // entry pointer in x13

    // check if slot is empty (name_ptr == NULL)
    ldr     x12, [x13, #SYM_NAME_PTR]
    cbz     x12, sym_lookup_empty

    // compare name_len
    ldr     w11, [x13, #SYM_NAME_LEN]
    cmp     w16, w11
    b.ne    sym_lookup_next

    // compare name bytes (x12 = direct pointer into input buffer)
    add     x0, x16, #0                  // counter
1:  sub     x0, x0, #1
    ldrb    w9, [x12, x0]
    ldrb    w10, [x15, x0]
    cmp     w10, w9
    b.ne    sym_lookup_next
    cbnz    x0, 1b
    mov     x1, #1

sym_lookup_empty:
    // x1 is already 0 — zeroed by hash loop countdown, never modified during probing
sym_lookup_ret:
    add     x0, x13, #0
    ret

sym_lookup_next:
    add     x17, x17, #1
    and     x17, x17, #(SYM_TBL_SLOTS - 1)
    b       sym_lookup_probe

// ──────────────────────────────────────────────────────────────────────────
//  sym_define — insert or update a symbol
//  x0 = name pointer, x1 = name length, x2 = value, x3 = flags
//
//  if the symbol already exists, updates value and flags (OR'd).
//  if new, stores direct name pointer from input buffer.
// ──────────────────────────────────────────────────────────────────────────
sym_define:
    str     x30, [sp, #48]          // free slot in process_line's frame
    // x2 = value, x3 = flags (both preserved across sym_lookup — leaf, doesn't touch x2/x3)
    bl      sym_lookup
    // x0 = entry, x15 = name ptr, x16 = name len (set by sym_lookup)

    cbnz    x1, sym_define_update

    // ── new entry: store name pointer + length ─────────────────────────────
    stp     x15, x16, [x0]           // NAME_PTR(0) + NAME_LEN(8), upper word is padding

sym_define_update:
    str     x2, [x0, #SYM_VALUE]
    // OR in flags (don't clobber existing bits)
    ldr     x9, [x0, #SYM_FLAGS]
    orr     x9, x3, x9
    str     x9, [x0, #SYM_FLAGS]

    ldr     x30, [sp, #48]
    ret

// ──────────────────────────────────────────────────────────────────────────
//  expect_eol_done — error unless only whitespace or a // comment remains
//  after [x28, #ST_EOL_CUR]; then finishes the line (jumps to pl_done)
// ──────────────────────────────────────────────────────────────────────────
expect_eol_done:
    ldr     x0, [x28, #ST_EOL_CUR]
1:  ldrb    w9, [x0], #1
    cbz     w9, pl_done
    cmp     w9, #' '
    b.ls    1b
    cmp     w9, #'/'
    b.ne    2f
    ldrb    w9, [x0]                 // comments are exactly "//": a lone '/'
    cmp     w9, #'/'                 // is trailing garbage (GAS rejects it too)
    b.eq    pl_done
2:  adr     x0, msg_trailing
    b       error_at

// ──────────────────────────────────────────────────────────────────────────
//  error_at — print "filename:line: msg\n" to stderr and exit(1)
//  x0 = message pointer (null-terminated)
//
//  uses state block for filename and line number
// ──────────────────────────────────────────────────────────────────────────
error_at:
    add     x19, x0, #0                  // msg ptr

    // write filename
    ldr     x1, [x28, #ST_INPUT_NAME]
    bl      strlen_write2

    // build ":[linenum]: " in frame buffer and write it
    ldr     x9, [x28, #ST_LINE_NUM]
    add     x11, sp, #44
    add     x10, x11, #0
    mov     x13, #10
3:  udiv    x12, x9, x13
    msub    x14, x12, x13, x9
    add     w14, w14, #'0'
    strb    w14, [x10, #-1]!
    add     x9, x12, #0
    cbnz    x9, 3b
    movz    w14, #0x203A
    strb    w14, [x10, #-1]!
    strh    w14, [x11]
    add     x1, x10, #0
    sub     x2, x11, x10
    add     x2, x2, #2
    bl      write2

    // write message (includes \n) and exit
    add     x1, x19, #0
    b       die_msg

// ══════════════════════════════════════════════════════════════════════════
//  Pass driver and line processing
// ══════════════════════════════════════════════════════════════════════════


// ──────────────────────────────────────────────────────────────────────────
//  run_pass — iterate over all source lines
//  x0 = pass number (1 or 2)
// ──────────────────────────────────────────────────────────────────────────
run_pass:
    stp     x30, x19, [sp, #-64]!
    stp     x20, x21, [sp, #16]
    stp     x22, x23, [sp, #32]

    str     x0, [x28, #ST_PASS]

    // reset section positions and current section
    stp     xzr, xzr, [x28, #ST_TEXT_POS]
    stp     xzr, xzr, [x28, #ST_BSS_POS]

    // reset line number (x21 = line counter, synced to state before process_line)
    mov     x21, #1
    adrp    x0, reloc_table
    add     x0, x0, :lo12:reloc_table
    str     x0, [x28, #ST_RELOC_PTR]

    // reset numeric label counts/cursors (slot 0 of each digit block)
    add     x0, x27, x29, lsl #1       // numlab_defs
    mov     x2, #NUMLAB_DIGITS
1:  str     wzr, [x0]
    add     x0, x0, #(NUMLAB_MAX_DEFS * 4)
    subs    x2, x2, #1
    b.ne    1b

    // set up input pointers
    add     x19, x28, #INPUT_BUF_OFF   // input_buf
    ldr     x9, [x28, #ST_INPUT_LEN]
    add     x20, x19, x9              // x20 = end of input

run_pass_loop:
    cmp     x19, x20
    b.ge    pl_done

    // lines are already null-terminated (_start zeroed every newline;
    // the BSS zero after the last byte terminates a final unterminated line)
    str     x21, [x28, #ST_LINE_NUM]
    add     x0, x19, #0
    bl      process_line

    // advance past the line terminator
1:  ldrb    w10, [x19], #1
    cbnz    w10, 1b
    add     x21, x21, #1

    b       run_pass_loop

// ──────────────────────────────────────────────────────────────────────────
//  process_line — handle one null-terminated source line
//  x0 = line start (null-terminated)
// ──────────────────────────────────────────────────────────────────────────
process_line:
    stp     x30, x19, [sp, #-64]!
    stp     x20, x21, [sp, #16]
    stp     x22, x23, [sp, #32]

    bl      skip_ws
    add     x19, x0, #0

pl_check_content:
    // empty line? (w9 pre-loaded by skip_ws / ws_x19)
    cbz     w9, pl_done
    // note: a // comment needs no check here — it fails the numeric-label
    // test below, isn't '.', and parse_ident returns length 0 → pl_done

    // ── check for numeric label (digit followed by ':') ───────────────────
    ldrh    w10, [x19]              // for "N:", w10 = 0x3A30..0x3A39
    movz    w11, #0x3A30             // ':' << 8 | '0'
    sub     w10, w10, w11
    cmp     w10, #9
    b.hi    pl_not_numlab

    // numeric label — record in pass 1 (digit 0-9 stays in x10)
    bl      handle_numlab
    add     x19, x19, #2
    b       pl_after_label

pl_not_numlab:
    // ── check for named label or mnemonic ─────────────────────────────────
    cmp     w9, #'.'
    b.eq    pl_directive

    add     x0, x19, #0
    bl      parse_ident
    cbz     x1, pl_done              // no identifier → skip

    // is it a label (followed by ':')?
    ldrb    w9, [x2]
    cmp     w9, #':'
    b.ne    pl_instruction

    // ── named label ───────────────────────────────────────────────────────
    add     x19, x2, #1             // past ':'

    // only define in pass 1 (pass 2 uses rebased values)
    ldr     x9, [x28, #ST_PASS]
    tbnz    x9, #1, pl_after_label

    // value = current section offset
    ldr     x11, [x28, #ST_CUR_SEC]
    ldr     x2, [x28, x11]
    // flags = DEFINED | (cur_section << SEC_SHIFT); x11 = sec*8 = sec << 3
    add     x3, x11, #SYMF_DEFINED   // x11 = sec*8, bit 0 clear: add == orr
    bl      sym_define

pl_after_label:
    bl      ws_x19
    add     x19, x0, #0
    b       pl_check_content

    // ── directive (starts with '.') ───────────────────────────────────────
pl_directive:
    add     x0, x19, #1            // skip '.'
    bl      parse_ident
    cbz     x1, pl_done
    // x0 = name start, x1 = name length, x2 = end pointer
    add     x19, x2, #0                  // position after directive name

    // dispatch on directive name — check first char then length
    ldrb    w9, [x0]

    cmp     w9, #'b'
    mov     x10, #SEC_BSS            // doesn't affect flags
    b.eq    dir_sec_set

    cmp     w9, #'s'
    b.ne    5f
    cmp     x1, #7
    mov     x10, #SEC_RODATA         // doesn't affect flags
    b.eq    dir_sec_set
    bl      parse_expr0_x19           // .skip: inline
    b       advance_sec_pos

5:  cmp     w9, #'a'
    b.ne    6f
    ldrb    w10, [x0, #4]
    cmp     w10, #'n'
    b.eq    dir_align
    b       dir_str_common

6:  cmp     w9, #'e'
    b.ne    7f
    // inline dir_equ: define first (placeholder value), patch after parsing
    bl      ws_x19
    bl      parse_ident
    cbz     x1, pl_done
    mov     x3, #(SYMF_DEFINED | SYMF_EQU)
    bl      sym_define               // x2 (= end ptr) stored as placeholder
    add     x20, x0, #0              // entry pointer (x2 preserved: at ',')
    bl      ws_x2_skip1
    bl      parse_expr0
    str     x0, [x20, #SYM_VALUE]
    b       expect_eol_done          // .equ name, expr — nothing more

7:  cmp     w9, #'g'
    b.eq    pl_done                  // .global — ignored

    cmp     w9, #'d'
    b.ne    dir_word
    bl      ws_x19
    cmp     w9, #'_'                 // label ref ('_' or letter) → reloc form;
    b.hs    dir_dword_reloc          // literal starts (digit ( ' -) are < '_'

dir_dword_lit:
    mov     x22, #8
    b       dir_data_common

dir_dword_reloc:
    // relocatable .dword form: label[+const|-const], only valid in .rodata
    ldr     x11, [x28, #ST_CUR_SEC]
    cmp     x11, #SEC_RODATA
    b.ne    pe_atom_err

    bl      parse_expr0              // x0 = target value (sym + addend)

    // write provisional value (section known to be .rodata; same address
    // computation as dir_data_common so the words share dict entries)
    ldr     x11, [x28, #ST_CUR_SEC]
    ldr     x10, [x28, x11]             // slot offset within .rodata
    add     x9, x27, x11, lsl #17       // rodata_buf
    str     x0, [x9, x10]

    // pass 2: emit relocation table entry {slot_off_rodata, target_off_from_text}
    ldr     x9, [x28, #ST_PASS]
    tbz     x9, #1, dir_dword_emit_done
    sub     x12, x0, #CODE_START
    // a real label target is >= CODE_START; label-difference exprs are not
    tbnz    x12, #63, pe_atom_err

    ldr     x14, [x28, #ST_RELOC_PTR]
    stp     w10, w12, [x14], #8
    str     x14, [x28, #ST_RELOC_PTR]

dir_dword_emit_done:
    mov     x0, #8
    b       advance_sec_pos

dir_word:
    cmp     w9, #'w'
    b.ne    dir_text
    mov     x22, #4
dir_data_common:
    // .word/.dword <expr> — emit x22-byte value (x22 preserved across parse_expr)
    bl      parse_expr0_x19
    ldr     x11, [x28, #ST_CUR_SEC]
    ldr     x10, [x28, x11]             // current pos
    add     x9, x27, x11, lsl #17       // text_buf + sec * 1MB
    str     x0, [x9, x10]               // store 8 bytes (extra bytes harmless)
    add     x0, x22, #0
    b       advance_sec_pos

dir_text:
    cmp     w9, #'t'
    mov     x10, #SEC_TEXT           // doesn't affect flags
    b.ne    pl_done
dir_sec_set:
    str     x10, [x28, #ST_CUR_SEC]

pl_done:
    ldp     x22, x23, [sp, #32]
    ldp     x20, x21, [sp, #16]
    ldp     x30, x19, [sp], #64
    ret

// ══════════════════════════════════════════════════════════════════════════
//  Directive handlers
//
//  On entry: x19 = parse position after directive name
//            x20, x21 available (saved by process_line's frame)
//  Must jump to pl_done when finished.
// ══════════════════════════════════════════════════════════════════════════

// .align N — align to 2^N boundary
dir_align:
    bl      parse_expr0_x19
    // x0 = N (alignment power); advance by delta = (-pos) & ((1<<N)-1)
    ldr     x11, [x28, #ST_CUR_SEC]
    mov     x9, #1
    lsl     x9, x9, x0              // 1 << N
    ldr     x0, [x28, x11]          // current position
    sub     x9, x9, #1              // mask
    neg     x0, x0
    and     x0, x0, x9              // delta to aligned position
    b       advance_sec_pos

// .ascii/.asciz "string" — w10 still holds directive[4] ('i' or 'z')
dir_str_common:
    cmp     w10, #'z'
    cset    x21, eq                  // null_flag: 1 if asciz, 0 if ascii
    bl      ws_x19                   // x0 = pointer to '"'
    // always compute dest buffer (pass 1 writes are harmless, overwritten in pass 2)
    ldr     x11, [x28, #ST_CUR_SEC]  // x0 preserved
    add     x20, x27, x11, lsl #17   // text_buf + sec * 1MB
    ldr     x10, [x28, x11]
    add     x20, x20, x10
    add     x1, x20, #0
    bl      parse_string             // x0 = count, x1 = ptr past
    strb    wzr, [x20, x0]           // null terminator (harmless for .ascii:
    add     x0, x0, x21             // not counted, overwritten by next emit)
advance_sec_pos:
    ldr     x11, [x28, #ST_CUR_SEC]
    ldr     x10, [x28, x11]
    add     x10, x10, x0
    str     x10, [x28, x11]
    b       expect_eol_done          // cursor stored by the last primitive

// ──────────────────────────────────────────────────────────────────────────
//  handle_numlab — record a numeric label definition
//  x10 = digit (0-9)
// ──────────────────────────────────────────────────────────────────────────
handle_numlab:
    // leaf function, no frame needed
    // slot 0 of the digit block is the def count in pass 1, the cursor in
    // pass 2 (run_pass zeroes it at the start of each pass); defs are
    // 1-indexed so the incremented count doubles as the store index
    add     x11, x27, x29, lsl #1   // numlab_defs = text_buf + 2*1MB
    add     x11, x11, x10, lsl #8   // digit * 64 * 4
    ldr     w12, [x11]              // count/cursor
    add     w12, w12, #1
    str     w12, [x11]
    ldr     x9, [x28, #ST_PASS]
    tbnz    x9, #1, 1f              // pass 2: just advance the cursor

    // pass 1: record def address (numeric labels are always in .text)
    ldr     x9, [x28, #ST_TEXT_POS]
    str     w9, [x11, x12, lsl #2]
1:  ret

// ──────────────────────────────────────────────────────────────────────────
//  sym_value — resolve a symbol table entry's value
//  x0 = entry pointer; returns x0 = value, with the section base added for
//  labels in pass 2 (.equ values and pass-1 offsets are returned raw)
// ──────────────────────────────────────────────────────────────────────────
sym_value:
    ldp     x9, x0, [x0, #SYM_FLAGS]   // flags, value
    tbnz    x9, #2, 1f                  // SYMF_EQU: no section base
    ldr     x10, [x28, #ST_PASS]
    tbz     x10, #1, 1f                 // pass 1: raw section offset
    ubfx    x9, x9, #SYMF_SEC_SHIFT, #2
    add     x9, x28, x9, lsl #3
    ldr     x9, [x9, #ST_TEXT_BASE]
    add     x0, x0, x9
1:  ret

// ══════════════════════════════════════════════════════════════════════════
//  Expression evaluator — recursive descent
//
//  Each function: x0 = pointer → x0 = value, x1 = pointer past expr
//
//  Precedence (low to high): |  &  +/-  *  <</>>  unary(~ -)  atom
// ══════════════════════════════════════════════════════════════════════════

// ──────────────────────────────────────────────────────────────────────────
//  parse_expr — Pratt binary expression parser
//  x0 = pointer, x1 = min_prec (0 for top-level callers)
//  returns x0 = value, x1 = pointer past expr
//
//  Precedence: | (1) < & (2) < +/- (3) < * (4) < <<,>> (5)
// ──────────────────────────────────────────────────────────────────────────
parse_expr0_x19:
    add     x0, x19, #0
parse_expr0:
    mov     x1, #0
parse_expr:
    stp     x30, x19, [sp, #-64]!
    stp     x20, x21, [sp, #16]
    stp     x22, x23, [sp, #32]
    add     x22, x1, #0                  // min_prec
    bl      parse_expr_unary
    add     x19, x0, #0                  // lhs value
    add     x20, x1, #0                  // current position

// Operator dispatch: x21 encodes (prec<<4)|opcode
// | → 0x10  & → 0x21  + → 0x32  - → 0x33  * → 0x44  << → 0x55  >> → 0x56
pe_loop:
    add     x0, x20, #0
    bl      skip_ws
    add     x20, x0, #0
    adr     x10, op_table
1:  ldrb    w11, [x10], #2
    cbz     w11, pe_done
    cmp     w11, w9
    b.ne    1b
    ldrb    w21, [x10, #-1]
    // opcode ≥ 5: doubled-char operator (<< >>), verify and consume 2nd char
    cmp     w21, #0x55
    b.lo    pe_check_prec
    ldrb    w10, [x20, #1]
    cmp     w10, w9
    b.ne    pe_done
    add     x20, x20, #1

pe_check_prec:
    lsr     x9, x21, #4              // prec = x21 >> 4
    and     x23, x21, #0xF           // opcode = x21 & 0xF (callee-saved)
    cmp     x9, x22                  // op_prec vs min_prec
    b.lt    pe_done                  // op_prec < min_prec: not ours
    add     x20, x20, #1            // skip operator char
    add     x0, x20, #0
    add     x1, x9, #1              // recurse with prec+1
    bl      parse_expr
    add     x20, x1, #0                  // update position
    adr     x9, pe_ops
    add     x9, x9, x23, lsl #3
    br      x9
pe_ops:
    orr     x19, x19, x0            // opcode 0: |
    b       pe_loop
    and     x19, x19, x0            // opcode 1: &
    b       pe_loop
    add     x19, x19, x0            // opcode 2: +
    b       pe_loop
    sub     x19, x19, x0            // opcode 3: -
    b       pe_loop
    mul     x19, x19, x0            // opcode 4: *
    b       pe_loop
    lsl     x19, x19, x0            // opcode 5: <<
    b       pe_loop
    lsr     x19, x19, x0            // opcode 6: >>
    b       pe_loop

pe_done:
    str     x20, [x28, #ST_EOL_CUR]
    add     x0, x19, #0
    add     x1, x20, #0
    b       pl_done

// ──────────────────────────────────────────────────────────────────────────
//  parse_expr_unary — handles '~', unary '-', then falls through to atom
// ──────────────────────────────────────────────────────────────────────────
parse_expr_unary:
    stp     x30, x20, [sp, #-16]!

    bl      skip_ws

    cmp     w9, #'~'
    cset    x20, eq                  // 1 if NOT, 0 if NEG (x: our cset is 64-bit)
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

    // digit or '-' or '\'' — numeric literal
    sub     w10, w9, #'0'
    cmp     w10, #9
    b.ls    pe_atom_num
    cmp     w9, #'\''
    b.eq    pe_atom_num

    // identifier — symbol reference
    bl      parse_ident
    cbz     x1, pe_atom_err
    add     x20, x2, #0                  // end pointer (return this)

    // look up symbol
    bl      sym_lookup
    cbz     x1, pe_atom_undef

    bl      sym_value
    b       pea_ret_x20

pe_atom_undef:
    // in pass 1, undefined symbols get 0 (forward ref in instruction)
    ldr     x9, [x28, #ST_PASS]
    tbz     x9, #1, 1f
    // pass 2: error
err_undef:
    adr     x0, msg_undef
    bl      error_at
1:  mov     x0, #0
    b       pea_ret_x20

pe_atom_paren:
    add     x0, x0, #1              // skip '('
    bl      parse_expr0
    add     x20, x0, #0                  // value
    bl      ws_x1
    cmp     w9, #')'
    b.ne    pe_atom_err
    add     x1, x0, #1              // pointer past ')'
    add     x0, x20, #0
    b       pea_ret

pe_atom_dot:
    add     x20, x0, #0                 // save pointer to '.'
    ldr     x11, [x28, #ST_CUR_SEC]
    ldr     x0, [x28, x11]          // section offset
    ldr     x10, [x28, #ST_PASS]
    tbz     x10, #1, 1f
    // pass 2: add section base (x11 = sec*8)
    add     x11, x28, x11
    ldr     x11, [x11, #ST_TEXT_BASE]
    add     x0, x0, x11
1:  add     x1, x20, #1             // pointer past '.'
    b       pea_ret

pe_atom_num:
    bl      parse_int
    b       pea_ret

pe_atom_err:
    adr     x0, msg_syntax
    bl      error_at

pe_unary_op:
    add     x0, x0, #1
    bl      parse_expr_unary         // recursive
    neg     x0, x0                   // both: negate first
    sub     x0, x0, x20             // NOT: -x-1 = ~x; NEG: -x-0 = -x
    b       pea_ret

// ══════════════════════════════════════════════════════════════════════════
//  String parsing
// ══════════════════════════════════════════════════════════════════════════

// ──────────────────────────────────────────────────────────────────────────
//  parse_string — parse a quoted string, count or emit bytes
//  x0 = pointer (at the opening '"')
//  x1 = destination (NULL to just count)
//  returns x0 = byte count, x1 = pointer past closing '"'
// ──────────────────────────────────────────────────────────────────────────
parse_string:
    str     x30, [sp, #48]          // free slot in process_line's frame
    add     x15, x1, #0                  // working dest pointer
    add     x0, x0, #1              // skip opening '"'

ps_loop:
    ldrb    w9, [x0], #1            // load + advance
    cbz     w9, pe_atom_err          // unterminated string
    cmp     w9, #'"'
    b.eq    ps_done                  // closing quote (x0 already past it)
    cmp     w9, #'\\'
    b.eq    ps_escape

    // plain character — x0 already advanced by post-increment
ps_store:
    strb    w9, [x15], #1
    b       ps_loop

ps_escape:
    ldrb    w9, [x0], #1            // load escape char, advance (past backslash)
    bl      decode_escape
    b       ps_store

ps_done:
    str     x0, [x28, #ST_EOL_CUR]  // source cursor past closing quote
    sub     x0, x15, x1             // byte count (x1 = original dest, unmodified)
    ldr     x30, [sp, #48]
    ret

// ══════════════════════════════════════════════════════════════════════════
//  Pass 2 infrastructure
// ══════════════════════════════════════════════════════════════════════════

// ──────────────────────────────────────────────────────────────────────────
//  emit_inst_done — emit instruction word then restore encode_instruction frame
//  x0 = instruction word; reached via 'b' from within encode_instruction
// ──────────────────────────────────────────────────────────────────────────
// emit_with_sf — apply sf bit into bit 31 of w0, then emit
emit_with_sf:
    add     w24, w23, #0
emit_with_sf24:
    orr     w0, w0, w24, lsl #31
emit_inst_done:
    ldr     x10, [x28, #ST_TEXT_POS]
    str     w0, [x27, x10]
    add     x10, x10, #4
    str     x10, [x28, #ST_TEXT_POS]
    // pass 2 only (operands are parsed then): reject trailing text
    ldr     x9, [x28, #ST_PASS]
    tbz     x9, #1, pl_done
    b       expect_eol_done

// ──────────────────────────────────────────────────────────────────────────
//  parse_label_pc_rel — parse label ref then compute PC-relative offset
//  uses [sp, #48] for return address
//  returns x0 = signed offset in instruction units
// ──────────────────────────────────────────────────────────────────────────
parse_label_pc_rel:
    str     x30, [sp, #48]
    bl      parse_label_ref
    ldr     x9, [x28, #ST_TEXT_BASE]
    ldr     x10, [x28, #ST_TEXT_POS]
    add     x9, x9, x10
    sub     x0, x0, x9
    asr     x0, x0, #2
    ldr     x30, [sp, #48]
    ret


// parse_x22_ws — parse first register into x22, save sf to x23, skip comma+ws
// uses [sp, #48] for return address
parse_x22_ws:
    str     x30, [sp, #48]
    bl      ws_x21_parse_reg
    add     x22, x0, #0
    add     x23, x1, #0                  // sf
    b       1f

// parse_x23_ws — parse first register into x23, save sf to x24, skip comma+ws
// uses [sp, #48] for return address
parse_x23_ws:
    str     x30, [sp, #48]
    bl      ws_x21_parse_reg
    add     x23, x0, #0
    add     x24, x1, #0                  // sf (callers can use x24 directly)
1:  ldr     x30, [sp, #48]
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
    add     x24, x0, #0                  // Rn
    bl      ws_x2_skip1                 // skip ','
p23_tail:
    ldr     x30, [sp, #56]
    b       parse_register

skip_lsl:
1:  ldrb    w9, [x0, #1]!
    cbz     w9, pe_atom_err          // hit end of line without finding '#'
    cmp     w9, #'#'
    b.ne    1b
    // falls through to parse_hash_imm

// ──────────────────────────────────────────────────────────────────────────
//  parse_hash_imm — parse #expr or #:lo12:expr
//  x0 = pointer (at '#')
//  returns x0 = value, x1 = pointer past, x2 = 1 if :lo12:
// ──────────────────────────────────────────────────────────────────────────
parse_hash_imm:
    str     x30, [sp, #48]

    // first char is always '#' or ':' (callers guarantee this)
    ldrb    w9, [x0]
    cmp     w9, #'#'
    b.eq    phi_hash

    // ':' prefix — verify :lo12: by checking second char is 'l'
    ldrb    w9, [x0, #1]
    cmp     w9, #'l'
    b.ne    phi_plain           // not :lo12:, parse from ':' — will give syntax error
    add     x0, x0, #6         // skip ':lo12:'
    bl      parse_expr0
    and     x0, x0, #0xFFF
    b       phi_ret

phi_hash:
    add     x0, x0, #1
phi_plain:
    bl      parse_expr0
phi_ret:
    ldr     x30, [sp, #48]
    ret

// ──────────────────────────────────────────────────────────────────────────
//  parse_label_ref — parse branch target (named label or Nf/Nb)
//  x0 = pointer
//  returns x0 = target address, x1 = pointer past
// ──────────────────────────────────────────────────────────────────────────
parse_label_ref:
    stp     x30, x20, [sp, #-16]!

    bl      skip_ws

    // numeric label ref? digit followed by 'f' or 'b'
    sub     w10, w9, #'0'
    cmp     w10, #9
    b.hi    plr_named

    ldrb    w11, [x0, #1]
    cmp     w11, #'b'
    cset    x1, eq                   // x1=1 backward, 0 forward
    b.eq    plr_numlab_common
    cmp     w11, #'f'
    b.ne    plr_named
plr_numlab_common:
    add     x20, x0, #2             // pointer past "Nf"/"Nb"
    add     x11, x27, x29, lsl #1   // numlab_defs = text_buf + 2*1MB
    add     x11, x11, x10, lsl #8   // digit block (w10 = digit)
    ldr     w0, [x11]               // cursor (defs consumed so far)
    add     x0, x0, #1
    sub     x0, x0, x1              // 1-indexed: fwd = cursor+1, back = cursor
    ldr     w0, [x11, x0, lsl #2]
    // defs are stored as .text offsets; add the text base (refs are pass-2 only)
    ldr     x9, [x28, #ST_TEXT_BASE]
    add     x0, x0, x9
    b       pea_ret_x20

plr_named:
    bl      parse_ident
    cbz     x1, err_undef
    add     x20, x2, #0                  // save end pointer

    bl      sym_lookup
    cbz     x1, err_undef

    bl      sym_value
pea_ret_x20:
    str     x20, [x28, #ST_EOL_CUR]
    add     x1, x20, #0
pea_ret:
    ldp     x30, x20, [sp], #16
    ret

// ──────────────────────────────────────────────────────────────────────────
//  encode_logical_imm — encode bitmask immediate for logical instructions
//  x0 = value, x1 = is_32bit (1=replicate low 32 to full 64)
//  returns x0 = (N << 12) | (immr << 6) | imms, or -1 if unencodable
// ──────────────────────────────────────────────────────────────────────────
encode_logical_imm:
    // leaf function — no frame needed, uses scratch registers only
    // for 32-bit, replicate low 32 bits
    cbz     x1, eli_start
    and     x0, x0, #0xFFFFFFFF
    orr     x0, x0, x0, lsl #32

eli_start:
    // x0 = val (left intact until the final encode)

    // reject all-zeros and all-ones
    cbz     x0, ei_logical_bad
    mvn     x9, x0
    cbz     x9, ei_logical_bad

    // rotation = ctz(val & (val + 1))
    add     x9, x0, #1
    and     x9, x9, x0
    rbit    x10, x9
    clz     x1, x10                  // rotation (x1 arg is dead by now)

    // normalized = ror(val, rotation)
    ror     x9, x0, x1

    // zeroes = clz(normalized)
    clz     x10, x9

    // ones = ctz(~normalized) = clz(rbit(~normalized))
    mvn     x11, x9
    rbit    x11, x11
    clz     x14, x11                 // ones

    // size = zeroes + ones
    add     x13, x14, x10

    // validate: ror(val, size) == val
    ror     x9, x0, x13
    cmp     x9, x0
    b.ne    ei_logical_bad

    // immr = (-rotation) & (size - 1)
    neg     x9, x1
    sub     x10, x13, #1
    and     x9, x9, x10             // immr

    // imms = (-(size << 1) | (ones - 1)) & 0x3F
    sub     x11, xzr, x13, lsl #1
    sub     x12, x14, #1
    orr     x11, x11, x12
    and     x11, x11, #0x3F         // imms

    // result = (N << 12) | (immr << 6) | imms  where N = size >> 6
    lsr     x12, x13, #6
    orr     x0, x11, x9, lsl #6
    orr     x0, x0, x12, lsl #12
    ret

// ──────────────────────────────────────────────────────────────────────────
//  parse_cond — parse condition code (eq, ne, lt, ge, hi, ls, etc.)
//  x0 = pointer (at first char of condition)
//  returns x0 = pointer past, x1 = cond code (0-14)
//  Uses cond_table in .rodata: 2-byte entries, index = code; cs/cc aliases at 15/16
// ──────────────────────────────────────────────────────────────────────────
parse_cond:
    ldrh    w9, [x0]
    add     x0, x0, #2
    str     x0, [x28, #ST_EOL_CUR]
    lsr     w10, w9, #8             // char1
    eor     w10, w10, w9            // char0 ^ char1
    and     w10, w10, #0x1F         // 5-bit index
    adr     x11, cond_xor_tbl
    ldrb    w1, [x11, x10]
    ret

parse_reg_fail:
    adr     x0, msg_badreg
    b       error_at

// ──────────────────────────────────────────────────────────────────────────
//  encode_instruction — dispatch mnemonic, parse operands, emit
//  x0 = mnemonic start, x1 = mnemonic length, x2 = operands start
// ──────────────────────────────────────────────────────────────────────────
pl_instruction:
    ldr     x9, [x28, #ST_PASS]
    tbz     x9, #1, emit_inst_done
encode_instruction:
    // x19 already equals x0 (set by process_line before parse_ident)
    str     x2, [x28, #ST_EOL_CUR]  // floor for the trailing-text check:
    add     x20, x1, #0             // no-operand forms (ret/nop) never parse
    add     x21, x2, #0

    // dispatch on first character of mnemonic
    ldrb    w9, [x19]
    ldrb    w10, [x19, #1]

    cmp     w9, #'a'
    b.eq    ei_a
    cmp     w9, #'b'
    b.eq    ei_b
    cmp     w9, #'c'
    b.eq    ei_c
    cmp     w9, #'e'
    movz    x22, #0x4000, lsl #16    // eor opc<<29 (doesn't affect flags)
    b.eq    ei_logical
    cmp     w9, #'l'
    b.eq    ei_l
    cmp     w9, #'m'
    b.eq    ei_m
    cmp     w9, #'n'
    b.eq    ei_n
    cmp     w9, #'o'
    movz    x22, #0x2000, lsl #16    // orr opc<<29 (doesn't affect flags)
    b.eq    ei_logical
    cmp     w9, #'r'
    b.eq    ei_r
    cmp     w9, #'s'
    b.eq    ei_s
    cmp     w9, #'t'
    b.eq    ei_t
    cmp     w9, #'u'
    b.ne    ei_bad
// udiv Rd, Rn, Rm / ubfx / ubfm / ubfiz / uxtb / uxth
ei_u:
    cmp     w10, #'b'
    b.eq    ei_bfm_unified
    cmp     w10, #'x'
    b.eq    ei_sxt_uxt
ei_udiv:
    mov     w25, #0
ei_div_common:
    bl      parse_3reg
    orr     w9, w25, #0x0800
    b       emit_3reg_1AC0_tail

    // ── 'a' mnemonics: add, and, adrp ─────────────────────────────────────
ei_a:
    cmp     w10, #'d'
    b.eq    ei_a_d
    cmp     w10, #'n'
    movz    w25, #0x2800             // ASRV opcode (speculative, harmless if AND)
    b.ne    ei_shift_common
    cmp     x20, #4                  // len=4 → ANDS
    movz    x22, #0x6000, lsl #16    // ANDS opc<<29
    csel    x22, x22, xzr, eq        // AND: opc 0
    b       ei_logical
// sxtb/sxth/sxtw/uxtb/uxth Rd, Rn — SBFM/UBFM Rd, Rn, #0, #imms
ei_sxt_uxt:
    bl      parse_2reg
    add     x24, x0, #0
    mov     x10, #0                  // immr = 0
    ldrb    w9, [x19, #3]            // suffix: 'b', 'h', or 'w'
    ubfx    w11, w9, #3, #2          // 'b'→0, 'h'→1, 'w'→2
    mov     w12, #8
    lsl     w11, w12, w11            // 8, 16, 32
    sub     w11, w11, #1             // 7, 15, 31
    ldrb    w9, [x19]               // 's' or 'u'
    cmp     w9, #'s'
    b.ne    ei_ubfm_emit             // uxt → UBFM path (sxt falls through)
ei_asr_sbfm:
    movz    w0, #0x1300, lsl #16     // 32-bit SBFM base (sf+N applied later)
    b       ei_bfm_apply_n_sf

ei_a_d:
    ldrb    w10, [x19, #2]
    cmp     w10, #'d'
    b.eq    ei_add
    cmp     w10, #'r'
    b.ne    ei_bad
    // adr/adrp shared: parse Rd, skip comma, precompute PC
    bl      parse_x22_ws
    ldr     x9, [x28, #ST_TEXT_BASE]
    ldr     x10, [x28, #ST_TEXT_POS]
    add     x25, x9, x10             // x25 = PC
    cmp     x20, #3
    b.eq    ei_adr_body
    // adrp: page-relative offset
    bl      parse_label_ref
    and     x23, x0, #~0xFFF
    and     x9, x25, #~0xFFF
    sub     x23, x23, x9
    asr     x23, x23, #12
    b       ei_adr_encode
ei_adr_body:
    bl      parse_expr0
    sub     x23, x0, x25             // imm21 = target - PC
ei_adr_encode:
    // encoding: immlo = imm21[1:0], immhi = imm21[20:2]
    and     w9, w23, #3              // immlo
    ubfx    w10, w23, #2, #19        // immhi (19 bits)
    sub     w23, w20, #3             // sf: 0=ADR(len3), 1=ADRP(len4)
    movz    w0, #0x1000, lsl #16     // ADR base opcode
    orr     w0, w0, w22
    orr     w0, w0, w9, lsl #29
    orr     w0, w0, w10, lsl #5
    b       emit_with_sf

    // ── 'b' mnemonics: b, bl, b.cond, bic, bfm, bfi, bfxil ────────────────
ei_b:
    cmp     w10, #'f'
    b.eq    ei_bfm_unified
    cmp     x20, #3
    b.eq    ei_b3
    b.hi    ei_bad
    cmp     w10, #'r'
    b.eq    ei_br
    // b (len=1) or bl (len=2): bit 31 = len-1
    sub     x9, x20, #1
    movz    w22, #0x1400, lsl #16
    orr     w22, w22, w9, lsl #31
    bl      ws_x21
    cmp     w9, #'.'
    b.eq    ei_bcond
    // B/BL: parse label, compute pc-relative offset
    bl      parse_label_pc_rel
    and     w0, w0, #0x3FFFFFF
    orr     w0, w0, w22
    b       emit_inst_done
// 3-char 'b' mnemonics: blr or bic
ei_b3:
    ldrb    w9, [x19, #2]
    cmp     w9, #'r'
    b.eq    ei_blr
// bic Rd, Rn, Rm — AND Rd, Rn, ~Rm
// sf 00 01010 sh 1 Rm imm6 Rn Rd
ei_bic:
    bl      parse_3reg
    movz    w9, #0x0A20, lsl #16     // 32-bit BIC
    b       emit_3reg_sf_tail
// br Xn / blr Xn — branch (with link) to register
// br: x20=2 (len), blr: x20=3 → sub 2 gives 0 or 1 for bit 21
ei_br:
ei_blr:
    bl      ws_x21_parse_reg
    sub     w10, w20, #2
    movz    w9, #0xD61F, lsl #16
    orr     w9, w9, w10, lsl #21     // blr: set bit 21 → 0xD63F
    orr     w0, w9, w0, lsl #5
    b       emit_inst_done

    // ── 'c' mnemonics: cmp, cbz, cbnz, clz, cset ──────────────────────────
ei_c:
    cmp     w10, #'m'
    b.eq    ei_c_cm
    cmp     w10, #'b'
    b.ne    2f
    ldrb    w10, [x19, #2]
    cmp     w10, #'z'
    cset    x22, ne                  // x22=0 for cbz, 1 for cbnz
    b.eq    ei_cbz_common
    cmp     w10, #'n'
    b.ne    ei_bad
ei_cbz_common:
    bl      parse_x23_ws
    bl      parse_label_pc_rel
    and     w0, w0, #0x7FFFF
    orr     w0, w23, w0, lsl #5
    orr     w0, w0, w22, lsl #24
    movz    w9, #0x3400, lsl #16
    b       ei_addsub_sf_emit
2:  cmp     w10, #'l'
    b.eq    ei_clz
    ldrb    w10, [x19, #3]
    cmp     w10, #'n'
    movz    w26, #0x0400                // CSINC bit (speculative)
    b.eq    ei_csel_common
    cmp     w10, #'l'
    movz    w26, #0                     // CSEL: no extra bits (speculative)
    b.eq    ei_csel_common
// cset Rd, cond — alias for CSINC Rd, xzr, xzr, invert(cond)
ei_cset:
    bl      parse_x22_ws                // x22 = Rd, x23 = sf
    bl      parse_cond                  // x1 = cond code
    eor     w1, w1, #1                  // invert condition (flip bit 0)
    movz    w26, #0x0400                // CSINC bit
    mov     x24, #31                    // Rn = xzr
    mov     x0, #31                     // Rm = xzr
    b       ei_csel_tail

// csel Rd, Rn, Rm, cond
// encoding: sf 00 11010100 Rm cond 00 Rn Rd
//   64-bit base: 0x9A800000
ei_csel_common:
    bl      parse_3reg                  // x22=Rd, x23=sf, x24=Rn, x0=Rm
    add     x25, x0, #0                     // save Rm
    bl      ws_x2_skip1                 // skip ','
    bl      parse_cond                  // x1 = cond
    add     x0, x25, #0                     // Rm for emit_3reg_sf_tail
ei_csel_tail:
    movk    w26, #0x1A80, lsl #16       // CSEL/CSINC base (clobbers w26)
    orr     w9, w26, w1, lsl #12        // | (cond << 12)
    b       emit_3reg_sf_tail

    // ── 'l' mnemonics: ldr, ldrb, lsl, lsr ────────────────────────────────
ei_l:
    cmp     w10, #'d'
    b.eq    ei_ld
// lsl/lsr — immediate (UBFM alias) or register (LSLV/LSRV)
ei_ls_shift:
    ldrb    w10, [x19, #2]
    movz    w25, #0x2000             // LSLV
    cmp     w10, #'r'
    b.ne    ei_shift_common
    movz    w25, #0x2400             // LSRV
ei_shift_common:
    bl      parse_2reg               // x22=Rd, x23=sf, x0=Rn, x2=ptr past
    add     x24, x0, #0                  // Rn
    bl      ws_x2_skip1
    cmp     w9, #'#'
    b.eq    ei_shift_imm_dispatch
    // register form
    bl      parse_register           // Rm
    add     w9, w25, #0
    b       emit_3reg_1AC0_tail

    // ── 'm' mnemonics: mov, movz, movn, movk, mul, msub, madd, mvn ────────
ei_m:
    cmp     w10, #'o'
    b.eq    ei_mo
    cmp     w10, #'u'
    b.eq    ei_mul
    cmp     w10, #'s'
    movz    x26, #0x8000                // MSUB bit15 (speculative)
    b.eq    ei_madd_msub_common
    cmp     w10, #'a'
    mov     x26, #0                     // MADD bit15 (speculative)
    b.eq    ei_madd_msub_common
// mvn Rd, Rm — alias for orn Rd, xzr, Rm
ei_mvn:
    movz    w25, #0x2A20, lsl #16     // 32-bit ORN base
    b       ei_neg_mvn_common

ei_mo:
    // mov (3 chars) vs movz/movn/movk (4 chars)
    cmp     x20, #3
    b.eq    ei_mov
    ldrb    w10, [x19, #3]
    cmp     w10, #'z'
    movz    w22, #0x5280, lsl #16    // MOVZ base (speculative)
    b.eq    ei_movwide
    cmp     w10, #'n'
    movz    w22, #0x1280, lsl #16    // MOVN base (speculative)
    b.eq    ei_movwide
    cmp     w10, #'k'
    b.ne    ei_bad
    movz    w22, #0x7280, lsl #16    // MOVK base
    b       ei_movwide

    // ── 's' mnemonics: sub, str, strb, svc, sbfm, sbfx, sbfiz, sxt* ──────
ei_s:
    cmp     w10, #'u'
    b.eq    ei_su
    cmp     w10, #'t'
    b.eq    ei_st
    cmp     w10, #'v'
    b.eq    ei_svc
    cmp     w10, #'b'
    b.eq    ei_bfm_unified
    cmp     w10, #'x'
    b.eq    ei_sxt_uxt
ei_sd:
    mov     w25, #0x400
    b       ei_div_common

ei_bad:
    adr     x0, msg_badins
    bl      error_at

ei_ret:
    movz    w0, #0x03C0
    movk    w0, #0xD65F, lsl #16
    b       emit_inst_done

ei_svc:
    bl      ws_x21
    bl      parse_hash_imm           // x0 = imm16 value
    ubfiz   w0, w0, #5, #16         // imm16 << 5, masked
    orr     w0, w0, #1              // set bit 0
    movk    w0, #0xD400, lsl #16    // SVC opcode
    b       emit_inst_done

ei_bcond:
    add     x0, x0, #1              // skip '.'
    movz    w22, #0x5400, lsl #16    // 0x54000000
    bl      parse_cond
    orr     w22, w22, w1             // base | cond
    bl      parse_label_pc_rel
    // 0x54000000 | (imm19 << 5) | cond
    and     w0, w0, #0x7FFFF
    orr     w0, w22, w0, lsl #5
    b       emit_inst_done

// clz Rd, Rn — 64-bit: 0xDAC01000, 32-bit: 0x5AC01000
ei_clz:
    mov     w25, #0x1000
    b       ei_clz_rbit_common

// rbit Rd, Rn — 64-bit: 0xDAC00000, 32-bit: 0x5AC00000
ei_r:
    cmp     w10, #'e'
    b.eq    ei_ret
    cmp     w10, #'o'
    b.eq    ei_ror
ei_rbit:
    mov     w25, #0
ei_clz_rbit_common:
    bl      parse_2reg               // x22=Rd, x23=sf, x0=Rn
    orr     w0, w22, w0, lsl #5      // Rd | (Rn << 5)
    movk    w25, #0x5AC0, lsl #16    // merge base into w25
    orr     w0, w0, w25
    b       emit_with_sf

// ror Rd, Rn, Rm — RORV: 0x1AC02C00 (32-bit) / 0x9AC02C00 (64-bit)
ei_ror:
    bl      parse_3reg
    movz    w9, #0x2C00
    b       emit_3reg_1AC0_tail

// add/adds Rd, Rn, #imm / Rm [, lsl #N] / :lo12:sym
ei_add:
    mov     x22, #0                  // op=0 (ADD)
    b       ei_addsub_s
// sub/subs Rd, Rn, #imm / Rm
ei_su:
ei_sub:
    movz    x22, #0x4000, lsl #16    // op=1 (SUB)
ei_addsub_s:
    sub     x9, x20, #3             // 0 for len=3, 1 for len=4
    orr     x22, x22, x9, lsl #29   // set S flag if len=4
ei_addsub:
    bl      parse_x23_ws
    bl      parse_register
    add     x25, x0, #0                  // save Rn
    bl      ws_x2_skip1                 // skip ','

    // is the third operand a register or immediate?
ei_addsub_operand:
    cmp     w9, #'a'
    b.lo    ei_addsub_imm            // '#' or ':lo12:' (both < 'a')
    movz    w26, #0x0B00, lsl #16    // add/sub register-form base

    // register form: Rd, Rn, Rm [, lsl #N] — w26=base, x25=Rn, x22=op bits
ei_reg_operand:
    bl      parse_register
    orr     w21, w23, w0, lsl #16    // save Rd | (Rm << 16)
    bl      ws_x2
    // check for optional ", lsl #N"
    cmp     w9, #','
    mov     x9, #0                   // shift amount default 0 (doesn't affect flags)
    b.ne    1f
    bl      skip_lsl                 // skip ", lsl" + parse_hash_imm
    add     x9, x0, #0                   // shift amount
1:  orr     w0, w21, w25, lsl #5     // (Rd|Rm<<16) | (Rn << 5)
    orr     w0, w0, w9, lsl #10      // imm6 (shift amount, ≤ 63)
    orr     w0, w0, w22              // op|S / opc bits
    orr     w0, w0, w26              // base opcode
    b       emit_with_sf24

ei_addsub_imm:
    // immediate form: #expr or #:lo12:expr
    bl      parse_hash_imm           // x0=val, x2=is_lo12
    lsr     x9, x0, #12
    cbnz    x9, ei_logical_bad       // imm12 out of range (0-4095)
    // sf op 0 10001 shift imm12 Rn Rd
    orr     w9, w23, w25, lsl #5     // Rd | (Rn << 5)
    orr     w9, w9, w0, lsl #10     // imm12 (bits 12+ known zero)
    orr     w9, w9, w22              // op|S bits
    movz    w0, #0x1100, lsl #16

// shared tail: w9=opcode bits (0x0B00 or 0x1100 << 16), x24=sf, w0=partial insn
ei_addsub_sf_emit:
    orr     w0, w0, w9
    b       emit_with_sf24

// cmp/cmn Rn, #imm / cmp/cmn Rn, Rm — reuse addsub with Rd=xzr
ei_c_cm:
    ldrb    w10, [x19, #2]
    cmp     w10, #'n'
    movz    x22, #0x6000, lsl #16    // CMP: SUBS bits 30:29 = 11
    b.ne    1f
    movz    x22, #0x2000, lsl #16    // CMN: ADDS bits 30:29 = 01
1:  bl      parse_x23_ws             // x23=Rn, x24=sf
    add     x25, x23, #0                 // save Rn
    mov     x23, #31                 // Rd = xzr
    b       ei_addsub_operand

// and/eor/orr — immediate (bitmask) or register
ei_logical:
    bl      parse_x23_ws
    bl      parse_register
    add     x25, x0, #0                  // Rn
    bl      ws_x2_skip1
ei_logical_operand:
    cmp     w9, #'#'
    b.eq    ei_logical_imm

    // register form: sf opc 01010 sh 0 Rm imm6 Rn Rd
    movz    w26, #0x0A00, lsl #16    // logical register-form base
    b       ei_reg_operand

ei_logical_imm:
    bl      parse_hash_imm
    eor     w1, w24, #1             // is_32bit = !sf (w-form: x1 zero-extended)
    bl      encode_logical_imm
    // x0 = (N<<12)|(immr<<6)|imms
    orr     w9, w23, w25, lsl #5     // Rd | (Rn << 5)
    orr     w9, w9, w0, lsl #10      // | N/immr/imms
    orr     w9, w9, w22              // opc bits (pre-positioned)
    movz    w0, #0x1200, lsl #16     // 100100 in bits 28:23
    b       ei_addsub_sf_emit        // orr w0|w9, apply sf, emit

// tst Rn, #imm / Rm — alias for ANDS XZR, Rn, operand
ei_tst:
    movz    x22, #0x6000, lsl #16    // opc = ANDS (3 << 29)
    bl      parse_x23_ws             // x23=Rn, x24=sf
    add     x25, x23, #0                 // Rn
    mov     x23, #31                 // Rd = XZR
    b       ei_logical_operand

ei_logical_bad:
    adr     x0, msg_badimm
    bl      error_at


// ldr/ldrb/str/strb/ldp/stp — multiple addressing modes
ei_ld:
ei_st:
    cmp     w9, #'l'
    cset    x22, eq                  // 1 for load ('l'), 0 for store ('s')
ei_ldst_dispatch:
    ldrb    w10, [x19, #2]
    cmp     w10, #'p'
    b.eq    ei_ldst_pair
ei_ldst:
    bl      parse_x23_ws             // x23=Rt, x24=sf
    // x24 already has sf from parse_x23_ws
    sub     x10, x20, #3            // 0 for ldr/str (len=3), 1 for ldrb/strb/ldrh/strh (len=4)
    // precompute size encoding: 0=byte, 1=half, 2=32bit, 3=64bit
    add     w20, w24, #2             // 2 or 3
    cbz     x10, 1f                  // len=3: use sf+2
    ldrb    w20, [x19, #3]          // 'b'=0x62, 'h'=0x68, 's'=0x73
    cmp     w20, #'s'
    b.eq    ei_ldrs_size             // sign-extending load (ldrsb/ldrsh/ldrsw)
    ubfx    w20, w20, #3, #2        // 0 for byte, 1 for half
1:  // literal load check: ldr Rt, label (no bracket)
    cbz     x22, ei_ldst_bracket     // store: must have [
    cbnz    x10, ei_ldst_bracket     // ldrb/ldrh: must have [
    cmp     w9, #'['
    b.ne    ei_ldr_literal
ei_ldst_bracket:
    bl      parse_mem                // x25=Rn, x0=imm/Rm, x26=mode
    cmp     x26, #4
    b.hs    ei_ldst_reg              // register offset
    cbz     x26, ei_ldst_uimm_encode // base / signed offset form
    // pre/post-index: simm9 with mode bits = x26 at [11:10]
    bl      ldst_base_simm9
    orr     w0, w0, w26, lsl #10
    b       ei_ldst_simm9_tail

ei_ldst_reg:
    add     x24, x0, #0                  // Rm
    ubfx    w10, w26, #3, #1         // S
    bl      ldst_base
    orr     w0, w0, w10, lsl #12     // S bit
    orr     w0, w0, w24, lsl #16     // Rm
    movz    w9, #0x6800              // 0x800 | 0x6000
    movk    w9, #0x3820, lsl #16     // | 0x38000000 | 0x00200000
    b       orr_w9_emit

ei_ldst_uimm_encode:
    tbnz    x0, #63, ei_ldst_unscaled   // negative → LDUR/STUR encoding
    lsr     x0, x0, x20
    and     w10, w0, #0xFFF
    bl      ldst_base
    orr     w0, w0, w10, lsl #10
    movz    w9, #0x3900, lsl #16
    b       orr_w9_emit
ei_ldst_unscaled:
    bl      ldst_base_simm9          // bits[11:10] = 00 (unscaled)
ei_ldst_simm9_tail:
    orr     w0, w0, w10, lsl #12     // imm9 at [20:12]
    orr     w0, w0, #0x38000000
    b       emit_inst_done

// ──────────────────────────────────────────────────────────────────────────
//  parse_mem — parse a load/store address operand
//  entry: x0 at '[' (w9 = '['); uses [sp, #56] for return address
//  returns x25 = Rn, x0 = imm (or Rm), x26 = mode:
//    0 = base / signed offset, 1 = post-index, 3 = pre-index,
//    4|S<<3 = register offset (x0 = Rm, S = lsl-shift flag)
//  clobbers x19
// ──────────────────────────────────────────────────────────────────────────
parse_mem:
    str     x30, [sp, #56]
    bl      skip1_ws                 // skip '['
    bl      parse_register           // Rn
    cbz     x1, parse_reg_fail       // base must be 64-bit (xN or sp)
    add     x25, x0, #0
    mov     x19, #0                  // imm = 0
    mov     x26, #0                  // mode = offset
    bl      ws_x2
    cmp     w9, #']'
    b.eq    pm_close
    cmp     w9, #','
    b.ne    pe_atom_err
    bl      skip1_ws                 // skip ','
    cmp     w9, #'a'
    b.lo    pm_imm                   // '#' or ':lo12:' (both < 'a')
    // register offset: Rm [, lsl #N]
    bl      parse_register
    add     x19, x0, #0                  // Rm
    mov     x26, #4
    bl      ws_x2
    cmp     w9, #']'
    b.eq    pm_rbracket
    bl      skip_lsl                 // skip ", lsl" + parse_hash_imm
    cbz     x0, 4f
    mov     x26, #12                 // mode 4 | S=1
4:  bl      ws_x1
    cmp     w9, #']'
    b.ne    pe_atom_err
pm_rbracket:
    add     x0, x0, #1               // consume ']'
    str     x0, [x28, #ST_EOL_CUR]
    b       pm_done
pm_imm:
    bl      parse_hash_imm           // x0 = imm
    add     x19, x0, #0
    bl      ws_x1
    cmp     w9, #']'
    b.ne    pe_atom_err              // unclosed memory operand
    bl      skip1_ws                 // skip ']'
    str     x0, [x28, #ST_EOL_CUR]
    cmp     w9, #'!'
    b.ne    pm_done
    add     x0, x0, #1               // consume '!'
    str     x0, [x28, #ST_EOL_CUR]
    mov     x26, #3                  // pre-index
    b       pm_done
pm_close:
    bl      skip1_ws                 // skip ']'
    str     x0, [x28, #ST_EOL_CUR]
    cmp     w9, #','
    b.ne    pm_done
    bl      skip1_ws                 // skip ','
    bl      parse_hash_imm           // (cursor stored by parse_expr)
    add     x19, x0, #0
    mov     x26, #1                  // post-index
pm_done:
    add     x0, x19, #0
    ldr     x30, [sp, #56]
    ret

// sign-extending load: determine size and opc from mnemonic suffix + dest register
// x24=sf (from parse_x23_ws), x19=mnemonic
ei_ldrs_size:
    ldrb    w9, [x19, #4]           // 5th char: 'b','h','w'
    ubfx    w20, w9, #3, #2         // 'b'→0, 'h'→1, 'w'→2
    eor     w22, w24, #3             // opc = 3 - sf (Xd→2, Wd→3) = sf^3
    b       ei_ldst_bracket

// ldr Rt, label — PC-relative literal load
// x23=Rt, x24=sf, x0=pointer to label
ei_ldr_literal:
    bl      parse_label_pc_rel       // x0 = (target - PC) / 4
    ubfiz   w0, w0, #5, #19         // imm19 << 5
    orr     w0, w0, w23              // Rt
    movz    w9, #0x1800, lsl #16     // 32-bit base (0x18000000)
    orr     w9, w9, w24, lsl #30     // sf=1 → 0x58000000 for 64-bit
    b       orr_w9_emit

ei_ldst_pair:
    // x22=L (already set by ei_ld/ei_st)
    bl      parse_x23_ws
    add     x21, x1, #0                  // save sf (0=32-bit, 1=64-bit)
    bl      parse_register           // Rt2
    add     x24, x0, #0                  // Rt2
    bl      ws_x2_skip1              // skip ',' → at '['
    bl      parse_mem                // x25=Rn, x0=imm, x26=mode
    // map mode {0,post=1,pre=3} → LDP/STP XOR bits {0,3,1} at [24:23]
    add     x9, x26, x26, lsl #1     // 3*mode
    and     x9, x9, #3
    add     w10, w21, #2             // shift: 2 (32-bit) or 3 (64-bit)
    asr     w0, w0, w10
    movz    w11, #0x2900, lsl #16    // 32-bit STP/LDP base (signed offset)
    orr     w11, w11, w21, lsl #31   // sf=1 → 0xA900
    eor     w11, w11, w9, lsl #23    // apply addressing mode bits
    orr     w11, w11, w22, lsl #22
    bfi     w11, w0, #15, #7         // imm7 at bits[21:15]
    orr     w11, w11, w24, lsl #10
    orr     w11, w11, w25, lsl #5
    orr     w0, w11, w23
    b       emit_inst_done

// madd/msub Rd, Rn, Rm, Ra — 0x1B000000 (32) / 0x9B000000 (64)
ei_madd_msub_common:
    bl      parse_3reg                  // x22=Rd, x23=sf, x24=Rn, x0=Rm
    orr     w25, w22, w0, lsl #16       // save Rd | (Rm << 16)
    bl      ws_x2_skip1                 // skip ','
    bl      parse_register              // Ra
    orr     w9, w25, w0, lsl #10        // (Rd | Rm<<16) | (Ra << 10)
    orr     w9, w9, w24, lsl #5         // | (Rn << 5)
    movk    w26, #0x1B00, lsl #16       // 32-bit base (clobbers w26)
    orr     w0, w26, w23, lsl #31       // sf
    b       orr_w9_emit

// mul Rd, Rn, Rm — MADD Rd, Rn, Rm, XZR
// 64-bit: 0x9B007C00 | (Rm<<16) | (Rn<<5) | Rd
// 32-bit: 0x1B007C00 | ...
ei_mul:
    bl      parse_3reg
    movz    w9, #0x7C00
    movk    w9, #0x1B00, lsl #16     // 32-bit base
    b       emit_3reg_sf_tail

ei_shift_imm_dispatch:
ei_shift_imm:
    bl      parse_hash_imm
    // x0 = shift amount (no bl before use, safe to use directly)
    mov     x11, #31
    add     x11, x11, x23, lsl #5   // size-1 = 31 or 63 (shared)
    tst     w25, #0xC00
    b.ne    ei_lsr_asr_imm
    // LSL #n: UBFM Rd, Rn, #(-n mod size), #(size-1-n)
    neg     x10, x0
    and     x10, x11, x10           // immr = (-n) & (size-1)
    sub     x11, x11, x0            // imms = (size-1) - n
    b       ei_ubfm_emit

ei_lsr_asr_imm:
    add     x10, x0, #0                  // immr = n
    tbnz    w25, #11, ei_asr_sbfm    // bit 11 set in w25 = ASR (0x2800)

ei_ubfm_emit:
    movz    w0, #0x5300, lsl #16     // UBFM base (sf+N applied below)
ei_bfm_apply_n_sf:
    orr     w0, w0, w23, lsl #22     // N bit = sf
ei_ubfm_orr:
    orr     w0, w0, w22
    orr     w0, w0, w24, lsl #5
    orr     w0, w0, w11, lsl #10
    orr     w0, w0, w10, lsl #16
    b       emit_with_sf

// ── unified bitfield handler (ubfx/ubfm/ubfiz/sbfx/sbfm/sbfiz/bfm/bfi/bfxil)
ei_bfm_unified:
    bl      parse_2reg               // x22=Rd, x23=sf, x0=Rn, x2=ptr past
    add     x24, x0, #0                  // Rn
    bl      ws_x2_skip1              // skip ','
    bl      parse_hash_imm           // #op3
    add     x25, x0, #0
    bl      ws_x1
    bl      skip1_ws                 // skip ','
    bl      parse_hash_imm           // #op4
    add     x9, x0, #0                   // op4 in x9
    // determine base opcode from mnemonic first char (x19 preserved)
    ldrb    w10, [x19]
    movz    w0, #0x3300, lsl #16     // BFM base
    mov     w11, #2                  // suffix offset for b* prefix
    cmp     w10, #'b'
    b.eq    1f
    mov     w11, #3                  // suffix offset for u*/s* prefix
    sub     w10, w10, #'t'           // 's'-'t'=-1, 'u'-'t'=+1
    add     w0, w0, w10, lsl #29     // SBFM: -0x20000000, UBFM: +0x20000000
1:  ldrb    w11, [x19, x11]          // load distinguishing char
    cmp     w11, #'x'
    b.eq    bfm_extract_apply
    cmp     w11, #'m'
    b.eq    bfm_raw_apply

// insert: immr=(-lsb) mod size, imms=width-1 (fall-through from dispatch)
bfm_insert_apply:
    sub     x11, x9, #1
    mov     x10, #31
    add     x10, x10, x23, lsl #5   // size-1 = 31 or 63
    neg     x9, x25
    and     x10, x9, x10
    b       ei_bfm_apply_n_sf

// extract: immr=lsb(x25), imms=lsb+width-1 (falls through to raw)
bfm_extract_apply:
    add     x9, x25, x9
    sub     x9, x9, #1
// raw: immr=x25, imms=x9
bfm_raw_apply:
    add     x10, x25, #0
    add     x11, x9, #0
    b       ei_bfm_apply_n_sf

// (bitfield handlers unified into ei_bfm_unified above)

// mov — multiple forms
ei_mov:
    bl      parse_x22_ws

    cmp     w9, #'#'
    b.eq    ei_mov_imm

    // register form
    bl      parse_register
    // if either reg is 31, use ADD Rd, Rn, #0 (handles SP)
    cmp     x22, #31
    b.eq    ei_mov_add
    cmp     x0, #31
    b.eq    ei_mov_add
    // ORR Rd, XZR, Rm — x0 = Rm from parse_register
    movz    w25, #0x2A00, lsl #16    // 32-bit ORR base
    b       ei_zr_rn_tail            // Rn=xzr, shares neg/mvn tail

ei_mov_add:
    // ADD Rd, Rn, #0 — x0 = Rm from parse_register
    orr     w0, w22, w0, lsl #5
    movk    w0, #0x1100, lsl #16
    b       emit_with_sf            // x23 = sf

ei_mov_imm:
    bl      parse_hash_imm
    // x0 = immediate (no bl in loop, safe to use directly)
    mov     x26, #0                  // phase: 0=MOVZ, 1=MOVN
ei_mov_try_phase:
    mov     x25, #0                  // hw shift counter (reset each phase)
ei_mov_hw_loop:
    ror     x9, x0, x25
    lsr     x11, x9, #16
    cbz     x11, ei_mov_found
    add     x25, x25, #16
    cmp     x25, #64
    b.lt    ei_mov_hw_loop
    // try MOVN phase
    cbnz    x26, ei_logical_bad
    mvn     x0, x0
    mov     x26, #1
    b       ei_mov_try_phase

ei_mov_found:
    // x9 = imm16, x25 = shift, x26 = phase (0=MOVZ, 1=MOVN)
    movz    w0, #0x5280, lsl #16    // MOVZ base
    sub     w0, w0, w26, lsl #30    // MOVN: subtract 0x40000000 (clear bit 30)
    orr     w0, w0, w23, lsl #31    // sf bit
    orr     w0, w0, w22             // Rd
    orr     w0, w0, w9, lsl #5      // imm16
    orr     w0, w0, w25, lsl #17    // hw (shift_amount << 17 = hw << 21)
    b       emit_inst_done

// movz/movn/movk Rd, #imm16 [, lsl #N]
ei_movwide:
    bl      parse_x23_ws
    bl      parse_hash_imm           // #imm16
    and     w25, w0, #0xFFFF         // imm16 (callee-saved)

    // check for optional ", lsl #N"
    bl      ws_x1
    cmp     w9, #','
    mov     w10, #0                  // hw = 0 default (doesn't affect flags)
    b.ne    ei_movwide_emit
    bl      skip_lsl                 // skip ", lsl" + parse_hash_imm
    add     w10, w0, #0                  // raw shift amount

ei_movwide_emit:
    orr     w0, w22, w24, lsl #31    // base | sf
    orr     w0, w0, w23              // | Rd
    orr     w0, w0, w25, lsl #5      // | imm16
    orr     w0, w0, w10, lsl #17     // | hw (shift<<17 = hw<<21)
    b       emit_inst_done

// tbz/tbnz Rt, #bit, label — b5 011011 op b40 imm14 Rt
ei_t:
    cmp     w10, #'s'
    b.eq    ei_tst
    ldrb    w9, [x19, #2]
    sub     x22, x20, #3            // 0 for tbz (len=3), 1 for tbnz (len=4)
    cmp     w9, #'z'
    b.eq    ei_tbz_common
    cmp     w9, #'n'
    b.ne    ei_bad
ei_tbz_common:
    bl      parse_x23_ws
    bl      parse_hash_imm
    add     x24, x0, #0                  // bit number
    bl      ws_x1
    add     x0, x0, #1              // skip ','
    bl      parse_label_pc_rel
    and     w0, w0, #0x3FFF
    orr     w0, w23, w0, lsl #5
    bfi     w0, w24, #19, #5
    lsr     w9, w24, #5
    orr     w0, w0, w9, lsl #31
    orr     w0, w0, w22, lsl #24
    movz    w9, #0x3600, lsl #16
orr_w9_emit:
    orr     w0, w0, w9
    b       emit_inst_done

// neg Rd, Rm — alias for sub Rd, xzr, Rm  /  nop
ei_n:
    cmp     w10, #'o'
    b.eq    ei_nop
ei_neg:
    movz    w25, #0x4B00, lsl #16     // 32-bit SUB base
ei_neg_mvn_common:
    bl      parse_2reg               // x22=Rd, x23=sf, x0=Rm
ei_zr_rn_tail:
    mov     x24, #31                 // Rn = xzr
    add     w9, w25, #0
    b       emit_3reg_sf_tail

// nop — 0xD503201F
ei_nop:
    movz    w0, #0x201F
    movk    w0, #0xD503, lsl #16
    b       emit_inst_done

// ── shared emit tails ─────────────────────────────────────────────────────
// emit_3reg_sf_tail: w9=32-bit base, x23=sf -> set bit31 if sf, then emit_3reg_tail
// emit_3reg_tail: w9=base, x0=Rm, x22=Rd, x24=Rn -> emit and done
// emit_3reg_1AC0_tail: w9=low opcode bits, x23=sf, x0=Rm, x22=Rd, x24=Rn
// completes with 0x1AC0/0x9AC0 opcode and emits
emit_3reg_1AC0_tail:
    movk    w9, #0x1AC0, lsl #16
emit_3reg_sf_tail:
    orr     w9, w9, w23, lsl #31
emit_3reg_tail:
    orr     w9, w9, w22
    orr     w9, w9, w24, lsl #5
    orr     w0, w9, w0, lsl #16
    b       emit_inst_done
// ldst_base_simm9: extract 9-bit immediate then fall through to ldst_base
ldst_base_simm9:
    and     w10, w0, #0x1FF
// ldst_base: compute size<<30 | opc<<22 | Rn<<5 | Rt for load/store encodings
// reads x20=size, x22=opc, w23=Rt, x25=Rn; returns w0=partial insn
ldst_base:
    lsl     w0, w20, #30
    orr     w0, w0, w22, lsl #22
    orr     w0, w0, w23
    orr     w0, w0, w25, lsl #5
    ret

// ══════════════════════════════════════════════════════════════════════════
//  Compression — two-tier dictionary encoder
// ══════════════════════════════════════════════════════════════════════════

// ──────────────────────────────────────────────────────────────────────────
//  compress_text — compress text_buf into input_buf using dictionary
//
//  Input:  x27 = text_buf, [x28, #ST_TEXT_POS] = text size
//  Output: x20 = compressed stream size (bytes)
//  Uses input_buf as scratch (safe — input already consumed)
// ──────────────────────────────────────────────────────────────────────────
compress_text:
    // leaf function — no bl calls, caller doesn't need x19/x20 preserved
    ldr     x11, [x28, #ST_STUB_BASE]
    add     x11, x11, #STUB_SIZE           // x11 = full dict base

    add     x12, x27, #0                       // src = text_buf
    ldr     x1, [x28, #ST_TEXT_POS]
    add     x0, x12, x1                    // src_end
    // dst: stream lands at its final image offset, right after the
    // header+stub+dict template copied in by _start
    add     x20, x28, #(INPUT_BUF_OFF + CODE_START + STUB_SIZE + DICT_SIZE)
    add     x2, x20, #0

    // one forward scan over all three tiers: code w5 walks 1..254 while
    // the cursor x4 advances 4/3/2 bytes per entry (= 4 - lit_bytes);
    // w13 = lit_bytes (0 full, 1 t24, 2 t16, 4 raw escape)
ct_loop:
    cmp     x12, x0
    b.hs    ct_done
    ldr     w3, [x12], #4
    mov     w5, #0                   // code
    mov     w13, #0                  // lit_bytes / tier
    add     x4, x11, #0              // dict cursor
ct_scan:
    add     w5, w5, #1
    cmp     w5, #(FULL_DICT_ENTRIES + 1)
    b.ne    1f
    mov     w13, #1
1:  cmp     w5, #(FULL_DICT_ENTRIES + T24_DICT_ENTRIES + 1)
    b.ne    2f
    mov     w13, #2
2:  cmp     w5, #255
    b.ne    3f
    mov     w13, #4                  // raw escape (code 255 + 4 literal bytes)
    b       ct_emit
3:  ldr     w6, [x4]                 // entry (may over-read into next entry)
    lsl     w14, w13, #3             // compare top (32 - 8*lit) bits
    lsr     w7, w3, w14
    eor     w6, w6, w7
    add     x4, x4, #4
    sub     x4, x4, x13              // next entry (entry size = 4 - lit)
    lsl     w6, w6, w14              // discard over-read bits
    cbnz    w6, ct_scan

ct_emit:
    strb    w5, [x2], #1             // code byte
    str     w3, [x2]                 // low literal bytes (overwrite-safe)
    add     x2, x2, x13
    b       ct_loop

ct_done:
    strb    wzr, [x2], #1              // end marker
    sub     x20, x2, x20               // x20 = compressed size
    ret

// ── appended data (stage 0: asm_stage0.s; self-hosted: file image)
_appended_data:
