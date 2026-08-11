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
RAM_KBD_SHIFT  equ 0x0510    ; byte: 1 = Shift (левый или правый) сейчас зажат
RAM_KBD_PENDING equ 0x0511   ; byte: 1 = есть декодированная клавиша, ждущая выборки
RAM_KBD_PENDING_CHAR equ 0x0512 ; byte: ASCII-код ожидающей клавиши
RAM_KBD_PENDING_SCAN equ 0x0513 ; byte: сырой Scan Set 2 код ожидающей клавиши
RAM_GEOM_SPT equ 0x0514      ; byte: секторов/дорожку для ТЕКУЩЕГО вызова
                              ; int 13h AH=0x02/0x08 - не персистентно, просто
                              ; рабочая область (в регистрах уже не хватает места)
RAM_GEOM_HPC equ 0x0515      ; byte: головок для текущего вызова int 13h

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

    ; Аналогично - int 16h (клавиатурные сервисы), вектор 0x16*4.
    ; Загруженный код может читать клавиатуру через "int 16h" вместо
    ; прямого поллинга портов 0x60/0x64, как это делает настоящий BIOS.
    call install_int16h_vector

    ; Аналогично - int 13h (дисковые сервисы), вектор 0x13*4.
    ; Загруженный код может читать диск через "int 13h" вместо
    ; прямого поллинга ATA-портов, как это делает настоящий BIOS
    ; (сама BIOS по-прежнему читает MBR напрямую через ata_read_mbr -
    ; у неё самой int 13h взять неоткуда).
    call install_int13h_vector

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

; =========================================================
; int 16h - клавиатурные сервисы. Поддерживаются:
;   AH=0x00 - блокирующее чтение символа (-> AL=ASCII, AH=сырой скан-код)
;   AH=0x01 - неблокирующая проверка (ZF=1 если клавиш нет; иначе
;             ZF=0 и AL/AH заполнены, КАК И в AH=0x00, но клавиша НЕ
;             потребляется - следующий AH=0x00/0x01 увидит её снова)
; Поверх того же "сырого" поллинга портов 0x60/0x64 (Scan Set 2), что
; уже используется в setup_menu, но декодированного в ASCII через
; таблицы kbd_ascii_lo/kbd_ascii_hi и с учётом состояния Shift.
; Не поддерживаются: numpad, функциональные и прочие клавиши без
; ASCII-эквивалента (тихо игнорируются, как и всё вне MAX_SCAN), а
; также расширенные (E0-префиксные) клавиши в общем случае - E0
; просто пропускается, и следующий байт трактуется как обычный (тот
; же приём, что и в setup_menu); из-за этого расширенный код клавиши
; может случайно совпасть с кодом обычной клавиши на numpad (см.
; комментарий у MAX_SCAN) - осознанное упрощение, а не баг.
;
; AH=0x01 - особый случай регистровой конвенции: результат нужно
; вернуть через флаг ZF, а "iret" восстанавливает FLAGS из стека (то,
; что запушил сам "int"), а не из текущего регистра флагов - поэтому
; после вызова обработчика приходится патчить слово FLAGS в кадре
; стека напрямую. CX/DX используются как scratch и не сохраняются -
; для AH=0x01 это не задокументированный вывод, как и в настоящем BIOS.
; =========================================================
install_int16h_vector:
    push ax
    push es

    xor ax, ax
    mov es, ax
    mov word [es:0x16*4], int16h_isr
    mov word [es:0x16*4+2], cs

    ; гарантируем чистое состояние автомата разбора клавиатуры -
    ; RAM не обязана быть обнулена на старте (реальное железо после
    ; power-on этого не гарантирует).
    mov byte [ss:RAM_BREAK_FLAG], 0
    mov byte [ss:RAM_KBD_SHIFT], 0
    mov byte [ss:RAM_KBD_PENDING], 0

    pop es
    pop ax
    ret

