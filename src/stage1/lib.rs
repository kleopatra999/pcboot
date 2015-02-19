#![crate_name = "stage1"]
#![crate_type = "rlib"]
#![feature(lang_items)]
#![feature(no_std)]
#![feature(core)]
#![no_std]

extern crate core;
use core::prelude::*;

#[path = "../shared/macros.rs"] #[macro_use]
mod macros;

// Define a dummy std module that contains libcore's fmt module.  The std::fmt
// module is needed to satisfy the std::fmt::Arguments reference created by the
// format_args! and format_args_method! built-in macros used in lowlevel.rs's
// failure handling.
mod std {
    pub use core::fmt;
}

#[path = "../shared/io.rs"]             mod io;
#[path = "../shared/lowlevel.rs"]       mod lowlevel;
#[path = "../shared/num_to_str.rs"]     mod num_to_str;

mod crc32c;
mod fat32;

const STAGE2_SIZE: usize = 0x73000;

extern {
    static mut _stage2: [u8; STAGE2_SIZE];
    static mut _stage2_end: [u8; 0];
}

#[no_mangle]
pub extern "C" fn pcboot_main(disk_number: u8, volume_lba: u32) -> ! {
    io::print_str("pcboot loading...\r\n");

    unsafe {
        // Ideally, this check would be done at compile-time, but I do not know
        // whether that is possible.
        let linker_size =
            _stage2_end.as_ptr() as usize - _stage2.as_ptr() as usize;
        assert!(linker_size == STAGE2_SIZE);
    }

    let disk = io::open_disk(disk_number).unwrap();
    let volume = fat32::open_volume(&disk, volume_lba as io::SectorIndex);

    unsafe {
        let file_size = fat32::read_file_reusing_buffer_in_find(&volume, "STAGE2  BIN", &mut _stage2);
        let checksum_offset = (file_size - 4) as usize;
        let expected_checksum = io::get32(&_stage2, checksum_offset);
        let actual_checksum = crc32c::compute(&crc32c::table(), &_stage2[..checksum_offset]);

        io::print_str("read ");
        io::print_u32(file_size);
        io::print_str(" bytes (crc32c:");
        io::print_u32(actual_checksum);
        io::print_str(")\r\n");

        if expected_checksum != actual_checksum {
            io::print_str("pcboot error: bad checksum on stage2.bin!");
            lowlevel::halt();
        }
    }

    extern "C" {
        fn call_real_mode(callee: unsafe extern "C" fn(), ...) -> u64;
        fn transfer_to_stage2();
    }

    unsafe { call_real_mode(transfer_to_stage2, disk_number as u32, volume_lba); }
    lowlevel::halt();
}
