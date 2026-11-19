# SRAM PUF-Based Secret Key Generation for Encryption Using STM32 and FPGA

## Project Overview

This project implements a **Physical Unclonable Function (PUF)-based 256-bit cryptographic key generation system** using an **STM32 microcontroller** as the real hardware PUF source and a **Digilent Nexys A7-100T FPGA** for cryptographic key processing.

The STM32's physical SRAM power-up values — unique to each chip due to manufacturing transistor variations — are transmitted to the FPGA via UART. The FPGA receives these bits, applies BCH error correction, SHA-256 hashing, and 256-bit LFSR expansion to produce a **256-bit cryptographic key** that is unique, reproducible, and never stored in memory.

---

## Complete System Architecture

STM32 Microcontroller (Real SRAM Power-Up Values) | | UART TX → 32 bytes (256 bits) at 115200 baud | PMOD JA1 — FPGA Pin C17 ↓ ┌─────────────────────────────────────────────┐ │ Nexys A7-100T FPGA │ │ │ │ uart_puf_rx.v │ │ (Receives 256-bit PUF response from STM32) │ │ ↓ │ │ sram_puf_controller.v (13-state FSM) │ │ ↓ │ │ Stability Analysis (10 power-up cycles) │ │ ↓ │ │ fuzzy_extractor.v │ │ BCH(31,16,3) Error Correction │ │ ↓ │ │ key_gen.v + sha256_core.v │ │ SHA-256 Hashing (128-bit → 256-bit) │ │ ↓ │ │ lfsr_256.v │ │ 256-bit Galois LFSR Expansion │ │ ↓ │ │ 256-bit Cryptographic Key │ └─────────────────────────────────────────────┘ | | ↓ ↓ UART Terminal 8-digit 7-Segment 64 hex chars Last 8 hex digits (Full 256-bit key) (Frozen after done)



---

## Hardware Platform

| Component | Details |
|---|---|
| **Microcontroller** | STM32 (Real SRAM PUF source) |
| **FPGA Board** | Digilent Nexys A7-100T |
| **FPGA Chip** | Xilinx XC7A100T Artix-7 |
| **Clock** | 100 MHz onboard oscillator |
| **EDA Tool** | Vivado 2025.2 |
| **HDL** | Verilog |
| **Communication** | UART 115200 baud 8N1 |

---

## STM32 to FPGA Hardware Connection

| Signal | STM32 Pin | Nexys A7 Port | FPGA Pin | Description |
|---|---|---|---|---|
| PUF Data | UART TX | `uart_rxd_stm32` | C17 (PMOD JA1) | 256-bit PUF response |
| Key Output | — | `uart_txd` | D4 (USB-UART) | 64 hex chars to PC |
| Ground | GND | GND | GND | Common ground |

---

## Repository Structure
PHASE_FINAL/ ├── PHASE_FINAL.srcs/ │ ├── sources_1/new/ │ │ ├── nexys_a7_top.v ← Top level module (board interface) │ │ ├── sram_puf_params.vh ← Global parameters and FSM state defines │ │ ├── sram_puf_controller.v ← 13-state FSM orchestrator │ │ ├── uart_puf_rx.v ← UART receiver for STM32 PUF data │ │ ├── sram_puf_core.v ← SRAM PUF simulation core │ │ ├── fuzzy_extractor.v ← BCH-based fuzzy extractor │ │ ├── bch_codec.v ← BCH(31,16,3) encoder/decoder │ │ ├── hamming_codec.v ← Hamming(7,4) codec (alternative ECC) │ │ ├── key_gen.v ← SHA-256 key generation wrapper │ │ ├── sha256_core.v ← Full hardware SHA-256 core │ │ └── lfsr_256.v ← 256-bit Galois LFSR │ ├── sim_1/new/ │ │ └── tb_sram_puf_top.v ← System testbench │ └── constrs_1/new/ │ └── basys3.xdc ← Nexys A7-100T pin constraints └── README.md



---

## Module Description

### `nexys_a7_top.v` — Top Level Board Interface
- Button debouncing (20ms at 100MHz = 2,000,000 cycles)
- Rising-edge pulse detection for BTNL / BTNC / BTNR
- PUF controller and UART RX instantiation
- 16 LED pipeline stage indicators
- 8-digit 7-segment display (demo freeze mode)
- UART TX — sends full 256-bit key as 64 hex characters at 115200 baud
- `uart_rxd_stm32` input — receives PUF data from STM32