int16h_isr:
    push si
    push di
    push bp
    push ds
    push es

    cmp ah, 0x00
    je .fn_00
    cmp ah, 0x01
    je .fn_01
    jmp .done                 ; неподдерживаемая функция - молча игнорируем

.fn_00:
    pop es
    pop ds
    pop bp
    pop di
    pop si
    call int16h_read_char     ; блокирующее чтение - AL=ASCII, AH=скан-код
    iret

.fn_01:
    pop es
    pop ds
    pop bp
    pop di
    pop si
    ; стек уже чист: [sp]=IP [sp+2]=CS [sp+4]=FLAGS(оригинал - его и
    ; восстановит iret)
    call int16h_check_key     ; ZF: 1=клавиш нет, 0=есть (+AL/AH)

    jz .no_key
    xor cx, cx                    ; ZF было 0 (клавиша есть) -> патченный ZF=0
    jmp .have_zf
.no_key:
    mov cx, 0x0040                 ; ZF было 1 (клавиш нет) -> патченный ZF=1
.have_zf:
    push bp
    mov bp, sp
    ; [bp+0]=наш push bp, [bp+2]=IP, [bp+4]=CS, [bp+6]=FLAGS(оригинал)
    mov dx, [ss:bp+6]
    and dx, 0xFFBF                ; сбрасываем бит ZF
    or dx, cx                      ; проставляем вычисленный
    mov [ss:bp+6], dx
    pop bp
    iret

.done:
    pop es
    pop ds
    pop bp
    pop di
    pop si
    iret

; Блокирующее чтение (AH=0x00): крутится в kbd_service, пока не
; появится декодированная клавиша, затем забирает её из "буфера"
; (сбрасывая RAM_KBD_PENDING - в отличие от AH=0x01, эта функция
; клавишу ПОТРЕБЛЯЕТ). "Get"-функция - AX не сохраняется, в нём
; возвращается результат.
int16h_read_char:
.wait:
    call kbd_service
    cmp byte [ss:RAM_KBD_PENDING], 0
    je .wait

    mov al, [ss:RAM_KBD_PENDING_CHAR]
    mov ah, [ss:RAM_KBD_PENDING_SCAN]
    mov byte [ss:RAM_KBD_PENDING], 0
    ret

; Неблокирующая проверка (AH=0x01): один раз пытается продвинуть
; kbd_service, затем смотрит "буфер" - НЕ потребляет клавишу (в
; отличие от int16h_read_char), поэтому следующий вызов увидит её
; снова. ZF отражает результат для вызывающего кода (см. .fn_01 в
; int16h_isr, где это транслируется через стек в реальный iret).
int16h_check_key:
    call kbd_service
    cmp byte [ss:RAM_KBD_PENDING], 0
    je .none

    mov al, [ss:RAM_KBD_PENDING_CHAR]
    mov ah, [ss:RAM_KBD_PENDING_SCAN]
    ret
.none:
    ret

; Продвигает автомат разбора клавиатуры максимум на один "сырой" байт
; Scan Set 2, если он уже доступен у контроллера (порт 0x64, бит 0) -
; НЕ блокирует. Логика E0/F0 - та же, что в setup_menu (см. её
; комментарий): E0 просто пропускается, F0 выставляет RAM_BREAK_FLAG
; на один байт вперёд. Shift (0x12/0x59) обрабатывается отдельно - не
; как обычная клавиша, а как модификатор для kbd_ascii_hi/_lo. Если
; уже есть непотреблённая клавиша (RAM_KBD_PENDING=1) - ничего не
; делает, чтобы её не затереть до того, как её заберут.
kbd_service:
    push ax
    push bx

    cmp byte [ss:RAM_KBD_PENDING], 0
    jne .done

    in al, 0x64
    test al, 0x01
    jz .done                    ; данных нет - неблокирующий выход

    in al, 0x60

    cmp al, 0xE0
    je .done                     ; префикс расширенной клавиши - пропускаем

    cmp al, 0xF0
    jne .not_break_prefix
    mov byte [ss:RAM_BREAK_FLAG], 1
    jmp .done
