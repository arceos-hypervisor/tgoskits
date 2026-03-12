#![cfg_attr(not(test), no_std)]

use core::{
    ptr::NonNull,
    sync::atomic::{Ordering, fence},
};

#[cfg(feature = "alloc")]
extern crate alloc;

#[cfg(feature = "alloc")]
mod api;

pub use core::fmt::Write;
pub use embedded_hal_nb::nb::block;
pub use embedded_hal_nb::serial::ErrorKind;

use aux_mini::AuxMini;
pub use fdt_parser::Node;
use fdt_parser::{Chosen, Fdt};
use ns16550::Ns16550;
use pl011::Pl011;

mod aux_mini;
mod ns16550;
mod pl011;

pub type Error = embedded_hal_nb::nb::Error<ErrorKind>;
pub type FnPhysToVirt = fn(usize) -> *mut u8;

pub struct Uart {
    data: UartData,
    pub tx: Option<Sender>,
    pub rx: Option<Receiver>,
    op: UartOp,
}

impl Uart {
    fn _new<C: Console>(data: UartData) -> Self {
        let op = C::to_op();
        C::open(data);

        Self {
            data,
            tx: Some(Sender { uart: data, op }),
            rx: Some(Receiver { uart: data, op }),
            op,
        }
    }

    pub fn new_port_8250(base: usize) -> Self {
        let data = UartData::new(base as _, IoKind::Port, |p| p as _);
        Self::_new::<Ns16550>(data)
    }

    pub fn mmio_base_add(&mut self, offset: usize) {
        self.data.base += offset;
    }

    pub fn new_by_fdt_node(node: &Node<'_>, f: FnPhysToVirt) -> Option<Self> {
        let reg = node.reg()?.next()?;

        let io_kind = IoKind::Mmio32;

        // TODO: support io kind detect

        let uart = UartData::new(reg.address, io_kind, f);

        for c in node.compatibles() {
            macro_rules! of_uart {
                ($name:ty, $compatible:expr) => {
                    for want in $compatible {
                        if c.contains(want) {
                            return Some(Uart::_new::<$name>(uart));
                        }
                    }
                };
            }

            of_uart!(AuxMini, ["brcm,bcm2835-aux-uart"]);
            of_uart!(Pl011, ["arm,pl011", "arm,primecell"]);
            of_uart!(Ns16550, ["snps,dw-apb-uart"]);
        }
        None
    }

    pub fn set_irq_enable(&mut self, enable: bool) {
        (self.op.set_irq_enable)(self.data, enable);
    }

    pub fn get_irq_enable(&mut self) -> bool {
        (self.op.get_irq_enable)(self.data)
    }

    pub fn clean_irq_event(&mut self, event: IrqEvent) {
        (self.op.clean_irq_event)(self.data, event);
    }