### `uart_puf_rx.v` — STM32 UART Receiver
- Receives 32 bytes (256 bits) from STM32 over UART at 115200 baud
- 4-state RX FSM: IDLE → START → DATA → STOP
- Synchronizes RX line with 3-stage flip-flop (metastability protection)
- Samples each bit at center of baud period (BAUD_DIV/2 offset)
- Accumulates 32 bytes into 256-bit `puf_buffer`
- Asserts `read_done` when all 256 bits received
- `meta_flags` tied to 0 — physical STM32 PUF has no simulated metastability

### `sram_puf_controller.v` — 13-State FSM Orchestrator
Controls the complete key generation pipeline:
IDLE ↓ (BTNC) ENROLL_POWERUP → ENROLL_WAIT_READ → ENROLL_ANALYZE → ENROLL_SELECT → ENROLL_EXTRACT → KEYGEN → LFSR → DONE

IDLE ↓ (BTNR) RECONSTRUCT_POWERUP → RECONSTRUCT_READ → RECONSTRUCT_DECODE → KEYGEN → LFSR → DONE



### `sram_puf_core.v` — SRAM PUF Simulation Core
- 256 SRAM cells with deterministic bias per cell (Linear Congruential Generator)
- Metastable cell detection (bias in range 0x70–0x90)
- ~4% noise injection modeling real temperature/voltage variations
- Used in simulation; replaced by `uart_puf_rx.v` for real STM32 PUF

### `fuzzy_extractor.v` — Fuzzy Extractor
- **Enrollment:** 128 stable bits → 8 blocks × BCH(31,16) encode → XOR with secret → 248-bit helper data
- **Reconstruction:** noisy bits XOR helper → BCH decode → original 128-bit secret recovered

### `bch_codec.v` — BCH(31,16,3) Codec
- Galois field: GF(2⁵)
- Primitive polynomial: x⁵ + x² + 1
- Generator polynomial: x¹⁵ + x¹¹ + x¹⁰ + x⁹ + x⁸ + x⁷ + x⁵ + x³ + x² + x + 1
- **Encoder:** Systematic polynomial division
- **Decoder:** Syndrome calculation → Berlekamp-Massey → Chien search → bit flip
- Corrects up to **3 bit errors per 31-bit block**

### `hamming_codec.v` — Hamming(7,4) Codec
- Alternative ECC option (selected when USE_BCH=0)
- Encodes 4 data bits into 7-bit codeword
- Corrects single-bit errors, detects double-bit errors

### `key_gen.v` — SHA-256 Key Generation Wrapper
- Pads 128-bit secret to 512-bit block (SHA-256 format)
- Instantiates `sha256_core.v`
- Outputs 256-bit hash as key seed for LFSR

### `sha256_core.v` — SHA-256 Hardware Core
- Full 64-round compression function
- Standard SHA-256 K constants and H initial values
- 3-state FSM: PREPARE (message schedule) → COMPRESS (64 rounds) → FINALIZE
- Input: 512-bit padded message block
- Output: 256-bit hash

### `lfsr_256.v` — 256-bit Galois LFSR
- Primitive polynomial: x²⁵⁶ + x²⁵³ + x²⁵⁰ + x²⁴⁵ + 1
- Feedback taps at bits 255, 253, 250, 245
- Seeded with SHA-256 output
- Runs 256 clock cycles
- Final register state = **256-bit cryptographic key**

---

## FSM State Table

| State | Value | Description |
|---|---|---|
| IDLE | 0 | Waiting for button press |
| ENROLL_POWERUP | 1 | PUF reset / power cycle |
| ENROLL_WAIT_READ | 2 | Reading 256 PUF cells |
| ENROLL_ANALYZE | 3 | Majority vote across 10 readings |
| ENROLL_SELECT | 4 | Filter stable cells (≥8/10) |
| ENROLL_EXTRACT | 5 | BCH encode + generate helper data |
| RECONSTRUCT_POWERUP | 6 | PUF power cycle for reconstruction |
| RECONSTRUCT_READ | 7 | Read noisy PUF response |
| RECONSTRUCT_DECODE | 8 | BCH decode using stored helper data |
| KEYGEN | 9 | SHA-256 hash 128-bit secret |
| DONE | 10 | Key ready, operation complete |
| ERROR | 11 | Error — insufficient stable cells |
| LFSR | 12 | 256-cycle LFSR key expansion |

---

## PUF Parameters