.not_break_prefix:

    cmp byte [ss:RAM_BREAK_FLAG], 0
    je .make_event

    ; код ОТПУСКАНИЯ (после F0) - из всех клавиш нас интересует
    ; только отпускание Shift, остальное как и раньше просто игнорируем
    mov byte [ss:RAM_BREAK_FLAG], 0
    cmp al, 0x12
    je .shift_release
    cmp al, 0x59
    je .shift_release
    jmp .done
.shift_release:
    mov byte [ss:RAM_KBD_SHIFT], 0
    jmp .done

.make_event:
    cmp al, 0x12
    je .shift_press
    cmp al, 0x59
    je .shift_press

    cmp al, MAX_SCAN
    ja .done                      ; вне таблицы - клавиша без ASCII, игнорируем

    xor bh, bh
    mov bl, al
    cmp byte [ss:RAM_KBD_SHIFT], 0
    jne .use_shifted
    mov ah, [cs:kbd_ascii_lo+bx]
    jmp .have_char
.use_shifted:
    mov ah, [cs:kbd_ascii_hi+bx]
.have_char:
    cmp ah, 0
    je .done                       ; в таблице пусто - непечатаемая клавиша

    mov byte [ss:RAM_KBD_PENDING_SCAN], al
    mov byte [ss:RAM_KBD_PENDING_CHAR], ah
    mov byte [ss:RAM_KBD_PENDING], 1
    jmp .done

.shift_press:
    mov byte [ss:RAM_KBD_SHIFT], 1

.done:
    pop bx
    pop ax
    ret

; Таблицы трансляции "сырого" Scan Set 2 make-кода (0x00-MAX_SCAN) в
; ASCII. Индекс - сам скан-код; 0 = клавиша без ASCII-эквивалента.
; Числовые коды вместо символьных литералов - там, где символ сам по
; себе конфликтует с синтаксисом NASM (кавычки, обратный слэш): 8=BS,
; 9=TAB, 13=CR(Enter), 27=ESC, 34=", 39=', 59=;, 92=\.
MAX_SCAN equ 0x76

kbd_ascii_lo:
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,9,96,0                          ; 0x00-0x0F
    db 0,0,0,0,0,'q','1',0,0,0,'z','s','a','w','2',0             ; 0x10-0x1F
    db 0,'c','x','d','e','4','3',0,0,' ','v','f','t','r','5',0   ; 0x20-0x2F
    db 0,'n','b','h','g','y','6',0,0,0,'m','j','u','7','8',0     ; 0x30-0x3F
    db 0,',','k','i','o','0','9',0,0,'.','/','l',59,'p','-',0    ; 0x40-0x4F
    db 0,0,39,0,'[','=',0,0,0,0,13,']',0,92,0,0                  ; 0x50-0x5F
    db 0,0,0,0,0,0,8,0,0,0,0,0,0,0,0,0                           ; 0x60-0x6F
    db 0,0,0,0,0,0,27                                            ; 0x70-0x76

kbd_ascii_hi:
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,9,126,0                         ; 0x00-0x0F
    db 0,0,0,0,0,'Q','!',0,0,0,'Z','S','A','W','@',0             ; 0x10-0x1F
    db 0,'C','X','D','E','$','#',0,0,' ','V','F','T','R','%',0   ; 0x20-0x2F
    db 0,'N','B','H','G','Y','^',0,0,0,'M','J','U','&','*',0     ; 0x30-0x3F
    db 0,'<','K','I','O',')','(',0,0,'>','?','L',58,'P','_',0    ; 0x40-0x4F
    db 0,0,34,0,'{','+',0,0,0,0,13,'}',0,124,0,0                 ; 0x50-0x5F
    db 0,0,0,0,0,0,8,0,0,0,0,0,0,0,0,0                           ; 0x60-0x6F
    db 0,0,0,0,0,0,27                                            ; 0x70-0x76

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
    jmp .check_scroll

