# Any Uart

[![Check, Build and Test](https://github.com/rcore-os/dtb-earyly-console/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/rcore-os/dtb-earyly-console/actions/workflows/ci.yml)

A easy way to use early console in ARM.

Get the debug uart address from dtb, and some uart driver are supported.

## supported uart

* 8250 and 16550
* pl011
* aux_mini (raspi 4b)

## example

```rust
use core::ptr::NonNull;

// your dtb address
let dtb_addr = 0usize as *mut u8

fn phys_to_virt(addr: usize) -> *mut u8 { 
    // phys addr to virt addr logic
    addr as *mut u8
}

if let Some(mut uart) = any_uart::init(NonNull::new(dtb_addr).unwrap(), phys_to_virt) {
    let mut tx = uart.tx.take().unwrap();
    let _ = tx.write_str_blocking("Hello, world!\n");
}
```

## test

```shell
cargo install ostool
# test with qemu
cargo test -p hello --test test -- --show-output
# test with uboot
cargo test --release -p hello --test test -- --show-output --uboot
```