| Parameter | Value | Description |
|---|---|---|
| PUF Size | 256 cells | SRAM cells or STM32 bits |
| Enroll Cycles | 10 | Power-up repetitions |
| Stability Threshold | 8/10 | Min same-value count |
| Secret Bits | 128 bits | Stable bits used |
| Helper Bits | 248 bits | BCH encoded helper data |
| ECC | BCH(31,16,3) | Up to 3 bit corrections |

---

## Board Controls

| Button | FPGA Pin | Function |
|---|---|---|
| **BTNL** | P17 | System reset — clears all state, ready for new enrollment |
| **BTNC** | N17 | Start enrollment — full PUF pipeline, generates key |
| **BTNR** | M17 | Reconstruct — reproduces same key using stored helper |

---

## LED Indicators

| LED | Meaning |
|---|---|
| LD0 | PUF power-up stage completed |
| LD1 | PUF read stage completed |
| LD2 | Stability analysis completed |
| LD3 | BCH error correction completed |
| LD4 | SHA-256 hashing completed |
| LD5 | LFSR expansion completed |
| LD6–LD13 | Lower 8 bits of generated key (binary) |
| LD14 | Error flag |
| LD15 | Operation complete |

---

## 7-Segment Display — Demo Mode

| State | Display Behavior |
|---|---|
| Power on / Reset | Blank (all anodes off) |
| During operation | Blank |
| After key generated | Last 8 hex digits of key — frozen permanently |
| Next button press | Blanks again, ready for next operation |

**Proof of reproducibility:** Press BTNR multiple times — same 8 hex digits every time ✅

---

## UART Output Specification

| Parameter | Value |
|---|---|
| Baud Rate | 115200 |
| Format | 8N1 |
| Clock Divisor | 868 (100 MHz / 115200) |
| Output | 64 hex characters + CR (0x0D) + LF (0x0A) |
| Total | 66 bytes per operation |
| FPGA TX Pin | D4 (USB-UART bridge to PC) |
| STM32 RX Pin | C17 (PMOD JA1) |

---

## FPGA Implementation Results

| Metric | Value |
|---|---|
| Target Device | Xilinx XC7A100T Artix-7 |
| Clock Frequency | 100 MHz |
| Worst Negative Slack (WNS) | +0.548 ns ✅ |
| Maximum Achievable Frequency | 105.8 MHz |
| Failing Timing Endpoints | 0 |
| Total Timing Endpoints | 17,566 |
| LUT Utilization | 50% |
| Flip-Flop Utilization | 5% |
| DSP Utilization | 1% |
| IO Utilization | 18% |
| Total On-Chip Power | 0.126 W |
| Junction Temperature | 25.6°C |
| Thermal Margin | 59.4°C |

---

## BCH Error Correction Test Results

| Test Case | Errors Injected | Result |
|---|---|---|
| No errors | 0 | ✅ Pass |
| Single bit flip | 1 | ✅ Pass |
| Double bit flip | 2 | ✅ Pass |
| Triple bit flip (max) | 3 | ✅ Pass |

---

## Demo Procedure
Step 1: Connect STM32 UART TX → Nexys A7 PMOD JA1 (pin C17) Step 2: Connect GND → GND (common ground) Step 3: Connect Nexys A7 USB to PC Step 4: Open serial terminal at 115200 baud on Nexys A7 COM port Step 5: Power on both STM32 and Nexys A7 Step 6: Press BTNC → Enrollment runs → 64 hex characters appear on terminal → Last 8 hex digits frozen on 7-segment display Step 7: Note the displayed key (e.g., 3A17E153) Step 8: Press BTNR → Reconstruction runs → SAME 64 hex characters on terminal ✅ → SAME 8 digits on display ✅ Step 9: Press BTNR again → SAME result again ✅ This proves PUF reproducibility



---

## Security Properties

| Property | Description |
|---|---|
| **Uniqueness** | Each STM32 chip produces a different key |
| **Reproducibility** | Same chip always produces same key |
| **No Key Storage** | Key derived from physics, never written to memory |
| **Tamper Resistance** | Chip destruction = permanent key destruction |
| **Error Tolerance** | BCH corrects up to 3 bit flips per 31-bit block |
| **Key Strength** | 256-bit key — suitable for AES-256 encryption |
| **Unpredictability** | Cannot predict key without measuring physical chip |

---

## Tools Used

| Tool | Purpose |
|---|---|
| Vivado 2025.2 | Synthesis, Implementation, Bitstream generation |
| STM32CubeIDE | STM32 firmware development |
| Verilog HDL | FPGA hardware description language |
| DocLight / PuTTY | UART terminal for key verifica