.newline:
    mov bx, [ss:RAM_VGA_POS]
    xor dx, dx
    mov ax, bx
    mov cx, 160            ; 80 колонок * 2 байта
    div cx                  ; ax = номер строки, dx = остаток (не нужен)
    inc ax
    mul cx                   ; ax = ax * 160 = начало следующей строки
    mov [ss:RAM_VGA_POS], ax

.check_scroll:
    ; курсор ушёл за последнюю строку (25*160=4000)? Без этой проверки
    ; длинный вывод молча "утекает" за пределы видимого буфера - экран
    ; выглядит зависшим, хотя код продолжает работать (так был найден
    ; этот баг: длинный человекочитаемый тест перестал что-либо рисовать
    ; примерно на середине).
    cmp word [ss:RAM_VGA_POS], 4000
    jb .done
    call vga_scroll_up
    mov word [ss:RAM_VGA_POS], 3840          ; начало последней строки (24*160)

.done:
    pop es
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; Прокручивает текстовый экран на одну строку вверх: строки 1-24
; копируются в 0-23 (3840 байт = 24*160), освободившаяся строка 24
; заливается пробелами (атрибут 0x07). Вызывается из vga_char_out,
; когда курсор пытается уйти за последнюю строку.
vga_scroll_up:
    push ax
    push cx
    push si
    push di
    push es
    push ds

    cld

    mov ax, 0xB800
    mov es, ax
    mov ds, ax

    xor si, si
    add si, 160           ; источник - начало строки 1
    xor di, di              ; назначение - начало строки 0
    mov cx, 3840              ; байт для переноса (24 строки * 160)
    rep movsb

    mov cx, 80                  ; di сейчас = 3840 (начало строки 24) -
.clear_loop:                     ; заливаем её пробелами
    mov word [es:di], 0x0720
    add di, 2
    loop .clear_loop

    pop ds
    pop es
    pop di
    pop si
    pop cx
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
; int 13h - дисковые сервисы. Поддерживаются:
;   AH=0x00 - сброс контроллера (DL=диск, игнорируем - у нас один)
;   AH=0x02 - чтение секторов по CHS (-> данные в ES:BX)
;   AH=0x08 - параметры диска (геометрия)
; Прочие функции явно сигнализируют ошибку (CF=1, AH=1) - в отличие
; от int10h/int16h, для дисковых операций тихо промолчать об успехе
; там, где на самом деле ничего не произошло, опаснее, чем явно
; сказать "не поддерживается": вызывающий код может решить, что
; запись/чтение прошли успешно, и продолжить работать с мусором.
;
; У нас нет IDENTIFY DEVICE, поэтому настоящей геометрии диска мы не
; знаем - CHS транслируется в LBA по условной геометрии SPT=63/
; HPC=16 (тот же компромисс, что и у многих учебных BIOS). AH=0x08
; репортит "классический" максимум цилиндра (1023) вне зависимости
; от реального размера образа диска - реальная граница всё равно
; определяется тем, что фактически лежит на диске (ATA просто
; вернёт ошибку/мусор при выходе за его пределы).
;
; Регистровая конвенция - та же, что у int10h/int16h: ISR сохраняет
; только ds/es/si/di/bp, каждая функция сама решает, что ей нужно.
; Особый случай - CF: как и AH=0x01 у int16h (см. её комментарий),
; результат нужно вернуть через флаг, а iret восстанавливает FLAGS
; из стека (то, что запушил сам "int"), а не из текущего регистра -
; поэтому используется общий patch_stack_cf, вызываемый СРАЗУ после
; обработчика функции, по сигналу в BL (0=CF снять, иначе=CF
; выставить). BL/CX/DX (а для read - ещё и AL/AH сверх официального
; вывода) не сохраняются - не задокументированный вывод для этих
; функций.
; =========================================================
install_int13h_vector:
    push ax
    push es

    xor ax, ax
    mov es, ax
    mov word [es:0x13*4], int13h_isr
    mov word [es:0x13*4+2], cs

    pop es
    pop ax
    ret

