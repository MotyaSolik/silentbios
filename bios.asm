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
                              ; 0x050E свободен - раньше RAM_BREAK_FLAG,
                              ; больше не нужен с аппаратной трансляцией
                              ; в Set 1 (отпускание - один байт, не F0+код)
RAM_VIDEO_MODE equ 0x050F    ; byte: текущий видеорежим (для int 10h AH=0x0F)
RAM_KBD_SHIFT  equ 0x0510    ; byte: 1 = Shift (левый или правый) сейчас зажат
RAM_KBD_PENDING equ 0x0511   ; byte: 1 = есть декодированная клавиша, ждущая выборки
RAM_KBD_PENDING_CHAR equ 0x0512 ; byte: ASCII-код ожидающей клавиши
RAM_KBD_PENDING_SCAN equ 0x0513 ; byte: Scan Set 1 код ожидающей клавиши
RAM_GEOM_SPT equ 0x0514      ; byte: секторов/дорожку для ТЕКУЩЕГО вызова
                              ; int 13h AH=0x02/0x08 - не персистентно, просто
                              ; рабочая область (в регистрах уже не хватает места)
RAM_GEOM_HPC equ 0x0515      ; byte: головок для текущего вызова int 13h
RAM_MEM_KB   equ 0x0516      ; word: объём conventional-памяти в KB, найденный
                              ; post_memory_test (для int 12h)
RAM_GEOM_DRIVEBIT equ 0x0518 ; byte: бит выбора master/slave (0x1F6, бит4)
                              ; для ТЕКУЩЕГО вызова int 13h AH=0x02 - как и
                              ; RAM_GEOM_SPT/_HPC, не персистентно
RAM_ENTER_SETUP equ 0x0519   ; byte: 1 = во время prompt_setup_key нажат Del -
                              ; не персистентно, живёт только до конца POST
RAM_BOOT_DRIVE equ 0x051A    ; byte: DL диска для boot_try_disk (0x80=master,
                              ; 0x81=slave) - персистентно, из setup-меню
RAM_QUIET_BOOT equ 0x051B    ; byte: 1 = не печатать POST-диагностику на VGA
                              ; (баннер/тест памяти/самотест клавиатуры) -
                              ; персистентно, из setup-меню
RAM_CPU_BRAND equ 0x051C     ; 49 байт: ASCIIZ строка модели CPU (CPUID) -
                              ; не персистентно, как RAM_DEC_BUF - заново
                              ; заполняется каждый раз при открытии System
                              ; Information (см. cpu_get_brand)

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

    ; int 12h (объём conventional-памяти) и int 15h (AH=0x88 - объём
    ; расширенной памяти) - см. их комментарии. RAM_MEM_KB, которую
    ; читает int 12h, заполняет post_memory_test чуть ниже по коду
    ; (ДО того, как загруженный код вообще сможет вызвать int 12h).
    call install_int12h_vector
    call install_int15h_vector

    ; Настоящий BIOS всегда переинициализирует 8259 PIC во время POST
    ; (IRQ0-7 -> INT 0x08-0x0F, IRQ8-15 -> INT 0x70-0x77) - иначе после
    ; RESET контроллер прерываний не запрограммирован вообще. Мы сами
    ; прерываниями не пользуемся (IF весь POST выключен - см. cli выше),
    ; но загруженная ОС может на это полагаться неявно: если её
    ; клавиатурный обработчик просто вешается на "стандартный" вектор
    ; IRQ1, ожидая, что PIC уже приведён в это состояние настоящим BIOS
    ; (частая практика в простых ОС, не делающих собственный remap),
    ; без этого шага IRQ1 у неё либо не долетит до обработчика вообще,
    ; либо попадёт на чужой вектор.
    call pic_init
    call lapic_unmask_lint0

    ; Настоящий IRQ0 (таймер) и IRQ1 (клавиатура) теперь реально
    ; доходят до CPU (см. lapic_unmask_lint0 выше) - а значит, любой
    ; загруженный код, который просто честно делает "sti" (СТАНДАРТНАЯ
    ; практика для boot-секторов, наш собственный boot.asm включая),
    ; ожидает, что настоящий BIOS уже поставил обработчики на IVT[0x08]/
    ; IVT[0x09] - без этого первый же таймерный тик прыгает в мусор
    ; (что бы ни лежало в ещё не тронутой низкой памяти) и всё виснет.
    ; Раньше это было незаметно ровно потому, что IRQ0/1 никогда не
    ; доходили до CPU вообще - см. историю в claude.md.
    call install_int08_vector
    call install_int09_vector

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

    ; Видеопамять не трогается процессорным reset (это отдельное от
    ; CPU устройство) - на настоящей "холодной" загрузке она и так
    ; чистая, но при Quiet boot (короткий вывод) вперемешку с warm
    ; reset (например, Ctrl+Alt+Del) старый текст с предыдущей
    ; загрузки иначе остаётся виден вокруг "Press DEL...". Раньше
    ; это маскировалось длинным баннером/POST-выводом, перекрывавшим
    ; экран целиком.
    call vga_clear_screen
    mov word [ss:RAM_VGA_POS], 0
    mov si, msg_banner
    call print_vga_post

    call post_memory_test
    call post_keyboard_test

    mov si, msg_done
    call print_serial
    mov si, msg_done
    call print_vga_post

    ; Настоящий BIOS не открывает setup сам по себе каждую загрузку -
    ; он коротко ждёт условленную клавишу (обычно Del) и, если её не
    ; нажали, идёт сразу дальше. RAM_ENTER_SETUP выставляется внутри
    ; prompt_setup_key, если Del успели нажать за отведённое время.
    call prompt_setup_key
    cmp byte [ss:RAM_ENTER_SETUP], 0
    je .skip_setup
    call setup_menu
.skip_setup:

    ; Setup закрыт (или не открывался) - продолжаем обычную
    ; последовательность загрузки: пробуем найти и загрузить MBR с
    ; диска (как это делает настоящий BIOS после POST/setup).
    call boot_try_disk

halt_cpu:
    hlt
    jmp halt_cpu

