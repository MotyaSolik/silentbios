; =========================================================
; Вторая стадия тестового загрузчика - НЕ помещается в один сектор
; MBR, поэтому её читает stage1 (boot.asm) через int 13h AH=0x02 и
; передаёт сюда управление. Весь смысл в том, чтобы вывод был
; понятен человеку с первого взгляда - в отличие от компактных меток
; в самом boot.asm/дебажных тестах, здесь место не поджимает.
; org - тот же адрес (0x9000), куда stage1 её загружает.
; =========================================================
[bits 16]
[org 0x9000]

%include "disklayout.inc"

start2:
    mov si, banner
    call print_string

    ; ===== int 10h =====
    mov si, hdr10
    call print_string

    mov si, t10_02
    call print_string
    mov ah, 0x02
    xor bh, bh
    mov dh, 9
    mov dl, 2
    int 0x10
    mov si, ok
    call print_string

    mov si, t10_0e
    call print_string
    mov si, sample_text
    call print_string
    mov si, ok
    call print_string

    mov si, t10_03
    call print_string
    mov ah, 0x03
    xor bh, bh
    int 0x10
    mov si, s_row
    call print_string
    mov al, dh
    call print_dec_al
    mov si, s_col
    call print_string
    mov al, dl
    call print_dec_al
    mov si, crlf
    call print_string
    mov si, ok
    call print_string

    mov si, t10_0f
    call print_string
    mov ah, 0x0F
    int 0x10
    mov cl, al                  ; режим и число колонок - сохраняем в CX
    mov ch, ah                    ; (НЕ BX - print_string сама зануляет BH
                                     ; и ставит BL=0x07, а вот CX не трогает)
    mov si, s_mode
    call print_string
    mov al, cl
    call print_dec_al
    mov si, s_cols
    call print_string
    mov al, ch
    call print_dec_al
    mov si, crlf
    call print_string
    mov si, ok
    call print_string
    mov si, crlf
    call print_string

    ; ===== int 16h =====
    mov si, hdr16
    call print_string

    mov si, t16_00
    call print_string
    mov si, prompt3
    call print_string
    mov ah, 0x00
    int 0x16
    call print_char_al
    mov ah, 0x00
    int 0x16
    call print_char_al
    mov ah, 0x00
    int 0x16
    call print_char_al
    mov si, crlf
    call print_string
    mov si, ok
    call print_string

    mov si, t16_01
    call print_string
    mov si, prompt1
    call print_string
.wait_peek:
    mov ah, 0x01
    int 0x16
    jz .wait_peek

    mov dl, al                  ; символ - сохраняем в DX, НЕ BX (print_string
                                   ; сама зануляет BH и ставит BL=0x07)
    mov si, s_peek1
    call print_string
    mov al, dl
    call print_char_al
    mov si, crlf
    call print_string

    mov ah, 0x01
    int 0x16
    mov dl, al
    mov si, s_peek2
    call print_string
    mov al, dl
    call print_char_al
    mov si, crlf
    call print_string

    mov ah, 0x00
    int 0x16
    mov dl, al
    mov si, s_consumed
    call print_string
    mov al, dl
    call print_char_al
    mov si, crlf
    call print_string

    ; ВАЖНО: захватываем результат ZF в dl СРАЗУ после int 0x16, пока
    ; print_string его не затёрла (она тоже трогает флаги внутри себя).
    ; DX, не BX - см. комментарий выше.
    mov ah, 0x01
    int 0x16
    jz .is_empty
    xor dl, dl                   ; dl=0 -> клавиша всё ещё "висит" (баг)
    jmp .captured
.is_empty:
    mov dl, 1                     ; dl=1 -> пусто, как и должно быть
.captured:
    mov si, s_after
    call print_string
    cmp dl, 1
    je .empty_ok
    mov si, fail
    call print_string
    jmp .after_check
.empty_ok:
    mov si, ok
    call print_string
