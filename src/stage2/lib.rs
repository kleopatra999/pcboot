#![crate_name = "stage2"]
#![crate_type = "staticlib"]
#![feature(lang_items)]
#![feature(no_std)]
#![feature(core)]
#![no_std]

#[macro_use] extern crate core;
extern crate sys;

// Define a dummy std module that contains libcore's fmt module.  The std::fmt
// module is needed to satisfy the std::fmt::Arguments reference created by the
// format_args! and format_args_method! built-in macros used in lowlevel.rs's
// failure handling.
mod std {
    pub use core::fmt;
}

#[lang = "panic_fmt"] #[cold] #[inline(never)]
extern fn rust_panic_fmt(_msg: std::fmt::Arguments, file: &'static str, line: usize) -> ! {
    // TODO: Replace this with a full argument-printing panic function.
    sys::simple_panic(file, line as u32, "rust_panic_fmt", "")
}

#[no_mangle]
pub extern "C" fn pcboot_main(disk_number: u8, volume_lba: u32) -> ! {
    sys::print_str("pcboot stage2 loading...\r\n");
    sys::halt();
}