int13h_isr:
    push si
    push di
    push bp
    push ds
    push es

    cmp ah, 0x00
    je .fn_00
    cmp ah, 0x02
    je .fn_02
    cmp ah, 0x08
    je .fn_08

    ; неподдерживаемая функция - явно сигнализируем ошибку (см.
    ; обоснование в комментарии к блоку выше)
    pop es
    pop ds
    pop bp
    pop di
    pop si
    mov ah, 1
    mov bl, 1
    call patch_stack_cf
    iret

.fn_00:
    pop es
    pop ds
    pop bp
    pop di
    pop si
    call int13h_reset
    call patch_stack_cf
    iret

.fn_02:
    pop es
    pop ds
    pop bp
    pop di
    pop si
    call int13h_read_sectors
    call patch_stack_cf
    iret

.fn_08:
    pop es
    pop ds
    pop bp
    pop di
    pop si
    call int13h_get_params
    call patch_stack_cf
    iret

; Патчит бит CF (бит 0) младшего байта FLAGS, лежащего в стеке чуть
; выше нашего собственного возвратного адреса - вызывать СРАЗУ после
; того, как обработчик функции отработал и стек уже "чист" (см.
; int13h_isr .fn_XX, где si/di/bp/ds/es уже выкинуты до вызова).
; Вход: BL=0 -> CF=0 (успех), любое ненулевое BL -> CF=1 (ошибка).
; Тот же приём и то же предупреждение про полярность, что у AH=0x01
; в int16h_isr - перепутать 0/1 здесь легко и незаметно.
patch_stack_cf:
    and bl, 1
    push bp
    mov bp, sp
    ; [bp+0]=наш push bp, [bp+2]=наш возвратный адрес (call),
    ; [bp+4]=IP(оригинал), [bp+6]=CS(оригинал), [bp+8]=младший байт
    ; FLAGS(оригинал, в нём и лежит CF - бит 0)
    mov bh, [ss:bp+8]
    and bh, 0xFE
    or bh, bl
    mov [ss:bp+8], bh
    pop bp
    ret

; int 13h AH=0x00 - сброс контроллера. DL=диск (игнорируем - у нас
; один). Пульс SRST через Device Control Register (0x3F6, бит 2),
; затем ждём BSY=0 на статусном порту. Порт 0x80 (POST-диагностика)
; используется как дешёвая задержка на несколько шин-циклов - запись
; в него ни на что не влияет, кроме времени выполнения.
; Выход: AH=код статуса (0=OK), BL=0/1 для patch_stack_cf.
int13h_reset:
    push cx
    push dx

    mov dx, 0x3F6
    mov al, 0x04              ; SRST=1
    out dx, al

    mov cx, 4
.srst_delay:
    out 0x80, al
    loop .srst_delay

    xor al, al                 ; SRST=0
    out dx, al

    mov dx, 0x1F7
    mov cx, 0xFFFF
.wait_ready:
    in al, dx
    test al, 0x80                ; BSY?
    jz .ok
    loop .wait_ready

    mov ah, 1                     ; таймаут - статус "ошибка"
    mov bl, 1
    jmp .done
.ok:
    xor ah, ah
    xor bl, bl
.done:
    pop dx
    pop cx
    ret

; int 13h AH=0x08 - параметры диска. Вход: DL=диск - в отличие от
; остальных функций, ЗДЕСЬ его не игнорируем: DL<0x80 (floppy) и
; DL>=0x80 (HDD) получают разную геометрию (см. .floppy_params ниже
; и комментарий у SPT_HDD/SPT_FLOPPY перед int13h_read_sectors - те
; же константы, чтобы AH=0x08 и AH=0x02 не могли разъехаться).
; Выход: CH=младшие 8 бит макс.цилиндра, CL: биты0-5=SPT,
; биты6-7=старшие 2 бита макс.цилиндра; DH=макс.головка (HPC-1);
; DL=число дисков (1); AH=0. ES:DI (указатель на drive parameter
; table) не трогаем - большинство вызывающих читают геометрию через
; CH/CL/DH и не разыменовывают этот указатель.
MAX_CYL_HDD    equ 1023   ; классический предел 10-битного поля
MAX_CYL_FLOPPY equ 79      ; 80 дорожек (0-79) - стандарт для 1.44MB

