[bits 16]
[org 0x0000]

; =========================================================
; ВАЖНО про память:
;   CS = DS = 0xF000 - это сегмент самого ROM-образа. В реальном
;   железе это Flash-память: она доступна на ЧТЕНИЕ, но запись
;   в неё либо игнорируется, либо не работает как обычная RAM.
;   Поэтому любые переменные, которые код должен МЕНЯТЬ (курсор
;   VGA, буфер под число и т.п.), нельзя хранить внутри самого
;   ROM-образа - их нужно держать в настоящей RAM.
;
;   Ниже используется низкая память сразу после IVT (0x000-0x3FF)
;   и BDA (0x400-0x4FF) - с адреса 0x500, куда никто до нас ещё
;   ничего не положил. SS всегда равен 0x0000, поэтому все "наши"
;   переменные адресуются через префикс ss: - это не зависит от
;   того, что в данный момент лежит в DS.
; =========================================================
RAM_VGA_POS  equ 0x0500      ; word: смещение курсора в видеопамяти
RAM_DEC_BUF  equ 0x0502      ; 8 байт: буфер для печати чисел
RAM_MENU_SEL equ 0x050A      ; word: индекс выбранного пункта меню
RAM_SERIAL_ON equ 0x050C     ; byte: 1 = COM1-вывод включён
RAM_VGA_ON    equ 0x050D     ; byte: 1 = VGA-вывод включён
RAM_BREAK_FLAG equ 0x050E    ; byte: 1, если только что пришёл префикс F0 (break)
RAM_VIDEO_MODE equ 0x050F    ; byte: текущий видеорежим (для int 10h AH=0x0F)

start:
    cli
    cld

    ; DS = CS (читаем строки-константы прямо из ROM)
    mov ax, cs
    mov ds, ax

    ; SS:SP - стек в RAM. После RESET SS:SP не определены,
    ; ставим сами в безопасное место в conventional-памяти.
    xor ax, ax
    mov ss, ax
    mov sp, 0x7C00

    ; Настройки тумблеров грузим из CMOS/NVRAM (если там уже есть
    ; наша сигнатура) или заводим значения по умолчанию. Это должно
    ; быть ДО первого вызова print_serial/print_vga, иначе они
    ; прочитают мусор из ещё не инициализированной RAM.
    call cmos_load_settings

    ; Устанавливаем вектор int 10h в IVT (0000:0040, т.к. запись
    ; под номер N лежит по адресу N*4) - чтобы загруженный код/ОС
    ; мог пользоваться обычным "int 10h" вместо прямого call наших
    ; функций, как это делает настоящий BIOS.
    call install_int10h_vector

    call init_serial

    mov si, msg_banner
    call print_serial

    ; У нас нет отдельного видео-BIOS/option ROM, поэтому VGA
    ; остаётся в состоянии "экран не инициализирован" (так делают
    ; и QEMU, и настоящее железо), пока мы сами не выставим регистры
    ; контроллера в режим 80x25 text (0x03).
    call vga_set_mode3
    mov byte [ss:RAM_VIDEO_MODE], 0x03

    ; Своей видео-BIOS у нас нет, поэтому и растровый шрифт для
    ; текстового режима никто не загрузит - его нужно самим
    ; закачать в Character Generator RAM (это "план 2" видеопамяти).
    call vga_load_font

    mov word [ss:RAM_VGA_POS], 0
    mov si, msg_banner
    call print_vga

    call post_memory_test
    call post_keyboard_test

    mov si, msg_done
    call print_serial
    mov si, msg_done
    call print_vga

    call setup_menu

    ; Setup закрыт - продолжаем обычную последовательность загрузки:
    ; пробуем найти и загрузить MBR с диска (как это делает
    ; настоящий BIOS после POST/setup).
    call boot_try_disk

halt_cpu:
    hlt
    jmp halt_cpu

; =========================================================
; COM1: инициализация 9600 8N1
; =========================================================
init_serial:
    push ax
    push dx

    mov dx, 0x3FB
    mov al, 0x80
    out dx, al

    mov dx, 0x3F8
    mov al, 12
    out dx, al

    mov dx, 0x3F9
    xor al, al
    out dx, al

    mov dx, 0x3FB
    mov al, 0x03
    out dx, al

    pop dx
    pop ax
    ret

; Печать ASCIIZ-строки DS:SI в COM1.
; Управляется тумблером RAM_SERIAL_ON из setup-меню.
print_serial:
    cmp byte [ss:RAM_SERIAL_ON], 0
    je .noop
    push ax
    push bx
    push dx
.next_char:
    lodsb
    cmp al, 0
    jz .done
    mov bl, al
.wait_tx:
    mov dx, 0x3FD
    in al, dx
    test al, 0x20
    jz .wait_tx
    mov dx, 0x3F8
    mov al, bl
    out dx, al
    jmp .next_char
.done:
    pop dx
    pop bx
    pop ax
    ret
.noop:
    ret

