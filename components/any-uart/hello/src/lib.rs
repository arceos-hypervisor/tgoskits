#![no_std]
#![no_main]

use core::{
    arch::naked_asm,
    ptr::{NonNull, slice_from_raw_parts_mut},
};

use aarch64_cpu::{asm::barrier, registers::*};
use any_uart::Uart;
use fdt_parser::Fdt;
use smccc::{Hvc, Smc, psci};

const FLAG_LE: usize = 0b0;
const FLAG_PAGE_SIZE_4K: usize = 0b10;
const FLAG_ANY_MEM: usize = 0b1000;

#[unsafe(naked)]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".text.head")]
/// The entry point of the kernel.
unsafe extern "C" fn _start() -> ! {
    naked_asm!(
        // code0/code1
        "nop",
        "bl {entry}",
        // text_offset
        ".quad 0",
        // image_size
        ".quad _kernel_size",
        // flags
        ".quad {flags}",
        // Reserved fields
        ".quad 0",
        ".quad 0",
        ".quad 0",
        // magic - yes 0x644d5241 is the same as ASCII string "ARM\x64"
        ".ascii \"ARM\\x64\"",
        // Another reserved field at the end of the header
        ".byte 0, 0, 0, 0",
        flags = const FLAG_LE | FLAG_PAGE_SIZE_4K | FLAG_ANY_MEM,
        entry = sym primary_entry,
    )
}

#[unsafe(naked)]
#[unsafe(link_section = ".text.boot")]
/// The entry point of the kernel.
unsafe extern "C" fn primary_entry() -> ! {
    naked_asm!(
        "ADR      x11, .",
        "LDR      x10, ={this_func}",
        "SUB      x18, x10, x11", // x18 = va_offset
        "MOV      x19, x0",        // x19 = dtb_addr

        // setup stack
        "LDR      x1,  =_stack_top",
        "SUB      x1,  x1, x18", // X1 == STACK_TOP
        "MOV      sp,  x1",


        "MOV      x0,  x18",
        "MOV      x1,  x19",
        "BL       {entry}",
        this_func = sym primary_entry,
        entry = sym rust_entry,
    )
}

fn phys_to_virt(addr: usize) -> *mut u8 {
    addr as _
}

fn rust_entry(_text_va: usize, fdt: *mut u8) -> ! {
    clean_bss();
    enable_fp();

    if let Some(mut uart) = any_uart::init(NonNull::new(fdt).unwrap(), phys_to_virt) {
        let mut tx = uart.tx.take().unwrap();
        let _ = tx.write_str_blocking("Hello, world!\n");

        let f = Fdt::from_ptr(NonNull::new(fdt).unwrap()).unwrap();
        let n = f.chosen().unwrap();
        let node = n.debugcon().unwrap();
        let mut u = Uart::new_by_fdt_node(&node, phys_to_virt).unwrap();
        let _ = tx.write_str_blocking("found\n");

        u.tx.take()
            .unwrap()
            .write_str_blocking("Hello, world!\n")
            .unwrap();

        let _ = tx.write_str_blocking("All tests passed!\n");
    }

    shutdown(fdt);
    unreachable!()
}

fn shutdown(fdt: *mut u8) -> Option<()> {
    let fdt = Fdt::from_ptr(NonNull::new(fdt).unwrap()).ok()?;

    let cp = ["arm,psci-1.0", "arm,psci-0.2", "arm,psci"];

    let mut node = None;

    for one in fdt.all_nodes() {
        for c in one.compatibles() {
            for c2 in cp {
                if c == c2 {
                    node = Some(one.clone());
                    break;
                }
            }
        }
    }

    let node = node?;

    let method = node.find_property("method")?.str();

    if method.eq("smc") {
        let _ = psci::system_off::<Smc>();
    } else if method.eq("hvc") {
        let _ = psci::system_off::<Hvc>();
    }

    Some(())
}

#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

fn clean_bss() {
    unsafe extern "C" {
        fn _sbss();
        fn _ebss();
    }

    let start = _sbss as *const u8 as usize;
    let end = _ebss as *const u8 as usize;
    let bss = unsafe { &mut *slice_from_raw_parts_mut(start as *mut u8, end - start) };
    bss.fill(0);
}

fn enable_fp() {
    CPACR_EL1.write(CPACR_EL1::FPEN::TrapNothing);
    barrier::isb(barrier::SY);
}
