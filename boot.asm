[bits 16]
[org 0x7C00]

start:
    ; Инициализация сегментов
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    ; --- Тест int 10h AH=0x00: установка видеорежима 3 (80x25 текст).
    ; Должна сама очистить экран и сбросить курсор в 0,0 - если этого
    ; не произойдёт, весь дальнейший вывод будет "плыть".
    mov ax, 0x0003
    int 0x10

    mov si, msg_mode_ok
    call print_string

    ; --- Тест AH=0x02: ставим курсор на строку 5, колонку 10.
    mov ah, 0x02
    xor bh, bh
    mov dh, 5
    mov dl, 10
    int 0x10

    ; --- Тест AH=0x0E (через print_string): печатаем ровно в точке,
    ; куда только что поставили курсор через AH=0x02.
    mov si, msg_at_cursor
    call print_string

    ; --- Тест AH=0x03: читаем текущую позицию курсора и печатаем её
    ; как десятичные числа - после строки выше курсор должен стоять
    ; на той же строке (5), в колонке 10+длина(msg_at_cursor).
    mov si, msg_cursor_label
    call print_string
    mov ah, 0x03
    xor bh, bh
    int 0x10
    mov al, dh
    call print_dec_al
    mov si, msg_comma
    call print_string
    mov al, dl
    call print_dec_al
    mov si, crlf
    call print_string

    ; --- Тест AH=0x0F: читаем текущий видеорежим (-> AL) и число
    ; колонок (-> AH), печатаем оба как десятичные числа.
    mov si, msg_mode_label
    call print_string
    mov ah, 0x0F
    int 0x10
    mov cl, ah                   ; число колонок - сохраняем ДО print_string,
                                  ; т.к. она не сохраняет AX и затрёт его
    call print_dec_al            ; AL = режим
    mov si, msg_cols_label
    call print_string
    mov al, cl
    call print_dec_al
    mov si, crlf
    call print_string

    mov si, msg_prompt
    call print_string

    ; --- Ожидание символа из COM1 (для автоматизации через -serial stdio) ---
.wait_serial:
    mov dx, 0x3FD               ; Регистр статуса линии (LSR) для COM1
    in al, dx
    test al, 0x01                ; Data Ready?
    jz .wait_serial

    mov dx, 0x3F8
    in al, dx                    ; читаем и сбрасываем принятый байт

    mov si, msg_ok
    call print_string

.halt:
    hlt
    jmp .halt

; Подпрограмма вывода строк DS:SI на экран через int 10h AH=0x0E
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

; Печатает AL (0-255) как десятичное число через int 10h AH=0x0E
print_dec_al:
    push ax
    push bx
    push cx
    push dx

    xor ah, ah          ; ax = число (0-255)
    mov bx, 10
    xor cx, cx           ; cx = сколько цифр положили на стек

.divloop:
    xor dx, dx
    div bx                ; dx:ax / bx -> ax=частное, dx=остаток (цифра)
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

; Данные
msg_mode_ok:      db "AH=0x00 set mode 3: OK (screen cleared)", 13, 10, 0
msg_at_cursor:    db "<-- printed via AH=0x02+0x0E", 0
msg_cursor_label: db "AH=0x03 cursor row,col = ", 0
msg_comma:        db ",", 0
msg_mode_label:   db "AH=0x0F mode = ", 0
msg_cols_label:   db ", cols = ", 0
crlf:             db 13, 10, 0
msg_prompt:       db "Press ANY key (IN TERMINAL) to continue...", 13, 10, 0
msg_ok:           db 13, 10, "Success! System unhalted.", 13, 10, 0

times 510-($-$$) db 0
dw 0xAA55