; =========================================================
; VGA текстовый режим 80x25, память 0xB800:0000, атрибут 0x07
; Курсор хранится в RAM (RAM_VGA_POS), а не в сегменте ROM.
; =========================================================
; =========================================================
; Настоящее CPU-прерывание int 10h (видео-сервисы), как в
; обычном BIOS. IVT - это просто массив из 256 дальних указателей
; (offset:segment по 2 слова) в самом начале памяти (0000:0000),
; запись под номером N лежит по адресу N*4. CPU сам обращается
; туда при выполнении "int N" - никакого отдельного механизма
; ловить это не нужно, достаточно один раз прописать адрес нашего
; обработчика в нужную ячейку.
;
; Поддерживаются функции:
;   AH=0x0E - teletype output (самая ходовая, ей пользуется абсолютное
;             большинство boot-кода/ОС для вывода текста)
;   AH=0x00 - установка видеорежима (только режим 0x03, 80x25 текст)
;   AH=0x02 - установка позиции курсора (DH=строка, DL=колонка, BH=страница)
;   AH=0x03 - чтение позиции курсора (-> DH/DL, CX=форма курсора)
;   AH=0x0F - чтение текущего видеорежима (-> AL=режим, AH=колонки, BH=стр.)
; Прочие функции пока просто тихо игнорируются - вернуть управление без
; ошибки безопаснее, чем зависнуть или уронить вызывающий код.
;
; Регистровая конвенция: ISR сама сохраняет только ds/es/si/di/bp - НЕ
; ax/bx/cx/dx, потому что "get"-функции (0x03, 0x0F) обязаны вернуть
; результат вызывающему коду именно через эти регистры. Поэтому каждый
; обработчик ниже сам решает, что ему нужно: "set"-функции (0x0E, 0x00,
; 0x02) push/pop-ят использованные регистры внутри себя, чтобы не
; испортить состояние вызывающего кода, а "get"-функции (0x03, 0x0F)
; сознательно ничего не восстанавливают в тех регистрах, где должны
; вернуть результат.
; =========================================================
install_int10h_vector:
    push ax
    push es

    xor ax, ax
    mov es, ax
    mov word [es:0x10*4], int10h_isr     ; offset обработчика
    mov word [es:0x10*4+2], cs             ; сегмент обработчика (=CS ROM)

    pop es
    pop ax
    ret

int10h_isr:
    push si
    push di
    push bp
    push ds
    push es

    ; ISR - код исполняется с "чужим" DS/ES (тем, что было у
    ; вызывающего кода на момент int 10h), а наши функции читают
    ; RAM_VGA_POS/RAM_VGA_ON через ss: (SS у нас всегда 0x0000),
    ; так что от DS/ES их результат не зависит - явно переключать
    ; их не нужно.
    cmp ah, 0x0E
    je .fn_0E
    cmp ah, 0x00
    je .fn_00
    cmp ah, 0x02
    je .fn_02
    cmp ah, 0x03
    je .fn_03
    cmp ah, 0x0F
    je .fn_0F
    jmp .done               ; неподдерживаемая функция - молча игнорируем

.fn_0E:
    call vga_char_out       ; AL уже содержит символ от вызывающего
    jmp .done
.fn_00:
    call int10h_set_mode
    jmp .done
.fn_02:
    call int10h_set_cursor
    jmp .done
.fn_03:
    call int10h_get_cursor
    jmp .done
.fn_0F:
    call int10h_get_mode

.done:
    pop es
    pop ds
    pop bp
    pop di
    pop si
    iret

; Ставит аппаратный курсор CRTC (регистры 0x0E/0x0F - cursor location
; high/low, индекс/данные через порты 0x3D4/0x3D5) в позицию AX
; (символьное смещение row*80+col - БЕЗ умножения на 2, в отличие от
; RAM_VGA_POS, который хранит байтовое смещение в видеопамяти).
vga_set_hw_cursor:
    push ax
    push bx
    push dx

    mov bx, ax

    mov dx, 0x3D4
    mov al, 0x0E
    out dx, al
    inc dx
    mov al, bh
    out dx, al
    dec dx

    mov al, 0x0F
    out dx, al
    inc dx
    mov al, bl
    out dx, al

    pop dx
    pop bx
    pop ax
    ret

; int 10h AH=0x00 - установка видеорежима. Поддерживается только
; AL=0x03 (80x25 текст) - реально это единственный режим, который эта
; BIOS умеет программировать, так что для любого другого значения AL
; честнее промолчать, чем делать вид, что режим сменился.
int10h_set_mode:
    push ax
    push cx
    push dx
    push si

    cmp al, 0x03
    jne .done

    call vga_set_mode3
    call vga_clear_screen
    mov word [ss:RAM_VGA_POS], 0
    mov byte [ss:RAM_VIDEO_MODE], 0x03

    xor ax, ax
    call vga_set_hw_cursor

.done:
    pop si
    pop dx
    pop cx
    pop ax
    ret

