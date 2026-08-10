; Общая раскладка тестового диска - подключается и в boot.asm (stage1),
; и в stage2.asm, чтобы номера секторов не разъехались между файлами.
;
; Сектор 1 (CHS, считая с 1 / LBA0)      - stage1 (сам boot.asm, MBR)
; Секторы 2..(STAGE2_SECTORS+1)          - stage2 (stage2.bin, читается
;                                           через int 13h AH=0x02)
; Секторы (STAGE2_SECTORS+2)..(+3)       - 2 демо-сектора с известным
;                                           текстом для проверки чтения
STAGE2_SECTORS equ 8
DATA_SECTOR    equ STAGE2_SECTORS + 2
