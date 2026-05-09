; ================================================================
;  SOLITAIRE.ASM  -  LC-3 Assembly
;  Author: Ian Codding II
;  Date: 5/6/2026
;  Revision: 1.0
;
;  HOW IT WORKS:
;   All subroutine calls use JSRR R5 (load address then jump).
;   All shared variable access uses LDR/STR through pointer words.
;   Each section has a LOCAL pointer table placed just before its
;   code so every LD stays within +-256 words of the instruction.
;
;  CARD ENCODING (one word per card):
;   Bits 5-4 = suit  0=Clubs 1=Diamonds 2=Hearts 3=Spades
;   Bits 3-0 = rank  0=Ace 1=2 ... 12=King
;   x0080 = face-down sentinel (real value OR'd with x0080)
;   x00FF = empty slot sentinel
;
;  MEMORY MAP:
;   x3000  Pointer table + shared data + MAIN
;   x3200  MENU + GET_SEED
;   x3280  INIT_DECK + LCG_RAND + MULTIPLY + MOD + SHUFFLE
;   x3350  DEAL
;   x3430  PRINT_STATE + PRINT_CARD + EBYTE + GET_INPUT
;   x3580  PARSE_MOVE
;   x3640  VALID_MOVE + helpers + TABADDR + SUIT_COLOR
;   x3780  DO_MOVE + MOVE_TAB_TAB + FLIP_TOP + CHECK_WIN + PRINT_WIN
;   x3900  Game arrays (DECK, STOCK, TAB_DATA, FOUND_TOP ...)
;
;  COMMANDS:
;   D        Draw top stock card to waste
;   R        Reset: move waste card back to stock
;   Q        Quit the game
;   Tn Fm    Move top of tableau n to foundation m  (n=1-7, m=1-4)
;   Tn Tm k  Move k cards from tableau n to tableau m
;   W Tn     Move waste top to tableau n
;   W Fn     Move waste top to foundation n
; ================================================================

; ================================================================
;  BLOCK 1: Pointer table + Shared data + MAIN  (x3000)
; ================================================================
        .ORIG x3000
        BRnzp MAIN              ; skip over data to MAIN code

; ----------------------------------------------------------------
;  SUBROUTINE ADDRESS TABLE
;  MAIN loads these into R5 then uses JSRR R5 to call each sub.
;  Storing addresses here puts them within +-256 of MAIN.
; ----------------------------------------------------------------
GA_MENU     .FILL MENU          ; address of MENU subroutine
GA_IDECK    .FILL INIT_DECK     ; address of INIT_DECK
GA_SHUF     .FILL SHUFFLE       ; address of SHUFFLE
GA_DEAL     .FILL DEAL          ; address of DEAL
GA_PSTATE   .FILL PRINT_STATE   ; address of PRINT_STATE
GA_GINPUT   .FILL GET_INPUT     ; address of GET_INPUT
GA_PMOVE    .FILL PARSE_MOVE    ; address of PARSE_MOVE
GA_VMOVE    .FILL VALID_MOVE    ; address of VALID_MOVE
GA_DOMOVE   .FILL DO_MOVE       ; address of DO_MOVE
GA_CHKWIN   .FILL CHECK_WIN     ; address of CHECK_WIN
GA_PWIN     .FILL PRINT_WIN     ; address of PRINT_WIN
GA_C_NL     .FILL C_NL          ; pointer to newline character (for DO_QUIT flush)

; ----------------------------------------------------------------
;  SHARED VARIABLES
;  All subroutines read/write these via pointer indirection.
; ----------------------------------------------------------------

; Move state - set by PARSE_MOVE, read by VALID_MOVE and DO_MOVE
MTYPE       .BLKW 1             ; move type: 0=Draw 1=TabFnd 2=TabTab 3=WstTab 4=WstFnd 5=Reset 6=Quit -1=invalid
MSRC        .BLKW 1             ; source pile index (0-based)
MDST        .BLKW 1             ; destination pile index (0-based)
MCNT        .BLKW 1             ; number of cards to move (default 1)
SCRATCH_CRD .BLKW 1             ; temporary card storage for validation
MTT_RSAVE   .BLKW 1             ; MOVE_TAB_TAB: saves R5 (source row) across JSRR

; R7 save slots - each subroutine saves its return address here
MN_R7   .BLKW 1                 ; MENU return address save
GS_R7   .BLKW 1                 ; GET_SEED return address save
ID_R7   .BLKW 1                 ; INIT_DECK return address save
LR_R7   .BLKW 1                 ; LCG_RAND return address save
MU_R7   .BLKW 1                 ; MULTIPLY return address save
MD_R7   .BLKW 1                 ; MOD return address save
SH_R7   .BLKW 1                 ; SHUFFLE return address save
DL_R7   .BLKW 1                 ; DEAL return address save
PS_R7   .BLKW 1                 ; PRINT_STATE return address save
PC_R7   .BLKW 1                 ; PRINT_CARD return address save
EB_R7   .BLKW 1                 ; EBYTE return address save
GI_R7   .BLKW 1                 ; GET_INPUT return address save
PM_R7   .BLKW 1                 ; PARSE_MOVE return address save
VM_R7   .BLKW 1                 ; VALID_MOVE return address save
VT_R7   .BLKW 1                 ; VM_TAB_TOP return address save
VK_R7   .BLKW 1                 ; VM_TAB_KCARD return address save
VF_R7   .BLKW 1                 ; VM_CHK_FND return address save
VC_R7   .BLKW 1                 ; VM_CHK_TAB return address save
TA_R7   .BLKW 1                 ; TABADDR return address save
DM_R7   .BLKW 1                 ; DO_MOVE return address save
MT_R7   .BLKW 1                 ; MOVE_TAB_TAB return address save
FT_R7   .BLKW 1                 ; FLIP_TOP return address save
CW_R7   .BLKW 1                 ; CHECK_WIN return address save
PW_R7   .BLKW 1                 ; PRINT_WIN return address save
SC_R7   .BLKW 1                 ; SUIT_COLOR return address save

; RNG state
SEED        .FILL x1234         ; LCG seed (overwritten by GET_SEED)
LCG_M       .FILL #25173        ; LCG multiplier
LCG_A       .FILL #13849        ; LCG addend
MASK15      .FILL x7FFF         ; mask to keep result 15-bit positive

; Card encoding constants
C_EMPTY     .FILL xFF           ; empty slot sentinel (x00FF)
C_FACEDN    .FILL x0080         ; face-down bit mask (bit 7)
MASK_RNK    .FILL x000F         ; mask for rank bits 3-0
MASK_SUT    .FILL x0030         ; mask for suit bits 5-4

; Move type ID constants
MV_DRAW     .FILL #0            ; D command: draw stock to waste
MV_TFND     .FILL #1            ; Tn Fm: tableau to foundation
MV_TTAB     .FILL #2            ; Tn Tm k: tableau to tableau
MV_WTAB     .FILL #3            ; W Tn: waste to tableau
MV_WFND     .FILL #4            ; W Fn: waste to foundation
MV_RST      .FILL #5            ; R command: reset waste to stock
MV_QUIT     .FILL #6            ; Q command: quit game

; Command character ASCII codes
CH_D        .FILL x44           ; ASCII 'D' = Draw
CH_R        .FILL x52           ; ASCII 'R' = Reset
CH_Q        .FILL x51           ; ASCII 'Q' = Quit
CH_W        .FILL x57           ; ASCII 'W' = Waste move
CH_T        .FILL x54           ; ASCII 'T' = Tableau source
CH_F        .FILL x46           ; ASCII 'F' = Foundation destination

; Frequently used output characters
C_NL        .FILL x0A           ; newline character
C_SPACE     .FILL x20           ; space character
C_PIPE      .FILL x7C           ; pipe '|' for box drawing
C_STAR      .FILL x2A           ; asterisk '*' for face-down cards
C_LBR       .FILL x5B           ; left bracket '['
C_RBR       .FILL x5D           ; right bracket ']'

; UTF-8 encoded suit symbols (3 bytes each, sent via PUTS as null-terminated strings)
; Using .FILL for each byte since LC-3 .STRINGZ only handles ASCII
UTF_B1      .FILL xE2           ; first byte of all suit symbols (E2)
UTF_B2      .FILL x99           ; second byte of all suit symbols (99)
SUT_C3      .FILL xA3           ; third byte for Clubs    (♣ = E2 99 A3)
SUT_D3      .FILL xA6           ; third byte for Diamonds (♦ = E2 99 A6)
SUT_H3      .FILL xA5           ; third byte for Hearts   (♥ = E2 99 A5)
SUT_S3      .FILL xA0           ; third byte for Spades   (♠ = E2 99 A0)
; Pre-built null-terminated suit strings for TRAP x22 (PUTS)
STR_CLB .FILL xE2   ; ♣ byte 1
        .FILL x99   ; ♣ byte 2
        .FILL xA3   ; ♣ byte 3
        .FILL x00   ; null terminator
STR_DIA .FILL xE2   ; ♦ byte 1
        .FILL x99   ; ♦ byte 2
        .FILL xA6   ; ♦ byte 3
        .FILL x00   ; null terminator
STR_HRT .FILL xE2   ; ♥ byte 1
        .FILL x99   ; ♥ byte 2
        .FILL xA5   ; ♥ byte 3
        .FILL x00   ; null terminator
STR_SPA .FILL xE2   ; ♠ byte 1
        .FILL x99   ; ♠ byte 2
        .FILL xA0   ; ♠ byte 3
        .FILL x00   ; null terminator

; Numeric constants that exceed the 5-bit immediate range (-16 to +15)
NEG_52      .FILL #-52          ; negative 52 (deck size)
NEG_32      .FILL #-32          ; negative 32 (used in suit detection)
NEG_30      .FILL #-30          ; negative 30 (screen clear loop count)
NEG_24      .FILL #-24          ; negative 24 (stock size after deal)
NEG_18      .FILL #-18          ; negative 18 (menu box height)
NEG_58      .FILL #-58          ; negative 58 (menu box inner width)
NEG_x30     .FILL xFFD0         ; -48 = -(ASCII '0'), used to convert digit chars to integers

; Pointers to game array base addresses (arrays live at x3900)
A_DECK      .FILL x3900         ; base address of DECK array (52 words)
A_STOCK     .FILL x3934         ; base address of STOCK array (52 words)
A_STKTOP    .FILL x3968         ; address of STOCK_TOP variable
A_WASTE     .FILL x3969         ; address of WASTE_TOP variable
A_TABDAT    .FILL x396A         ; base address of TAB_DATA (7 piles x 20 slots)
A_TABSZ     .FILL x39F6         ; base address of TAB_SZ array (7 words)
A_FNDTOP    .FILL x3A38         ; base address of FOUND_TOP array (4 words)
A_FNDSUT    .FILL FOUND_SUIT     ; base address of FOUND_SUIT array (4 words, -1=empty)

; Input buffer and rank character lookup table
INBUF       .BLKW 20            ; 20-char input buffer for user commands
RANK_CH     .STRINGZ "A23456789TJQK"  ; rank chars indexed 0-12: Ace,2-9,Ten,Jack,Queen,King

; ================================================================
;  MAIN - Entry point: initialise then run the game loop
; ================================================================
MAIN
        LD  R5, GA_MENU         ; load address of MENU
        JSRR R5                 ; show rules screen and get seed
        LD  R5, GA_IDECK        ; load address of INIT_DECK
        JSRR R5                 ; fill deck with encoded card values 0-51
        LD  R5, GA_SHUF         ; load address of SHUFFLE
        JSRR R5                 ; Fisher-Yates shuffle the deck
        LD  R5, GA_DEAL         ; load address of DEAL
        JSRR R5                 ; deal 28 cards to tableau, rest to stock

GAME_LOOP
        LD  R5, GA_PSTATE       ; load address of PRINT_STATE
        JSRR R5                 ; draw the board to the console
        LD  R5, GA_GINPUT       ; load address of GET_INPUT
        JSRR R5                 ; read a command line from keyboard -> INBUF
        LD  R5, GA_PMOVE        ; load address of PARSE_MOVE
        JSRR R5                 ; decode INBUF -> MTYPE,MSRC,MDST,MCNT
        LEA R5, MTYPE           ; R5 = address of MTYPE variable
        LDR R1, R5, #0          ; R1 = MTYPE value
        BRn GAME_LOOP           ; if MTYPE=-1 (unrecognised), loop back
        LEA R5, MV_QUIT         ; R5 = address of MV_QUIT constant
        LDR R2, R5, #0          ; R2 = 6 (quit move type ID)
        NOT R2, R2              ; R2 = bitwise NOT of 6
        ADD R2, R2, #1          ; R2 = -6 (two's complement negate)
        ADD R2, R1, R2          ; R2 = MTYPE - 6
        BRz DO_QUIT             ; if zero, MTYPE==6, user typed Q
        LD  R5, GA_VMOVE        ; load address of VALID_MOVE
        JSRR R5                 ; check if move is legal -> R0=1/0
        ADD R0, R0, #0          ; set condition codes from R0
        BRz BAD_MOVE            ; if R0=0, move is illegal
        LD  R5, GA_DOMOVE       ; load address of DO_MOVE
        JSRR R5                 ; execute the move, update game state
        LD  R5, GA_CHKWIN       ; load address of CHECK_WIN
        JSRR R5                 ; check if all foundations complete -> R0=1/0
        ADD R0, R0, #0          ; set condition codes from R0
        BRz GAME_LOOP           ; if R0=0, game not won yet, keep playing
        LD  R5, GA_PWIN         ; load address of PRINT_WIN
        JSRR R5                 ; print victory message
        HALT                    ; stop the simulator

BAD_MOVE
        LEA R0, STR_BAD         ; R0 = address of "Invalid move" string
        TRAP x22                ; PUTS: print the string
        BRnzp GAME_LOOP         ; unconditional branch back to game loop

DO_QUIT
        LD  R0, GA_C_NL         ; R0 = address of newline constant
        LDR R0, R0, #0          ; R0 = newline char
        TRAP x21                ; OUT: newline (flushes any pending output)
        LEA R0, STR_BYE         ; R0 = address of "Goodbye" string
        TRAP x22                ; PUTS: print it
        TRAP x21                ; one more flush
        HALT                    ; stop the simulator

STR_BAD .STRINGZ "Invalid move.\n"   ; printed when move is rejected
STR_BYE .STRINGZ "Goodbye!\n"        ; printed on quit

; ================================================================
;  BLOCK 2: MENU + GET_SEED  (x3200)
; ================================================================

; Local pointer table for MENU - sits just before MENU code
MN_R7W      .FILL MN_R7         ; pointer to MENU's R7 save slot
MN_CNLW     .FILL C_NL          ; pointer to newline character
MN_GSEED    .FILL GET_SEED      ; address of GET_SEED subroutine
MN_PS8      .FILL MN_S8         ; pointer to string MN_S8 (too far for LEA)
MN_PS9      .FILL MN_S9         ; pointer to string MN_S9 (too far for LEA)

; ----------------------------------------------------------------
;  MENU - Print rules/commands screen, wait for ENTER, get seed
;  In:  nothing
;  Out: SEED set, player ready to play
; ----------------------------------------------------------------
MENU
        LD  R5, MN_R7W          ; R5 = address of MN_R7 save slot
        STR R7, R5, #0          ; save return address
        LEA R0, MN_S1           ; R0 = address of title string 1
        TRAP x22                ; PUTS: print "===...==="
        LEA R0, MN_S2           ; R0 = address of title string 2
        TRAP x22                ; PUTS: print "KLONDIKE SOLITAIRE"
        LEA R0, MN_S3           ; R0 = address of title string 3
        TRAP x22                ; PUTS: print "===...==="
        LEA R0, MN_S4           ; R0 = address of goal string
        TRAP x22                ; PUTS: print goal explanation
        LEA R0, MN_S5           ; R0 = address of commands header
        TRAP x22                ; PUTS: print "COMMANDS:"
        LEA R0, MN_S6           ; R0 = address of D command help
        TRAP x22                ; PUTS: print draw command
        LEA R0, MN_S7           ; R0 = address of R command help
        TRAP x22                ; PUTS: print reset command
        LD  R0, MN_PS8          ; R0 = address of Tn Fm help (via pointer, too far for LEA)
        TRAP x22                ; PUTS: print tableau->foundation command
        LD  R0, MN_PS9          ; R0 = address of Tn Tm help (via pointer, too far for LEA)
        TRAP x22                ; PUTS: print remaining commands + ENTER prompt

MN_WAIT TRAP x20                ; GETC: read one character from keyboard -> R0
        LD  R1, MN_CNLW         ; R1 = address of newline constant
        LDR R1, R1, #0          ; R1 = newline value (x0A)
        NOT R1, R1              ; R1 = bitwise NOT of newline
        ADD R1, R1, #1          ; R1 = -newline (two's complement)
        ADD R1, R0, R1          ; R1 = char - newline
        BRnp MN_WAIT            ; if not zero, not ENTER yet, keep waiting
        LD  R5, MN_GSEED        ; R5 = address of GET_SEED
        JSRR R5                 ; call GET_SEED to read numeric seed
        LD  R5, MN_R7W          ; R5 = address of MN_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return to MAIN

; Menu display strings (placed after RET, within +-256 of LEA instructions above)
MN_S1   .STRINGZ "============================================\n"
MN_S2   .STRINGZ "          SOLITAIRE  -  LC-3 Edition\n"
MN_S3   .STRINGZ "============================================\n"
MN_S4   .STRINGZ "GOAL: Move all cards to the 4 Foundations (Ace to King).\n\n"
MN_S5   .STRINGZ "COMMANDS:\n"
MN_S6   .STRINGZ "  D        Draw from stock to waste\n"
MN_S7   .STRINGZ "  R        Reset waste back to stock\n"
MN_S8   .STRINGZ "  Tn Fm    Tableau n -> Foundation m\n"
MN_S9   .STRINGZ "  Tn Tm k  Move k cards from tab n to m\n  W Tn     Waste -> Tableau n\n  W Fn     Waste -> Foundation n    Q=Quit\n\nENTER to start...\n"

; Local pointer table for GET_SEED
PGS_R7      .FILL GS_R7         ; pointer to GET_SEED's R7 save slot
PGS_C_NL    .FILL C_NL          ; pointer to newline character
PGS_NEGx30  .FILL NEG_x30       ; pointer to -48 constant (converts ASCII digit to int)
PGS_SEED    .FILL SEED           ; pointer to SEED variable

; ----------------------------------------------------------------
;  GET_SEED - Read a decimal integer from keyboard, store in SEED
;  In:  nothing
;  Out: SEED = value typed by user
; ----------------------------------------------------------------
GET_SEED
        LD  R5, PGS_R7          ; R5 = address of GS_R7 save slot
        STR R7, R5, #0          ; save return address
        LEA R0, GS_STR          ; R0 = address of "Enter seed:" prompt
        TRAP x22                ; PUTS: print prompt
        AND R1, R1, #0          ; R1 = 0 (accumulator for decimal value)

GS_LP   TRAP x20                ; GETC: read character -> R0
        TRAP x21                ; OUT: echo character back to console
        LD  R2, PGS_C_NL        ; R2 = address of newline
        LDR R2, R2, #0          ; R2 = newline value
        NOT R2, R2              ; R2 = NOT newline
        ADD R2, R2, #1          ; R2 = -newline
        ADD R2, R0, R2          ; R2 = char - newline
        BRz GS_DN               ; if zero, user pressed ENTER, done
        LD  R2, PGS_NEGx30      ; R2 = address of -48 constant
        LDR R2, R2, #0          ; R2 = -48
        ADD R2, R0, R2          ; R2 = char - '0' (digit value or negative if not digit)
        BRn GS_LP               ; if negative, not a digit, skip
        ADD R3, R2, #-9         ; R3 = digit - 9
        BRp GS_LP               ; if positive, digit > 9, not valid, skip
        ADD R3, R1, R1          ; R3 = acc * 2
        ADD R1, R3, R3          ; R1 = acc * 4
        ADD R1, R1, R1          ; R1 = acc * 8
        ADD R1, R1, R3          ; R1 = acc * 10  (8+2=10)
        ADD R1, R1, R2          ; R1 = acc * 10 + digit
        BRnzp GS_LP             ; unconditional loop for next digit

GS_DN   LD  R5, PGS_SEED        ; R5 = address of SEED variable
        STR R1, R5, #0          ; SEED = accumulated value
        LD  R0, PGS_C_NL        ; R0 = address of newline
        LDR R0, R0, #0          ; R0 = newline char
        TRAP x21                ; OUT: print newline after input
        LD  R5, PGS_R7          ; R5 = address of GS_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return to MENU

GS_STR  .STRINGZ "Enter seed: "  ; prompt printed before reading seed

; ================================================================
;  BLOCK 3: RNG section  (x3280)
;  INIT_DECK, LCG_RAND, MULTIPLY, MOD, SHUFFLE
; ================================================================

; Local pointer table for the entire RNG section
RNG_ID_R7   .FILL ID_R7         ; pointer to INIT_DECK R7 save
RNG_A_DECK  .FILL A_DECK        ; pointer to DECK base address
RNG_NEG52   .FILL NEG_52        ; pointer to -52 constant
RNG_NEG13   .FILL ID_NEG13      ; pointer to -13 constant (for division by 13)
RNG_LR_R7   .FILL LR_R7         ; pointer to LCG_RAND R7 save
RNG_SEED    .FILL SEED           ; pointer to SEED variable
RNG_LCG_M   .FILL LCG_M         ; pointer to LCG multiplier (25173)
RNG_LCG_A   .FILL LCG_A         ; pointer to LCG addend (13849)
RNG_MASK15  .FILL MASK15         ; pointer to 15-bit mask (x7FFF)
RNG_MU_R7   .FILL MU_R7         ; pointer to MULTIPLY R7 save
RNG_MD_R7   .FILL MD_R7         ; pointer to MOD R7 save
RNG_SH_R7   .FILL SH_R7         ; pointer to SHUFFLE R7 save
RNG_LRAND   .FILL LCG_RAND      ; address of LCG_RAND subroutine
RNG_MOD     .FILL MOD            ; address of MOD subroutine
RNG_MUL     .FILL MULTIPLY       ; address of MULTIPLY subroutine
ID_NEG13    .FILL #-13           ; constant -13 for suit calculation

; ----------------------------------------------------------------
;  INIT_DECK - Fill DECK[i] = (suit<<4)|rank  for i=0..51
;  suit = i/13 (0=Clubs 1=Diamonds 2=Hearts 3=Spades)
;  rank = i%13 (0=Ace ... 12=King)
;  In:  A_DECK points to deck array
;  Out: DECK filled with properly encoded card values
; ----------------------------------------------------------------
INIT_DECK
        LD  R5, RNG_ID_R7       ; R5 = address of ID_R7 save slot
        STR R7, R5, #0          ; save return address
        LD  R5, RNG_A_DECK      ; R5 = address of A_DECK pointer
        LDR R1, R5, #0          ; R1 = base address of DECK array
        AND R0, R0, #0          ; R0 = 0, card index i starting at 0
        LD  R5, RNG_NEG52       ; R5 = address of NEG_52
        LDR R2, R5, #0          ; R2 = -52, loop counter (counts up to 0)

ID_LP   AND R3, R3, #0          ; R3 = 0, will accumulate suit (i/13)
        ADD R4, R0, #0          ; R4 = i, working copy for division

ID_DIV  LD  R5, RNG_NEG13       ; R5 = address of -13 constant
        LDR R5, R5, #0          ; R5 = -13
        ADD R4, R4, R5          ; R4 = R4 - 13 (subtract 13 once)
        BRn ID_DONE             ; if negative, we have divided enough
        ADD R3, R3, #1          ; suit++ (each full 13 = one suit)
        BRnzp ID_DIV            ; keep subtracting 13

ID_DONE LD  R5, RNG_NEG13       ; R5 = address of -13
        LDR R5, R5, #0          ; R5 = -13
        NOT R5, R5              ; R5 = 12 (NOT -13 = bitwise complement)
        ADD R5, R5, #1          ; R5 = 13 (two's complement +1)
        ADD R4, R4, R5          ; R4 = rank = i mod 13 (undo last overshoot)
        ADD R5, R3, R3          ; R5 = suit * 2
        ADD R5, R5, R5          ; R5 = suit * 4
        ADD R5, R5, R5          ; R5 = suit * 8
        ADD R5, R5, R5          ; R5 = suit * 16 = suit << 4
        ADD R5, R5, R4          ; R5 = (suit<<4) | rank = encoded card
        STR R5, R1, #0          ; DECK[i] = encoded card value
        ADD R1, R1, #1          ; advance deck pointer to next slot
        ADD R0, R0, #1          ; i++
        ADD R2, R2, #1          ; loop counter++ (towards 0)
        BRn ID_LP               ; if still negative, more cards to encode
        LD  R5, RNG_ID_R7       ; R5 = address of ID_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return to MAIN

; ----------------------------------------------------------------
;  LCG_RAND - Linear Congruential Generator
;  Formula: SEED = (SEED * 25173 + 13849) mod 32768
;  In:  SEED (global)
;  Out: R0 = new pseudo-random 15-bit value, SEED updated
; ----------------------------------------------------------------
LCG_RAND
        LD  R5, RNG_LR_R7       ; R5 = address of LR_R7 save slot
        STR R7, R5, #0          ; save return address
        LD  R5, RNG_SEED        ; R5 = address of SEED variable
        LDR R1, R5, #0          ; R1 = current SEED value (multiplicand)
        LD  R5, RNG_LCG_M       ; R5 = address of multiplier constant
        LDR R2, R5, #0          ; R2 = 25173 (multiplier)
        LD  R5, RNG_MUL         ; R5 = address of MULTIPLY subroutine
        JSRR R5                 ; R0 = (SEED * 25173) mod 65536
        LD  R5, RNG_LCG_A       ; R5 = address of addend constant
        LDR R2, R5, #0          ; R2 = 13849
        ADD R0, R0, R2          ; R0 = product + 13849
        LD  R5, RNG_MASK15      ; R5 = address of 15-bit mask
        LDR R2, R5, #0          ; R2 = x7FFF
        AND R0, R0, R2          ; R0 = result masked to 15 bits (always positive)
        LD  R5, RNG_SEED        ; R5 = address of SEED variable
        STR R0, R5, #0          ; SEED = new random value
        LD  R5, RNG_LR_R7       ; R5 = address of LR_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return with R0 = random number

; ----------------------------------------------------------------
;  MULTIPLY - R0 = (R1 * R2) mod 65536 using shift-and-add
;  Processes 16 bits of R2; for each set bit adds shifted R1.
;  Only 16 iterations regardless of values (much faster than loop).
;  In:  R1 = multiplicand, R2 = multiplier
;  Out: R0 = product mod 65536
; ----------------------------------------------------------------
MULTIPLY
        LD  R5, RNG_MU_R7       ; R5 = address of MU_R7 save slot
        STR R7, R5, #0          ; save return address
        AND R0, R0, #0          ; R0 = 0, accumulator for product
        AND R3, R3, #0          ; R3 = 0
        ADD R3, R3, #15         ; R3 = 15, bit counter (15 down to 0)

MU_LP   ADD R2, R2, #0          ; set condition codes from R2
        BRzp MU_SKIP            ; if bit 15 of R2 is 0, skip add
        ADD R0, R0, R1          ; bit 15 was 1: add current R1 to product

MU_SKIP ADD R1, R1, R1          ; R1 <<= 1 (shift multiplicand left)
        ADD R2, R2, R2          ; R2 <<= 1 (shift multiplier left, next bit -> bit 15)
        ADD R3, R3, #-1         ; decrement bit counter
        BRzp MU_LP              ; loop while counter >= 0 (16 iterations total)

MU_DN   LD  R5, RNG_MU_R7       ; R5 = address of MU_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return with R0 = product

; ----------------------------------------------------------------
;  MOD - R0 = R1 mod R2 using repeated subtraction
;  In:  R1 = dividend, R2 = divisor
;  Out: R0 = remainder (R1 mod R2)
; ----------------------------------------------------------------
MOD
        LD  R5, RNG_MD_R7       ; R5 = address of MD_R7 save slot
        STR R7, R5, #0          ; save return address
        AND R0, R0, #0          ; R0 = 0
        ADD R0, R1, #0          ; R0 = R1 (working copy of dividend)
        NOT R3, R2              ; R3 = NOT R2
        ADD R3, R3, #1          ; R3 = -R2 (two's complement negate)

MD_LP   ADD R0, R0, R3          ; R0 -= R2 (subtract divisor)
        BRn MD_RS               ; if negative, overshot: undo and finish
        BRz MD_DN               ; if zero, exact division: done
        BRnzp MD_LP             ; still positive: keep subtracting

MD_RS   ADD R0, R0, R2          ; undo last subtraction (restore remainder)
MD_DN   LD  R5, RNG_MD_R7       ; R5 = address of MD_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return with R0 = remainder

; ----------------------------------------------------------------
;  SHUFFLE - Fisher-Yates in-place shuffle of DECK[0..51]
;  For i=51 downto 1: swap DECK[i] with DECK[random mod (i+1)]
;  In:  DECK filled by INIT_DECK, SEED set
;  Out: DECK shuffled randomly
; ----------------------------------------------------------------
SHUFFLE
        LD  R5, RNG_SH_R7       ; R5 = address of SH_R7 save slot
        STR R7, R5, #0          ; save return address
        AND R4, R4, #0          ; R4 = 0
        ADD R4, R4, #15         ; R4 = 15 (building 51 from small immediates)
        ADD R4, R4, #15         ; R4 = 30
        ADD R4, R4, #15         ; R4 = 45
        ADD R4, R4, #6          ; R4 = 51 (i starts at 51)

SH_LP   LD  R5, RNG_LRAND       ; R5 = address of LCG_RAND
        JSRR R5                 ; R0 = random 15-bit value
        ADD R1, R0, #0          ; R1 = random value (dividend for MOD)
        ADD R2, R4, #1          ; R2 = i+1 (divisor: want j in range 0..i)
        LD  R5, RNG_MOD         ; R5 = address of MOD
        JSRR R5                 ; R0 = j = random mod (i+1)
        LD  R5, RNG_A_DECK      ; R5 = address of A_DECK pointer
        LDR R5, R5, #0          ; R5 = base address of DECK array
        ADD R6, R5, R4          ; R6 = &DECK[i]
        ADD R3, R5, R0          ; R3 = &DECK[j]
        LDR R1, R6, #0          ; R1 = DECK[i] (save before overwrite)
        LDR R2, R3, #0          ; R2 = DECK[j]
        STR R2, R6, #0          ; DECK[i] = DECK[j]
        STR R1, R3, #0          ; DECK[j] = old DECK[i] (swap complete)
        ADD R4, R4, #-1         ; i--
        BRp SH_LP               ; continue while i > 0
        LD  R5, RNG_SH_R7       ; R5 = address of SH_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return with DECK shuffled

; ================================================================
;  BLOCK 4: DEAL section  (x3350)
; ================================================================

; Local pointer table for DEAL
PDL_R7      .FILL DL_R7         ; pointer to DEAL R7 save slot
PDL_TABSZ   .FILL A_TABSZ       ; pointer to TAB_SZ base address
PDL_FNDTOP  .FILL A_FNDTOP      ; pointer to FOUND_TOP base address
PDL_FNDSUT  .FILL A_FNDSUT      ; pointer to FOUND_SUIT base address
PDL_WASTE   .FILL A_WASTE       ; pointer to WASTE_TOP address
PDL_EMPTY   .FILL C_EMPTY       ; pointer to empty sentinel (xFF)
PDL_DECK    .FILL A_DECK        ; pointer to DECK base address
PDL_TABDAT  .FILL A_TABDAT      ; pointer to TAB_DATA base address
PDL_FACEDN  .FILL C_FACEDN      ; pointer to face-down mask (x0080)
PDL_STOCK   .FILL A_STOCK       ; pointer to STOCK base address
PDL_NEG24   .FILL NEG_24        ; pointer to -24 constant
PDL_STKTOP  .FILL A_STKTOP      ; pointer to STOCK_TOP address

; ----------------------------------------------------------------
;  DEAL - Distribute shuffled deck to tableau piles and stock
;  Pile k (0-based) receives k+1 cards: first k are face-down,
;  last is face-up. Remaining 24 cards go to STOCK.
;  Face-down cards stored as: real_card | x0080 (bit 7 set).
;  FLIP_TOP strips bit 7 to reveal the card when needed.
;  In:  DECK shuffled
;  Out: TAB_DATA filled, TAB_SZ set, STOCK filled, STOCK_TOP=23
; ----------------------------------------------------------------
DEAL
        LD  R5, PDL_R7          ; R5 = address of DL_R7 save slot
        STR R7, R5, #0          ; save return address

        ; Initialise TAB_SZ[0..6] = 0 (all piles empty)
        LD  R5, PDL_TABSZ       ; R5 = address of A_TABSZ pointer
        LDR R0, R5, #0          ; R0 = base address of TAB_SZ array
        AND R1, R1, #0          ; R1 = 0 (value to store)
        AND R2, R2, #0          ; R2 = 0
        ADD R2, R2, #7          ; R2 = 7 (loop counter for 7 piles)
DL_CSZ  STR R1, R0, #0          ; TAB_SZ[pile] = 0
        ADD R0, R0, #1          ; advance to next TAB_SZ slot
        ADD R2, R2, #-1         ; decrement counter
        BRp DL_CSZ              ; repeat for all 7 piles

        ; Initialise FOUND_TOP[0..3] = -1 (all foundations empty)
        LD  R5, PDL_FNDTOP      ; R5 = address of A_FNDTOP pointer
        LDR R0, R5, #0          ; R0 = base address of FOUND_TOP array
        AND R1, R1, #0          ; R1 = 0
        ADD R1, R1, #-1         ; R1 = -1 (empty foundation sentinel)
        AND R2, R2, #0          ; R2 = 0
        ADD R2, R2, #4          ; R2 = 4 (loop counter for 4 foundations)
DL_CFT  STR R1, R0, #0          ; FOUND_TOP[foundation] = -1
        ADD R0, R0, #1          ; advance to next FOUND_TOP slot
        ADD R2, R2, #-1         ; decrement counter
        BRp DL_CFT              ; repeat for all 4 foundations

        ; Initialise FOUND_SUIT[0..3] = -1 (no suit assigned yet)
        LD  R5, PDL_FNDSUT      ; R5 = address of A_FNDSUT pointer
        LDR R0, R5, #0          ; R0 = base address of FOUND_SUIT array
        AND R1, R1, #0          ; R1 = 0
        ADD R1, R1, #-1         ; R1 = -1 (no suit assigned)
        AND R2, R2, #0          ; R2 = 0
        ADD R2, R2, #4          ; R2 = 4
DL_CST  STR R1, R0, #0          ; FOUND_SUIT[foundation] = -1
        ADD R0, R0, #1          ; advance
        ADD R2, R2, #-1         ; decrement
        BRp DL_CST              ; repeat for all 4

        ; Set WASTE_TOP = C_EMPTY (no waste card yet)
        LD  R5, PDL_WASTE       ; R5 = address of A_WASTE pointer
        LDR R0, R5, #0          ; R0 = address of WASTE_TOP variable
        LD  R5, PDL_EMPTY       ; R5 = address of C_EMPTY constant
        LDR R1, R5, #0          ; R1 = xFF (empty sentinel)
        STR R1, R0, #0          ; WASTE_TOP = xFF

        ; Deal cards to tableau: R5=deck pointer, R3=pile index
        LD  R5, PDL_DECK        ; R5 = address of A_DECK pointer
        LDR R5, R5, #0          ; R5 = base address of DECK array
        AND R3, R3, #0          ; R3 = 0 (current pile, 0-6)

DL_PIL  AND R4, R4, #0          ; R4 = 0
        ADD R4, R4, R3          ; R4 = pile index
        ADD R4, R4, #1          ; R4 = cards to deal to this pile (pile+1)

DL_CRD  ; Compute absolute address in TAB_DATA for this card slot
        ; Address = TAB_DATA_BASE + pile*20 + card_index_within_pile
        ADD R0, R3, R3          ; R0 = pile * 2
        ADD R1, R0, R0          ; R1 = pile * 4
        ADD R1, R1, R1          ; R1 = pile * 8
        ADD R1, R1, R1          ; R1 = pile * 16
        ADD R0, R0, R0          ; R0 = pile * 4 (reuse for *20 = *16 + *4)
        ADD R1, R1, R0          ; R1 = pile * 20
        ADD R0, R3, #1          ; R0 = pile + 1 (total cards this pile)
        NOT R2, R4              ; R2 = NOT R4
        ADD R2, R2, #1          ; R2 = -R4
        ADD R0, R0, R2          ; R0 = (pile+1) - R4 = card index (0-based within pile)
        ADD R1, R1, R0          ; R1 = pile*20 + card_index
        LD  R0, PDL_TABDAT      ; R0 = address of A_TABDAT pointer
        LDR R0, R0, #0          ; R0 = base address of TAB_DATA
        ADD R1, R1, R0          ; R1 = absolute address of this card's slot

        LDR R0, R5, #0          ; R0 = next card from deck
        ADD R5, R5, #1          ; advance deck pointer
        ADD R2, R4, #-1         ; R2 = R4 - 1 (is this the last card?)
        BRz DL_FUP              ; if zero, this is last card -> face-up
        LD  R2, PDL_FACEDN      ; R2 = address of C_FACEDN mask
        LDR R2, R2, #0          ; R2 = x0080 (face-down bit)
        ADD R0, R0, R2          ; card = real_value | x0080 (mark face-down)

DL_FUP  STR R0, R1, #0          ; store card into TAB_DATA slot

        ; Increment TAB_SZ[pile]
        LD  R0, PDL_TABSZ       ; R0 = address of A_TABSZ pointer
        LDR R0, R0, #0          ; R0 = base address of TAB_SZ
        ADD R0, R0, R3          ; R0 = address of TAB_SZ[pile]
        LDR R1, R0, #0          ; R1 = current pile size
        ADD R1, R1, #1          ; R1 = pile size + 1
        STR R1, R0, #0          ; TAB_SZ[pile] = new size

        ADD R4, R4, #-1         ; decrement cards-remaining counter
        BRp DL_CRD              ; if more cards for this pile, loop

        ADD R3, R3, #1          ; next pile
        ADD R0, R3, #-7         ; R0 = pile - 7
        BRn DL_PIL              ; if pile < 7, deal next pile

        ; Copy remaining 24 cards to STOCK
        LD  R0, PDL_STOCK       ; R0 = address of A_STOCK pointer
        LDR R0, R0, #0          ; R0 = base address of STOCK array
        LD  R2, PDL_NEG24       ; R2 = address of NEG_24
        LDR R2, R2, #0          ; R2 = -24 (loop counter)

DL_STK  LDR R3, R5, #0          ; R3 = next card from deck
        STR R3, R0, #0          ; STOCK[slot] = card
        ADD R5, R5, #1          ; advance deck pointer
        ADD R0, R0, #1          ; advance stock pointer
        ADD R2, R2, #1          ; increment counter (towards 0)
        BRn DL_STK              ; loop while counter < 0 (24 times)

        ; Set STOCK_TOP = 23 (index of top card, 0-based)
        LD  R0, PDL_STKTOP      ; R0 = address of A_STKTOP pointer
        LDR R0, R0, #0          ; R0 = address of STOCK_TOP variable
        AND R1, R1, #0          ; R1 = 0
        ADD R1, R1, #15         ; R1 = 15
        ADD R1, R1, #8          ; R1 = 23 (15+8, can't do 23 in one immediate)
        STR R1, R0, #0          ; STOCK_TOP = 23

        LD  R5, PDL_R7          ; R5 = address of DL_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return to MAIN

; ================================================================
;  BLOCK 5: DISPLAY section  (x3430)
;  PRINT_STATE, PRINT_CARD, EBYTE, GET_INPUT
; ================================================================

; Local pointer table for PRINT_STATE
PPS_R7      .FILL PS_R7         ; pointer to PRINT_STATE R7 save slot
PPS_STKTOP  .FILL A_STKTOP      ; pointer to STOCK_TOP address
PPS_STOCK   .FILL A_STOCK       ; pointer to STOCK base address
PPS_WASTE   .FILL A_WASTE       ; pointer to WASTE_TOP address
PPS_FNDTOP  .FILL A_FNDTOP      ; pointer to FOUND_TOP base address
PPS_TABSZ   .FILL A_TABSZ       ; pointer to TAB_SZ base address
PPS_TABDAT  .FILL A_TABDAT      ; pointer to TAB_DATA base address
PPS_C_NL    .FILL C_NL          ; pointer to newline character
PPS_C_SPC   .FILL C_SPACE       ; pointer to space character
PPS_PCARD   .FILL PRINT_CARD    ; address of PRINT_CARD subroutine
PPS_SVPILE  .FILL PS_PILE_SV    ; pointer to pile-counter save slot
PPS_SVMAX   .FILL PS_MAX_SV     ; pointer to max-size save slot
PPS_SVROW   .FILL PS_ROW_SV     ; pointer to row-counter save slot
PS_PILE_SV  .BLKW 1             ; scratch: saves R3 (pile counter) across PRINT_CARD calls
PS_MAX_SV   .BLKW 1             ; scratch: saves R4 (max pile size) across PRINT_CARD calls
PS_ROW_SV   .BLKW 1             ; scratch: saves R2 (row counter) across PRINT_CARD calls

; ----------------------------------------------------------------
;  PRINT_STATE - Render the complete game board to the console
;  Layout:
;    STOCK:[XS] WASTE:[XS]   FOUND:[XS][XS][XS][XS]
;    T1    T2    T3    T4    T5    T6    T7
;    row by row, [**]=face-down, [  ]=empty
;  In:  game arrays
;  Out: board printed to console
; ----------------------------------------------------------------
PRINT_STATE
        LD  R5, PPS_R7          ; R5 = address of PS_R7 save slot
        STR R7, R5, #0          ; save return address

        ; Print stock
        LEA R0, DPS_STKS        ; R0 = address of "STOCK:" string
        TRAP x22                ; PUTS: print "STOCK:"
        LD  R0, PPS_STKTOP      ; R0 = address of A_STKTOP pointer
        LDR R0, R0, #0          ; R0 = address of STOCK_TOP variable
        LDR R1, R0, #0          ; R1 = STOCK_TOP value (-1 if empty)
        BRn DPS_SKE             ; if negative, stock is empty
        LD  R2, PPS_STOCK       ; R2 = address of A_STOCK pointer
        LDR R2, R2, #0          ; R2 = base address of STOCK array
        ADD R2, R2, R1          ; R2 = address of top stock card
        LDR R1, R2, #0          ; R1 = top stock card value
        LD  R5, PPS_PCARD       ; R5 = address of PRINT_CARD
        JSRR R5                 ; print the stock card as [RS]
        BRnzp DPS_WST           ; skip the empty placeholder

DPS_SKE LEA R0, DPS_MTCD        ; R0 = address of "[  ]" string
        TRAP x22                ; PUTS: print empty card placeholder

        ; Print waste
DPS_WST LEA R0, DPS_WSTS        ; R0 = address of " WASTE:" string
        TRAP x22                ; PUTS: print " WASTE:"
        LD  R0, PPS_WASTE       ; R0 = address of A_WASTE pointer
        LDR R0, R0, #0          ; R0 = address of WASTE_TOP variable
        LDR R1, R0, #0          ; R1 = waste card value (xFF if empty)
        LD  R5, PPS_PCARD       ; R5 = address of PRINT_CARD
        JSRR R5                 ; print waste card (handles xFF as [  ])

        ; Print foundations (4 piles, suits 0-3)
        LEA R0, DPS_FNDS        ; R0 = address of "   FOUND:" string
        TRAP x22                ; PUTS: print foundation header
        AND R3, R3, #0          ; R3 = 0, foundation index

DPS_FLP LD  R0, PPS_FNDTOP      ; R0 = address of A_FNDTOP pointer
        LDR R0, R0, #0          ; R0 = base address of FOUND_TOP
        ADD R0, R0, R3          ; R0 = address of FOUND_TOP[foundation]
        LDR R1, R0, #0          ; R1 = top rank (-1 if empty)
        BRn DPS_FEM             ; if -1, foundation is empty
        ADD R2, R3, R3          ; R2 = suit * 2
        ADD R2, R2, R2          ; R2 = suit * 4
        ADD R2, R2, R2          ; R2 = suit * 8
        ADD R2, R2, R2          ; R2 = suit * 16 = suit<<4
        ADD R1, R1, R2          ; R1 = (suit<<4) | rank = encoded card word
        LD  R5, PPS_SVROW       ; R5 = address of row save slot
        STR R2, R5, #0          ; save R2 (suit bits) since PRINT_CARD clobbers it
        LD  R5, PPS_SVPILE      ; R5 = address of pile save slot
        STR R3, R5, #0          ; save R3 (foundation index) since PRINT_CARD clobbers it
        LD  R5, PPS_PCARD       ; R5 = address of PRINT_CARD
        JSRR R5                 ; print the foundation top card
        LD  R5, PPS_SVROW       ; R5 = address of row save slot
        LDR R2, R5, #0          ; restore R2
        LD  R5, PPS_SVPILE      ; R5 = address of pile save slot
        LDR R3, R5, #0          ; restore R3 (foundation index)
        BRnzp DPS_FNX           ; skip empty placeholder

DPS_FEM LEA R0, DPS_MTCD        ; R0 = address of "[  ]" string
        TRAP x22                ; PUTS: print empty foundation

DPS_FNX ADD R3, R3, #1          ; next foundation
        ADD R0, R3, #-4         ; R0 = foundation - 4
        BRn DPS_FLP             ; if < 4, print next foundation

        ; Newline then tableau header
        LD  R0, PPS_C_NL        ; R0 = address of newline
        LDR R0, R0, #0          ; R0 = newline char
        TRAP x21                ; OUT: newline
        LEA R0, DPS_HDR         ; R0 = address of "T1  T2 ..." header
        TRAP x22                ; PUTS: print column headers

        ; Find maximum pile size (determines how many rows to print)
        AND R4, R4, #0          ; R4 = 0 (will hold max pile size)
        AND R3, R3, #0          ; R3 = 0 (pile index 0-6)

DPS_MXL LD  R0, PPS_TABSZ       ; R0 = address of A_TABSZ pointer
        LDR R0, R0, #0          ; R0 = base of TAB_SZ
        ADD R0, R0, R3          ; R0 = address of TAB_SZ[pile]
        LDR R1, R0, #0          ; R1 = TAB_SZ[pile]
        NOT R2, R4              ; R2 = NOT current max
        ADD R2, R2, #1          ; R2 = -max
        ADD R2, R1, R2          ; R2 = pile_size - max
        BRnz DPS_MXN            ; if pile_size <= max, don't update
        ADD R4, R1, #0          ; max = pile_size

DPS_MXN ADD R3, R3, #1          ; next pile
        ADD R0, R3, #-7         ; R0 = pile - 7
        BRn DPS_MXL             ; if pile < 7, check next

        ; Print tableau rows 0..max-1
        AND R2, R2, #0          ; R2 = 0 (current row index)

DPS_ROW AND R3, R3, #0          ; R3 = 0 (current pile index for this row)

DPS_COL LD  R0, PPS_TABSZ       ; R0 = address of A_TABSZ pointer
        LDR R0, R0, #0          ; R0 = base of TAB_SZ
        ADD R0, R0, R3          ; R0 = address of TAB_SZ[pile]
        LDR R1, R0, #0          ; R1 = number of cards in this pile
        NOT R0, R2              ; R0 = NOT row
        ADD R0, R0, #1          ; R0 = -row
        ADD R0, R1, R0          ; R0 = pile_size - row
        BRnz DPS_EMP            ; if pile_size <= row, this cell is empty

        ; Compute address: TAB_DATA + pile*20 + row
        ADD R1, R3, R3          ; R1 = pile * 2
        ADD R0, R1, R1          ; R0 = pile * 4
        ADD R0, R0, R0          ; R0 = pile * 8
        ADD R0, R0, R0          ; R0 = pile * 16
        ADD R1, R1, R1          ; R1 = pile * 4
        ADD R0, R0, R1          ; R0 = pile * 20
        ADD R0, R0, R2          ; R0 = pile*20 + row
        LD  R1, PPS_TABDAT      ; R1 = address of A_TABDAT pointer
        LDR R1, R1, #0          ; R1 = base address of TAB_DATA
        ADD R0, R0, R1          ; R0 = absolute address of card slot
        LDR R1, R0, #0          ; R1 = card value at this slot

        ; Save R2,R3,R4 before PRINT_CARD (it clobbers them)
        LD  R5, PPS_SVROW       ; R5 = address of row save slot
        STR R2, R5, #0          ; save current row counter
        LD  R5, PPS_SVPILE      ; R5 = address of pile save slot
        STR R3, R5, #0          ; save current pile counter
        LD  R5, PPS_SVMAX       ; R5 = address of max save slot
        STR R4, R5, #0          ; save max pile size
        LD  R5, PPS_PCARD       ; R5 = address of PRINT_CARD
        JSRR R5                 ; print this card as [RS] or [**]
        ; Restore R2,R3,R4 after PRINT_CARD
        LD  R5, PPS_SVROW       ; R5 = address of row save slot
        LDR R2, R5, #0          ; restore row counter
        LD  R5, PPS_SVPILE      ; R5 = address of pile save slot
        LDR R3, R5, #0          ; restore pile counter
        LD  R5, PPS_SVMAX       ; R5 = address of max save slot
        LDR R4, R5, #0          ; restore max pile size
        BRnzp DPS_PAD           ; jump to padding

DPS_EMP LEA R0, DPS_BLK         ; R0 = address of "      " (6 spaces = card width)
        TRAP x22                ; PUTS: print blank for empty cell

DPS_PAD LD  R0, PPS_C_SPC       ; R0 = address of space character
        LDR R0, R0, #0          ; R0 = space char
        TRAP x21                ; OUT: print space between columns
        TRAP x21
        ADD R3, R3, #1          ; next pile
        ADD R0, R3, #-7         ; R0 = pile - 7
        BRn DPS_COL             ; if pile < 7, print next column

        ; End of row: newline and advance row counter
        LD  R0, PPS_C_NL        ; R0 = address of newline
        LDR R0, R0, #0          ; R0 = newline char
        TRAP x21                ; OUT: newline
        ADD R2, R2, #1          ; row++
        NOT R0, R4              ; R0 = NOT max
        ADD R0, R0, #1          ; R0 = -max
        ADD R0, R2, R0          ; R0 = row - max
        BRn DPS_ROW             ; if row < max, print another row

        LD  R5, PPS_R7          ; R5 = address of PS_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return to MAIN

; Strings for PRINT_STATE (placed after RET, within range of LEA)
DPS_STKS .STRINGZ "STOCK:"
DPS_WSTS .STRINGZ " WASTE:"
DPS_FNDS .STRINGZ "   FOUND:"
DPS_HDR  .STRINGZ "\nT1    T2    T3    T4    T5    T6    T7\n"
DPS_BLK  .STRINGZ "    "       ; 4 spaces + 2 from pading = 6 to align empty column
DPS_MTCD .STRINGZ "[  ]"       ; empty card display

; Local pointer table for PRINT_CARD
PPC_R7      .FILL PC_R7         ; pointer to PRINT_CARD R7 save slot
PPC_EMPTY   .FILL C_EMPTY       ; pointer to empty sentinel (xFF)
PPC_FACEDN  .FILL C_FACEDN      ; pointer to face-down mask (x0080)
PPC_LBR     .FILL C_LBR         ; pointer to '[' character
PPC_RBR     .FILL C_RBR         ; pointer to ']' character
PPC_SPACE   .FILL C_SPACE       ; pointer to space character
PPC_STAR    .FILL C_STAR        ; pointer to '*' character
PPC_MRNK    .FILL MASK_RNK      ; pointer to rank mask (x000F)
PPC_MSUT    .FILL MASK_SUT      ; pointer to suit mask (x0030)
PPC_RANKCH  .FILL RANK_CH       ; address of rank character table
PPC_NEG32   .FILL NEG_32        ; pointer to -32 (for Hearts suit detection)
PPC_SCLB    .FILL STR_CLB       ; address of pre-built Clubs string (♣)
PPC_SDIA    .FILL STR_DIA       ; address of pre-built Diamonds string (♦)
PPC_SHRT    .FILL STR_HRT       ; address of pre-built Hearts string (♥)
PPC_SSPA    .FILL STR_SPA       ; address of pre-built Spades string (♠)

; ----------------------------------------------------------------
;  PRINT_CARD - Print one card as [RS] where R=rank S=suit symbol
;  Special: xFF -> "[  ]" (empty),  x0080 flag -> "[**]" (face-down)
;  In:  R1 = card word (encoded as (suit<<4)|rank, or sentinel)
;  Out: characters printed to console
; ----------------------------------------------------------------
PRINT_CARD
        LD  R5, PPC_R7          ; R5 = address of PC_R7 save slot
        STR R7, R5, #0          ; save return address
        LD  R0, PPC_LBR         ; R0 = address of '[' constant
        LDR R0, R0, #0          ; R0 = '[' char value
        TRAP x21                ; OUT: print opening bracket

        ; Check for empty slot (card == xFF = 255)
        LD  R2, PPC_EMPTY       ; R2 = address of C_EMPTY (xFF)
        LDR R2, R2, #0          ; R2 = xFF = 255
        NOT R2, R2              ; R2 = NOT xFF = xFF00 = -256
        ADD R2, R2, #1          ; R2 = -255
        ADD R2, R1, R2          ; R2 = card - xFF
        BRz DPC_EMP             ; if zero, card is empty -> print "  "

        ; Check for face-down (bit 7 set: card AND x0080 != 0)
        LD  R2, PPC_FACEDN      ; R2 = address of C_FACEDN (x0080)
        LDR R2, R2, #0          ; R2 = x0080 (face-down bit mask)
        AND R2, R1, R2          ; isolate bit 7 of card
        BRnp DPC_FDN            ; if nonzero, card is face-down -> print "**"

        ; Print rank character: look up RANK_CH[rank]
        LD  R2, PPC_MRNK        ; R2 = address of rank mask
        LDR R2, R2, #0          ; R2 = x000F
        AND R2, R1, R2          ; R2 = rank (bits 3-0), value 0-12
        LD  R3, PPC_RANKCH      ; R3 = base address of RANK_CH table
        ADD R3, R3, R2          ; R3 = address of RANK_CH[rank]
        LDR R0, R3, #0          ; R0 = rank character ('A','2'..'9','T','J','Q','K')
        TRAP x21                ; OUT: print rank character

        ; Print suit symbol using UTF-8 bytes via EBYTE
        LD  R2, PPC_MSUT        ; R2 = address of suit mask
        LDR R2, R2, #0          ; R2 = x0030
        AND R2, R1, R2          ; R2 = suit bits (0=Clubs, 16=Diamonds, 32=Hearts, 48=Spades)
        BRz DPC_CLB             ; if 0, Clubs
        ADD R3, R2, #-16        ; R3 = suit_bits - 16
        BRz DPC_DIA             ; if 0, Diamonds
        LD  R3, PPC_NEG32       ; R3 = address of -32 constant
        LDR R3, R3, #0          ; R3 = -32
        ADD R3, R2, R3          ; R3 = suit_bits - 32
        BRz DPC_HRT             ; if 0, Hearts
        BRnzp DPC_SPA           ; otherwise Spades

DPC_CLB LD  R0, PPC_SCLB        ; ♣ Clubs: load address of pre-built string
        TRAP x22                ; PUTS: emit E2 99 A3 (♣) atomically
        BRnzp DPC_END           ; done with suit

DPC_DIA LD  R0, PPC_SDIA        ; ♦ Diamonds: load address of pre-built string
        TRAP x22                ; PUTS: emit E2 99 A6 (♦) atomically
        BRnzp DPC_END           ; done with suit

DPC_HRT LD  R0, PPC_SHRT        ; ♥ Hearts: load address of pre-built string
        TRAP x22                ; PUTS: emit E2 99 A5 (♥) atomically
        BRnzp DPC_END           ; done with suit

DPC_SPA LD  R0, PPC_SSPA        ; ♠ Spades: load address of pre-built string
        TRAP x22                ; PUTS: emit E2 99 A0 (♠) atomically
        BRnzp DPC_END           ; done with suit

DPC_EMP LD  R0, PPC_SPACE       ; empty card: print two spaces
        LDR R0, R0, #0          ; R0 = space char
        TRAP x21                ; OUT: first space
        TRAP x21                ; OUT: second space
        BRnzp DPC_END           ; done

DPC_FDN LD  R0, PPC_STAR        ; face-down card: print two asterisks
        LDR R0, R0, #0          ; R0 = '*' char
        TRAP x21                ; OUT: first asterisk
        TRAP x21                ; OUT: second asterisk

DPC_END LD  R0, PPC_RBR         ; print closing bracket
        LDR R0, R0, #0          ; R0 = ']' char
        TRAP x21                ; OUT: print ']'
        LD  R5, PPC_R7          ; R5 = address of PC_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return to caller

; Local pointer table for EBYTE
PEB_R7      .FILL EB_R7         ; pointer to EBYTE R7 save slot

; ----------------------------------------------------------------
;  EBYTE - Emit the low 8 bits of R0 via TRAP x21
;  TRAP x21 only sends R0[7:0], so this sends one raw byte.
;  Used to emit individual bytes of UTF-8 suit symbols.
;  In:  R0 = byte value to emit
;  Out: byte printed to console
; ----------------------------------------------------------------
EBYTE
        LD  R5, PEB_R7          ; R5 = address of EB_R7 save slot
        STR R7, R5, #0          ; save return address
        TRAP x21                ; OUT: emit low byte of R0
        LD  R5, PEB_R7          ; R5 = address of EB_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return to PRINT_CARD

; Local pointer table for GET_INPUT
PGI_R7      .FILL GI_R7         ; pointer to GET_INPUT R7 save slot
PGI_C_NL    .FILL C_NL          ; pointer to newline character
PGI_INBUF   .FILL INBUF         ; pointer to input buffer address

; ----------------------------------------------------------------
;  GET_INPUT - Read one line from keyboard into INBUF
;  Echoes each character, stops at newline, null-terminates.
;  In:  nothing
;  Out: INBUF filled with command string, null-terminated
; ----------------------------------------------------------------
GET_INPUT
        LD  R5, PGI_R7          ; R5 = address of GI_R7 save slot
        STR R7, R5, #0          ; save return address
        LEA R0, GI_PRM          ; R0 = address of prompt string
        TRAP x22                ; PUTS: print "\n> "
        LD  R1, PGI_INBUF       ; R1 = address of INBUF pointer
        LDR R1, R1, #0          ; R1 = base address of INBUF (write pointer)

GI_LP   TRAP x20                ; GETC: read one character -> R0
        TRAP x21                ; OUT: echo character back to console
        LD  R2, PGI_C_NL        ; R2 = address of newline constant
        LDR R2, R2, #0          ; R2 = newline char (x0A)
        NOT R2, R2              ; R2 = NOT newline
        ADD R2, R2, #1          ; R2 = -newline
        ADD R2, R0, R2          ; R2 = char - newline
        BRz GI_DN               ; if zero, user pressed Enter
        STR R0, R1, #0          ; INBUF[pos] = char
        ADD R1, R1, #1          ; advance write pointer
        BRnzp GI_LP             ; read next character

GI_DN   AND R0, R0, #0          ; R0 = 0 (null terminator)
        STR R0, R1, #0          ; INBUF[pos] = '\0' (null-terminate string)
        LD  R5, PGI_R7          ; R5 = address of GI_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return to MAIN

GI_PRM  .STRINGZ "\n> "         ; command prompt

; ================================================================
;  BLOCK 6: INPUT section  (x3580) - PARSE_MOVE
; ================================================================

; Local pointer table for PARSE_MOVE
PPM_R7      .FILL PM_R7         ; pointer to PARSE_MOVE R7 save slot
PPM_MTYPE   .FILL MTYPE         ; pointer to MTYPE variable
PPM_MSRC    .FILL MSRC          ; pointer to MSRC variable
PPM_MDST    .FILL MDST          ; pointer to MDST variable
PPM_MCNT    .FILL MCNT          ; pointer to MCNT variable
PPM_INBUF   .FILL INBUF         ; pointer to input buffer
PPM_CHD     .FILL CH_D          ; pointer to 'D' char constant
PPM_CHR     .FILL CH_R          ; pointer to 'R' char constant
PPM_CHQ     .FILL CH_Q          ; pointer to 'Q' char constant
PPM_CHW     .FILL CH_W          ; pointer to 'W' char constant
PPM_CHT     .FILL CH_T          ; pointer to 'T' char constant
PPM_CHF     .FILL CH_F          ; pointer to 'F' char constant
PPM_DRAW    .FILL MV_DRAW       ; pointer to draw move type (0)
PPM_RST     .FILL MV_RST        ; pointer to reset move type (5)
PPM_QUIT    .FILL MV_QUIT       ; pointer to quit move type (6)
PPM_WTAB    .FILL MV_WTAB       ; pointer to waste->tab type (3)
PPM_WFND    .FILL MV_WFND       ; pointer to waste->found type (4)
PPM_TFND    .FILL MV_TFND       ; pointer to tab->found type (1)
PPM_TTAB    .FILL MV_TTAB       ; pointer to tab->tab type (2)
PPM_NEGx30  .FILL NEG_x30       ; pointer to -48 (ASCII digit to int)

; ----------------------------------------------------------------
;  PARSE_MOVE - Decode INBUF command string into MTYPE,MSRC,MDST,MCNT
;  Sets MTYPE=-1 if command is unrecognised.
;  Valid commands: D  R  Q  Tn Fm  Tn Tm k  W Tn  W Fn
;  In:  INBUF = null-terminated command string
;  Out: MTYPE, MSRC, MDST, MCNT set appropriately
; ----------------------------------------------------------------
PARSE_MOVE
        LD  R5, PPM_R7          ; R5 = address of PM_R7 save slot
        STR R7, R5, #0          ; save return address

        ; Set defaults: MTYPE=-1, MSRC=0, MDST=0, MCNT=1
        AND R0, R0, #0          ; R0 = 0
        ADD R0, R0, #-1         ; R0 = -1 (invalid)
        LD  R5, PPM_MTYPE       ; R5 = address of MTYPE
        STR R0, R5, #0          ; MTYPE = -1
        AND R0, R0, #0          ; R0 = 0
        LD  R5, PPM_MSRC        ; R5 = address of MSRC
        STR R0, R5, #0          ; MSRC = 0
        LD  R5, PPM_MDST        ; R5 = address of MDST
        STR R0, R5, #0          ; MDST = 0
        ADD R0, R0, #1          ; R0 = 1
        LD  R5, PPM_MCNT        ; R5 = address of MCNT
        STR R0, R5, #0          ; MCNT = 1 (default move count)

        LD  R1, PPM_INBUF       ; R1 = address of INBUF pointer
        LDR R1, R1, #0          ; R1 = base address of INBUF
        LDR R0, R1, #0          ; R0 = first character of command

        ; Test for 'D' (Draw)
        LD  R2, PPM_CHD         ; R2 = address of 'D' constant
        LDR R2, R2, #0          ; R2 = 'D' char value
        NOT R2, R2              ; R2 = NOT 'D'
        ADD R2, R2, #1          ; R2 = -'D'
        ADD R2, R0, R2          ; R2 = char - 'D'
        BRnp IPM_ND             ; not 'D', try next
        LD  R5, PPM_DRAW        ; R5 = address of MV_DRAW
        LDR R2, R5, #0          ; R2 = 0 (draw type)
        LD  R5, PPM_MTYPE       ; R5 = address of MTYPE
        STR R2, R5, #0          ; MTYPE = 0 (draw)
        BRnzp IPM_DN            ; done parsing

IPM_ND  ; Test for 'R' (Reset)
        LD  R2, PPM_CHR         ; R2 = address of 'R' constant
        LDR R2, R2, #0          ; R2 = 'R'
        NOT R2, R2              ; R2 = NOT 'R'
        ADD R2, R2, #1          ; R2 = -'R'
        ADD R2, R0, R2          ; R2 = char - 'R'
        BRnp IPM_NR             ; not 'R', try next
        LD  R5, PPM_RST         ; R5 = address of MV_RST
        LDR R2, R5, #0          ; R2 = 5 (reset type)
        LD  R5, PPM_MTYPE       ; R5 = address of MTYPE
        STR R2, R5, #0          ; MTYPE = 5 (reset)
        BRnzp IPM_DN            ; done

IPM_NR  ; Test for 'Q' (Quit)
        LD  R2, PPM_CHQ         ; R2 = address of 'Q' constant
        LDR R2, R2, #0          ; R2 = 'Q'
        NOT R2, R2              ; R2 = NOT 'Q'
        ADD R2, R2, #1          ; R2 = -'Q'
        ADD R2, R0, R2          ; R2 = char - 'Q'
        BRnp IPM_NQ             ; not 'Q', try next
        LD  R5, PPM_QUIT        ; R5 = address of MV_QUIT
        LDR R2, R5, #0          ; R2 = 6 (quit type)
        LD  R5, PPM_MTYPE       ; R5 = address of MTYPE
        STR R2, R5, #0          ; MTYPE = 6 (quit)
        BRnzp IPM_DN            ; done

IPM_NQ  ; Test for 'W' (Waste move: "W Tn" or "W Fn")
        LD  R2, PPM_CHW         ; R2 = address of 'W' constant
        LDR R2, R2, #0          ; R2 = 'W'
        NOT R2, R2              ; R2 = NOT 'W'
        ADD R2, R2, #1          ; R2 = -'W'
        ADD R2, R0, R2          ; R2 = char - 'W'
        BRnp IPM_NW             ; not 'W', try next
        LDR R0, R1, #2          ; R0 = INBUF[2] ('T' or 'F')
        LDR R3, R1, #3          ; R3 = INBUF[3] (destination digit)
        LD  R2, PPM_NEGx30      ; R2 = address of -48 constant
        LDR R2, R2, #0          ; R2 = -48
        ADD R3, R3, R2          ; R3 = digit char - '0' = digit value
        ADD R3, R3, #-1         ; R3 = digit - 1 (convert to 0-based index)
        LD  R5, PPM_MDST        ; R5 = address of MDST
        STR R3, R5, #0          ; MDST = destination index
        LD  R2, PPM_CHT         ; R2 = address of 'T' constant
        LDR R2, R2, #0          ; R2 = 'T'
        NOT R2, R2              ; R2 = NOT 'T'
        ADD R2, R2, #1          ; R2 = -'T'
        ADD R2, R0, R2          ; R2 = INBUF[2] - 'T'
        BRnp IPM_WF             ; not 'T', must be 'F' (foundation)
        LD  R5, PPM_WTAB        ; R5 = address of MV_WTAB
        LDR R2, R5, #0          ; R2 = 3 (waste->tableau type)
        LD  R5, PPM_MTYPE       ; R5 = address of MTYPE
        STR R2, R5, #0          ; MTYPE = 3
        BRnzp IPM_DN            ; done

IPM_WF  LD  R5, PPM_WFND        ; R5 = address of MV_WFND
        LDR R2, R5, #0          ; R2 = 4 (waste->foundation type)
        LD  R5, PPM_MTYPE       ; R5 = address of MTYPE
        STR R2, R5, #0          ; MTYPE = 4
        BRnzp IPM_DN            ; done

IPM_NW  ; Test for 'T' (Tableau source: "Tn Fm" or "Tn Tm k")
        LD  R2, PPM_CHT         ; R2 = address of 'T' constant
        LDR R2, R2, #0          ; R2 = 'T'
        NOT R2, R2              ; R2 = NOT 'T'
        ADD R2, R2, #1          ; R2 = -'T'
        ADD R2, R0, R2          ; R2 = char - 'T'
        BRnp IPM_DN             ; not 'T' either -> unrecognised, MTYPE stays -1

        LDR R0, R1, #1          ; R0 = INBUF[1] (source pile digit)
        LD  R2, PPM_NEGx30      ; R2 = address of -48
        LDR R2, R2, #0          ; R2 = -48
        ADD R0, R0, R2          ; R0 = digit - '0'
        ADD R0, R0, #-1         ; R0 -= 1 (convert to 0-based)
        LD  R5, PPM_MSRC        ; R5 = address of MSRC
        STR R0, R5, #0          ; MSRC = source pile index

        LDR R0, R1, #3          ; R0 = INBUF[3] ('T' or 'F')
        LDR R3, R1, #4          ; R3 = INBUF[4] (destination digit)
        LD  R2, PPM_NEGx30      ; R2 = address of -48
        LDR R2, R2, #0          ; R2 = -48
        ADD R3, R3, R2          ; R3 = dest digit value
        ADD R3, R3, #-1         ; R3 -= 1 (0-based)
        LD  R5, PPM_MDST        ; R5 = address of MDST
        STR R3, R5, #0          ; MDST = destination index

        LD  R2, PPM_CHF         ; R2 = address of 'F' constant
        LDR R2, R2, #0          ; R2 = 'F'
        NOT R2, R2              ; R2 = NOT 'F'
        ADD R2, R2, #1          ; R2 = -'F'
        ADD R2, R0, R2          ; R2 = INBUF[3] - 'F'
        BRnp IPM_TT             ; not 'F', must be 'T' (tab->tab)
        LD  R5, PPM_TFND        ; R5 = address of MV_TFND
        LDR R2, R5, #0          ; R2 = 1 (tab->foundation)
        LD  R5, PPM_MTYPE       ; R5 = address of MTYPE
        STR R2, R5, #0          ; MTYPE = 1
        BRnzp IPM_DN            ; done

IPM_TT  LD  R5, PPM_TTAB        ; R5 = address of MV_TTAB
        LDR R2, R5, #0          ; R2 = 2 (tab->tab)
        LD  R5, PPM_MTYPE       ; R5 = address of MTYPE
        STR R2, R5, #0          ; MTYPE = 2
        LDR R0, R1, #6          ; R0 = INBUF[6] (optional count digit, 0 if absent)
        BRz IPM_DN              ; if null, no count specified, use default (1)
        LD  R2, PPM_NEGx30      ; R2 = address of -48
        LDR R2, R2, #0          ; R2 = -48
        ADD R0, R0, R2          ; R0 = count digit value
        LD  R5, PPM_MCNT        ; R5 = address of MCNT
        STR R0, R5, #0          ; MCNT = specified count

IPM_DN  LD  R5, PPM_R7          ; R5 = address of PM_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return to MAIN

; ================================================================
;  BLOCK 7: VALIDATE section  (x3640)
;  VALID_MOVE, VM_TAB_TOP, VM_TAB_KCARD, VM_CHK_FND,
;  VM_CHK_TAB, TABADDR, SUIT_COLOR
; ================================================================

; Local pointer table for VALIDATE section
PVM_R7      .FILL VM_R7         ; pointer to VALID_MOVE R7 save slot
PVM_MTYPE   .FILL MTYPE         ; pointer to MTYPE
PVM_DRAW    .FILL MV_DRAW       ; pointer to draw type (0)
PVM_RST     .FILL MV_RST        ; pointer to reset type (5)
PVM_TFND    .FILL MV_TFND       ; pointer to tab->found type (1)
PVM_TTAB    .FILL MV_TTAB       ; pointer to tab->tab type (2)
PVM_WTAB    .FILL MV_WTAB       ; pointer to waste->tab type (3)
PVM_STKTOP  .FILL A_STKTOP      ; pointer to STOCK_TOP address
PVM_WASTE   .FILL A_WASTE       ; pointer to WASTE_TOP address
PVM_EMPTY   .FILL C_EMPTY       ; pointer to empty sentinel
PVM_SCRATCH .FILL SCRATCH_CRD   ; pointer to scratch card variable
PVM_TABTOP  .FILL VM_TAB_TOP    ; address of VM_TAB_TOP helper
PVM_TABKCD  .FILL VM_TAB_KCARD  ; address of VM_TAB_KCARD helper
PVM_CHKFND  .FILL VM_CHK_FND    ; address of VM_CHK_FND helper
PVM_CHKTAB  .FILL VM_CHK_TAB    ; address of VM_CHK_TAB helper
PVM_VT_R7   .FILL VT_R7         ; pointer to VM_TAB_TOP R7 save
PVM_VK_R7   .FILL VK_R7         ; pointer to VM_TAB_KCARD R7 save
PVM_VF_R7   .FILL VF_R7         ; pointer to VM_CHK_FND R7 save
PVM_VC_R7   .FILL VC_R7         ; pointer to VM_CHK_TAB R7 save
PVM_MSRC    .FILL MSRC          ; pointer to MSRC
PVM_MDST    .FILL MDST          ; pointer to MDST
PVM_MCNT    .FILL MCNT          ; pointer to MCNT
PVM_TABSZ   .FILL A_TABSZ       ; pointer to TAB_SZ base address
PVM_FNDTOP  .FILL A_FNDTOP      ; pointer to FOUND_TOP base address
PVM_FNDSUT  .FILL A_FNDSUT      ; pointer to FOUND_SUIT base address
PVM_MSUT    .FILL MASK_SUT      ; pointer to suit mask
PVM_MRNK    .FILL MASK_RNK      ; pointer to rank mask
PVM_TABADDR .FILL TABADDR       ; address of TABADDR helper
PVM_SCOLOR  .FILL SUIT_COLOR    ; address of SUIT_COLOR helper
PVM_TABDAT  .FILL A_TABDAT      ; pointer to TAB_DATA base address

; ----------------------------------------------------------------
;  VALID_MOVE - Check if the current move (MTYPE,MSRC,MDST,MCNT) is legal
;  In:  MTYPE, MSRC, MDST, MCNT set by PARSE_MOVE
;  Out: R0 = 1 if move is legal, R0 = 0 if illegal
; ----------------------------------------------------------------
VALID_MOVE
        LD  R5, PVM_R7          ; R5 = address of VM_R7 save slot
        STR R7, R5, #0          ; save return address
        AND R0, R0, #0          ; R0 = 0 (default: invalid)
        LD  R5, PVM_MTYPE       ; R5 = address of MTYPE
        LDR R1, R5, #0          ; R1 = move type

        ; Check DRAW: valid if stock not empty (STOCK_TOP >= 0)
        LD  R5, PVM_DRAW        ; R5 = address of MV_DRAW
        LDR R2, R5, #0          ; R2 = 0 (draw type)
        NOT R2, R2              ; R2 = -1
        ADD R2, R2, #1          ; R2 = -0 = 0... use NOT+1 pattern for equality test
        ADD R2, R1, R2          ; R2 = MTYPE - MV_DRAW
        BRnp VVM_ND             ; not draw type, try next
        LD  R5, PVM_STKTOP      ; R5 = address of A_STKTOP pointer
        LDR R2, R5, #0          ; R2 = address of STOCK_TOP
        LDR R2, R2, #0          ; R2 = STOCK_TOP value
        BRn VVM_RET             ; if negative, stock empty -> invalid (R0=0)
        ADD R0, R0, #1          ; R0 = 1 (valid)
        BRnzp VVM_RET           ; done

VVM_ND  ; Check RESET: valid if stock empty AND waste has a card
        LD  R5, PVM_RST         ; R5 = address of MV_RST
        LDR R2, R5, #0          ; R2 = 5 (reset type)
        NOT R2, R2              ; negate for comparison
        ADD R2, R2, #1
        ADD R2, R1, R2          ; R2 = MTYPE - MV_RST
        BRnp VVM_NR             ; not reset, try next
        LD  R5, PVM_STKTOP      ; R5 = address of A_STKTOP pointer
        LDR R2, R5, #0          ; R2 = address of STOCK_TOP
        LDR R2, R2, #0          ; R2 = STOCK_TOP
        BRzp VVM_RET            ; if >= 0, stock not empty -> can't reset (R0=0)
        LD  R5, PVM_WASTE       ; R5 = address of A_WASTE pointer
        LDR R2, R5, #0          ; R2 = address of WASTE_TOP
        LDR R2, R2, #0          ; R2 = waste card value
        LD  R5, PVM_EMPTY       ; R5 = address of C_EMPTY
        LDR R3, R5, #0          ; R3 = xFF (empty sentinel)
        NOT R3, R3              ; R3 = NOT xFF
        ADD R3, R3, #1          ; R3 = -xFF
        ADD R3, R2, R3          ; R3 = waste - xFF
        BRz VVM_RET             ; if zero, waste is empty -> invalid (R0=0)
        ADD R0, R0, #1          ; R0 = 1 (valid: stock empty, waste has card)
        BRnzp VVM_RET           ; done

VVM_NR  ; Check TAB->FOUND: top of src pile must fit on foundation
        LD  R5, PVM_TFND        ; R5 = address of MV_TFND
        LDR R2, R5, #0          ; R2 = 1
        NOT R2, R2
        ADD R2, R2, #1
        ADD R2, R1, R2          ; R2 = MTYPE - MV_TFND
        BRnp VVM_NTF            ; not tab->found, try next
        LD  R5, PVM_TABTOP      ; R5 = address of VM_TAB_TOP
        JSRR R5                 ; R0 = top face-up card of MSRC (-1 if empty)
        ADD R2, R0, #0          ; R2 = card; CC set from card value
        BRn VVM_RET_Z           ; if -1, pile empty -> return R0=0
        AND R0, R0, #0          ; R0 = 0 (reset for return value)
        LD  R5, PVM_CHKFND      ; R5 = address of VM_CHK_FND
        JSRR R5                 ; R0 = 1 if card R2 fits on MDST foundation
        BRnzp VVM_RET           ; return result

VVM_NTF ; Check TAB->TAB: moved card(s) must fit on destination pile
        LD  R5, PVM_TTAB        ; R5 = address of MV_TTAB
        LDR R2, R5, #0          ; R2 = 2
        NOT R2, R2
        ADD R2, R2, #1
        ADD R2, R1, R2          ; R2 = MTYPE - MV_TTAB
        BRnp VVM_NTT            ; not tab->tab, try next
        LD  R5, PVM_TABKCD      ; R5 = address of VM_TAB_KCARD
        JSRR R5                 ; R0 = card MCNT from top of MSRC (-1 if invalid)
        ADD R2, R0, #0          ; R2 = card
        AND R0, R0, #0          ; R0 = 0 (reset for return)
        ADD R2, R2, #0          ; set CC
        BRn VVM_RET             ; not enough cards in pile -> invalid
        LD  R5, PVM_SCRATCH     ; R5 = address of SCRATCH_CRD
        STR R2, R5, #0          ; SCRATCH_CRD = card to move
        LD  R5, PVM_CHKTAB      ; R5 = address of VM_CHK_TAB
        JSRR R5                 ; R0 = 1 if SCRATCH_CRD fits on MDST tableau
        BRnzp VVM_RET           ; return result

VVM_NTT ; Check WASTE->TAB: waste card must fit on destination pile
        LD  R5, PVM_WTAB        ; R5 = address of MV_WTAB
        LDR R2, R5, #0          ; R2 = 3
        NOT R2, R2
        ADD R2, R2, #1
        ADD R2, R1, R2          ; R2 = MTYPE - MV_WTAB
        BRnp VVM_NWT            ; not waste->tab, must be waste->found
        LD  R5, PVM_WASTE       ; R5 = address of A_WASTE pointer
        LDR R3, R5, #0          ; R3 = address of WASTE_TOP
        LDR R2, R3, #0          ; R2 = waste card value
        LD  R5, PVM_EMPTY       ; R5 = address of C_EMPTY
        LDR R3, R5, #0          ; R3 = xFF
        NOT R3, R3
        ADD R3, R3, #1          ; R3 = -xFF
        ADD R3, R2, R3          ; R3 = waste - xFF; CC set here
        BRz VVM_RET_Z           ; waste is empty -> return R0=0
        LD  R5, PVM_SCRATCH     ; R5 = address of SCRATCH_CRD
        STR R2, R5, #0          ; SCRATCH_CRD = waste card
        LD  R5, PVM_CHKTAB      ; R5 = address of VM_CHK_TAB
        JSRR R5                 ; R0 = 1 if waste card fits on MDST tableau
        BRnzp VVM_RET           ; return result

VVM_NWT ; WASTE->FOUND: waste card must fit on destination foundation
        LD  R5, PVM_WASTE       ; R5 = address of A_WASTE pointer
        LDR R3, R5, #0          ; R3 = address of WASTE_TOP
        LDR R2, R3, #0          ; R2 = waste card value
        LD  R5, PVM_EMPTY       ; R5 = address of C_EMPTY
        LDR R3, R5, #0          ; R3 = xFF
        NOT R3, R3
        ADD R3, R3, #1          ; R3 = -xFF
        ADD R3, R2, R3          ; R3 = waste - xFF; CC set here
        BRz VVM_RET_Z           ; if zero, waste is empty -> return R0=0
        LD  R5, PVM_CHKFND      ; R5 = address of VM_CHK_FND
        JSRR R5                 ; R0 = 1 if waste card fits on MDST foundation
        BRnzp VVM_RET

VVM_RET_Z
        AND R0, R0, #0          ; R0 = 0 (invalid: waste empty)

VVM_RET LD  R5, PVM_R7          ; R5 = address of VM_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET                     ; return R0=1/0

; ----------------------------------------------------------------
;  VM_TAB_TOP - Get top face-up card of MSRC pile
;  In:  MSRC = pile index
;  Out: R0 = top card value, or -1 if pile is empty
; ----------------------------------------------------------------
VM_TAB_TOP
        LD  R5, PVM_VT_R7       ; R5 = address of VT_R7 save slot
        STR R7, R5, #0          ; save return address
        LD  R5, PVM_MSRC        ; R5 = address of MSRC
        LDR R1, R5, #0          ; R1 = source pile index
        LD  R5, PVM_TABSZ       ; R5 = address of A_TABSZ pointer
        LDR R2, R5, #0          ; R2 = base of TAB_SZ
        ADD R2, R2, R1          ; R2 = address of TAB_SZ[pile]
        LDR R2, R2, #0          ; R2 = size of pile
        ADD R2, R2, #-1         ; R2 = top row index (size-1)
        BRn VTT_EMP             ; if negative, pile is empty
        LD  R5, PVM_TABADDR     ; R5 = address of TABADDR
        JSRR R5                 ; R0 = address of TAB_DATA[pile][top_row]
        LDR R0, R0, #0          ; R0 = card value at top of pile
        BRnzp VTT_RET

VTT_EMP AND R0, R0, #0          ; R0 = 0
        ADD R0, R0, #-1         ; R0 = -1 (pile empty)

VTT_RET LD  R5, PVM_VT_R7       ; R5 = address of VT_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET

; ----------------------------------------------------------------
;  VM_TAB_KCARD - Get card MCNT positions from top of MSRC pile
;  Used for multi-card tab->tab moves.
;  In:  MSRC = pile index, MCNT = count from top
;  Out: R0 = card value, or -1 if not enough cards
; ----------------------------------------------------------------
VM_TAB_KCARD
        LD  R5, PVM_VK_R7       ; R5 = address of VK_R7 save slot
        STR R7, R5, #0          ; save return address
        LD  R5, PVM_MSRC        ; R5 = address of MSRC
        LDR R1, R5, #0          ; R1 = source pile index
        LD  R5, PVM_TABSZ       ; R5 = address of A_TABSZ pointer
        LDR R2, R5, #0          ; R2 = base of TAB_SZ
        ADD R2, R2, R1          ; R2 = address of TAB_SZ[pile]
        LDR R2, R2, #0          ; R2 = pile size
        LD  R5, PVM_MCNT        ; R5 = address of MCNT
        LDR R3, R5, #0          ; R3 = count
        NOT R3, R3              ; R3 = NOT count
        ADD R3, R3, #1          ; R3 = -count
        ADD R2, R2, R3          ; R2 = pile_size - count (row of bottom card to move)
        BRn VTK_EMP             ; if negative, not enough cards
        LD  R5, PVM_TABADDR     ; R5 = address of TABADDR
        JSRR R5                 ; R0 = address of TAB_DATA[pile][row]
        LDR R0, R0, #0          ; R0 = card at that row
        BRnzp VTK_RET

VTK_EMP AND R0, R0, #0          ; R0 = 0
        ADD R0, R0, #-1         ; R0 = -1 (not enough cards)

VTK_RET LD  R5, PVM_VK_R7       ; R5 = address of VK_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET

; ----------------------------------------------------------------
;  VM_CHK_FND - Check if card R2 can go on foundation MDST
;  Rules: suit must match MDST index, rank must be FOUND_TOP[suit]+1
;  (Ace=0 must go on empty foundation, then 2,3...King in order)
;  In:  R2 = card to check, MDST = foundation index (0-3)
;  Out: R0 = 1 if legal, R0 = 0 if not
; ----------------------------------------------------------------
VM_CHK_FND
        LD  R5, PVM_VF_R7       ; R5 = address of VF_R7 save slot
        STR R7, R5, #0          ; save return address

        ; Extract suit index (0-3) from card bits 5-4
        LD  R5, PVM_MSUT        ; R5 = address of suit mask
        LDR R5, R5, #0          ; R5 = x0030
        AND R3, R2, R5          ; R3 = suit bits (0, 16, 32, or 48)
        AND R4, R4, #0          ; R4 = 0 (suit index counter)

VCF_SLP ADD R3, R3, #-16        ; subtract 16 from suit bits
        BRn VCF_SD              ; if negative, we've counted enough
        ADD R4, R4, #1          ; suit index++
        BRnzp VCF_SLP           ; keep counting

VCF_SD  ; R4 = card suit index (0=Clubs, 1=Diamonds, 2=Hearts, 3=Spades)
        ; Extract card rank into R5
        LD  R5, PVM_MRNK        ; R5 = address of rank mask
        LDR R5, R5, #0          ; R5 = x000F
        AND R5, R2, R5          ; R5 = rank of card (0-12)

        ; Get FOUND_TOP[MDST] to check if foundation is empty
        LD  R3, PVM_MDST        ; R3 = address of MDST
        LDR R3, R3, #0          ; R3 = foundation index (0-3)
        LD  R2, PVM_FNDTOP      ; R2 = address of A_FNDTOP pointer
        LDR R2, R2, #0          ; R2 = base of FOUND_TOP
        ADD R2, R2, R3          ; R2 = address of FOUND_TOP[MDST]
        LDR R2, R2, #0          ; R2 = FOUND_TOP[MDST] (-1 if empty)

        ADD R2, R2, #0          ; set CC from FOUND_TOP
        BRn VCF_EMPTY           ; if -1, foundation is empty -> check for Ace

        ; Foundation not empty: card suit must match FOUND_SUIT[MDST]
        LD  R3, PVM_MDST        ; R3 = address of MDST
        LDR R3, R3, #0          ; R3 = foundation index
        LD  R0, PVM_FNDSUT      ; R0 = address of A_FNDSUT pointer
        LDR R0, R0, #0          ; R0 = base of FOUND_SUIT
        ADD R0, R0, R3          ; R0 = address of FOUND_SUIT[MDST]
        LDR R0, R0, #0          ; R0 = suit index recorded for this foundation
        NOT R0, R0              ; R0 = NOT suit
        ADD R0, R0, #1          ; R0 = -suit
        ADD R0, R4, R0          ; R0 = card_suit - foundation_suit
        BRnp VCF_NO             ; suit mismatch -> invalid

        ; Check rank: card rank must be FOUND_TOP[MDST] + 1
        ; R2 was FOUND_TOP[MDST] before we clobbered R2 above - reload
        LD  R3, PVM_MDST
        LDR R3, R3, #0
        LD  R0, PVM_FNDTOP
        LDR R0, R0, #0
        ADD R0, R0, R3
        LDR R2, R0, #0          ; R2 = FOUND_TOP[MDST]
        ADD R2, R2, #1          ; R2 = expected rank
        NOT R5, R5
        ADD R5, R5, #1          ; R5 = -card_rank
        ADD R2, R2, R5          ; R2 = expected - card_rank
        BRnp VCF_NO             ; rank mismatch -> invalid
        BRnzp VCF_YES

VCF_EMPTY
        ; Foundation is empty: only an Ace (rank 0) is accepted
        ADD R5, R5, #0          ; set CC from card rank
        BRnp VCF_NO             ; if rank != 0, not an Ace -> invalid
        ; Ace on empty foundation: valid regardless of suit

VCF_YES AND R0, R0, #0          ; R0 = 0
        ADD R0, R0, #1          ; R0 = 1 (valid)
        BRnzp VCF_RET

VCF_NO  AND R0, R0, #0          ; R0 = 0 (invalid)
VCF_RET LD  R5, PVM_VF_R7       ; R5 = address of VF_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET

; Local pointer table for VM_CHK_TAB (PVM_ table is out of +-256 range from here)
VCT_VC_R7   .FILL VC_R7         ; local: VC_R7 save slot
VCT_MDST    .FILL MDST          ; local: MDST
VCT_TABSZ   .FILL A_TABSZ       ; local: TAB_SZ base address
VCT_TABADDR .FILL TABADDR       ; local: address of TABADDR
VCT_SCRATCH .FILL SCRATCH_CRD   ; local: SCRATCH_CRD
VCT_MRNK    .FILL MASK_RNK      ; local: rank mask
VCT_MSUT    .FILL MASK_SUT      ; local: suit mask
VCT_SCOLOR  .FILL SUIT_COLOR    ; local: address of SUIT_COLOR

; ----------------------------------------------------------------
;  VM_CHK_TAB - Check if SCRATCH_CRD can go on tableau pile MDST
;  Rules: dst must have opposite-color card with rank exactly 1 higher,
;         or be empty (only Kings can go on empty piles).
;  In:  SCRATCH_CRD = card to place, MDST = destination pile
;  Out: R0 = 1 if legal, R0 = 0 if not
; ----------------------------------------------------------------
VM_CHK_TAB
        LD  R5, VCT_VC_R7       ; R5 = address of VC_R7 save slot
        STR R7, R5, #0          ; save return address
        LD  R5, VCT_MDST        ; R5 = address of MDST
        LDR R1, R5, #0          ; R1 = destination pile index
        LD  R5, VCT_TABSZ       ; R5 = address of A_TABSZ pointer
        LDR R3, R5, #0          ; R3 = base of TAB_SZ
        ADD R3, R3, R1          ; R3 = address of TAB_SZ[dst]
        LDR R3, R3, #0          ; R3 = destination pile size
        ADD R3, R3, #-1         ; R3 = top row index (-1 if empty)
        BRn VCT_EMP             ; if empty, only Kings allowed

        ; Get destination top card
        ADD R2, R3, #0          ; R2 = top row index
        LD  R5, VCT_TABADDR     ; R5 = address of TABADDR
        JSRR R5                 ; R0 = address of dst top card
        LDR R3, R0, #0          ; R3 = dst top card value

        ; Check rank: src_rank + 1 must equal dst_rank
        LD  R5, VCT_SCRATCH     ; R5 = address of SCRATCH_CRD
        LDR R4, R5, #0          ; R4 = src card
        LD  R5, VCT_MRNK        ; R5 = address of rank mask
        LDR R5, R5, #0          ; R5 = x000F
        AND R0, R4, R5          ; R0 = src rank
        AND R1, R3, R5          ; R1 = dst rank
        ADD R2, R0, #1          ; R2 = src_rank + 1
        NOT R1, R1              ; R1 = NOT dst_rank
        ADD R1, R1, #1          ; R1 = -dst_rank
        ADD R2, R2, R1          ; R2 = (src_rank+1) - dst_rank
        BRnp VCT_NO             ; if nonzero, ranks don't fit

        ; Check color: src and dst must be opposite colors
        LD  R5, VCT_MSUT        ; R5 = address of suit mask
        LDR R5, R5, #0          ; R5 = x0030
        AND R4, R4, R5          ; R4 = src suit bits
        ADD R1, R4, #0          ; R1 = src suit bits (argument for SUIT_COLOR)
        LD  R5, VCT_SCOLOR      ; R5 = address of SUIT_COLOR
        JSRR R5                 ; R0 = 0 if black, 1 if red
        ADD R4, R0, #0          ; R4 = src color

        LD  R5, VCT_MSUT        ; R5 = address of suit mask
        LDR R5, R5, #0          ; R5 = x0030
        AND R5, R3, R5          ; R5 = dst suit bits
        ADD R1, R5, #0          ; R1 = dst suit bits
        LD  R5, VCT_SCOLOR      ; R5 = address of SUIT_COLOR
        JSRR R5                 ; R0 = dst color
        NOT R5, R0              ; R5 = NOT dst_color
        ADD R5, R5, #1          ; R5 = -dst_color
        ADD R5, R4, R5          ; R5 = src_color - dst_color
        BRz VCT_NO              ; if zero, same color -> invalid

        AND R0, R0, #0          ; R0 = 0
        ADD R0, R0, #1          ; R0 = 1 (valid: opposite color, correct rank)
        BRnzp VCT_RET

; Local pointer table for VCT_EMP/VCT_RET (main PVM_ table is out of range)
VCE_SCRATCH .FILL SCRATCH_CRD   ; local copy: pointer to SCRATCH_CRD
VCE_MRNK    .FILL MASK_RNK      ; local copy: pointer to rank mask
VCE_VC_R7   .FILL VC_R7         ; local copy: pointer to VC_R7 save slot

VCT_EMP ; Empty pile: only a King (rank 12) may be placed
        LD  R5, VCE_SCRATCH     ; R5 = address of SCRATCH_CRD
        LDR R4, R5, #0          ; R4 = src card
        LD  R5, VCE_MRNK        ; R5 = address of rank mask
        LDR R5, R5, #0          ; R5 = x000F
        AND R4, R4, R5          ; R4 = src rank
        ADD R4, R4, #-12        ; R4 = rank - 12 (0 only for King)
        BRnp VCT_NO             ; if nonzero, not a King -> invalid
        AND R0, R0, #0          ; R0 = 0
        ADD R0, R0, #1          ; R0 = 1 (valid: King on empty pile)
        BRnzp VCT_RET

VCT_NO  AND R0, R0, #0          ; R0 = 0 (invalid)
VCT_RET LD  R5, VCE_VC_R7       ; R5 = address of VC_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET

; Local pointer table for TABADDR (placed just before it for range)
TAD_TA_R7   .FILL TA_R7         ; local: TABADDR R7 save slot
TAD_TABDAT  .FILL A_TABDAT      ; local: TAB_DATA base address

TABADDR
        LD  R5, TAD_TA_R7       ; R5 = address of TA_R7 save slot
        STR R7, R5, #0          ; save return address
        ADD R0, R1, R1          ; R0 = pile * 2
        ADD R0, R0, R0          ; R0 = pile * 4
        ADD R0, R0, R0          ; R0 = pile * 8
        ADD R0, R0, R0          ; R0 = pile * 16
        ADD R3, R1, R1          ; R3 = pile * 2
        ADD R3, R3, R3          ; R3 = pile * 4
        ADD R0, R0, R3          ; R0 = pile * 20 (16+4)
        ADD R0, R0, R2          ; R0 = pile*20 + row
        LD  R3, TAD_TABDAT      ; R3 = address of A_TABDAT pointer
        LDR R3, R3, #0          ; R3 = base address of TAB_DATA
        ADD R0, R0, R3          ; R0 = absolute address of card slot
        LD  R5, TAD_TA_R7       ; R5 = address of TA_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET

; Local pointer for SUIT_COLOR
PVM_NEG32   .FILL NEG_32        ; pointer to -32 for Hearts detection
PVM_SC_R7   .FILL SC_R7         ; pointer to SUIT_COLOR R7 save slot

; ----------------------------------------------------------------
;  SUIT_COLOR - Determine if a suit is black or red
;  Clubs(0)=black, Diamonds(16)=red, Hearts(32)=red, Spades(48)=black
;  In:  R1 = suit bits (0, 16, 32, or 48 from MASK_SUT)
;  Out: R0 = 0 if black, R0 = 1 if red
; ----------------------------------------------------------------
SUIT_COLOR
        LD  R5, PVM_SC_R7       ; R5 = address of SC_R7 save slot
        STR R7, R5, #0          ; save return address
        AND R0, R0, #0          ; R0 = 0 (default black)
        ADD R1, R1, #0          ; set condition codes from R1
        BRz VSC_RET             ; if 0 (Clubs), black -> return 0
        ADD R0, R1, #-16        ; R0 = suit_bits - 16
        BRz VSC_RED             ; if 0 (Diamonds=16), red
        LD  R0, PVM_NEG32       ; R0 = address of -32
        LDR R0, R0, #0          ; R0 = -32
        ADD R0, R1, R0          ; R0 = suit_bits - 32
        BRz VSC_RED             ; if 0 (Hearts=32), red
        AND R0, R0, #0          ; Spades(48): black -> R0 = 0
        BRnzp VSC_RET

VSC_RED AND R0, R0, #0          ; R0 = 0
        ADD R0, R0, #1          ; R0 = 1 (red)

VSC_RET LD  R5, PVM_SC_R7       ; R5 = address of SC_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET

; ================================================================
;  BLOCK 8: MOVES section  (x3780)
;  DO_MOVE, MOVE_TAB_TAB, FLIP_TOP, CHECK_WIN, PRINT_WIN
; ================================================================

; Local pointer table for MOVES section
PMV_R7      .FILL DM_R7         ; pointer to DO_MOVE R7 save slot
PMV_MTYPE   .FILL MTYPE         ; pointer to MTYPE
PMV_MSRC    .FILL MSRC          ; pointer to MSRC
PMV_MDST    .FILL MDST          ; pointer to MDST
PMV_MCNT    .FILL MCNT          ; pointer to MCNT
PMV_DRAW    .FILL MV_DRAW       ; pointer to draw type
PMV_RST     .FILL MV_RST        ; pointer to reset type
PMV_TFND    .FILL MV_TFND       ; pointer to tab->found type
PMV_TTAB    .FILL MV_TTAB       ; pointer to tab->tab type
PMV_WTAB    .FILL MV_WTAB       ; pointer to waste->tab type
PMV_STKTOP  .FILL A_STKTOP      ; pointer to STOCK_TOP address
PMV_STOCK   .FILL A_STOCK       ; pointer to STOCK base address
PMV_WASTE   .FILL A_WASTE       ; pointer to WASTE_TOP address
PMV_TABSZ   .FILL A_TABSZ       ; pointer to TAB_SZ base address
PMV_FNDTOP  .FILL A_FNDTOP      ; pointer to FOUND_TOP base address
PMV_FNDSUT  .FILL A_FNDSUT      ; pointer to FOUND_SUIT base address
PMV_MSUT    .FILL MASK_SUT      ; pointer to suit mask (for FOUND_SUIT recording)
PMV_EMPTY   .FILL C_EMPTY       ; pointer to empty sentinel
PMV_FACEDN  .FILL C_FACEDN      ; pointer to face-down mask
PMV_TABADDR .FILL TABADDR       ; address of TABADDR helper
PMV_MOVETT  .FILL MOVE_TAB_TAB  ; address of MOVE_TAB_TAB
PMV_FLIPTOP .FILL FLIP_TOP      ; address of FLIP_TOP
PMV_MT_R7   .FILL MT_R7         ; pointer to MOVE_TAB_TAB R7 save
PMV_FT_R7   .FILL FT_R7         ; pointer to FLIP_TOP R7 save
PMV_CW_R7   .FILL CW_R7         ; pointer to CHECK_WIN R7 save
PMV_PW_R7   .FILL PW_R7         ; pointer to PRINT_WIN R7 save
PMV_FNDTOP2 .FILL A_FNDTOP      ; second pointer to FOUND_TOP (used by CHECK_WIN and waste->found)
PMV_SCRATCH .FILL SCRATCH_CRD   ; pointer to scratch word (VALID_MOVE card storage)
PMV_MTTRSV  .FILL MTT_RSAVE     ; pointer to MOVE_TAB_TAB row save slot

; ----------------------------------------------------------------
;  DO_MOVE - Execute the current validated move, update game state
;  In:  MTYPE, MSRC, MDST, MCNT set by PARSE_MOVE
;  Out: game arrays updated
; ----------------------------------------------------------------
DO_MOVE
        LD  R5, PMV_R7          ; R5 = address of DM_R7 save slot
        STR R7, R5, #0          ; save return address
        LD  R5, PMV_MTYPE       ; R5 = address of MTYPE
        LDR R1, R5, #0          ; R1 = move type

        ; DRAW: move STOCK[STOCK_TOP] to WASTE, decrement STOCK_TOP
        LD  R5, PMV_DRAW        ; R5 = address of MV_DRAW
        LDR R2, R5, #0          ; R2 = 0
        NOT R2, R2
        ADD R2, R2, #1
        ADD R2, R1, R2          ; R2 = MTYPE - MV_DRAW
        BRnp DMV_ND             ; not draw, skip
        LD  R5, PMV_STKTOP      ; R5 = address of A_STKTOP pointer
        LDR R2, R5, #0          ; R2 = address of STOCK_TOP
        LDR R3, R2, #0          ; R3 = STOCK_TOP value (index)
        LD  R5, PMV_STOCK       ; R5 = address of A_STOCK pointer
        LDR R4, R5, #0          ; R4 = base of STOCK array
        ADD R4, R4, R3          ; R4 = address of STOCK[STOCK_TOP]
        LDR R5, R4, #0          ; R5 = top stock card value
        LD  R6, PMV_WASTE       ; R6 = address of A_WASTE pointer
        LDR R6, R6, #0          ; R6 = address of WASTE_TOP
        STR R5, R6, #0          ; WASTE_TOP = drawn card
        LD  R6, PMV_EMPTY       ; R6 = address of C_EMPTY
        LDR R6, R6, #0          ; R6 = xFF (empty sentinel)
        STR R6, R4, #0          ; STOCK[STOCK_TOP] = xFF (clear drawn slot)
        ADD R3, R3, #-1         ; STOCK_TOP--
        STR R3, R2, #0          ; update STOCK_TOP
        BRnzp DMV_DN            ; done

DMV_ND  ; RESET: put waste card back, restore full stock
        LD  R5, PMV_RST         ; R5 = address of MV_RST
        LDR R2, R5, #0          ; R2 = 5
        NOT R2, R2
        ADD R2, R2, #1
        ADD R2, R1, R2          ; R2 = MTYPE - MV_RST
        BRnp DMV_NR             ; not reset, skip
        ; Waste card goes back into stock at position 0
        LD  R5, PMV_WASTE       ; R5 = address of A_WASTE pointer
        LDR R2, R5, #0          ; R2 = address of WASTE_TOP
        LDR R3, R2, #0          ; R3 = waste card value
        LD  R5, PMV_STOCK       ; R5 = address of A_STOCK pointer
        LDR R4, R5, #0          ; R4 = base of STOCK array
        STR R3, R4, #0          ; STOCK[0] = waste card (restores last drawn card)
        ; Restore STOCK_TOP = 0 (only the waste card goes back; played cards are gone)
        LD  R5, PMV_STKTOP      ; R5 = address of A_STKTOP pointer
        LDR R5, R5, #0          ; R5 = address of STOCK_TOP
        AND R3, R3, #0          ; R3 = 0
        STR R3, R5, #0          ; STOCK_TOP = 0
        ; Clear waste
        LD  R5, PMV_WASTE       ; R5 = address of A_WASTE pointer
        LDR R5, R5, #0          ; R5 = address of WASTE_TOP
        LD  R3, PMV_EMPTY       ; R3 = address of C_EMPTY
        LDR R3, R3, #0          ; R3 = xFF
        STR R3, R5, #0          ; WASTE_TOP = xFF (empty)
        BRnzp DMV_DN            ; done

DMV_NR  ; TAB->FOUND: remove top of MSRC pile, increment FOUND_TOP[MDST]
        LD  R5, PMV_TFND        ; R5 = address of MV_TFND
        LDR R2, R5, #0          ; R2 = 1
        NOT R2, R2
        ADD R2, R2, #1
        ADD R2, R1, R2          ; R2 = MTYPE - MV_TFND
        BRnp DMV_NTF            ; not tab->found, skip
        LD  R5, PMV_MSRC        ; R5 = address of MSRC
        LDR R1, R5, #0          ; R1 = source pile index
        LD  R5, PMV_TABSZ       ; R5 = address of A_TABSZ pointer
        LDR R2, R5, #0          ; R2 = base of TAB_SZ
        ADD R2, R2, R1          ; R2 = address of TAB_SZ[src]
        LDR R3, R2, #0          ; R3 = pile size
        ADD R3, R3, #-1         ; R3 = top row index
        ADD R2, R3, #0          ; R2 = row to pass to TABADDR
        LD  R5, PMV_TABADDR     ; R5 = address of TABADDR
        JSRR R5                 ; R0 = address of top card slot
        LDR R6, R0, #0          ; R6 = card value (save before clearing)
        LD  R5, PMV_EMPTY       ; R5 = address of C_EMPTY
        LDR R5, R5, #0          ; R5 = xFF
        STR R5, R0, #0          ; clear the slot (card moved to foundation)
        LD  R5, PMV_TABSZ       ; R5 = address of A_TABSZ pointer
        LDR R5, R5, #0          ; R5 = base of TAB_SZ
        ADD R5, R5, R1          ; R5 = address of TAB_SZ[src]
        LDR R0, R5, #0          ; R0 = current pile size
        ADD R0, R0, #-1         ; R0 = new size
        STR R0, R5, #0          ; TAB_SZ[src]--
        LD  R5, PMV_MDST        ; R5 = address of MDST
        LDR R5, R5, #0          ; R5 = foundation index
        LD  R4, PMV_FNDTOP      ; R4 = address of A_FNDTOP pointer
        LDR R4, R4, #0          ; R4 = base of FOUND_TOP
        ADD R4, R4, R5          ; R4 = address of FOUND_TOP[foundation]
        LDR R0, R4, #0          ; R0 = current top rank
        ADD R0, R0, #1          ; R0 = new top rank
        STR R0, R4, #0          ; FOUND_TOP[foundation]++
        ; If this was an Ace (new rank == 0, i.e. was -1->0), record suit
        BRnp DMV_TF_NS          ; if new rank != 0, not an Ace, skip suit record
        ; Extract suit index from card (R6) and store in FOUND_SUIT[MDST]
        LD  R4, PMV_MSUT        ; R4 = address of suit mask
        LDR R4, R4, #0          ; R4 = x0030
        AND R4, R6, R4          ; R4 = suit bits
        AND R3, R3, #0          ; R3 = suit index counter
DMV_TSLO ADD R4, R4, #-16
        BRn DMV_TSLD
        ADD R3, R3, #1
        BRnzp DMV_TSLO
DMV_TSLD LD  R4, PMV_FNDSUT     ; R4 = address of A_FNDSUT pointer
        LDR R4, R4, #0          ; R4 = base of FOUND_SUIT
        LD  R0, PMV_MDST
        LDR R0, R0, #0          ; R0 = foundation index
        ADD R4, R4, R0          ; R4 = address of FOUND_SUIT[MDST]
        STR R3, R4, #0          ; FOUND_SUIT[MDST] = suit index
DMV_TF_NS
        LD  R5, PMV_FLIPTOP     ; R5 = address of FLIP_TOP
        JSRR R5                 ; reveal new top card of src pile if face-down
        BRnzp DMV_DN            ; done

DMV_NTF ; TAB->TAB: move MCNT cards from MSRC to MDST
        LD  R5, PMV_TTAB        ; R5 = address of MV_TTAB
        LDR R2, R5, #0          ; R2 = 2
        NOT R2, R2
        ADD R2, R2, #1
        ADD R2, R1, R2          ; R2 = MTYPE - MV_TTAB
        BRnp DMV_NTT            ; not tab->tab, skip
        LD  R5, PMV_MOVETT      ; R5 = address of MOVE_TAB_TAB
        JSRR R5                 ; execute the card transfer
        BRnzp DMV_DN            ; done

DMV_NTT ; WASTE->TAB: append waste card to MDST pile, clear waste
        LD  R5, PMV_WTAB        ; R5 = address of MV_WTAB
        LDR R2, R5, #0          ; R2 = 3
        NOT R2, R2
        ADD R2, R2, #1
        ADD R2, R1, R2          ; R2 = MTYPE - MV_WTAB
        BRnp DMV_NWT            ; not waste->tab, must be waste->found
        LD  R5, PMV_MDST        ; R5 = address of MDST
        LDR R1, R5, #0          ; R1 = destination pile index
        LD  R5, PMV_TABSZ       ; R5 = address of A_TABSZ pointer
        LDR R2, R5, #0          ; R2 = base of TAB_SZ
        ADD R2, R2, R1          ; R2 = address of TAB_SZ[dst]
        LDR R3, R2, #0          ; R3 = current pile size (= new card's row)
        ADD R2, R3, #0          ; R2 = row index for new card
        LD  R5, PMV_TABADDR     ; R5 = address of TABADDR
        JSRR R5                 ; R0 = address of new slot
        LD  R4, PMV_WASTE       ; R4 = address of A_WASTE pointer
        LDR R4, R4, #0          ; R4 = address of WASTE_TOP
        LDR R5, R4, #0          ; R5 = waste card value
        STR R5, R0, #0          ; TAB_DATA[dst][size] = waste card
        LD  R5, PMV_TABSZ       ; R5 = address of A_TABSZ pointer
        LDR R5, R5, #0          ; R5 = base of TAB_SZ
        ADD R5, R5, R1          ; R5 = address of TAB_SZ[dst]
        LDR R6, R5, #0          ; R6 = current size
        ADD R6, R6, #1          ; R6 = new size
        STR R6, R5, #0          ; TAB_SZ[dst]++
        LD  R5, PMV_EMPTY       ; R5 = address of C_EMPTY
        LDR R5, R5, #0          ; R5 = xFF
        STR R5, R4, #0          ; WASTE_TOP = xFF (empty)
        BRnzp DMV_DN            ; done

DMV_NWT ; WASTE->FOUND: increment FOUND_TOP[MDST], clear waste, record suit if Ace
        LD  R4, PMV_WASTE       ; R4 = address of A_WASTE pointer
        LDR R4, R4, #0          ; R4 = address of WASTE_TOP
        LDR R6, R4, #0          ; R6 = waste card value (save before clearing)
        LD  R5, PMV_EMPTY       ; R5 = address of C_EMPTY
        LDR R5, R5, #0          ; R5 = xFF
        STR R5, R4, #0          ; WASTE_TOP = xFF (empty)
        LD  R5, PMV_MDST        ; R5 = address of MDST
        LDR R1, R5, #0          ; R1 = foundation index
        LD  R5, PMV_FNDTOP2     ; R5 = address of A_FNDTOP pointer
        LDR R2, R5, #0          ; R2 = base of FOUND_TOP
        ADD R2, R2, R1          ; R2 = address of FOUND_TOP[foundation]
        LDR R3, R2, #0          ; R3 = current top rank
        ADD R3, R3, #1          ; R3 = new top rank
        STR R3, R2, #0          ; FOUND_TOP[foundation]++
        ; If Ace (new rank == 0), record suit in FOUND_SUIT[MDST]
        ADD R3, R3, #0          ; set CC from new rank
        BRnp DMV_WF_NS          ; if != 0, not Ace, skip
        LD  R4, PMV_MSUT        ; R4 = address of suit mask
        LDR R4, R4, #0          ; R4 = x0030
        AND R4, R6, R4          ; R4 = suit bits from waste card
        AND R3, R3, #0          ; R3 = suit index counter
DMV_WSLO ADD R4, R4, #-16
        BRn DMV_WSLD
        ADD R3, R3, #1
        BRnzp DMV_WSLO
DMV_WSLD LD  R4, PMV_FNDSUT     ; R4 = address of A_FNDSUT pointer
        LDR R4, R4, #0          ; R4 = base of FOUND_SUIT
        ADD R4, R4, R1          ; R4 = address of FOUND_SUIT[MDST]
        STR R3, R4, #0          ; FOUND_SUIT[MDST] = suit index
DMV_WF_NS

DMV_DN  LD  R5, PMV_R7          ; R5 = address of DM_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET

; ----------------------------------------------------------------
;  MOVE_TAB_TAB - Move MCNT cards from MSRC tableau to MDST tableau
;  Cards are moved one at a time from the start row downward.
;  After moving, calls FLIP_TOP to reveal any newly-exposed face-down card.
;  In:  MSRC, MDST, MCNT set
;  Out: TAB_DATA and TAB_SZ updated
; ----------------------------------------------------------------
MOVE_TAB_TAB
        LD  R5, PMV_MT_R7       ; R5 = address of MT_R7 save slot
        STR R7, R5, #0          ; save return address
        LD  R5, PMV_MCNT        ; R5 = address of MCNT
        LDR R3, R5, #0          ; R3 = count (number of cards to move)
        LD  R5, PMV_MSRC        ; R5 = address of MSRC
        LDR R1, R5, #0          ; R1 = source pile index
        LD  R5, PMV_TABSZ       ; R5 = address of A_TABSZ pointer
        LDR R2, R5, #0          ; R2 = base of TAB_SZ
        ADD R2, R2, R1          ; R2 = address of TAB_SZ[src]
        LDR R4, R2, #0          ; R4 = source pile size
        NOT R5, R3              ; R5 = NOT count
        ADD R5, R5, #1          ; R5 = -count
        ADD R5, R4, R5          ; R5 = size - count = first row to move

MTT_LP  ADD R2, R5, #0          ; R2 = current source row
        LD  R6, PMV_MSRC        ; R6 = address of MSRC
        LDR R1, R6, #0          ; R1 = source pile index
        ; Save R5 (source row) - TABADDR clobbers R5
        LD  R6, PMV_MTTRSV      ; R6 = address of MTT_RSAVE
        STR R5, R6, #0          ; save source row
        LD  R6, PMV_TABADDR     ; R6 = address of TABADDR
        JSRR R6                 ; R0 = address of src card
        ; Restore R5 after JSRR
        LD  R6, PMV_MTTRSV      ; R6 = address of MTT_RSAVE
        LDR R5, R6, #0          ; R5 = source row (restored)
        LDR R6, R0, #0          ; R6 = card value to move
        LD  R4, PMV_EMPTY       ; R4 = address of C_EMPTY
        LDR R4, R4, #0          ; R4 = xFF
        STR R4, R0, #0          ; clear source slot

        ; Append card to destination pile
        LD  R1, PMV_MDST        ; R1 = address of MDST
        ; Jump over local data table (can't put data in instruction stream)
        BRnzp MTT_DST
MTT_MDST .FILL MDST             ; local: MDST
MTT_TABSZ .FILL A_TABSZ         ; local: TAB_SZ base address
MTT_SCRT .FILL MTT_RSAVE        ; local: dedicated row-save slot (NOT SCRATCH_CRD)
MTT_TABD .FILL TABADDR          ; local: address of TABADDR
MTT_MSRC .FILL MSRC             ; local: MSRC
MTT_MCNT .FILL MCNT             ; local: MCNT
MTT_DST
        LDR R1, R1, #0          ; R1 = destination pile index
        LD  R4, MTT_TABSZ       ; R4 = address of A_TABSZ pointer
        LDR R2, R4, #0          ; R2 = base of TAB_SZ
        ADD R2, R2, R1          ; R2 = address of TAB_SZ[dst]
        LDR R2, R2, #0          ; R2 = current dst size (= new card's row)
        ; Save R5 before second JSRR
        LD  R4, MTT_SCRT        ; R4 = address of SCRATCH_CRD
        STR R5, R4, #0          ; save source row in scratch
        LD  R4, MTT_TABD        ; R4 = address of TABADDR
        JSRR R4                 ; R0 = address of dst slot
        ; Restore R5 after second JSRR
        LD  R4, MTT_SCRT        ; R4 = address of SCRATCH_CRD
        LDR R5, R4, #0          ; R5 = source row (restored)
        STR R6, R0, #0          ; TAB_DATA[dst][size] = card

        ; Increment dst pile size
        LD  R1, MTT_MDST        ; R1 = address of MDST
        LDR R1, R1, #0          ; R1 = dst pile index
        LD  R4, MTT_TABSZ       ; R4 = address of A_TABSZ pointer
        LDR R2, R4, #0          ; R2 = base of TAB_SZ
        ADD R2, R2, R1          ; R2 = address of TAB_SZ[dst]
        LDR R0, R2, #0          ; R0 = current size
        ADD R0, R0, #1          ; R0 = new size
        STR R0, R2, #0          ; TAB_SZ[dst]++

        ADD R5, R5, #1          ; advance source row
        ADD R3, R3, #-1         ; decrement card counter
        BRp MTT_LP              ; if more cards, loop

        ; Decrement source pile size by count
        LD  R5, MTT_MSRC        ; R5 = address of MSRC
        LDR R1, R5, #0          ; R1 = source pile index
        LD  R5, MTT_TABSZ       ; R5 = address of A_TABSZ pointer
        LDR R2, R5, #0          ; R2 = base of TAB_SZ
        ADD R2, R2, R1          ; R2 = address of TAB_SZ[src]
        LDR R0, R2, #0          ; R0 = current src size
        LD  R5, MTT_MCNT        ; R5 = address of MCNT
        LDR R3, R5, #0          ; R3 = count
        NOT R3, R3              ; R3 = NOT count
        ADD R3, R3, #1          ; R3 = -count
        ADD R0, R0, R3          ; R0 = src_size - count
        STR R0, R2, #0          ; TAB_SZ[src] -= count

        BRnzp MTT_FLIP          ; jump over local data words
MTT_FTP .FILL FLIP_TOP          ; local: address of FLIP_TOP
MTT_MTR .FILL MT_R7             ; local: MT_R7 save slot
MTT_FLIP
        LD  R5, MTT_FTP         ; R5 = address of FLIP_TOP
        JSRR R5                 ; reveal new top of src pile if face-down
        LD  R5, MTT_MTR         ; R5 = address of MT_R7 save slot
        LDR R7, R5, #0          ; restore return address
        RET

; Local pointer table for FLIP_TOP  (PMV_ table is out of +-256 range from here)
FTP_L_FT_R7  .FILL FT_R7        ; FT_R7 save slot
FTP_L_MSRC   .FILL MSRC         ; MSRC variable
FTP_L_TABSZ  .FILL A_TABSZ      ; TAB_SZ base address
FTP_L_TABAD  .FILL TABADDR      ; address of TABADDR
FTP_L_FCDN   .FILL C_FACEDN     ; face-down mask x0080

; ----------------------------------------------------------------
;  FLIP_TOP - Reveal the top face-down card of MSRC pile
;  Face-down cards are stored as real_card | x0080.
;  Strips bit 7 (AND with xFF7F) to reveal the actual card value.
;  In:  MSRC = pile index
;  Out: top card of MSRC pile updated if it was face-down
; ----------------------------------------------------------------
FLIP_TOP
        LD  R5, FTP_L_FT_R7     ; save return address
        STR R7, R5, #0
        LD  R5, FTP_L_MSRC
        LDR R1, R5, #0          ; R1 = source pile index
        LD  R5, FTP_L_TABSZ
        LDR R2, R5, #0          ; R2 = base of TAB_SZ
        ADD R2, R2, R1          ; R2 = &TAB_SZ[src]
        LDR R3, R2, #0          ; R3 = pile size
        BRz FTP_DN              ; empty pile - nothing to flip
        ADD R3, R3, #-1         ; R3 = top row index
        ADD R2, R3, #0          ; R2 = row for TABADDR
        LD  R5, FTP_L_TABAD
        JSRR R5                 ; R0 = &top card slot
        LDR R3, R0, #0          ; R3 = top card value
        LD  R5, FTP_L_FCDN
        LDR R4, R5, #0          ; R4 = x0080
        AND R4, R3, R4          ; isolate face-down bit
        BRz FTP_DN              ; not face-down - skip
        LD  R5, FTP_L_FCDN
        LDR R4, R5, #0          ; R4 = x0080
        NOT R4, R4              ; R4 = xFF7F
        AND R3, R3, R4          ; strip face-down bit
        STR R3, R0, #0          ; write revealed card back
FTP_DN  LD  R5, FTP_L_FT_R7
        LDR R7, R5, #0          ; restore return address
        RET

; Local pointer table for CHECK_WIN  (PMV_ table is out of +-256 range from here)
CWN_L_CW_R7  .FILL CW_R7        ; CW_R7 save slot
CWN_L_FNDTP  .FILL A_FNDTOP     ; FOUND_TOP base address

; ----------------------------------------------------------------
;  CHECK_WIN - Check if all four foundations are complete (King on top)
;  Win condition: FOUND_TOP[0..3] all equal 12
;  In:  FOUND_TOP array
;  Out: R0 = 1 if won, R0 = 0 otherwise
; ----------------------------------------------------------------
CHECK_WIN
        LD  R5, CWN_L_CW_R7
        STR R7, R5, #0          ; save return address
        AND R2, R2, #0
        ADD R2, R2, #4          ; R2 = 4 foundations to check
        LD  R5, CWN_L_FNDTP
        LDR R1, R5, #0          ; R1 = base of FOUND_TOP
CWN_LP  LDR R0, R1, #0          ; R0 = FOUND_TOP[i]
        ADD R0, R0, #-12        ; 0 only if King
        BRnp CWN_NO             ; not King - not won
        ADD R1, R1, #1
        ADD R2, R2, #-1
        BRp CWN_LP
        AND R0, R0, #0
        ADD R0, R0, #1          ; R0 = 1 (won)
        BRnzp CWN_RET
CWN_NO  AND R0, R0, #0          ; R0 = 0 (not won)
CWN_RET LD  R5, CWN_L_CW_R7
        LDR R7, R5, #0          ; restore return address
        RET

; Local pointer table for PRINT_WIN  (PMV_ table is out of +-256 range from here)
PWN_L_PW_R7  .FILL PW_R7        ; PW_R7 save slot

; ----------------------------------------------------------------
;  PRINT_WIN - Display the victory message
;  In:  nothing
;  Out: congratulations message printed
; ----------------------------------------------------------------
PRINT_WIN
        LD  R5, PWN_L_PW_R7
        STR R7, R5, #0          ; save return address
        LEA R0, WIN_STR
        TRAP x22                ; PUTS victory message
        LD  R5, PWN_L_PW_R7
        LDR R7, R5, #0          ; restore return address
        RET

WIN_STR .STRINGZ "\n*** YOU WIN! Congratulations! ***\n"

        .END

; ================================================================
;  BLOCK 9: Game arrays  (x3900)
;
;  DECK       x3900  52 words  - shuffled encoded card values
;  STOCK      x3934  52 words  - draw pile (undealt cards)
;  STOCK_TOP  x3968   1 word   - index of top card (-1 = empty)
;  WASTE_TOP  x3969   1 word   - current waste card (xFF = empty)
;  TAB_DATA   x396A  140 words - 7 piles x 20 slots each
;  TAB_SZ     x39F6   7 words  - number of cards in each tableau pile
;  TAB_UP     x39FD   7 words  - reserved (not used in this impl)
;  FOUND      x3A04  52 words  - reserved (foundation storage)
;  FOUND_TOP  x3A38   4 words  - top rank per foundation (-1 = empty)
; ================================================================
        .ORIG x3900
DECK        .BLKW 52            ; card storage for shuffled deck
STOCK       .BLKW 52            ; draw pile storage
STOCK_TOP   .BLKW 1             ; STOCK_TOP: index of top draw card
WASTE_TOP   .BLKW 1             ; WASTE_TOP: current waste card value
TAB_DATA    .BLKW 140           ; tableau card slots (7 piles, 20 slots each)
TAB_SZ      .BLKW 7             ; TAB_SZ[0..6]: card count per pile
TAB_UP      .BLKW 7             ; reserved
FOUND       .BLKW 52            ; reserved foundation storage
FOUND_TOP   .BLKW 4             ; FOUND_TOP[0..3]: top rank per foundation
FOUND_SUIT  .BLKW 4             ; FOUND_SUIT[0..3]: suit index per foundation (-1=empty)
        .END