; =========================================================
; Переинициализация (remap) 8259 PIC - master на порты 0x20/0x21,
; slave на 0xA0/0xA1. Стандартная последовательность ICW1-ICW4,
; та же, что делает любой настоящий PC/AT BIOS: master IRQ0-7 ->
; INT 0x08-0x0F, slave IRQ8-15 -> INT 0x70-0x77 (без этого IRQ0-7
; конфликтовали бы с векторами процессорных исключений 0x00-0x07 -
; собственно, поэтому remap обязателен даже для тех, кто прерывания
; не использует). Маски (OCW1) оставляем как у типичного BIOS:
; открыты только IRQ0 (таймер), IRQ1 (клавиатура) и IRQ2 (каскад на
; slave, без него ничего со slave вообще не дойдёт до CPU), slave
; полностью замаскирован - каждая ОС/драйвер сама открывает то, что
; ей реально нужно.
; =========================================================
pic_init:
    push ax

    mov al, 0x11          ; ICW1: edge-triggered, cascade, ICW4 будет
    out 0x20, al
    out 0xA0, al

    mov al, 0x08           ; ICW2 (master): вектор смещения IRQ0 = 0x08
    out 0x21, al
    mov al, 0x70            ; ICW2 (slave): вектор смещения IRQ8 = 0x70
    out 0xA1, al

    mov al, 0x04              ; ICW3 (master): slave подключен на IRQ2
    out 0x21, al
    mov al, 0x02                ; ICW3 (slave): свой ID = 2
    out 0xA1, al

    mov al, 0x01                  ; ICW4: 8086/88 mode на обоих
    out 0x21, al
    out 0xA1, al

    mov al, 0xF8                    ; OCW1 (master): открыты IRQ0/1/2
    out 0x21, al
    mov al, 0xFF                      ; OCW1 (slave): всё закрыто
    out 0xA1, al

    pop ax
    ret

; =========================================================
; Разблокировка доставки аппаратных IRQ через 8259 PIC до самого
; CPU - регистр LVT LINT0 у Local APIC (физический адрес
; 0xFEE00350). По Intel SDM этот вход после RESET замаскирован по
; умолчанию - без явного снятия маски НИ ОДНО аппаратное прерывание
; не доходит до ядра, даже если PIC (см. pic_init выше) и
; периферия настроены абсолютно правильно. Настоящий BIOS всегда
; это делает; подробная история находки (включая первую, неудачную
; попытку через полноценный real->protected->real переход с
; far jmp) - в claude.md.
;
; Адрес 0xFEE00350 недостижим из чистой сегментной адресации
; реального режима (максимум ~1 МБ+64K через A20). Первая попытка
; решить это полным переключением в 32-битный protected mode (со
; сменой CS через far jmp туда и обратно) стабильно проваливалась
; на обратном прыжке по необъяснённой причине. Эта версия использует
; "unreal mode" - CS вообще не трогается: PE=1 включается, ES
; ненадолго получает плоский (0-4ГБ) дескриptor из GDT, PE=0
; выключается обратно - и всё это время CS остаётся тем же самым
; реальным сегментом с тем же самым кэшем, каким был всегда, поэтому
; никакой валидации/перезагрузки CS не происходит и в ней нечему
; сломаться. `jmp $+2` после возврата - обычный ближний переход
; (не far, CS не трогает), нужен только чтобы сбросить очередь
; предвыборки после смены CR0.PE - как и весь остальной POST, это
; выполняется с IF=0 (см. cli в start:), так что делать это можно
; спокойно.
; =========================================================
lapic_unmask_lint0:
    pusha
    push es

    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    mov ax, 0x08
    mov es, ax

    mov eax, cr0
    and eax, 0xFFFFFFFE
    mov cr0, eax

    jmp $+2

    a32 mov dword [es:0xFEE000F0], 0x1FF   ; SVR: bit8=APIC software enable, spurious vector 0xFF
    a32 mov dword [es:0xFEE00350], 0x700   ; LVT LINT0: delivery mode=ExtINT(0b111), unmasked

    pop es
    popa
    ret

gdt_start:
    dq 0
gdt_data:
    dw 0xFFFF, 0x0000
    db 0x00, 10010010b, 11001111b, 0x00
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd 0xF0000 + gdt_start

; =========================================================
; IRQ0 (таймер) и IRQ1 (клавиатура) - настоящие аппаратные
; обработчики на IVT[0x08]/IVT[0x09], как у любого реального BIOS.
; Отдельная пара от install_int10h_vector и т.п. выше: те ставят
; вектора для СОФТВЕРНЫХ "int N" вызовов (сервисы, которые кто-то
; сам вызывает), а эти два - для настоящих HARDWARE IRQ, которые
; CPU получает сам, без чьего-либо "int" (нужны, только когда
; interrupt flag реально включён где-то в загруженном коде).
; =========================================================
install_int08_vector:
    push ax
    push es

    xor ax, ax
    mov es, ax
    mov word [es:0x08*4], int08_isr
    mov word [es:0x08*4+2], cs

    pop es
    pop ax
    ret

install_int09_vector:
    push ax
    push es

    xor ax, ax
    mov es, ax
    mov word [es:0x09*4], int09_isr
    mov word [es:0x09*4+2], cs

    pop es
    pop ax
    ret

; IRQ0: считаем тики в BDA (0x0040:0x006C), как настоящий BIOS -
; ничего, кроме этого счётчика, само по себе от таймера не зависит,
; но не увеличивать его молча вместо честного счёта было бы хуже
; (см. философию "явная нулевая честность лучше тихой лжи" у
; int13h выше) - а рассинхронизация суток (полночный флаг) за
; пределами того, что нужно этому проекту.
int08_isr:
    push ax
    push es

    mov ax, 0x0040
    mov es, ax
    inc dword [es:0x6C]

    mov al, 0x20
    out 0x20, al
    pop es
    pop ax
    iret

; IRQ1: просто переиспользуем kbd_service - к моменту вызова ISR
; байт уже точно есть на порту 0x60 (иначе IRQ бы не случился), так
; что её собственный поллинг-чек тривиально пройдёт с первого раза.
; Один и тот же однослотовый буфер (RAM_KBD_PENDING/_CHAR/_SCAN)
; работает одинаково что при IRQ-доставке, что при обычном поллинге
; из int16h - ничего дублировать не пришлось.
int09_isr:
    push ax
    call kbd_service
    mov al, 0x20
    out 0x20, al
    pop ax
    iret

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
;   AH=0x09 - запись символа с атрибутом, без сдвига курсора (AL=символ,
;             BL=атрибут, CX=повторов) - нужна GRUB для рамки меню
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
    cmp ah, 0x09
    je .fn_09
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
    jmp .done