int13h_get_params:
    cmp dl, 0x80
    jb .floppy_params

    mov ch, MAX_CYL_HDD & 0xFF
    mov cl, (MAX_CYL_HDD >> 8) & 0x03
    shl cl, 6
    or cl, SPT_HDD
    mov dh, HPC_HDD - 1
    jmp .common

.floppy_params:
    mov ch, MAX_CYL_FLOPPY & 0xFF
    mov cl, (MAX_CYL_FLOPPY >> 8) & 0x03
    shl cl, 6
    or cl, SPT_FLOPPY
    mov dh, HPC_FLOPPY - 1

.common:
    mov dl, 1
    xor ah, ah
    xor bl, bl
    ret

; int 13h AH=0x02 - чтение секторов (CHS). Вход: AL=число секторов
; (0 трактуется как 1 - полный диапазон 256 нашим крошечным тестовым
; образам не нужен), CH=цилиндр(биты0-7), CL: биты0-5=сектор(1-63),
; биты6-7=биты8-9 цилиндра, DH=головка, DL=диск, ES:BX=буфер
; назначения. LBA считается 32-битно (dx:ax), но на порты уходят
; только младшие 28 бит - тот же протокол, что и в ata_read_mbr.
; Секторы читаются по одному (не пачкой) - проще и надёжнее ждать
; DRQ перед каждым, чем полагаться на то, что контроллер сам не
; потребует этого между секторами при multi-sector READ.
;
; DL здесь НЕ игнорируется (в отличие от AH=0x00/0x08... то есть
; кроме самого AH=0x08, который тоже теперь смотрит на DL - см. его
; комментарий): DL<0x80 (floppy) транслирует CHS в LBA по геометрии
; 18 секторов/дорожку, 2 головки (стандарт 1.44MB), DL>=0x80 (HDD) -
; по 63/16. Раньше геометрия была одна жёстко зашитая (63/16) для
; всех дисков - именно на этом споткнулась попытка загрузить с неё
; настоящую дискету FreeDOS: её загрузчик читает по CHS из СВОЕЙ
; (floppy) геометрии, мы транслировали по чужой (HDD) - в итоге
; читали не те LBA, получали не те данные, без единой ошибки CF.
; Выход: AL=число реально прочитанных секторов, AH=код статуса,
; BL=0/1 для patch_stack_cf.
;
; Распределение регистров внутри функции (пояснение, т.к. регистров
; впритык): di - буфер назначения (offset, захватывается из BX
; СРАЗУ на входе, дальше bx свободен); si - сектор-1, потом счётчик
; прочитанных секторов; bp - цилиндр, потом временный перенос при
; умножении, потом запрошенное число секторов; cx - LBA биты 0-15
; (cl/ch), bx - LBA биты 16-31 (bl/bh, реально нужны только 16-27).
SPT_HDD    equ 63
HPC_HDD    equ 16
SPT_FLOPPY equ 18
HPC_FLOPPY equ 2

int13h_read_sectors:
    push si
    push di
    push bp

    mov di, bx                  ; di = буфер назначения (offset) - ES не
                                   ; трогаем, он уже = ES вызывающего кода

    ; --- геометрия по DL - см. комментарий выше. Кладём в RAM
    ; (RAM_GEOM_SPT/_HPC), а не в регистр: свободных регистров для
    ; ещё одного значения, живущего через весь расчёт LBA, уже нет.
    cmp dl, 0x80
    jb .floppy_geom
    mov byte [ss:RAM_GEOM_SPT], SPT_HDD
    mov byte [ss:RAM_GEOM_HPC], HPC_HDD
    jmp .geom_done
