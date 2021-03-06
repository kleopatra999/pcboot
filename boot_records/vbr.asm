; pcboot volume boot record (VBR)
;
; Searches the boot disk for the FAT32 pcboot boot volume and loads the stage1
; code embedded in the reserved area after the VBR sector.
;
; The VBR follows the same interface as other VBRs--it does not assume it was
; invoked from the pcboot MBR.  As far I know, there is no reliable way in the
; VBR to get the VBR's LBA from the MBR.[1][2]  To find the boot volume, the
; VBR scans the disk's partitions, just like the MBR.  Like the MBR, it looks
; for a VBR with the appropriate marker, and succeeds only if a single match
; exists.
;
; Once it has found a match, it loads the post-VBR sector and jumps to it.
; The post-VBR sector loads stage1 from the remaining 15KiB of the FAT32
; reserved area, then jumps into it.  (Partitioning tools usually, if not
; always, initialize a FAT32 partition with 32 sectors reserved at the front,
; which includes the VBR.)
;
; There is an extreme shortage of room in the VBR for code.  While the MBR has
; a 72-byte reserved area at the end, the FAT32 VBR has a 90-byte table of
; fields at the beginning (as well as the required 0xaa55 suffix).  In
; addition, the VBR does more than the MBR:
;  - It must reload the MBR sector.
;  - It sanity-checks the post-VBR sector before jumping.
;  - It contains an 18-byte suffix for MBR identification.
; All the necessary behavior and error checking seems to fit, but with very
; few bytes to spare.
;
; Dropping support for CHS I/O would free up a large amount of space.
; Supposedly all PCs from the Pentium forward support the INT13 LBA
; extensions.[4]
;
; [1] There is a convention of passing a pointer to the booted partition table
; entry in SI.  I don't know how reliable this convention is.  (What if the
; partition is a logical partition?  Are there bootloaders that can chain to a
; logical partition other than pcboot's MBR?)
;
; [2] There is another convention of using the BPB_HiddSec field in the
; FAT32/NTFS VBRs to locate the volume.  All versions of DOS and Windows use
; this approach, so partition tools reliably update the BPB_HiddSec field when
; moving a FAT32/NTFS filesystem.  Unfortunately, they do not update the field
; usefully for a *logical* partition.[3]  DOS/Windows do not allow booting to a
; logical partition.
;
; [3] Some tools appear to write 63 as the BPB_HiddSec value for logical FAT32
; partitions (Win7 Disk Mgmt, MiniTool Partition Wizard).
;
; [4] "Every BIOS since the mid-90's supports the extensions[.] ... "There
; exist some 486 systems that do not support LBA in any way.  All known Pentium
; systems support Extended LBA in the BIOS."
; http://wiki.osdev.org/ATA_in_x86_RealMode_(BIOS)
;


        bits 16


;
; Memory layout:
;   0x600..0x7ff                MBR
;   0x800..0xbff                CRC-32C table
;   ...
;   0x????..0x7bff              stack
;   0x7c00..0x7dff              executing VBR
;   0x7e00..0x7fff              uninitialized variables
;   0x8000..0x81ff              sector read buffer
;   0x8200..0x83ff              relocated stage1 load-loop
;   ...
;   0x9000..0x????              stage1
;
; This VBR does not initialize CS, and therefore, the stage1 binary must
; be loaded *above* the 0x7c00 entry point.  (i.e. If the VBR is running at
; 0x7c0:0, then we cannot jump before 0x7c00, but we can reach 0x7c0:0x400.)
;

mbr:                            equ 0x600
crc32c_table:                   equ 0x800
vbr:                            equ 0x7c00
stack:                          equ 0x7c00
sector_buffer:                  equ 0x8000
stage1_load_loop:               equ 0x8200
stage1:                         equ 0x9000
stage1_sector_count:            equ 28


;
; Global variables.
;
; For code size effiency, globals are accessed throughout the program using an
; offset from the BP register.
;

disk_number:            equ disk_number_storage         - bp_address
no_match_yet:           equ no_match_yet_storage        - bp_address
match_lba:              equ match_lba_storage           - bp_address
read_sector_lba:        equ read_sector_lba_storage     - bp_address
error_char:             equ 'A'


%include "shared_macros.asm"


        section .boot_record

        global main
main:
bp_address:             equ main + 0x200 - 120
        ;
        ; Prologue.  Skip FAT32 boot parameters, setup registers.
        ;
        ;  * According to Intel docs (286, 386, and contemporary), moving into
        ;    SS masks interrupts until after the next instruction executes.
        ;    Hence, this code avoids clearing interrupts.  (Saves one byte.)
        ;
        ;  * The CS register is not initialized.  It's possible that this code
        ;    is running at 0x7c0:0 rather than 0:0x7c00.  The VBR can only use
        ;    relative jumps and calls.
        ;

        jmp short .skip_fat32_params
        nop


        ;
        ; Two FAT32 fields that give the location of the FSInfo and backup VBR
        ; sectors.  These two sectors live (typically? or always?) in the
        ; reserved area.  We must skip over them when reading (or installing)
        ; stage1.
        ;
        times 48-($-main) db 0
.fsinfo_sector:         dw 0            ; Relative sector # of FSInfo sector
.backup_vbr_sector:     dw 0            ; Relative sector # of backup VBR


        times 90-($-main) db 0