.fn_09:
    call int10h_write_char_attr

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

; int 10h AH=0x09 - запись символа с атрибутом в текущую позицию
; курсора, БЕЗ его продвижения (в отличие от AH=0x0E). Вход: AL=
; символ, BH=страница (игнорируем - у нас одна), BL=атрибут (цвет),
; CX=сколько раз повторить подряд от текущей позиции. Пишет байт как
; есть, без спецобработки 13/10 (как и настоящий BIOS для этой
; функции - CR/LF тут просто печатаются как есть, а не переводят
; строку). Найдена нужной эмпирически: GRUB рисует ей цветную рамку
; меню (137 вызовов при загрузке) - без неё меню просто не
; отрисовывалось, хотя сам GRUB после этого продолжал работать
; (доходил до интерактивного ожидания клавиши, просто невидимо).
; "Set"-функция - ничего не возвращает, поэтому сохраняет всё, что
; использует.
int10h_write_char_attr:
    cmp byte [ss:RAM_VGA_ON], 0
    je .done

    push ax
    push bx
    push cx
    push dx
    push di
    push es

    mov dx, 0xB800
    mov es, dx
    mov di, [ss:RAM_VGA_POS]
    mov dl, al                  ; символ - забираем, дальше al свободен

.loop:
    jcxz .pop_done
    mov [es:di], dl
    mov [es:di+1], bl
    add di, 2
    dec cx
    jmp .loop

.pop_done:
    pop es
    pop di
    pop dx
    pop cx
    pop bx
    pop ax
.done:
    ret

; =========================================================
; int 16h - клавиатурные сервисы. Поддерживаются:
;   AH=0x00 - блокирующее чтение символа (-> AL=ASCII, AH=сырой скан-код)
;   AH=0x01 - неблокирующая проверка (ZF=1 если клавиш нет; иначе
;             ZF=0 и AL/AH заполнены, КАК И в AH=0x00, но клавиша НЕ
;             потребляется - следующий AH=0x00/0x01 увидит её снова)
; Поверх того же поллинга портов 0x60/0x64 (Scan Set 1, аппаратно
; транслированный контроллером - см. фикс IRQ1 в post_keyboard_test),
; что уже используется в setup_menu, но декодированного в ASCII через
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

; Продвигает автомат разбора клавиатуры максимум на один байт Scan
; Set 1, если он уже доступен у контроллера (порт 0x64, бит 0) - НЕ
; блокирует. С аппаратной трансляцией включённой (см. фикс IRQ1 в
; post_keyboard_test) отпускание клавиши в Set 1 - это ОДИН байт
; (код нажатия с установленным битом7), а не F0+код, как в сыром
; Set 2 - поэтому отдельный флаг-автомат (RAM_BREAK_FLAG) больше не
; нужен вообще. E0 (расширенная клавиша) по-прежнему просто
; пропускается - то же осознанное упрощение, что и раньше (см.
; комментарий у MAX_SCAN). Shift (0x2A/0x36 - Set 1 коды) обрабатывается
; отдельно - не как обычная клавиша, а как модификатор для
; kbd_ascii_hi/_lo. Если уже есть непотреблённая клавиша
; (RAM_KBD_PENDING=1) - ничего не делает, чтобы её не затереть до
; того, как её заберут.
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

    test al, 0x80
    jz .make_event

    ; код ОТПУСКАНИЯ (бит7=1, Set 1) - из всех клавиш нас интересует
    ; только отпускание Shift, остальное просто игнорируем
    mov ah, al
    and ah, 0x7F
    cmp ah, 0x2A
    je .shift_release
    cmp ah, 0x36
    je .shift_release
    jmp .done
.shift_release:
    mov byte [ss:RAM_KBD_SHIFT], 0
    jmp .done

.make_event:
    cmp al, 0x2A
    je .shift_press
    cmp al, 0x36
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

    mov byte [ss:RAM_KBD_PENDING_CHAR], ah
    mov byte [ss:RAM_KBD_PENDING_SCAN], al   ; al уже Set 1 - трансляция не нужна
    mov byte [ss:RAM_KBD_PENDING], 1
    jmp .done

.shift_press:
    mov byte [ss:RAM_KBD_SHIFT], 1

.done:
    pop bx
    pop ax
    ret

; Таблицы трансляции Scan Set 1 make-кода (0x00-MAX_SCAN) в ASCII.
; Индекс - сам скан-код (как его отдаёт контроллер с включённой
; аппаратной трансляцией - см. фикс IRQ1 в post_keyboard_test); 0 =
; клавиша без ASCII-эквивалента. Числовые коды вместо символьных
; литералов - там, где символ сам по себе конфликтует с синтаксисом
; NASM (кавычки, обратный слэш): 8=BS, 9=TAB, 13=CR(Enter), 27=ESC,
; 34=", 39=', 58=:, 59=;, 92=\, 96=`, 124=|, 126=~.
MAX_SCAN equ 0x58

kbd_ascii_lo:
    db 0,27,'1','2','3','4','5','6','7','8','9','0','-','=',8,9      ; 0x00-0x0F
    db 'q','w','e','r','t','y','u','i','o','p','[',']',13,0,'a','s'  ; 0x10-0x1F
    db 'd','f','g','h','j','k','l',59,39,96,0,92,'z','x','c','v'     ; 0x20-0x2F
    db 'b','n','m',',','.','/',0,0,0,' ',0,0,0,0,0,0                 ; 0x30-0x3F
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0                               ; 0x40-0x4F
    db 0,0,0,0,0,0,0,0,0                                             ; 0x50-0x58

