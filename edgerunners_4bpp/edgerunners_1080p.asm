; edgerunners_1080p.asm - Native x86-64 Linux + SDL2, 1080p tiled logo with glitch effect
; 80x45 grid of 24x24 tiles, 4BPP (16 colours), drawn 1:1 into a 1920x1080 framebuffer.
; Each frame: copy clean image -> framebuffer, randomly tear bands, split RGB,
; corrupt tiles in short bursts, then darken every 4th row for scanlines.
; Keys: F11 = Toggle Fullscreen, ESC = Quit
;
; Build:
;   nasm -f elf64 edgerunners_1080p.asm -o edgerunners_1080p.o
;   ld edgerunners_1080p.o -o edgerunners_1080p -lSDL2 -dynamic-linker /lib64/ld-linux-x86-64.so.2

; ------------------------------------------------------- ;
; NASM Assembler Directives                               ;
; ------------------------------------------------------- ;
bits 64                                                   ; 64-bit Long Mode (x86-64)
default rel                                               ; RIP-relative memory addressing

; ------------------------------------------------------- ;
; SDL2 Constants                                          ;
; ------------------------------------------------------- ;
%define SDL_INIT_VIDEO                  0x00000020        ; Init video and event subsystems
%define SDL_WINDOWPOS_CENTERED          0x2FFF0000        ; Center window on screen
%define SDL_WINDOW_RESIZABLE            0x00000020        ; Allow window resizing
%define SDL_WINDOW_FULLSCREEN_DESKTOP   0x00001001        ; Borderless desktop fullscreen

%define SDL_RENDERER_ACCELERATED        0x00000002        ; Use hardware-backed presentation
%define SDL_RENDERER_PRESENTVSYNC       0x00000004        ; Sync frame present to monitor refresh
%define SDL_PIXELFORMAT_ARGB8888        0x16362004        ; 32-bit 0xAARRGGBB pixel layout
%define SDL_TEXTUREACCESS_STREAMING     1                 ; Texture updated from CPU RAM

%define SDL_QUIT                        0x00000100        ; Window close request event
%define SDL_KEYDOWN                     0x00000300        ; Physical key press event
%define SDL_SCANCODE_ESCAPE             41                ; USB HID scancode for ESC
%define SDL_SCANCODE_F11                68                ; USB HID scancode for F11

; ------------------------------------------------------- ;
; Screen & Tile Constants                                 ;
; ------------------------------------------------------- ;
%define SCREEN_W        1920                              ; Framebuffer width in pixels
%define SCREEN_H        1080                              ; Framebuffer height in pixels
; ------------------------------------------------------- ;
; Glitch Tuning                                           ;
; ------------------------------------------------------- ;
%define GLITCH_CHANCE   40                                ; 1 in N frames starts a burst (~0.7s at 60Hz)
%define BURST_MIN       3                                 ; Burst length: BURST_MIN..BURST_MIN+BURST_RAND-1 frames
%define BURST_RAND      6
%define BANDS_MAX       5                                 ; 2..BANDS_MAX+1 torn bands per glitch frame
%define BAND_STEP       8                                 ; Snap bands/shifts to 8px (retro pixel grid)
%define SHIFT_STEPS     12                                ; Max shift = SHIFT_STEPS * BAND_STEP px
%define CORRUPT_MAX     6                                 ; 0..CORRUPT_MAX-1 wrong tiles per glitch frame
%define SCANLINE_STEP   4                                 ; Darken every Nth row (rows 0, 4, 8...)

%define SCREEN_PITCH    (SCREEN_W * 4)                    ; Bytes per scanline (7680)
%define TOTAL_PIXELS    (SCREEN_W * SCREEN_H)             ; 2,073,600 pixels

; Tile constants (TILE_SIZE, ROW_BYTES, TILE_BYTES, MAP_COLS, MAP_ROWS, TILE_COUNT)
; come from tiles.asm, included in .rodata below.

; ------------------------------------------------------- ;
; libSDL2-2.0.so.0                                        ;
; ------------------------------------------------------- ;
extern SDL_Init
extern SDL_CreateWindow
extern SDL_CreateRenderer
extern SDL_RenderSetLogicalSize
extern SDL_CreateTexture
extern SDL_PollEvent
extern SDL_SetWindowFullscreen
extern SDL_UpdateTexture
extern SDL_RenderClear
extern SDL_RenderCopy
extern SDL_RenderPresent
extern SDL_DestroyTexture
extern SDL_DestroyRenderer
extern SDL_DestroyWindow
extern SDL_Quit