; int 10h AH=0x02 - установка позиции курсора. Вход: DH=строка(0-24),
; DL=колонка(0-79), BH=страница (игнорируется - у нас только одна
; страница). "Set"-функция - не должна менять регистры вызывающего,
; поэтому всё, что использует, сохраняет и восстанавливает сама.
int10h_set_cursor:
    push ax
    push bx
    push cx
    push dx

    ; отбрасываем координаты за пределами видимой области 80x25,
    ; иначе легко улететь за пределы видеопамяти
    cmp dl, 80
    jb .col_ok
    mov dl, 79
.col_ok:
    cmp dh, 25
    jb .row_ok
    mov dh, 24
.row_ok:

    ; mul затирает весь DX, поэтому колонку (DL) забираем в BX ДО
    ; умножения (тот же приём, что и в vga_print_at).
    xor bh, bh
    mov bl, dl

    xor ax, ax
    mov al, dh
    mov cx, 80
    mul cx                    ; ax = строка*80 (dx теперь мусор)
    add ax, bx                 ; ax = row*80+col (символьное смещение)

    push ax
    call vga_set_hw_cursor
    pop ax

    shl ax, 1                   ; -> байтовое смещение для RAM_VGA_POS
    mov [ss:RAM_VGA_POS], ax

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; int 10h AH=0x03 - чтение позиции курсора. Выход: DH=строка,
; DL=колонка, CX=форма курсора (CH=начальная, CL=конечная строка
; развёртки). BH (страница) не трогаем - у нас она всегда 0. "Get"-
; функция - CX/DX сознательно не восстанавливаются, в них возвращается
; результат; AX используется только как scratch, поэтому его сохраняем.
int10h_get_cursor:
    push ax
    push si

    mov si, [ss:RAM_VGA_POS]   ; байтовое смещение
    shr si, 1                    ; -> символьное смещение (row*80+col)

    xor dx, dx
    mov ax, si
    mov cx, 80
    div cx                       ; ax = строка, dx = колонка (остаток)
    mov dh, al
    mov cx, 0x0607                ; стандартная форма текстового курсора

    pop si
    pop ax
    ret

; int 10h AH=0x0F - чтение видеорежима. Выход: AL=режим, AH=число
; колонок (80), BH=активная страница (0). "Get"-функция - AX/BH
; сознательно не восстанавливаются, в них возвращается результат.
int10h_get_mode:
    mov al, [ss:RAM_VIDEO_MODE]
    mov ah, 80
    mov bh, 0
    ret

; Печать ASCIIZ-строки DS:SI на экран, поддерживает 13,10 (CR/LF).
; Управляется тумблером RAM_VGA_ON из setup-меню.
; Посимвольная логика вынесена в vga_char_out - её же использует
; обработчик int 10h (AH=0x0E), чтобы поведение не расходилось.
print_vga:
    cmp byte [ss:RAM_VGA_ON], 0
    je .noop
    push ax
    push si
.next_char:
    lodsb
    cmp al, 0
    jz .done
    call vga_char_out
    jmp .next_char
.done:
    pop si
    pop ax
    ret
.noop:
    ret

; Печать ОДНОГО символа на экран (AL=символ). Сама проверяет
; тумблер RAM_VGA_ON и сама ставит ES=0xB800 - самодостаточна,
; можно звать откуда угодно, в том числе из ISR прерывания.
vga_char_out:
    push ax
    push bx
    push cx
    push dx
    push es

    cmp byte [ss:RAM_VGA_ON], 0
    je .done

    push ax
    mov ax, 0xB800
    mov es, ax
    pop ax

    cmp al, 13
    je .done              ; CR игнорируем (перевод строки - через 10/LF)
    cmp al, 10
    je .newline

    mov bx, [ss:RAM_VGA_POS]
    mov [es:bx], al
    inc bx
    mov byte [es:bx], 0x07
    inc bx
    mov [ss:RAM_VGA_POS], bx
    jmp .done

.newline:
    mov bx, [ss:RAM_VGA_POS]
    xor dx, dx
    mov ax, bx
    mov cx, 160            ; 80 колонок * 2 байта
    div cx                  ; ax = номер строки, dx = остаток (не нужен)
    inc ax
    mul cx                   ; ax = ax * 160 = начало следующей строки
    mov [ss:RAM_VGA_POS], ax

.done:
    pop es
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =========================================================
; Ручная настройка VGA в текстовый режим 80x25 (аналог режима 03h).
; Без видео-BIOS/option ROM карта сама в этот режим не встанет -
; программируем Sequencer, CRTC, Graphics Controller и Attribute
; Controller напрямую через порты. Это стандартный, общеизвестный
; набор регистровых значений для режима 03h.
; =========================================================
vga_set_mode3:
    push ax
    push cx
    push dx
    push si

    ; Misc Output Register
    mov dx, 0x3C2
    mov al, 0x67
    out dx, al

    ; Sequencer (0x3C4/0x3C5), регистры 0..4
    mov dx, 0x3C4
    mov si, seq_regs
    xor cx, cx
.seq_loop:
    mov al, cl
    out dx, al
    inc dx
    mov al, [cs:si]
    out dx, al
    dec dx
    inc si
    inc cx
    cmp cx, 5
    jb .seq_loop

    ; Снимаем защиту с регистров CRTC 0..7 (сбрасываем protect-бит в reg 0x11)
    mov dx, 0x3D4
    mov al, 0x11
    out dx, al
    inc dx
    xor al, al
    out dx, al
    dec dx

    ; CRTC (0x3D4/0x3D5), регистры 0..0x18 (25 штук)
    mov si, crtc_regs
    xor cx, cx