kbd_ascii_hi:
    db 0,27,'!','@','#','$','%','^','&','*','(',')','_','+',8,9      ; 0x00-0x0F
    db 'Q','W','E','R','T','Y','U','I','O','P','{','}',13,0,'A','S'  ; 0x10-0x1F
    db 'D','F','G','H','J','K','L',58,34,126,0,124,'Z','X','C','V'   ; 0x20-0x2F
    db 'B','N','M','<','>','?',0,0,0,' ',0,0,0,0,0,0                 ; 0x30-0x3F
    db 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0                               ; 0x40-0x4F
    db 0,0,0,0,0,0,0,0,0                                             ; 0x50-0x58

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

; То же самое, что print_vga, но дополнительно уважает тумблер
; "Quiet boot" - используется ТОЛЬКО для самих POST-сообщений
; (баннер, тест памяти, самотест клавиатуры), не для setup-меню и не
; для сообщений загрузки диска - те должны быть видны всегда,
; независимо от Quiet boot.
print_vga_post:
    cmp byte [ss:RAM_QUIET_BOOT], 0
    jne .noop
    jmp print_vga
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
    call print_vga_post

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
    mov [ss:RAM_MEM_KB], ax  ; запоминаем для int 12h
    call print_dec_ax

    mov si, msg_kb
    call print_serial
    mov si, msg_kb
    call print_vga_post

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
    call print_vga_post

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
    call print_vga_post

    ; Самотест контроллера прошёл, но сам по себе он ещё не значит,
    ; что контроллер будет поднимать линию IRQ1 при нажатии клавиши -
    ; за это отвечает отдельный бит (бит0) в Controller Configuration
    ; Byte, читаемом/записываемом командами 0x20/0x60 на порт 0x64.
    ; Мы сами читаем клавиатуру только поллингом (см. kbd_service),
    ; которому этот бит не нужен - поэтому раньше он никогда не
    ; включался. Настоящий BIOS всегда включает его при POST; без
    ; этого шага любая загруженная ОС с interrupt-driven (не polling)
    ; клавиатурным драйвером не получит вообще ни одного прерывания,
    ; даже если сама всё правильно настроила (свой IDT, свой remap
    ; PIC) - на уровне ниже физически нечему сработать. Заодно
    ; включаем бит6 (аппаратная трансляция Set 2 -> Set 1) - весь
    ; клавиатурный стек ниже (kbd_service, setup_menu) теперь тоже
    ; ждёт готовый Set 1 прямо с порта 0x60, как и настоящий BIOS.
    ; Best-effort: таймаут на любом шаге просто пропускает остаток -
    ; самотест уже прошёл, это не повод сообщать об ошибке.
    mov cx, 0xFFFF
.kbdcfg_wait_ibe1:
    in al, 0x64
    test al, 0x02
    jz .kbdcfg_read_cmd
    loop .kbdcfg_wait_ibe1
    jmp .kbd_done

.kbdcfg_read_cmd:
    mov al, 0x20            ; "Read Controller Configuration Byte"
    out 0x64, al

    mov cx, 0xFFFF
.kbdcfg_wait_obf:
    in al, 0x64
    test al, 0x01
    jnz .kbdcfg_got_byte
    loop .kbdcfg_wait_obf
    jmp .kbd_done

.kbdcfg_got_byte:
    in al, 0x60
    or al, 0x41              ; бит0=1: включить IRQ1; бит6=1: включить
                                ; аппаратную трансляцию Set 2 -> Set 1 -
                                ; так же, как это делает настоящий BIOS.
                                ; Раньше здесь было наоборот (бит6=0,
                                ; сырой Set 2), под собственную софтверную
                                ; трансляцию - но внешний код (загруженная
                                ; ОС), читающий порт 0x60 напрямую в обход
                                ; int16h, ожидает готовый Set 1 оттуда же,
                                ; откуда его ожидает настоящий BIOS. См.
                                ; историю в claude.md про перепутанные
                                ; символы при IRQ-driven вводе.
    mov ah, al                 ; сохраняем новый байт на время ожидания порта

    mov cx, 0xFFFF
.kbdcfg_wait_ibe2:
    in al, 0x64
    test al, 0x02
    jz .kbdcfg_write_cmd
    loop .kbdcfg_wait_ibe2
    jmp .kbd_done

.kbdcfg_write_cmd:
    mov al, 0x60             ; "Write Controller Configuration Byte"
    out 0x64, al

    mov cx, 0xFFFF
.kbdcfg_wait_ibe3:
    in al, 0x64
    test al, 0x02
    jz .kbdcfg_write_byte
    loop .kbdcfg_wait_ibe3
    jmp .kbd_done

.kbdcfg_write_byte:
    mov al, ah
    out 0x60, al
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

    call num_to_dec_buf

    mov si, RAM_DEC_BUF
    call print_serial
    mov si, RAM_DEC_BUF
    call print_vga_post

    pop ds
    pop si
    pop dx
    pop cx
    pop bx
    ret

; Конвертирует AX (0-65535) в ASCIIZ-строку в RAM_DEC_BUF (RAM,
; сегмент 0x0000) - общая часть print_dec_ax и vga_print_dec_at,
; выделена, чтобы не дублировать деление на 10 в столбик дважды.
; Портит AX/BX/CX/DX/SI/DS - вызывающий сам решает, что сохранять.
num_to_dec_buf:
    push ax
    xor ax, ax
    mov ds, ax              ; DS = 0x0000 (RAM), там лежит RAM_DEC_BUF
    pop ax                   ; восстановили число для конвертации

    mov bx, 10
    xor cx, cx

    cmp ax, 0
    jne .divloop
    mov byte [RAM_DEC_BUF], '0'
    mov byte [RAM_DEC_BUF+1], 0
    ret

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

; То же самое, что vga_print_at, но для числа (AX, 0-65535) вместо
; готовой строки - переиспользует num_to_dec_buf, которым уже
; пользуется print_dec_ax. DH/DL (позиция) и BL (атрибут) нужно
; сохранить вокруг num_to_dec_buf - она сама портит BX/CX/DX/SI/DS.
vga_print_dec_at:
    push ax
    push bx
    push cx
    push dx
    push si
    push ds

    push dx                  ; сохраняем позицию (DH/DL)
    push bx                   ; сохраняем атрибут (BL, целиком через BX)

    call num_to_dec_buf

    pop bx
    pop dx

    xor ax, ax
    mov ds, ax
    mov si, RAM_DEC_BUF
    call vga_print_at

    pop ds
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    ret