; ------------------------------------------------------- ;
; Read-Only Data                                          ;
; ------------------------------------------------------- ;
section .rodata
    win_title db "Edgerunners 1080p Tilemap - F11 Fullscreen, ESC Quit", 0

    %include "tiles.asm"                  ; TILE_SIZE, ROW_BYTES, TILE_BYTES, MAP_COLS,
                                          ; MAP_ROWS, Palette, Tiles, Tilemap

; ================================================================= ;
; Block Started by Symbol                                           ;
; ================================================================= ;
section .bss
    alignb 32
    base        resd TOTAL_PIXELS                   ; Clean rendered image (never modified after init)
    framebuffer resd TOTAL_PIXELS                   ; Per-frame output, glitched copy of base
    sdl_event   resb 64                             ; SDL_Event scratch space
    rng_state   resd 1                              ; xorshift32 state
    burst_left  resd 1                              ; Glitch frames remaining in current burst

; ================================================================= ;
; Code                                                              ;
; ================================================================= ;
section .text
    global _start

_start:
    ; ------------------------------------------------------------- ;
    ; Seed the RNG from the CPU timestamp counter (never zero)      ;
    ; ------------------------------------------------------------- ;
    rdtsc
    or eax, 1
    mov [rng_state], eax

    ; ------------------------------------------------------------- ;
    ; RENDER THE TILEMAP ONCE INTO 'base' (1:1, no scaling)         ;
    ; ------------------------------------------------------------- ;
    xor r12d, r12d                                  ; r12 = map row
.map_row:
    xor r13d, r13d                                  ; r13 = map column
.map_col:
    imul eax, r12d, MAP_COLS
    add eax, r13d
    lea rbx, [Tilemap]
    movzx ecx, word [rbx + rax*2]                   ; ecx = tile ID (word tilemap)
    lea rdi, [base]
    mov esi, r13d
    mov edx, r12d
    call draw_tile
    inc r13d
    cmp r13d, MAP_COLS
    jb .map_col
    inc r12d
    cmp r12d, MAP_ROWS
    jb .map_row

    xor r15d, r15d                                  ; r15d = fullscreen state (0 = windowed)

    ; ------------------------------------------------------------- ;
    ; INITIALIZE SDL2 1080P WINDOW & STREAMING TEXTURE              ;
    ; ------------------------------------------------------------- ;
    mov edi, SDL_INIT_VIDEO
    call SDL_Init
    test eax, eax
    js .exit_err

    lea rdi, [win_title]
    mov esi, SDL_WINDOWPOS_CENTERED
    mov edx, SDL_WINDOWPOS_CENTERED
    mov ecx, SCREEN_W
    mov r8d, SCREEN_H
    mov r9d, SDL_WINDOW_RESIZABLE
    call SDL_CreateWindow
    test rax, rax
    jz .quit_sdl
    mov r12, rax                                    ; r12 = SDL_Window*

    mov rdi, r12
    mov esi, -1
    mov edx, (SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC)
    call SDL_CreateRenderer
    test rax, rax
    jz .destroy_win
    mov r13, rax                                    ; r13 = SDL_Renderer*

    mov rdi, r13
    mov esi, SCREEN_W
    mov edx, SCREEN_H
    call SDL_RenderSetLogicalSize

    mov rdi, r13
    mov esi, SDL_PIXELFORMAT_ARGB8888
    mov edx, SDL_TEXTUREACCESS_STREAMING
    mov ecx, SCREEN_W
    mov r8d, SCREEN_H
    call SDL_CreateTexture
    test rax, rax
    jz .destroy_ren
    mov r14, rax                                    ; r14 = SDL_Texture*