.crtc_loop:
    mov al, cl
    out dx, al
    inc dx
    mov al, [cs:si]
    out dx, al
    dec dx
    inc si
    inc cx
    cmp cx, 25
    jb .crtc_loop

    ; Graphics Controller (0x3CE/0x3CF), регистры 0..8
    mov dx, 0x3CE
    mov si, gc_regs
    xor cx, cx
.gc_loop:
    mov al, cl
    out dx, al
    inc dx
    mov al, [cs:si]
    out dx, al
    dec dx
    inc si
    inc cx
    cmp cx, 9
    jb .gc_loop

    ; Attribute Controller (0x3C0) - индекс и данные пишутся в один
    ; и тот же порт, переключение по внутреннему flip-flop
    mov dx, 0x3DA
    in al, dx              ; чтение сбрасывает flip-flop в состояние "индекс"
    mov dx, 0x3C0
    mov si, ac_regs
    xor cx, cx
.ac_loop:
    mov al, cl
    out dx, al              ; индекс (бит5=0 -> экран выключен на время загрузки)
    mov al, [cs:si]
    out dx, al              ; данные
    inc si
    inc cx
    cmp cx, 21
    jb .ac_loop

    mov al, 0x20             ; бит5=1 -> включить вывод обратно
    out dx, al

    ; DAC (0x3C8/0x3C9): без своей видео-BIOS палитра после сброса
    ; не гарантированно проинициализирована - если не задать её
    ; явно, текст может оказаться "серым по чёрному", где оба
    ; цвета физически одинаковы (чёрные) и ничего не видно.
    ; Пишем стандартную 16-цветную EGA/VGA-палитру (компоненты 0-63).
    xor al, al
    mov dx, 0x3C8
    out dx, al              ; начинаем запись с индекса 0
    inc dx                   ; dx = 0x3C9 (порт данных R,G,B)

    mov si, dac_palette
    mov cx, 48               ; 16 цветов * 3 байта (R,G,B)
.dac_loop:
    mov al, [cs:si]
    out dx, al
    inc si
    loop .dac_loop

    pop si
    pop dx
    pop cx
    pop ax
    ret

; Стандартная 16-цветная палитра EGA/VGA, компоненты R,G,B (0-63)
dac_palette:
    db 0,0,0        ; 0  чёрный
    db 0,0,42       ; 1  синий
    db 0,42,0       ; 2  зелёный
    db 0,42,42      ; 3  голубой
    db 42,0,0       ; 4  красный
    db 42,0,42      ; 5  пурпурный
    db 42,21,0      ; 6  коричневый
    db 42,42,42     ; 7  светло-серый
    db 21,21,21     ; 8  тёмно-серый
    db 21,21,63     ; 9  ярко-синий
    db 21,63,21     ; 10 ярко-зелёный
    db 21,63,63     ; 11 ярко-голубой
    db 63,21,21     ; 12 ярко-красный
    db 63,21,63     ; 13 ярко-пурпурный
    db 63,63,21     ; 14 жёлтый
    db 63,63,63     ; 15 белый

seq_regs:  db 0x03, 0x00, 0x03, 0x00, 0x02
crtc_regs: db 0x5F,0x4F,0x50,0x82,0x55,0x81,0xBF,0x1F,0x00,0x4F, \
              0x0D,0x0E,0x00,0x00,0x00,0x50,0x9C,0x0E,0x8F,0x28, \
              0x1F,0x96,0xB9,0xA3,0xFF
gc_regs:   db 0x00,0x00,0x00,0x00,0x00,0x10,0x0E,0x00,0xFF
; Внутренние палитровые регистры Attribute Controller (индексы 0-15):
; используем прямое отображение атрибут-цвет -> DAC-индекс (0x00-0x0F),
; чтобы совпадать с нашей таблицей dac_palette (мы её тоже программируем
; только для входов 0-15, а не для классического EGA-смещения 0x38-0x3F).
ac_regs:   db 0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09, \
              0x0A,0x0B,0x0C,0x0D,0x0E,0x0F,0x0C,0x00,0x0F,0x08,0x00

; =========================================================
; Загрузка растрового шрифта 8x16 в Character Generator RAM
; (план 2 видеопамяти VGA). Без этого текстовый режим просто
; ничего не рисует - глифов нет ни у одного символа.
; Сами байты шрифта (256 символов * 16 байт) подключаются как
; готовый бинарный файл через incbin.
; =========================================================
vga_load_font:
    push ax
    push cx
    push dx
    push es
    push si
    push di

    ; Переключаемся на прямой доступ к плану 2 (там живёт шрифт)
    mov dx, 0x3C4
    mov ax, 0x0402        ; Map Mask: только план 2
    out dx, ax
    mov ax, 0x0704        ; Memory Mode: линейная адресация (без odd/even)
    out dx, ax

    mov dx, 0x3CE
    mov ax, 0x0005        ; Graphics Mode: write mode 0
    out dx, ax
    mov ax, 0x0406        ; Misc: графическое окно 0xA0000-0xAFFFF
    out dx, ax

    mov ax, 0xA000
    mov es, ax
    xor di, di
    mov si, vga_font_data
    mov cx, 256
