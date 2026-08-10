; =========================================================
; Тестовый диск - stage1 (этот сектор, ровно 512 байт, MBR) +
; stage2.bin (человекочитаемый набор тестов int 10h/int 16h/int 13h,
; подключается ниже через incbin) + 2 демо-сектора с текстом.
;
; Сам stage1 - минимальный загрузчик: читает stage2 с диска через
; int 13h AH=0x02 (тот самый сервис, который эта BIOS предоставляет)
; и передаёт туда управление. Специально не пихаем читаемые тесты
; сюда же - одному сектору не хватило бы места на понятный текст,
; отсюда и вторая стадия. См. disklayout.inc за раскладкой секторов.
; =========================================================
[bits 16]
[org 0x7C00]

%include "disklayout.inc"

STAGE2_ADDR equ 0x9000

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti

    mov ax, 0x0003
    int 0x10

    mov si, msg_loading
    call print_string

    mov ax, 0x0200 | STAGE2_SECTORS   ; AH=0x02 (read), AL=STAGE2_SECTORS
    mov ch, 0
    mov cl, 2                            ; stage2 начинается со 2-го сектора
    mov dh, 0
    mov dl, 0x80
    mov bx, STAGE2_ADDR
    int 0x13
    jnc .load_ok

    mov si, msg_fail
    call print_string
    jmp .halt

.load_ok:
    jmp 0x0000:STAGE2_ADDR                ; управление дальше не возвращается

.halt:
    hlt
    jmp .halt

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

msg_loading: db "SilentBIOS test disk: loading stage 2 via int 13h...", 13, 10, 0
msg_fail:    db "int 13h read failed! Halting.", 13, 10, 0

times 510-($-$$) db 0
dw 0xAA55

; --- stage2 (секторы 2..STAGE2_SECTORS+1) - см. disklayout.inc ---
stage2_start:
incbin "stage2.bin"
stage2_end:
times (512*STAGE2_SECTORS) - (stage2_end - stage2_start) db 0

; --- демо-секторы (см. disklayout.inc, DATA_SECTOR) - известный
; текстовый паттерн для проверки int 13h AH=0x02 ---
sector_a_data:
db "SECTOR-A-DATA-OK!!!"
times 512-($-sector_a_data) db 0x00

sector_b_data:
db "SECTOR-B-DATA-OK!!!"
times 512-($-sector_b_data) db 0x00