.floppy_geom:
    mov byte [ss:RAM_GEOM_SPT], SPT_FLOPPY
    mov byte [ss:RAM_GEOM_HPC], HPC_FLOPPY
.geom_done:

    push ax                       ; сохраняем запрошенное число секторов (AL)

    ; --- вытаскиваем составляющие CHS в безопасные регистры ДО
    ; каких-либо умножений (mul портит весь DX) ---
    xor ah, ah
    mov al, dh
    mov bx, ax                     ; bx = голова (временно, до вычисления LBA)

    mov al, cl
    and al, 0x3F
    dec al
    xor ah, ah
    mov si, ax                      ; si = сектор-1 (временно)

    mov al, cl
    shr al, 6
    xor ah, ah
    mov bp, ax
    mov al, ch
    xor ah, ah
    shl bp, 8
    or bp, ax                        ; bp = цилиндр (временно)

    ; --- LBA (32 бита, dx:ax) = (cylinder*HPC + head) * SPT + (sector-1) ---
    mov ax, bp
    xor ch, ch
    mov cl, [ss:RAM_GEOM_HPC]
    mul cx                             ; dx:ax = cylinder*HPC
    add ax, bx                          ; + голова (пока ещё в bx)
    adc dx, 0
    xor ch, ch
    mov cl, [ss:RAM_GEOM_SPT]
    push ax
    mov ax, dx
    mul cx
    mov bp, ax                            ; bp = перенос (старшая часть) - временно
    pop ax
    mul cx
    add dx, bp
    add ax, si
    adc dx, 0
    ; dx:ax = LBA (32 бита)

    ; --- раскладываем LBA по байтам: cx = биты0-15, bx = биты16-31 ---
    mov cx, ax
    mov bx, dx

    pop ax                                  ; восстанавливаем запрошенное число секторов
    xor ah, ah
    or al, al
    jnz .have_count
    mov al, 1
.have_count:
    mov bp, ax                                ; bp = запрошенное число секторов

    xor si, si                                  ; si = сколько секторов уже прочитано

.sector_loop:
    cmp si, bp
    jae .all_done

    mov dx, 0x1F6
    mov al, bh
    and al, 0x0F                                  ; биты 24-27 LBA
    or al, 0xE0                                     ; master + LBA-режим
    out dx, al

    mov dx, 0x1F2
    mov al, 1
    out dx, al

    mov dx, 0x1F3
    mov al, cl
    out dx, al
    mov dx, 0x1F4
    mov al, ch
    out dx, al
    mov dx, 0x1F5
    mov al, bl
    out dx, al

    mov dx, 0x1F7
    mov al, 0x20                                     ; READ SECTORS
    out dx, al

    push cx
    mov cx, 0xFFFF
.wait_drq:
    in al, dx
    test al, 0x80                                       ; BSY?
    jnz .wdrq_next
    test al, 0x08                                         ; DRQ?
    jnz .wdrq_ok
.wdrq_next:
    loop .wait_drq
    pop cx
    jmp .read_fail
.wdrq_ok:
    pop cx

    mov dx, 0x1F0
    push cx
    mov cx, 256
.xfer_loop:
    in ax, dx
    mov [es:di], ax
    add di, 2
    loop .xfer_loop
    pop cx

    add cx, 1                                               ; LBA++ (32-битно, cx:bx)
    adc bx, 0

    inc si
    jmp .sector_loop

.read_fail:
    mov ax, si                                                ; al = сколько успели прочитать (ah тоже 0)
    mov ah, 1                                                   ; статус - ошибка
    mov bl, 1
    jmp .exit

.all_done:
    mov ax, si                                                    ; al = число прочитанных, ah=0 (OK)
    xor bl, bl

.exit:
    pop bp
    pop di
    pop si
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