; ================================================================= ;
; EVENT & DISPLAY LOOP                                              ;
; ================================================================= ;
.main_loop:
    lea rdi, [sdl_event]
    call SDL_PollEvent
    test eax, eax
    jz .present

    mov eax, dword [sdl_event]
    cmp eax, SDL_QUIT
    je .cleanup

    cmp eax, SDL_KEYDOWN
    jne .main_loop
    cmp byte [sdl_event + 13], 0                    ; Ignore key repeat
    jne .main_loop

    mov eax, dword [sdl_event + 16]                 ; keysym.scancode
    cmp eax, SDL_SCANCODE_ESCAPE
    je .cleanup
    cmp eax, SDL_SCANCODE_F11
    jne .main_loop

    xor r15d, SDL_WINDOW_FULLSCREEN_DESKTOP         ; Toggle borderless fullscreen
    mov rdi, r12
    mov esi, r15d
    call SDL_SetWindowFullscreen
    jmp .main_loop

.present:
    call glitch_frame                               ; base -> framebuffer (+ glitches)

    mov rdi, r14                                    ; Upload this frame
    xor esi, esi
    lea rdx, [framebuffer]
    mov ecx, SCREEN_PITCH
    call SDL_UpdateTexture

    mov rdi, r13
    call SDL_RenderClear
    mov rdi, r13
    mov rsi, r14
    xor edx, edx
    xor ecx, ecx
    call SDL_RenderCopy
    mov rdi, r13
    call SDL_RenderPresent                          ; Vsync paces the loop
    jmp .main_loop

.cleanup:
    mov rdi, r14
    call SDL_DestroyTexture
.destroy_ren:
    mov rdi, r13
    call SDL_DestroyRenderer
.destroy_win:
    mov rdi, r12
    call SDL_DestroyWindow
.quit_sdl:
    call SDL_Quit
    xor edi, edi
    jmp .exit_syscall
.exit_err:
    mov edi, 1
.exit_syscall:
    mov eax, 60
    syscall

; ================================================================= ;
; draw_tile: draw one 24x24 4BPP tile into a 1920x1080 buffer       ;
;   rdi = buffer, esi = map column, edx = map row, ecx = tile ID    ;
;   Each byte holds 2 pixels: high nibble = left, low nibble = right;
;   Clobbers rax, rcx, rdx, rdi, r8 to r11. Preserves rbx.          ;
; ================================================================= ;
draw_tile:
    push rbx
    imul eax, edx, TILE_SIZE * SCREEN_W             ; pixel index of tile's top-left
    imul r8d, esi, TILE_SIZE
    add eax, r8d
    lea r8, [rdi + rax*4]                           ; r8 = top-left pixel pointer
    imul ecx, ecx, TILE_BYTES
    lea r9, [Tiles]
    add r9, rcx                                     ; r9 = this tile's data (advances per byte)
    lea r10, [Palette]
    mov r11d, TILE_SIZE                             ; rows left

.row:
    mov rdi, r8
    mov ecx, ROW_BYTES                              ; 12 bytes = 24 pixels
.byte:
    movzx eax, byte [r9]
    mov ebx, eax
    shr ebx, 4                                      ; left pixel = high nibble
    mov ebx, [r10 + rbx*4]
    mov [rdi], ebx
    and eax, 0x0F                                   ; right pixel = low nibble
    mov eax, [r10 + rax*4]
    mov [rdi + 4], eax
    add rdi, 8
    inc r9
    dec ecx
    jnz .byte

    add r8, SCREEN_PITCH
    dec r11d
    jnz .row
    pop rbx
    ret

; ================================================================= ;
; rand: xorshift32. Out: eax = random. Clobbers edx.                ;
; rand_mod: in ecx = n. Out: eax = random 0..n-1. Clobbers edx.     ;
; ================================================================= ;
rand:
    mov eax, [rng_state]
    mov edx, eax
    shl edx, 13
    xor eax, edx
    mov edx, eax
    shr edx, 17
    xor eax, edx
    mov edx, eax
    shl edx, 5
    xor eax, edx
    mov [rng_state], eax
    ret

rand_mod:
    call rand
    xor edx, edx
    div ecx
    mov eax, edx
    ret

