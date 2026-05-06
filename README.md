# Solitaire — LC-3 Assembly

**Author:** Ian Codding II  
**Date:** May 6, 2026  
**Course:** CS155

---

## Description

A solid structure for the game of Solitaire written entirely in LC-3 assembly language.
The game runs in your simulator and supports will complete all initualizing of the game:
displaying menu, seeding a randum variable, shuffleing the deck, and printing to deck to the screen in an orderly fashon.

Cards are displayed using Unicode suit symbols (♣ ♦ ♥ ♠) via UTF-8 byte output.
Face-down cards display as `[**]` and empty slots display as `[  ]`.

### Features
- Pseudo-random shuffle via a seeded Linear Congruential Generator (LCG)
- Player-chosen seed for reproducible games
- Tobe - Multi-card tableau-to-tableau moves (`Tn Tm k`)
- Tobe - Automatic card reveal when a face-down card is exposed
- Tobe - Win detection when all 52 cards reach the foundations

---

## LC-3 Simulator

This program is written for and tested on **LC3Tools**:

🔗 https://github.com/chiragsakhuja/lc3tools

> **Note:** LC3Tools must support UTF-8 terminal output for suit symbols
> (♣ ♦ ♥ ♠) to display correctly. If symbols appear garbled, ensure your
> terminal is set to UTF-8 encoding.

---

## How to Run

1. Clone this repository
2. Open `Solitaire.asm` in LC3Tools
3. Assemble and load the program
4. Run from address `x3000`

---

## Special Requirements

| Requirement | Detail |
|---|---|
| Terminal encoding | UTF-8 required for suit symbols |
| Terminal width | At least **60 characters wide** |
| Terminal height | At least **25 lines tall** |

If your terminal is too small the board will wrap and become unreadable.
Resize your terminal window before starting the program.

---

## Commands

| Command | Action |
|---|---|
| `D` | Draw top card from stock to waste |
| `R` | Reset waste card back to stock |
| `Tn Fm` | Move top of tableau pile n → foundation m |
| `Tn Tm` | Move top card of tableau pile n → tableau pile m |
| `Tn Tm k` | Move k cards from tableau pile n → tableau pile m |
| `W Tn` | Move waste card → tableau pile n |
| `W Fn` | Move waste card → foundation n |
| `Q` | Quit the game |

Pile numbers are 1-based: `T1`–`T7` for tableau, `F1`–`F4` for foundations.

---

### Card Encoding

Each card is stored as a single 16-bit word:
-Bits 5-4 = suit   (00=Clubs  01=Diamonds  10=Hearts  11=Spades)
-Bits 3-0 = rank   (0=Ace  1=Two  ...  12=King)
-Bit    7 = face-down flag (set = face-down, cleared when revealed)
-x00FF    = empty slot sentinel
---

## Memory Map

| Address | Contents |
|---|---|
| `x3000` | Shared data + MAIN game loop |
| `x3200` | MENU + GET\_SEED |
| `x3280` | INIT\_DECK + LCG\_RAND + MULTIPLY + MOD + SHUFFLE |
| `x3350` | DEAL |
| `x3430` | PRINT\_STATE + PRINT\_CARD + EBYTE + GET\_INPUT |
| `x3580` | PARSE\_MOVE |
| `x3640` | VALID\_MOVE + helpers + TABADDR + SUIT\_COLOR |
| `x3780` | DO\_MOVE + MOVE\_TAB\_TAB + FLIP\_TOP + CHECK\_WIN + PRINT\_WIN |
| `x3900` | Game arrays (DECK, STOCK, TAB\_DATA, FOUND\_TOP …) |

---

## Architecture Notes

- **No hardware stack** — each subroutine saves its return address (R7) to a
  dedicated memory slot and restores it before returning.
- **Local pointer tables** — each code section has a small table of `.FILL`
  words placed immediately before it. This keeps every `LD` instruction
  within the ±256-word PC-relative range.
- **Subroutine calls** — use `JSRR R5` (load address into R5, then jump) or
  `JSR label` for nearby targets within ±1024 words.
- **Card shuffle** — Fisher-Yates algorithm using a 15-bit LCG with
  multiplier 25173 and addend 13849.

---

## Example Board
<img width="513" height="322" alt="image" src="https://github.com/user-attachments/assets/12aaa5c2-6338-4a67-b556-fd9bcb399488" />
---

## License

This project was created for academic purposes for CS155.