.skip_fat32_params:
        xor ax, ax
        mov ss, ax
        mov sp, stack
        mov ds, ax                      ; Clear DS
        mov es, ax                      ; Clear ES
        sti

        ; Use BP to access global variables with smaller memory operands.
        mov bp, bp_address

        init_disk_number

        ; Load the MBR and copy it out of the way.
        xor esi, esi
        call read_sector
        jc short .skip_primary_scan_loop
        mov si, sector_buffer
        mov di, mbr
        mov cx, 512
        cld
        rep movsb

        mov bx, mbr + 446

.primary_scan_loop:
        xor esi, esi
        call scan_pcboot_vbr_partition
        call scan_extended_partition
        add bx, 0x10
        cmp bx, mbr + 510
        jne short .primary_scan_loop

.skip_primary_scan_loop:
        ; If we didn't find a match, fail at this point.
        cmp byte [bp + no_match_yet], 0
        push word missing_vbr_error     ; Push error code. (No return.)
        jne near fail

        ;
        ; Load the post-VBR boot sector.
        ;
        mov esi, [bp + match_lba]

        ;
        ; An "add esi, 0xNN" instruction.  The 0xNN is a one-byte field giving
        ; the sector index of the post-VBR sector.  It is necessary because the
        ; reserved area also contains FSInfo and backup-VBR sectors.
        ;
        db 0x66, 0x83, 0xc6
.post_VBR_sector:
        db 0x7f
.continue_loading:

        call read_sector

        ;
        ; Verify that the next sector ends with a marker.
        ;
        ; Perhaps a partitioning tool could fail to preserve the reserved
        ; area's contents.
        ;
        push word missing_post_vbr_marker_error         ; Push error code. (No return.)
        cmp dword [sector_buffer + 512 - 4], post_VBR_sector_marker
        jne short fail
        jmp sector_buffer




%include "shared_items.asm"


        ; Ensure that the self-modifying code in read_sector uses a single-byte
        ; memory operand.
        static_assert_in_i8_range bp_address, fail.read_error_flag




;
; Statically-initialized data area.
;
no_match_yet_storage:           db 1
disk_number_storage:            db 0x80

        static_assert_in_i8_range bp_address, no_match_yet_storage
        static_assert_in_i8_range bp_address, disk_number_storage

vbr_code_end:




        times 512 - (10 + 2 + 4 + 2) - ($ - main) db 0

; Save code space by combining the pcboot marker and error message.
pcboot_error:
pcboot_vbr_marker:
        db "pcboot err"                 ; Error text and part of marker
pcboot_error_char:
        db 0, 0                         ; Error code and NUL terminator
        db 0x8f, 0x70, 0x92, 0x77       ; Default marker ID number
        dw 0xaa55                       ; PC bootable sector marker
pcboot_vbr_marker_size: equ ($ - pcboot_vbr_marker)




;
; Uninitialized data area.
;
; Variables here are not initialized at load-time.  They are still defined
; using initialized data directives, because nasm insists on having initialized
; data in a non-bss section.
;

match_lba_storage:              dd 0
read_sector_lba_storage:        dd 0

        static_assert_in_i8_range bp_address, match_lba_storage
        static_assert_in_i8_range bp_address, read_sector_lba_storage




;
; stage1 prep code area
;
; This post-VBR code is loaded by the VBR.  It reuses the code in the VBR to
; load stage1.  As with the MBR code, this sector must be relocated first to
; avoid being trampled by the next sector read.
;

        times (stage1_load_loop-vbr)-($-main) db 0

stage1_load_loop_entry:
        mov di, stage1_load_loop
        mov si, sector_buffer
        mov cx, 512
        cld
        rep movsb
        jmp 0:.relocated                ; Ensure CS is zero.

.relocated:
        ;
        ; Load stage1.
        ;
        push word read_error            ; Push error code. (No return.)
        mov di, stage1
        mov eax, 1
        mov bx, stage1_sector_count
.read_loop:
        ; Check whether this sector index is reserved for something.
        cmp ax, word [main.fsinfo_sector]
        je .next_sector
        cmp ax, word [main.backup_vbr_sector]
        je .next_sector
        cmp al, byte [main.post_VBR_sector]
        je .next_sector

        ; Read the next sector and move it into place.
        mov esi, [bp + match_lba]

        add esi, eax
        call read_sector
        jc near fail
        mov cx, 512
        mov si, sector_buffer
        cld
        rep movsb

        ; Finish once we've read all the sectors.
        dec bx
        jz short .read_done

.next_sector:
        ; Advance to the next sector.
        inc ax
        jmp .read_loop

.read_done:
        ; Check the checksum.
        mov si, stage1
        mov cx, stage1_sector_count * 512 - 4
        call crc32c
        mov edx, [stage1 + stage1_sector_count * 512 - 4]
        cmp eax, edx
        push bad_stage1_checksum_error
        jne fail

        ;
        ; Jump to stage1.
        ;  - dl is the BIOS disk number.
        ;  - esi points to the starting LBA of the boot volume.
        ;
        mov dl, byte [bp + disk_number]
        mov esi, [bp + match_lba]
        jmp stage1


%include "crc32c.asm"


        ;
        ; pcboot post-VBR sector marker
        ;
        ; Use a marker that cannot collide with the FSInfo and backup VBR
        ; sectors, which also inhabit the reserved area.
        ;
        post_VBR_sector_marker:                 dd 0xcc99cc99
        times 508-($-stage1_load_loop_entry) db 0
        dd post_VBR_sector_marker