.char_loop:
    push cx
    mov cx, 16
.byte_loop:
    mov al, [cs:si]
    mov [es:di], al
    inc si
    inc di
    loop .byte_loop
    add di, 16              ; слот символа - 32 байта, мы заполнили только 16
    pop cx
    loop .char_loop

    ; Возвращаем контроллер в обычный текстовый режим (планы 0+1,
    ; окно 0xB8000) - те же значения, что и в vga_set_mode3.
    mov dx, 0x3C4
    mov ax, 0x0302
    out dx, ax
    mov ax, 0x0204
    out dx, ax

    mov dx, 0x3CE
    mov ax, 0x1005
    out dx, ax
    mov ax, 0x0E06
    out dx, ax

    pop di
    pop si
    pop es
    pop dx
    pop cx
    pop ax
    ret

vga_font_data:
incbin "font.bin"

; =========================================================
; POST: тест conventional-памяти (0..640KB), блоками по 64KB.
; Сегмент 0x0000 сырыми записями по offset 0 не трогаем, чтобы
; не повредить IVT/BDA - раз код вообще выполняется и стек
; работает, первые 64KB уже заведомо рабочие, засчитываем сразу.
; =========================================================
post_memory_test:
    push ax
    push bx
    push cx
    push dx
    push es

    mov si, msg_mem_test
    call print_serial
    mov si, msg_mem_test
    call print_vga

    mov cx, 1              ; первый блок (сегмент 0) уже "дан по умолчанию"
    mov bx, 0x1000          ; тестируем со следующего 64KB-сегмента

.test_block:
    cmp bx, 0xA000            ; 640KB / 64KB = 10 блоков -> до сегмента 0x9000
    jae .test_done

    mov es, bx
    mov word [es:0], 0x1234
    cmp word [es:0], 0x1234
    jne .test_done

    mov word [es:0], 0x5678
    cmp word [es:0], 0x5678
    jne .test_done

    inc cx
    add bx, 0x1000
    jmp .test_block

.test_done:
    mov ax, cx
    mov dx, 64
    mul dx                 ; ax = cx * 64 = итог в KB
    call print_dec_ax

    mov si, msg_kb
    call print_serial
    mov si, msg_kb
    call print_vga

    pop es
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =========================================================
; POST: самотест контроллера клавиатуры 8042 (команда 0xAA)
; =========================================================
post_keyboard_test:
    push ax
    push cx

    mov si, msg_kbd_test
    call print_serial
    mov si, msg_kbd_test
    call print_vga

    mov cx, 0xFFFF
.wait_input_empty:
    in al, 0x64
    test al, 0x02
    jz .send_cmd
    loop .wait_input_empty
    jmp .kbd_fail

.send_cmd:
    mov al, 0xAA
    out 0x64, al

    mov cx, 0xFFFF
.wait_output_full:
    in al, 0x64
    test al, 0x01
    jnz .read_result
    loop .wait_output_full
    jmp .kbd_fail

.read_result:
    in al, 0x60
    cmp al, 0x55
    jne .kbd_fail

    mov si, msg_ok
    call print_serial
    mov si, msg_ok
    call print_vga
    jmp .kbd_done

.kbd_fail:
    mov si, msg_fail
    call print_serial
    mov si, msg_fail
    call print_vga

.kbd_done:
    pop cx
    pop ax
    ret

; =========================================================
; Печать беззнакового 16-битного числа из AX (0..65535).
; Буфер под цифры лежит в RAM (RAM_DEC_BUF), поэтому на время
; сборки и печати числа DS временно переключается на RAM
; (сегмент 0x0000), а не на сегмент ROM.
; =========================================================
print_dec_ax:
    push bx
    push cx
    push dx
    push si
    push ds

    push ax
    xor ax, ax
    mov ds, ax              ; DS = 0x0000 (RAM), там лежит RAM_DEC_BUF
    pop ax                   ; восстановили число для печати

    mov bx, 10
    xor cx, cx

    cmp ax, 0
    jne .divloop
    mov byte [RAM_DEC_BUF], '0'
    mov byte [RAM_DEC_BUF+1], 0
    jmp .print_it

.divloop:
    cmp ax, 0
    je .after_div
    xor dx, dx
    div bx
    add dl, '0'
    push dx
    inc cx
    jmp .divloop

.after_div:
    mov si, RAM_DEC_BUF
.pop_digits:
    cmp cx, 0
    je .terminate
    pop dx
    mov [si], dl
    inc si
    dec cx
    jmp .pop_digits
.terminate:
    mov byte [si], 0

.print_it:
    mov si, RAM_DEC_BUF
    call print_serial
    mov si, RAM_DEC_BUF
    call print_vga

    pop ds
    pop si
    pop dx
    pop cx
    pop bx
    ret