; ================================================================= ;
; glitch_frame: build this frame in 'framebuffer' from 'base'       ;
;   1. Copy the clean image                                         ;
;   2. Maybe start a burst; if in a burst:                          ;
;      - tear 2..6 horizontal bands sideways (wrapping)             ;
;        or split RGB in them (red shifted, green/blue in place)    ;
;      - draw a few random tiles in random cells                    ;
;   3. Apply scanlines (every frame, glitch or not)                 ;
;   Preserves rbx, rbp, r12 to r15.                                 ;
; ================================================================= ;
glitch_frame:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15

    lea rsi, [base]                                 ; 1. clean copy
    lea rdi, [framebuffer]
    mov ecx, TOTAL_PIXELS / 2
    rep movsq

    mov eax, [burst_left]                           ; 2. burst control
    test eax, eax
    jnz .active
    mov ecx, GLITCH_CHANCE
    call rand_mod
    test eax, eax
    jnz .done                                       ; no glitch this frame
    mov ecx, BURST_RAND
    call rand_mod
    add eax, BURST_MIN
    mov [burst_left], eax
.active:
    dec dword [burst_left]

    mov ecx, BANDS_MAX                              ; r12 = number of bands
    call rand_mod
    lea r12d, [rax + 2]

.band:
    mov ecx, SCREEN_H / BAND_STEP                   ; r13 = band top y (grid-snapped)
    call rand_mod
    imul r13d, eax, BAND_STEP
    mov ecx, 8                                      ; r14 = band height, 8..64 px
    call rand_mod
    inc eax
    imul r14d, eax, BAND_STEP
    lea eax, [r13 + r14]                            ; clamp to bottom of screen
    cmp eax, SCREEN_H
    jbe .height_ok
    mov r14d, SCREEN_H
    sub r14d, r13d
.height_ok:
    mov ecx, SHIFT_STEPS * 2 + 1                    ; r15 = shift, -96..+96 px
    call rand_mod
    sub eax, SHIFT_STEPS
    imul r15d, eax, BAND_STEP
    call rand                                       ; ebp = mode: 0 tear, 1 RGB split
    and eax, 1
    mov ebp, eax

.band_row:
    imul eax, r13d, SCREEN_PITCH                    ; byte offset of this scanline
    lea rsi, [base]
    add rsi, rax
    lea rdi, [framebuffer]
    add rdi, rax
    xor ecx, ecx                                    ; ecx = x
.band_px:
    mov eax, ecx                                    ; source x = (x - shift) wrapped
    sub eax, r15d
    test eax, eax
    jns .not_neg
    add eax, SCREEN_W
    jmp .wrapped
.not_neg:
    cmp eax, SCREEN_W
    jb .wrapped
    sub eax, SCREEN_W
.wrapped:
    mov edx, [rsi + rax*4]                          ; shifted pixel
    test ebp, ebp
    jz .store
    and edx, 0xFFFF0000                             ; RGB split: alpha+red from shifted pixel,
    mov ebx, [rsi + rcx*4]                          ; green+blue from the unshifted one
    and ebx, 0x0000FFFF
    or edx, ebx
.store:
    mov [rdi + rcx*4], edx
    inc ecx
    cmp ecx, SCREEN_W
    jb .band_px

    inc r13d
    dec r14d
    jnz .band_row
    dec r12d
    jnz .band

    mov ecx, CORRUPT_MAX                            ; tile corruption
    call rand_mod
    mov r12d, eax
    test eax, eax
    jz .done
.corrupt:
    mov ecx, MAP_COLS
    call rand_mod
    mov r13d, eax
    mov ecx, MAP_ROWS
    call rand_mod
    mov r14d, eax
    mov ecx, TILE_COUNT
    call rand_mod
    mov ecx, eax                                    ; random tile ID
    lea rdi, [framebuffer]
    mov esi, r13d
    mov edx, r14d
    call draw_tile
    dec r12d
    jnz .corrupt

.done:
    ; ------------------------------------------------------------- ;
    ; Scanlines: darken every SCANLINE_STEP-th row by 25%           ;
    ; c - (c >> 2) per channel; the mask keeps channels separate    ;
    ; and leaves alpha untouched.                                   ;
    ; ------------------------------------------------------------- ;
    lea rdi, [framebuffer]
    mov r8d, SCREEN_H / SCANLINE_STEP
.scan_row:
    mov rsi, rdi
    mov ecx, SCREEN_W
.scan_px:
    mov eax, [rsi]
    mov edx, eax
    shr edx, 2
    and edx, 0x003F3F3F
    sub eax, edx
    mov [rsi], eax
    add rsi, 4
    dec ecx
    jnz .scan_px
    add rdi, SCREEN_PITCH * SCANLINE_STEP
    dec r8d
    jnz .scan_row

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