; =========================================================
; Короткое окно после POST, где можно нажать Del, чтобы попасть в
; setup - как у настоящего BIOS, вместо того чтобы открывать
; setup-меню безусловно на каждой загрузке. Если Del не нажали за
; отведённое время, RAM_ENTER_SETUP остаётся 0, и start: идёт сразу
; к загрузке диска.
;
; Del на полноразмерной клавиатуре - расширенная клавиша (E0 53 в
; Set 1); Del/"." на numpad с выключенным NumLock шлёт тот же код
; 0x53 без префикса E0. Поскольку E0 в этом проекте везде просто
; пропускается (см. комментарий у setup_menu), оба случая ловятся
; одной и той же проверкой на следующем непропущенном байте - не
; нужно отдельно разбирать расширенную последовательность.
;
; Таймаут - обычный instruction-count busy-wait (тот же приём, что и
; у остальных таймаутов в проекте, см. например .srst_delay в
; int13h_reset), без привязки к реальным секундам - подобран
; тестированием в QEMU до субъективно комфортной паузы.
; =========================================================
KEY_DEL equ 0x53

prompt_setup_key:
    push ax
    push cx
    push dx

    mov byte [ss:RAM_ENTER_SETUP], 0

    mov si, msg_press_del
    call print_serial
    mov si, msg_press_del
    call print_vga

    mov dx, 1200
.outer:
    mov cx, 0xFFFF
.wait:
    in al, 0x64
    test al, 0x01
    jz .next

    in al, 0x60

    cmp al, 0xE0
    je .next                     ; расширенный префикс - пропускаем

    test al, 0x80
    jnz .next                     ; отпускание - игнорируем

    cmp al, KEY_DEL
    jne .next

    mov byte [ss:RAM_ENTER_SETUP], 1
    jmp .done

.next:
    loop .wait
    dec dx
    jnz .outer

.done:
    pop dx
    pop cx
    pop ax
    ret

; =========================================================
; Интерактивное setup-меню: стрелки вверх/вниз, Enter, Esc.
; Опрос клавиатуры - простым поллингом порта 0x64/0x60 (без
; IRQ/PIC).
;
; Контроллер транслирует в Scan Code Set 1 (см. фикс IRQ1 в
; post_keyboard_test - бит6 Configuration Byte), как и настоящий
; BIOS: стрелки идут как E0 48 / E0 50, Enter как 0x1C, Esc как
; 0x01. Байт-префикс E0 (расширенная клавиша) просто пропускаем.
; Отпускание клавиши в Set 1 - это ОДИН байт (код нажатия с битом7),
; не отдельный префикс F0 - проверяем его прямо на входном байте.
; =========================================================
KEY_UP    equ 0x48
KEY_DOWN  equ 0x50
KEY_ENTER equ 0x1C
KEY_ESC   equ 0x01

setup_menu:
    push ax

    mov word [ss:RAM_MENU_SEL], 0

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

    ; --- пункт 2: Boot device ---
    mov dh, 5
    mov dl, 2
    mov bl, 0x07
    cmp word [ss:RAM_MENU_SEL], 2
    jne .item2_draw
    mov bl, 0x70
.item2_draw:
    mov si, menu_item2
    call vga_print_at
    mov dh, 5
    mov dl, 26
    mov bl, 0x0F
    cmp byte [ss:RAM_BOOT_DRIVE], 0x80
    jne .item2_slave
    mov si, str_master
    jmp .item2_status
.item2_slave:
    mov si, str_slave
.item2_status:
    call vga_print_at

    ; --- пункт 3: Quiet boot ---
    mov dh, 6
    mov dl, 2
    mov bl, 0x07
    cmp word [ss:RAM_MENU_SEL], 3
    jne .item3_draw
    mov bl, 0x70
.item3_draw:
    mov si, menu_item3
    call vga_print_at
    mov dh, 6
    mov dl, 26
    mov bl, 0x0F
    cmp byte [ss:RAM_QUIET_BOOT], 0
    jne .item3_on
    mov si, str_off
    jmp .item3_status
.item3_on:
    mov si, str_on
.item3_status:
    call vga_print_at

    ; --- пункт 4: System Information (не тумблер, открывает экран) ---
    mov dh, 8
    mov dl, 2
    mov bl, 0x07
    cmp word [ss:RAM_MENU_SEL], 4
    jne .item4_draw
    mov bl, 0x70
.item4_draw:
    mov si, menu_item4
    call vga_print_at

    ; --- пункт 5: Exit ---
    mov dh, 10
    mov dl, 2
    mov bl, 0x07
    cmp word [ss:RAM_MENU_SEL], 5
    jne .item5_draw
    mov bl, 0x70
.item5_draw:
    mov si, menu_item5
    call vga_print_at

    mov dh, 13
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

    test al, 0x80
    jnz .wait_key            ; бит7=1 - код ОТПУСКАНИЯ (Set 1, один байт) - игнорируем

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
    cmp ax, 5
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
    cmp ax, 2
    je .toggle_boot_drive
    cmp ax, 3
    je .toggle_quiet
    cmp ax, 4
    je .show_system_info
    jmp .key_esc          ; пункт 5 (Exit) по Enter

.toggle_serial:
    xor byte [ss:RAM_SERIAL_ON], 1
    call cmos_save_settings
    jmp .redraw

.toggle_vga:
    xor byte [ss:RAM_VGA_ON], 1
    call cmos_save_settings
    jmp .redraw

.toggle_boot_drive:
    cmp byte [ss:RAM_BOOT_DRIVE], 0x80
    jne .set_master
    mov byte [ss:RAM_BOOT_DRIVE], 0x81
    jmp .boot_drive_saved
.set_master:
    mov byte [ss:RAM_BOOT_DRIVE], 0x80
.boot_drive_saved:
    call cmos_save_settings
    jmp .redraw

.toggle_quiet:
    xor byte [ss:RAM_QUIET_BOOT], 1
    call cmos_save_settings
    jmp .redraw

.show_system_info:
    call system_info_screen
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