; =========================================================
; Очистка экрана: заполняет все 80x25 знакомест пробелом
; с атрибутом 0x07 (светло-серый на чёрном).
; =========================================================
vga_clear_screen:
    push ax
    push cx
    push di
    push es

    mov ax, 0xB800
    mov es, ax
    xor di, di
    mov cx, 80*25
.clear_loop:
    mov word [es:di], 0x0720   ; младший байт - символ(0x20), старший - атрибут(0x07)
    add di, 2
    loop .clear_loop

    pop es
    pop di
    pop cx
    pop ax
    ret

; =========================================================
; Печать строки в произвольном месте экрана (для меню), в
; отличие от print_vga не трогает RAM_VGA_POS и не понимает
; переносы строк - строки должны быть однострочными.
; Вход: DH=строка(0-24), DL=колонка(0-79), BL=атрибут, DS:SI=ASCIIZ
; =========================================================
vga_print_at:
    push ax
    push cx
    push dx
    push es
    push di

    mov ax, 0xB800
    mov es, ax

    ; ВАЖНО: mul затирает весь DX, поэтому колонку (DL) нужно
    ; забрать в другой регистр ДО умножения, иначе она обнулится.
    xor ch, ch
    mov cl, dl              ; cx = колонка (сохраняем, пока DX ещё цел)
    shl cx, 1                ; cx = col*2 (байт на знакоместо)
    push cx                   ; сохраняем на стеке, т.к. mul использует cx

    xor ax, ax
    mov al, dh
    mov cx, 160
    mul cx                     ; ax = row*160 (dx теперь мусор - не используем)

    pop cx                      ; cx = col*2
    add ax, cx
    mov di, ax

.next_char:
    lodsb
    cmp al, 0
    je .done
    mov [es:di], al
    mov [es:di+1], bl
    add di, 2
    jmp .next_char

.done:
    pop di
    pop es
    pop dx
    pop cx
    pop ax
    ret

; =========================================================
; Интерактивное setup-меню: стрелки вверх/вниз, Enter, Esc.
; Опрос клавиатуры - простым поллингом порта 0x64/0x60 (без
; IRQ/PIC).
;
; ВАЖНО: контроллер здесь НЕ транслирует в Scan Code Set 1 -
; отдаёт "сырой" Scan Code Set 2 (проверено эмпирически через
; QEMU: стрелки идут как E0 72 / E0 75, Enter как 0x5A, Esc как
; 0x76). Байт-префикс E0 (расширенная клавиша) просто
; пропускаем. Префикс F0 означает "это код ОТПУСКАНИЯ клавиши" -
; следующий байт совпадает с кодом нажатия, поэтому его нужно
; отдельно игнорировать, иначе одно нажатие сработает дважды.
; =========================================================
KEY_UP    equ 0x75
KEY_DOWN  equ 0x72
KEY_ENTER equ 0x5A
KEY_ESC   equ 0x76

setup_menu:
    push ax

    mov word [ss:RAM_MENU_SEL], 0
    mov byte [ss:RAM_BREAK_FLAG], 0

.redraw:
    call vga_clear_screen

    mov dh, 1
    mov dl, 2
    mov bl, 0x0F
    mov si, menu_title
    call vga_print_at

    ; --- пункт 0: Serial (COM1) output ---
    mov dh, 3
    mov dl, 2
    mov bl, 0x07
    cmp word [ss:RAM_MENU_SEL], 0
    jne .item0_draw
    mov bl, 0x70
.item0_draw:
    mov si, menu_item0
    call vga_print_at
    mov dh, 3
    mov dl, 26
    mov bl, 0x0F
    cmp byte [ss:RAM_SERIAL_ON], 0
    jne .item0_on
    mov si, str_off
    jmp .item0_status
.item0_on:
    mov si, str_on
.item0_status:
    call vga_print_at

    ; --- пункт 1: VGA output ---
    mov dh, 4
    mov dl, 2
    mov bl, 0x07
    cmp word [ss:RAM_MENU_SEL], 1
    jne .item1_draw
    mov bl, 0x70
.item1_draw:
    mov si, menu_item1
    call vga_print_at
    mov dh, 4
    mov dl, 26
    mov bl, 0x0F
    cmp byte [ss:RAM_VGA_ON], 0
    jne .item1_on
    mov si, str_off
    jmp .item1_status
.item1_on:
    mov si, str_on
.item1_status:
    call vga_print_at

    ; --- пункт 2: Exit ---
    mov dh, 6
    mov dl, 2
    mov bl, 0x07
    cmp word [ss:RAM_MENU_SEL], 2
    jne .item2_draw
    mov bl, 0x70
.item2_draw:
    mov si, menu_item2
    call vga_print_at

    mov dh, 9
    mov dl, 2
    mov bl, 0x08
    mov si, menu_hint
    call vga_print_at

.wait_key:
    in al, 0x64
    test al, 0x01
    jz .wait_key
    in al, 0x60

    cmp al, 0xE0
    je .wait_key            ; префикс расширенной клавиши - просто пропускаем

    cmp al, 0xF0
    jne .not_break_prefix
    mov byte [ss:RAM_BREAK_FLAG], 1
    jmp .wait_key
