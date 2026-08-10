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
    ; как десятичные числа (row,col - должны отражать, где реально
    ; остановился курсор после печати строки выше).
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

    ; --- Тест int 16h AH=0x00: блокирующее чтение символа (3 раза),
    ; каждый раз эхо через int 10h AH=0x0E. Проверяет и саму трансляцию
    ; Scan Set 2 -> ASCII, и учёт состояния Shift.
    mov si, msg_kbd1
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

    ; --- Тест int 16h AH=0x01: неблокирующая проверка. Ждём клавишу
    ; поллингом AH=0x01 (сам по себе демонстрирует неблокирующее ZF),
    ; затем дважды "подсматриваем" (peek) - оба раза должен быть один
    ; и тот же символ, т.к. AH=0x01 не потребляет клавишу. Потом
    ; потребляем через AH=0x00 (тот же символ) и проверяем, что после
    ; этого AH=0x01 честно говорит "клавиш нет" (ZF=1).
    mov si, msg_kbd2
    call print_string
.wait_peek:
    mov ah, 0x01
    int 0x16
    jz .wait_peek

    call print_char_al           ; peek #1
    mov ah, 0x01
    int 0x16
    call print_char_al           ; peek #2 - должен совпасть с #1

    mov ah, 0x00
    int 0x16
    call print_char_al           ; потребили - тот же символ

    mov ah, 0x01
    int 0x16
    jz .empty_ok
    mov al, 'X'                  ; БАГ: клавиша всё ещё "висит" после потребления
    jmp .empty_print
.empty_ok:
    mov al, 'E'                  ; OK: после потребления буфер пуст
.empty_print:
    call print_char_al
    mov si, crlf
    call print_string

    ; --- Тест int 13h AH=0x08: параметры диска (макс.головка, SPT) ---
    mov si, msg13_params
    call print_string
    mov ah, 0x08
    mov dl, 0x80
    int 0x13
    mov al, dh
    call print_dec_al
    mov si, msg_comma
    call print_string
    mov al, cl
    and al, 0x3F
    call print_dec_al
    mov si, crlf
    call print_string

    ; --- Тест int 13h AH=0x02: читаем 2 сектора (CHS 0,0,2) в 0x8000 -
    ; сектора 2 и 3 на диске несут известный текстовый паттерн (см.
    ; конец файла), печатаем их обратно, чтобы сверить содержимое.
    mov si, msg13_read
    call print_string
    mov ax, 0x0202
    mov ch, 0
    mov cl, 2
    mov dh, 0
    mov dl, 0x80
    mov bx, 0x8000
    int 0x13
    call print_dec_al             ; AL = число реально прочитанных секторов
    mov si, crlf
    call print_string

    mov si, 0x8000
    mov cx, 19
.p13_1:
    lodsb
    call print_char_al
    loop .p13_1
    mov si, crlf
    call print_string

    mov si, 0x8200
    mov cx, 19
.p13_2:
    lodsb
    call print_char_al
    loop .p13_2
    mov si, crlf
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

; Печатает один символ из AL через int 10h AH=0x0E
print_char_al:
    mov ah, 0x0E
    int 0x10
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
msg_mode_ok:      db "M3clr", 13, 10, 0
msg_at_cursor:    db "X02E", 0
msg_cursor_label: db "cur=", 0
msg_comma:        db ",", 0
msg_mode_label:   db "mode=", 0
msg_cols_label:   db ",cols=", 0
crlf:             db 13, 10, 0
msg_kbd1:         db "K00:", 0
msg_kbd2:         db 13, 10, "K01:", 0
msg13_params:     db "13/08 hd,spt=", 0
msg13_read:       db "13/02 read=", 0

times 510-($-$$) db 0
dw 0xAA55

; --- Секторы 2 и 3 диска (LBA=1,2) - известный текстовый паттерн для
; проверки int 13h AH=0x02 (не часть загружаемого кода - обычный
; загрузчик их сюда не положит, это только для теста). ---
sector2_data:
db "SECTOR2-DATA-OK!!!!"
times 512-($-sector2_data) db 0x00

sector3_data:
db "SECTOR3-DATA-OK!!!!"
times 512-($-sector3_data) db 0x00