; Заполняет RAM_CPU_BRAND ASCIIZ-строкой с моделью CPU через CPUID:
; сначала честно проверяет, есть ли сам CPUID (переключение бита 21
; EFLAGS - "ID flag", стандартный приём для реального режима, работает
; и на 386/486 без CPUID, где бит просто не переключится), затем
; смотрит на максимальный расширенный лист (EAX=0x80000000) - если
; >=0x80000004, есть "brand string" (то самое "Intel(R) Core(TM)...",
; три листа по 16 байт = 48 символов). Если brand string недоступен,
; но CPUID есть - берём 12-байтный Vendor ID (EAX=0, всегда
; поддерживается, если CPUID вообще есть). Если CPUID нет вообще -
; честно "Unknown", а не молчим и не выдумываем - та же философия,
; что и у AH=0x88/AH=0x08 в других местах проекта.
cpu_get_brand:
    pushad
    push es
    push ds

    xor ax, ax
    mov ds, ax
    mov es, ax

    pushfd
    pop eax
    mov ecx, eax
    xor eax, 0x200000
    push eax
    popfd
    pushfd
    pop eax
    push ecx
    popfd
    xor eax, ecx
    test eax, 0x200000
    jnz .cpuid_ok

    mov si, str_cpu_unknown
    mov di, RAM_CPU_BRAND
.copy_unknown:
    lodsb
    stosb
    cmp al, 0
    jne .copy_unknown
    jmp .done

.cpuid_ok:
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .use_vendor

    mov edi, RAM_CPU_BRAND
    mov eax, 0x80000002
    cpuid
    mov [edi], eax
    mov [edi+4], ebx
    mov [edi+8], ecx
    mov [edi+12], edx
    add edi, 16

    mov eax, 0x80000003
    cpuid
    mov [edi], eax
    mov [edi+4], ebx
    mov [edi+8], ecx
    mov [edi+12], edx
    add edi, 16

    mov eax, 0x80000004
    cpuid
    mov [edi], eax
    mov [edi+4], ebx
    mov [edi+8], ecx
    mov [edi+12], edx
    add edi, 16

    mov byte [edi], 0     ; терминатор - 49-й байт RAM_CPU_BRAND

    ; brand string обычно дополнен пробелами слева до фиксированной
    ; ширины - подвинем начало строки к первому непробельному символу,
    ; иначе на экране будет лишний отступ
    mov si, RAM_CPU_BRAND
.skip_spaces:
    cmp byte [si], ' '
    jne .found_start
    inc si
    jmp .skip_spaces
.found_start:
    cmp si, RAM_CPU_BRAND
    je .done
    mov di, RAM_CPU_BRAND
.shift_loop:
    lodsb
    stosb
    cmp al, 0
    jne .shift_loop
    jmp .done

.use_vendor:
    xor eax, eax
    cpuid
    mov edi, RAM_CPU_BRAND
    mov [edi], ebx
    mov [edi+4], edx
    mov [edi+8], ecx
    mov byte [edi+12], 0

.done:
    pop ds
    pop es
    popad
    ret

; =========================================================
; Информационный экран (не тумблер, просто просмотр) - модель CPU
; (см. cpu_get_brand), объём памяти (conventional через RAM_MEM_KB,
; extended через CMOS - см. int15h_ext_mem_kb), геометрия дисков и
; текущий загрузочный привод. Ничего не меняет. Геометрия HDD/floppy -
; фиксированные константы (SPT_HDD/HPC_HDD/SPT_FLOPPY/HPC_FLOPPY, см.
; их комментарий у int13h_get_params), поэтому просто печатаются как
; готовые строки, а не собираются из чисел - у нас всё равно нет
; IDENTIFY DEVICE, чтобы узнать настоящую геометрию диска.
; =========================================================
system_info_screen:
    push ax
    push dx
    push bx
    push si

    call cpu_get_brand      ; заполняет RAM_CPU_BRAND - до vga_clear_screen
                              ; не важно, но пусть весь сбор данных идёт
                              ; одним блоком в начале
    call vga_clear_screen

    mov dh, 1
    mov dl, 2
    mov bl, 0x0F
    mov si, sysinfo_title
    call vga_print_at

    mov dh, 3
    mov dl, 2
    mov bl, 0x07
    mov si, sysinfo_cpu
    call vga_print_at
    mov dh, 3
    mov dl, 24
    mov bl, 0x0F
    push ds                 ; RAM_CPU_BRAND - в RAM (сегмент 0), а не в
    push ax                   ; ROM, где обычно живёт DS - vga_print_at
    xor ax, ax                  ; читает строку через DS:SI, ей всё равно,
    mov ds, ax                    ; какой DS у вызывающего
    mov si, RAM_CPU_BRAND
    call vga_print_at
    pop ax
    pop ds

    mov dh, 5
    mov dl, 2
    mov bl, 0x07
    mov si, sysinfo_mem_conv
    call vga_print_at
    mov dh, 5
    mov dl, 24
    mov bl, 0x0F
    mov ax, [ss:RAM_MEM_KB]
    call vga_print_dec_at
    mov dh, 5
    mov dl, 28
    mov bl, 0x07
    mov si, str_kb
    call vga_print_at

    mov dh, 6
    mov dl, 2
    mov bl, 0x07
    mov si, sysinfo_mem_ext
    call vga_print_at
    call int15h_ext_mem_kb    ; ax = расширенная память в КБ (из CMOS)
    mov dh, 6
    mov dl, 24
    mov bl, 0x0F
    call vga_print_dec_at
    mov dh, 6
    mov dl, 28
    mov bl, 0x07
    mov si, str_kb
    call vga_print_at

    mov dh, 8
    mov dl, 2
    mov bl, 0x07
    mov si, sysinfo_boot_drive
    call vga_print_at
    mov dh, 8
    mov dl, 24
    mov bl, 0x0F
    cmp byte [ss:RAM_BOOT_DRIVE], 0x80
    jne .info_slave
    mov si, str_master
    jmp .info_drive_status
.info_slave:
    mov si, str_slave