    pub fn get_irq_event(&mut self) -> IrqEvent {
        (self.op.get_irq_event)(self.data)
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct IrqEvent {
    pub rx: bool,
    pub tx: bool,
}

#[derive(Clone, Copy)]
struct UartOp {
    can_put: fn(UartData) -> bool,
    put: fn(UartData, u8) -> Result<(), ErrorKind>,
    can_get: fn(UartData) -> bool,
    get: fn(UartData) -> Result<u8, ErrorKind>,
    set_irq_enable: fn(UartData, bool),
    get_irq_enable: fn(UartData) -> bool,
    get_irq_event: fn(UartData) -> IrqEvent,
    clean_irq_event: fn(UartData, IrqEvent),
}

pub struct Sender {
    uart: UartData,
    op: UartOp,
}

impl Sender {
    pub fn write(&mut self, word: u8) -> Result<(), Error> {
        if !self.can_write() {
            return Err(Error::WouldBlock);
        }
        fence(Ordering::Release);
        unsafe { self.write_uncheck(word)? };
        Ok(())
    }

    pub fn mmio_base_add(&mut self, offset: usize) {
        self.uart.base += offset;
    }

    pub fn can_write(&self) -> bool {
        (self.op.can_put)(self.uart)
    }

    /// Write a byte to the UART.
    ///
    /// # Safety
    ///
    /// Need to check the UART status register before writing.
    pub unsafe fn write_uncheck(&mut self, word: u8) -> Result<(), ErrorKind> {
        (self.op.put)(self.uart, word)
    }

    pub fn write_str_blocking(&mut self, s: &str) -> core::fmt::Result {
        for c in s.bytes() {
            let _ = block!(self.write(c));
        }
        Ok(())
    }

    pub fn mmio(&self) -> usize {
        self.uart.base
    }
}

pub struct Receiver {
    uart: UartData,
    op: UartOp,
}

impl Receiver {
    pub fn read(&mut self) -> Result<u8, Error> {
        if !self.can_read() {
            return Err(Error::WouldBlock);
        }
        fence(Ordering::Release);
        let byte = unsafe { self.read_uncheck()? };
        Ok(byte)
    }

    pub fn can_read(&self) -> bool {
        (self.op.can_get)(self.uart)
    }

    pub fn mmio_base_add(&mut self, offset: usize) {
        self.uart.base += offset;
    }

    /// Read a byte from the UART.
    ///
    /// # Safety
    ///
    /// Need to check the UART status register before reading.
    pub unsafe fn read_uncheck(&mut self) -> Result<u8, ErrorKind> {
        (self.op.get)(self.uart)
    }
}

pub(crate) trait Console {
    fn open(uart: UartData);
    fn can_put(uart: UartData) -> bool;
    fn put(uart: UartData, c: u8) -> Result<(), ErrorKind>;
    fn can_get(uart: UartData) -> bool;
    fn get(uart: UartData) -> Result<u8, ErrorKind>;
    fn set_irq_enable(uart: UartData, enable: bool);
    fn get_irq_enable(uart: UartData) -> bool;
    fn get_irq_event(uart: UartData) -> IrqEvent;
    fn clean_irq_event(uart: UartData, event: IrqEvent);

    fn to_op() -> UartOp {
        UartOp {
            can_put: Self::can_put,
            put: Self::put,
            can_get: Self::can_get,
            get: Self::get,
            set_irq_enable: Self::set_irq_enable,
            get_irq_enable: Self::get_irq_enable,
            get_irq_event: Self::get_irq_event,
            clean_irq_event: Self::clean_irq_event,
        }
    }
}

#[derive(Clone, Copy)]
pub(crate) struct UartData {
    pub base: usize,
    pub io_kind: IoKind,
}

impl UartData {
    fn new(base: u64, io_kind: IoKind, f: FnPhysToVirt) -> Self {
        let mmio = f(base as _);

        Self {
            base: mmio as _,
            io_kind,
        }
    }

    pub fn reg_u8(&self, offset: usize) -> *mut u8 {
        self.reg(offset)
    }

    pub fn reg<T: Sized>(&self, offset: usize) -> *mut T {
        unsafe {
            let ptr = self.base as *mut T;
            ptr.add(offset)
        }
    }
}

pub fn init(fdt_addr: NonNull<u8>, fn_phys_to_virt: FnPhysToVirt) -> Option<Uart> {
    let fdt = Fdt::from_ptr(fdt_addr).ok()?;

    let chosen = fdt.chosen()?;

    let mut io_kind = IoKind::Mmio32;
    let node;
    let mut is_8250 = false;

    match chosen.stdout() {
        Some(n) => node = n.node,
        None => {
            let (n, io) = fdt_bootargs_find_node(&chosen, &fdt)?;
            node = n;
            io_kind = io;
            is_8250 = true;
        }
    };

    let reg = node.reg()?.next()?;

    let uart = UartData::new(reg.address, io_kind, fn_phys_to_virt);

    if is_8250 {
        return Some(Uart::_new::<Ns16550>(uart));
    } else {
        for c in node.compatibles() {
            macro_rules! of_uart {
                ($name:ty, $compatible:expr) => {
                    for want in $compatible {
                        if c.contains(want) {
                            return Some(Uart::_new::<$name>(uart));
                        }
                    }
                };
            }

            of_uart!(AuxMini, ["brcm,bcm2835-aux-uart"]);
            of_uart!(Pl011, ["arm,pl011", "arm,primecell"]);
            of_uart!(Ns16550, ["snps,dw-apb-uart"]);
        }
    }

    None
}

#[derive(Clone, Copy)]
pub enum IoKind {
    Port,
    Mmio,
    Mmio16,
    Mmio32,
    Mmio32be,
}

impl IoKind {
    pub fn width(&self) -> usize {
        match self {
            IoKind::Port => 1,
            IoKind::Mmio => 4,
            IoKind::Mmio16 => 2,
            IoKind::Mmio32 => 4,
            IoKind::Mmio32be => 4,
        }
    }
}

impl From<&str> for IoKind {
    fn from(value: &str) -> Self {
        match value {
            "mmio" => IoKind::Mmio,
            "mmio16" => IoKind::Mmio16,
            "mmio32" => IoKind::Mmio32,
            "mmio32be" => IoKind::Mmio32be,
            "mmio32native" => {
                if cfg!(target_endian = "little") {
                    IoKind::Mmio32
                } else {
                    IoKind::Mmio32be
                }
            }
            _ => IoKind::Port,
        }
    }
}

fn fdt_bootargs_find_node<'a>(chosen: &Chosen<'a>, fdt: &'a Fdt<'a>) -> Option<(Node<'a>, IoKind)> {
    let bootargs = chosen.bootargs()?;

    let earlycon = bootargs
        .split_ascii_whitespace()
        .find(|&arg| arg.contains("earlycon"))?;

    let mut tmp = earlycon.split('=');
    let _ = tmp.next()?;
    let values = tmp.next()?;

    let mut values = values.split(',');

    let name = values.next()?;

    if !name.contains("uart") {
        return None;
    }

    let param2 = values.next()?;
    let addr_str;
    let io_kind = if param2.contains("0x") {
        addr_str = param2;
        IoKind::Mmio
    } else {
        addr_str = values.next()?;
        IoKind::from(param2)
    };

    let mmio = u64::from_str_radix(addr_str.trim_start_matches("0x"), 16).ok()?;

    for node in fdt.all_nodes() {
        if let Some(regs) = node.reg() {
            for reg in regs {
                if reg.address.eq(&mmio) {
                    return Some((node, io_kind));
                }
            }
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_uart_init() {
        let fdt = include_bytes!("../../dtb/rk3568-firefly-roc-pc-se.dtb");
        let fdt_addr = NonNull::new(fdt.as_ptr() as usize as _).unwrap();
        let _ = init(fdt_addr, |r| r as _).unwrap();
    }
}