.not_break_prefix:

    cmp byte [ss:RAM_BREAK_FLAG], 0
    je .process_make
    ; это код ОТПУСКАНИЯ клавиши (следует за F0) - игнорируем его
    mov byte [ss:RAM_BREAK_FLAG], 0
    jmp .wait_key

.process_make:
    cmp al, KEY_UP
    je .key_up
    cmp al, KEY_DOWN
    je .key_down
    cmp al, KEY_ENTER
    je .key_enter
    cmp al, KEY_ESC
    je .key_esc
    jmp .wait_key

.key_up:
    mov ax, [ss:RAM_MENU_SEL]
    cmp ax, 0
    je .redraw
    dec ax
    mov [ss:RAM_MENU_SEL], ax
    jmp .redraw

.key_down:
    mov ax, [ss:RAM_MENU_SEL]
    cmp ax, 2
    jae .redraw
    inc ax
    mov [ss:RAM_MENU_SEL], ax
    jmp .redraw

.key_enter:
    mov ax, [ss:RAM_MENU_SEL]
    cmp ax, 0
    je .toggle_serial
    cmp ax, 1
    je .toggle_vga
    jmp .key_esc          ; пункт 2 (Exit) по Enter

.toggle_serial:
    xor byte [ss:RAM_SERIAL_ON], 1
    call cmos_save_settings
    jmp .redraw

.toggle_vga:
    xor byte [ss:RAM_VGA_ON], 1
    call cmos_save_settings
    jmp .redraw

.key_esc:
    call vga_clear_screen
    mov dh, 1
    mov dl, 2
    mov bl, 0x07
    mov si, msg_setup_exit
    call vga_print_at

    pop ax
    ret

; =========================================================
; Загрузка и запуск MBR с диска.
;
; У нас нет int 13h (это как раз то, что предоставляет BIOS,
; а не то, чем он пользуется) - поэтому читаем диск напрямую
; через порты первичного ATA-контроллера в режиме PIO.
; Загружаем сектор 0 (LBA=0, 512 байт) в 0x0000:0x7C00 - это
; стандартный адрес, куда настоящий BIOS кладёт MBR. Если там
; найдена сигнатура 0x55AA - передаём туда управление, выставив
; регистры так же, как это делает настоящий BIOS (DS=ES=SS=0,
; SP=0x7C00, DL=номер загрузочного диска).
; =========================================================
BOOT_ADDR equ 0x7C00

boot_try_disk:
    push ax

    ; Чистим экран и сбрасываем курсор - иначе сообщения о загрузке
    ; просто дописывались бы туда, где остановилось setup-меню.
    call vga_clear_screen
    mov word [ss:RAM_VGA_POS], 0

    mov si, msg_boot_try
    call print_serial
    mov si, msg_boot_try
    call print_vga

    call ata_read_mbr
    jc .boot_fail

    cmp word [ss:BOOT_ADDR+510], 0xAA55
    jne .boot_fail

    mov si, msg_boot_jump
    call print_serial
    mov si, msg_boot_jump
    call print_vga

    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, BOOT_ADDR
    mov dl, 0x80             ; номер загрузочного диска (первый HDD)
    jmp 0x0000:BOOT_ADDR      ; управление дальше не возвращается

.boot_fail:
    mov si, msg_boot_fail
    call print_serial
    mov si, msg_boot_fail
    call print_vga
    pop ax
    ret

; Читает LBA=0 (1 сектор, 512 байт) с primary ATA master через PIO
; в SS:BOOT_ADDR (SS=0x0000). CF=1 при ошибке/таймауте/отсутствии диска.
ata_read_mbr:
    push ax
    push cx
    push dx
    push di

    mov dx, 0x1F7
    call .wait_not_busy
    jc .fail

    mov dx, 0x1F6
    mov al, 0xE0              ; master, LBA-режим, биты 24-27 LBA = 0
    out dx, al

    mov dx, 0x1F2
    mov al, 1                  ; читаем 1 сектор
    out dx, al

    mov dx, 0x1F3
    xor al, al                 ; LBA биты 0-7
    out dx, al
    mov dx, 0x1F4
    xor al, al                 ; LBA биты 8-15
    out dx, al
    mov dx, 0x1F5
    xor al, al                 ; LBA биты 16-23
    out dx, al

    mov dx, 0x1F7
    mov al, 0x20                ; команда READ SECTORS (с повтором)
    out dx, al

    call .wait_drq
    jc .fail

    mov dx, 0x1F0
    mov di, BOOT_ADDR
    mov cx, 256                  ; 256 слов = 512 байт
.read_loop:
    in ax, dx
    mov [ss:di], ax
    add di, 2
    loop .read_loop

    clc
    jmp .done
.fail:
    stc
.done:
    pop di
    pop dx
    pop cx
    pop ax
    ret

; ждём BSY=0 на порту, который уже в DX (с ограничением по времени)
.wait_not_busy:
    push cx
    mov cx, 0xFFFF