.after_check:
    mov si, crlf
    call print_string

    ; ===== int 13h =====
    mov si, hdr13
    call print_string

    mov si, t13_08
    call print_string
    mov ah, 0x08
    mov dl, 0x80
    int 0x13
    mov si, s_heads
    call print_string
    mov al, dh
    call print_dec_al
    mov si, s_spt
    call print_string
    mov al, cl
    and al, 0x3F
    call print_dec_al
    mov si, crlf
    call print_string
    mov si, ok
    call print_string

    ; читаем 2 демо-сектора, лежащие на диске СРАЗУ ПОСЛЕ секторов
    ; самой stage2 (см. DATA_SECTOR в boot.asm) - известный текстовый
    ; паттерн, чтобы сверить содержимое глазами
    mov si, t13_02
    call print_string
    mov ax, 0x0202
    mov ch, 0
    mov cl, DATA_SECTOR
    mov dh, 0
    mov dl, 0x80
    mov bx, 0xA000
    int 0x13
    mov dl, al                  ; число прочитанных секторов - сохраняем в DX
                                   ; (НЕ BX - см. комментарий у AH=0x0F выше;
                                   ; и не сам BX - int13h его тоже не сохраняет)
    mov si, s_read
    call print_string
    mov al, dl
    call print_dec_al
    mov si, s_sectors
    call print_string

    mov si, s_sector_a
    call print_string
    mov si, 0xA000
    mov cx, 19
.pr1:
    lodsb
    call print_char_al
    loop .pr1
    mov si, crlf
    call print_string

    mov si, s_sector_b
    call print_string
    mov si, 0xA200
    mov cx, 19
.pr2:
    lodsb
    call print_char_al
    loop .pr2
    mov si, crlf
    call print_string
    mov si, ok
    call print_string
    mov si, crlf
    call print_string

    mov si, footer
    call print_string

.halt:
    hlt
    jmp .halt

; --- вывод строк/символов - те же примитивы, что и в boot.asm ---
print_string:
    mov ah, 0x0E
    xor bh, bh
    mov bl, 0x07
.loop:
    lodsb
    cmp al, 0
    je .done
    int 0x10
    jmp .loop
.done:
    ret

print_char_al:
    mov ah, 0x0E
    int 0x10
    ret

print_dec_al:
    push ax
    push bx
    push cx
    push dx

    xor ah, ah
    mov bx, 10
    xor cx, cx

.divloop:
    xor dx, dx
    div bx
    push dx
    inc cx
    test ax, ax
    jnz .divloop

.printloop:
    pop dx
    add dl, '0'
    mov ah, 0x0E
    mov al, dl
    int 0x10
    loop .printloop

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; --- тексты ---
crlf:         db 13, 10, 0
ok:           db "  -> OK", 13, 10, 0
fail:         db "  -> FAIL (unexpected!)", 13, 10, 0

banner:       db 13, 10
              db "=========================================================", 13, 10
              db "  SilentBIOS live test - int 10h / int 16h / int 13h", 13, 10
              db "  (this whole screen was loaded via int 13h by stage 1)", 13, 10
              db "=========================================================", 13, 10, 13, 10, 0

hdr10:        db "--- int 10h (video services) ---", 13, 10, 0
t10_02:       db "AH=0x02 Set cursor to row 9, col 2...", 13, 10, 0
t10_0e:       db "AH=0x0E Print text at that position: ", 0
sample_text:  db "Hello from int 10h!", 13, 10, 0
t10_03:       db "AH=0x03 Read cursor back:", 0
s_row:        db " row=", 0
s_col:        db " col=", 0
t10_0f:       db "AH=0x0F Read video mode:", 0
s_mode:       db " mode=", 0
s_cols:       db " cols=", 0

hdr16:        db "--- int 16h (keyboard services) ---", 13, 10, 0
t16_00:       db "AH=0x00 Blocking read.", 13, 10, 0
prompt3:      db "  Type any 3 keys now: ", 0
t16_01:       db "AH=0x01 Non-blocking check (peek, then consume).", 13, 10, 0
prompt1:      db "  Press one more key: ", 13, 10, 0
s_peek1:      db "  peek #1 (not consumed): ", 0
s_peek2:      db "  peek #2 (same key, still not consumed): ", 0
s_consumed:   db "  now consumed via AH=0x00: ", 0
s_after:      db "  buffer empty after consume?", 0

hdr13:        db "--- int 13h (disk services) ---", 13, 10, 0
t13_08:       db "AH=0x08 Get drive parameters:", 0
s_heads:      db " heads=", 0
s_spt:        db " sectors/track=", 0
t13_02:       db "AH=0x02 Read 2 known data sectors from disk...", 13, 10, 0
s_read:       db "  sectors actually read: ", 0
s_sectors:    db 13, 10, 0
s_sector_a:   db "  1st sector says: ", 0
s_sector_b:   db "  2nd sector says: ", 0

footer:       db 13, 10
              db "=========================================================", 13, 10
              db "  All tests ran. If everything above says OK and the two", 13, 10
              db "  disk sectors show 'DATA-OK', the BIOS is working.", 13, 10
              db "  System halted - close this window or reset to try again.", 13, 10
              db "=========================================================", 13, 10, 0