.info_drive_status:
    call vga_print_at

    mov dh, 10
    mov dl, 2
    mov bl, 0x07
    mov si, sysinfo_hdd_geom
    call vga_print_at
    mov dh, 10
    mov dl, 24
    mov bl, 0x0F
    mov si, sysinfo_hdd_geom_val
    call vga_print_at

    mov dh, 11
    mov dl, 2
    mov bl, 0x07
    mov si, sysinfo_fdd_geom
    call vga_print_at
    mov dh, 11
    mov dl, 24
    mov bl, 0x0F
    mov si, sysinfo_fdd_geom_val
    call vga_print_at

    mov dh, 14
    mov dl, 2
    mov bl, 0x08
    mov si, sysinfo_hint
    call vga_print_at

.wait_any_key:
    in al, 0x64
    test al, 0x01
    jz .wait_any_key
    in al, 0x60

    cmp al, 0xE0
    je .wait_any_key             ; расширенный префикс - пропускаем
    test al, 0x80
    jnz .wait_any_key            ; отпускание - ждём именно нажатия

    pop si
    pop bx
    pop dx
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

    ; --- сначала проверяем DL, ДО диспетчеризации по AH: физически
    ; мы умеем говорить только с master/slave primary ATA-канала
    ; (DL<0x80 - floppy-геометрия, но физически те же порты, что и
    ; master; DL=0x80 - master; DL=0x81 - slave). Для любого другого
    ; DL честно отвечаем "такого диска нет" (CF=1), а не молча
    ; успеваем на нём же master - иначе GRUB, перебирающая номера
    ; дисков в поисках своего, решает, что у нас 16+ дисков (каждый
    ; DL успешно отвечает). Раньше этой проверки не было вообще.
    cmp dl, 0x82
    jb .drive_ok
    pop es
    pop ds
    pop bp
    pop di
    pop si
    mov ah, 1
    mov bl, 1
    call patch_stack_cf
    iret
.drive_ok:

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
    push dx                     ; настоящий int 13h AH=0x02 не трогает DL/DH
                                   ; на выходе, а ниже DX многократно
                                   ; переиспользуется как адрес порта
                                   ; (0x1F0-0x1F7) - без сохранения вызывающий
                                   ; получил бы обратно DL=0xF0 (низкий байт
                                   ; последнего mov dx,0x1F0) вместо своего
                                   ; номера диска. Именно так и ловился этот
                                   ; баг: GRUB читает diskboot.img (1 сектор),
                                   ; получает "исправный" ответ, но с убитым
                                   ; DL, и следующий же вызов (chтение
                                   ; остального core.img) уходит с DL=0xF0 -
                                   ; наша же проверка DL<0x82 (см. int13h_isr)
                                   ; его честно отклоняет, GRUB печатает
                                   ; "Read Error".

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

    ; --- master/slave по DL, ПОКА DL ещё цел (дальше в этой функции
    ; будет mul, а он портит весь DX/DL - см. общий гоча-комментарий
    ; про mul в начале файла). DL=0x80 и DL<0x80(floppy) -> master
    ; (бит4=0); DL=0x81 -> slave (второй диск на ТОМ ЖЕ primary
    ; ATA-канале 0x1F0-0x1F7, т.е. -hdb в QEMU). Другие DL (0x82+) не
    ; поддерживаем - у нас нет secondary-канала (0x170-0x177), тихо
    ; трактуем как master, тот же принцип, что и везде в проекте.
    ; Раньше этого не было вообще - int13h всегда ходил на master,
    ; из-за чего GRUB, перебирая номера дисков, видел один и тот же
    ; физический диск под кучей разных "hdN".
    xor bl, bl                      ; bx (не al!) - al ещё нужен целым для
                                       ; входного числа секторов, его сохраняют
                                       ; чуть ниже через push ax
    cmp dl, 0x81
    jne .drivebit_done
    mov bl, 0x10
.drivebit_done:
    mov [ss:RAM_GEOM_DRIVEBIT], bl

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
    or al, 0xE0                                     ; зарезервированные биты + LBA-режим
    or al, [ss:RAM_GEOM_DRIVEBIT]                    ; 0=master, 0x10=slave
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
    pop dx
    pop bp
    pop di
    pop si
    ret

; =========================================================
; int 12h - объём conventional-памяти. В отличие от int 10h/13h/16h,
; у настоящего int 12h никогда не было диспетчера по AH - это одна-
; единственная функция. Выход: AX = KB памяти (0-640, кратно 64),
; найденной post_memory_test при POST (см. RAM_MEM_KB). "Get"-функция,
; поэтому AX не сохраняется - в нём и возвращается результат; больше
; никакие регистры не трогаем, поэтому даже si/di/bp/ds/es сохранять
; не нужно (не используются).
; =========================================================
install_int12h_vector:
    push ax
    push es

    xor ax, ax
    mov es, ax
    mov word [es:0x12*4], int12h_isr
    mov word [es:0x12*4+2], cs

    pop es
    pop ax
    ret

int12h_isr:
    mov ax, [ss:RAM_MEM_KB]
    iret

; =========================================================
; int 15h - системные сервисы. Поддерживается только AH=0x88 (объём
; расширенной памяти сверх 1MB, в KB). Мы её не тестируем сами (нет
; A20-gate/unreal mode для доступа выше 1MB, post_memory_test
; проверяет только conventional-память 0-640KB) - вместо этого читаем
; из стандартных CMOS-ячеек 0x17 (младший байт)/0x18 (старший байт),
; куда объём памяти кладёт сама платформа при старте (часть обычной
; PC/AT раскладки CMOS, QEMU её тоже эмулирует) - тем же способом,
; которым эту пару ячеек читает настоящий BIOS. Поле 16-битное и
; насыщается на 0xFFFF (65535 KB, ~64MB) - это историческое
; ограничение самой функции AH=0x88, а не наша недоработка. Прочие
; функции явно сигнализируют "не поддерживается" (CF=1, AH=0x86 -
; тот же код статуса, что использует для этого случая настоящий
; BIOS), тем же приёмом (patch_stack_cf), что и int 13h - см. его
; комментарий про регистровую конвенцию и про сам приём патча CF.
;
; Найдено эмпирически: GRUB падает с "out of memory" в своём
; аллокаторе кучи (kern/mm.c:grub_memalign), если честно ответить "0"
; на AH=0x88 - ему буквально некуда положить свою кучу. Проверка
; вручную (тестовый диск, читающий CMOS[0x17/0x18/0x30/0x31/0x34/0x35]
; напрямую и печатающий значения) показала, что QEMU действительно
; заполняет их правильно (0x34/0x35 = память выше 16MB в блоках по
; 64KB - у нас вышло ровно 128MB, это как раз RAM по умолчанию у
; QEMU), так что читать их - надёжнее и намного проще, чем городить
; A20-gate и пробинг памяти самим.
; =========================================================
install_int15h_vector:
    push ax
    push es

    xor ax, ax
    mov es, ax
    mov word [es:0x15*4], int15h_isr
    mov word [es:0x15*4+2], cs

    pop es
    pop ax
    ret