.wnb_loop:
    in al, dx
    test al, 0x80             ; BSY
    jz .wnb_ok
    loop .wnb_loop
    pop cx
    stc
    ret
.wnb_ok:
    pop cx
    clc
    ret

; ждём готовности данных: BSY=0 и DRQ=1 на порту статуса 0x1F7
.wait_drq:
    push cx
    push dx
    mov dx, 0x1F7
    mov cx, 0xFFFF
.wdrq_loop:
    in al, dx
    test al, 0x80              ; BSY?
    jnz .wdrq_next
    test al, 0x08               ; DRQ?
    jnz .wdrq_ok
.wdrq_next:
    loop .wdrq_loop
    pop dx
    pop cx
    stc
    ret
.wdrq_ok:
    pop dx
    pop cx
    clc
    ret

; =========================================================
; CMOS/NVRAM (микросхема часов реального времени, порты 0x70
; индекс/0x71 данные) - в реальном ПК держится на батарейке и
; переживает выключение и перезагрузку. Используем один байт под
; свои настройки и байт-сигнатуру, чтобы отличить "уже сохранённые
; настройки" от "чип ещё девственный/не наш". Смещения 0x40-0x41
; в обычной практике свободны (RTC использует только 0x00-0x0D,
; плюс пара служебных байт до 0x2F).
; =========================================================
CMOS_CFG_OFFSET equ 0x40
CMOS_SIG_OFFSET equ 0x41
CMOS_SIG_VALUE  equ 0x5A

; Вход: AL=индекс байта в CMOS. Выход: AL=значение.
cmos_read_byte:
    out 0x70, al
    in al, 0x71
    ret

; Вход: AL=индекс байта в CMOS, AH=значение для записи.
cmos_write_byte:
    push ax
    out 0x70, al
    mov al, ah
    out 0x71, al
    pop ax
    ret

; Загружает RAM_SERIAL_ON/RAM_VGA_ON из CMOS, если там наша
; сигнатура, иначе выставляет значения по умолчанию и сохраняет их.
cmos_load_settings:
    push ax
    push bx

    mov al, CMOS_SIG_OFFSET
    call cmos_read_byte
    cmp al, CMOS_SIG_VALUE
    jne .defaults

    mov al, CMOS_CFG_OFFSET
    call cmos_read_byte        ; al = сохранённый байт настроек
    mov bl, al
    and bl, 0x01
    mov [ss:RAM_SERIAL_ON], bl
    mov bl, al
    and bl, 0x02
    shr bl, 1
    mov [ss:RAM_VGA_ON], bl
    jmp .done

.defaults:
    mov byte [ss:RAM_SERIAL_ON], 1
    mov byte [ss:RAM_VGA_ON], 1
    call cmos_save_settings     ; сразу сохраняем дефолты + сигнатуру

.done:
    pop bx
    pop ax
    ret

; Упаковывает текущие RAM_SERIAL_ON/RAM_VGA_ON в один байт и
; сохраняет в CMOS вместе с сигнатурой.
cmos_save_settings:
    push ax
    push bx

    mov bl, [ss:RAM_SERIAL_ON]
    and bl, 1
    mov bh, [ss:RAM_VGA_ON]
    and bh, 1
    shl bh, 1
    or bl, bh

    mov al, CMOS_CFG_OFFSET
    mov ah, bl
    call cmos_write_byte

    mov al, CMOS_SIG_OFFSET
    mov ah, CMOS_SIG_VALUE
    call cmos_write_byte

    pop bx
    pop ax
    ret

; =========================================================
; Данные (строки-константы - живут в ROM, это нормально: их
; только читают, никогда не пишут)
; =========================================================
msg_banner:   db "SilentBIOS (SBIOS) v0.2 Initialized successfully!", 13, 10, 0
msg_mem_test: db "Memory test: ", 0
msg_kb:       db " KB OK", 13, 10, 0
msg_kbd_test: db "Keyboard controller self-test: ", 0
msg_ok:       db "OK", 13, 10, 0
msg_fail:     db "FAIL", 13, 10, 0
msg_done:     db "POST complete.", 13, 10, 0

menu_title:   db "SilentBIOS Setup", 0
menu_item0:   db "Serial (COM1) output", 0
menu_item1:   db "VGA output", 0
menu_item2:   db "Exit", 0
menu_hint:    db "Arrows: Move   Enter: Toggle/Select   Esc: Exit", 0
str_on:       db "ON ", 0
str_off:      db "OFF", 0
msg_setup_exit: db "Setup closed.", 0

msg_boot_try:  db "Booting: reading MBR from disk (ATA PIO)...", 13, 10, 0
msg_boot_jump: db "Valid boot signature found, jumping to 0x7C00...", 13, 10, 0
msg_boot_fail: db "No bootable disk found. System halted.", 13, 10, 0

; -------------------------------------------------------------------------
; Выравнивание до Reset Vector (размер файла 64 КБ = 65536 байт)
; -------------------------------------------------------------------------
times 65520 - ($ - $$) db 0xFF

reset_vector:
    jmp start

times 65536 - ($ - $$) db 0