int15h_isr:
    push si
    push di
    push bp
    push ds
    push es

    cmp ah, 0x88
    je .fn_88

    pop es
    pop ds
    pop bp
    pop di
    pop si
    mov ah, 0x86              ; "функция не поддерживается" - тот же
                                ; код статуса, что и у настоящего BIOS
    mov bl, 1
    call patch_stack_cf
    iret

.fn_88:
    pop es
    pop ds
    pop bp
    pop di
    pop si
    call int15h_ext_mem_kb        ; ax = KB расширенной памяти (из CMOS)
    mov bl, 0
    call patch_stack_cf
    iret

; Читает объём расширенной памяти (1MB-16MB, в KB) из CMOS 0x17
; (младший байт)/0x18 (старший байт) - см. комментарий у AH=0x88 выше.
int15h_ext_mem_kb:
    push bx

    mov al, 0x17
    call cmos_read_byte
    mov bl, al                     ; bl = младший байт результата

    mov al, 0x18
    call cmos_read_byte
    mov ah, al                       ; ah = старший байт результата
    mov al, bl                          ; ax = итоговое значение

    pop bx
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
    mov dl, [ss:RAM_BOOT_DRIVE]  ; номер загрузочного диска - из setup-меню
    jmp 0x0000:BOOT_ADDR      ; управление дальше не возвращается

.boot_fail:
    mov si, msg_boot_fail
    call print_serial
    mov si, msg_boot_fail
    call print_vga
    pop ax
    ret

; Читает LBA=0 (1 сектор, 512 байт) с primary ATA master/slave (см.
; RAM_BOOT_DRIVE, настраивается в setup-меню) через PIO в SS:BOOT_ADDR
; (SS=0x0000). CF=1 при ошибке/таймауте/отсутствии диска. Тот же
; диск, что потом получит загруженный код в DL (см. boot_try_disk) -
; иначе можно было бы прочитать MBR с одного физического диска, а
; передать управление с DL другого.
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
    cmp byte [ss:RAM_BOOT_DRIVE], 0x81
    jne .drive_select_ready
    or al, 0x10                 ; slave (бит4 регистра drive/head)
.drive_select_ready:
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

; Загружает RAM_SERIAL_ON/RAM_VGA_ON/RAM_BOOT_DRIVE/RAM_QUIET_BOOT из
; CMOS, если там наша сигнатура, иначе выставляет значения по
; умолчанию и сохраняет их. Формат байта настроек: бит0=Serial,
; бит1=VGA, бит2=Boot drive (0=master/0x80, 1=slave/0x81), бит3=Quiet
; boot.
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

    mov bl, al
    and bl, 0x04
    mov bh, 0x80
    jz .master_loaded
    mov bh, 0x81
.master_loaded:
    mov [ss:RAM_BOOT_DRIVE], bh

    mov bl, al
    and bl, 0x08
    shr bl, 3
    mov [ss:RAM_QUIET_BOOT], bl
    jmp .done

.defaults:
    mov byte [ss:RAM_SERIAL_ON], 1
    mov byte [ss:RAM_VGA_ON], 1
    mov byte [ss:RAM_BOOT_DRIVE], 0x80
    mov byte [ss:RAM_QUIET_BOOT], 0
    call cmos_save_settings     ; сразу сохраняем дефолты + сигнатуру

.done:
    pop bx
    pop ax
    ret

; Упаковывает текущие RAM_SERIAL_ON/RAM_VGA_ON/RAM_BOOT_DRIVE/
; RAM_QUIET_BOOT в один байт и сохраняет в CMOS вместе с сигнатурой -
; формат см. в комментарии у cmos_load_settings.
cmos_save_settings:
    push ax
    push bx

    mov bl, [ss:RAM_SERIAL_ON]
    and bl, 1
    mov bh, [ss:RAM_VGA_ON]
    and bh, 1
    shl bh, 1
    or bl, bh

    mov bh, [ss:RAM_BOOT_DRIVE]
    cmp bh, 0x81
    jne .master_bit
    mov bh, 1
    jmp .drive_bit_ready
.master_bit:
    xor bh, bh
.drive_bit_ready:
    shl bh, 2
    or bl, bh

    mov bh, [ss:RAM_QUIET_BOOT]
    and bh, 1
    shl bh, 3
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
menu_item2:   db "Boot device", 0
menu_item3:   db "Quiet boot", 0
menu_item4:   db "System Information", 0
menu_item5:   db "Exit", 0
menu_hint:    db "Arrows: Move   Enter: Toggle/Select   Esc: Exit", 0
str_on:       db "ON ", 0
str_off:      db "OFF", 0
str_master:   db "Master", 0
str_slave:    db "Slave ", 0
str_kb:       db " KB", 0
msg_setup_exit: db "Setup closed.", 0
msg_press_del: db "Press DEL to enter SETUP...", 13, 10, 0

sysinfo_title:        db "System Information", 0
sysinfo_cpu:          db "Processor:", 0
str_cpu_unknown:      db "Unknown (no CPUID)", 0
sysinfo_mem_conv:     db "Conventional memory:", 0
sysinfo_mem_ext:      db "Extended memory:", 0
sysinfo_boot_drive:   db "Boot drive:", 0
sysinfo_hdd_geom:     db "HDD geometry:", 0
sysinfo_fdd_geom:     db "Floppy geometry:", 0
sysinfo_hdd_geom_val: db "63 sectors/track, 16 heads", 0
sysinfo_fdd_geom_val: db "18 sectors/track, 2 heads", 0
sysinfo_hint:         db "Press any key to return", 0

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