use cfg_if::cfg_if;

use crate::{Console, ErrorKind, IoKind, IrqEvent, UartData};

pub struct Ns16550 {}

impl Ns16550 {
    fn sts(uart: UartData) -> u32 {
        Self::read(uart, 5)
    }

    fn write(uart: UartData, reg: usize, val: u32) {
        unsafe {
            match uart.io_kind {
                IoKind::Port => {
                    cfg_if! {
                        if #[cfg(target_arch = "x86_64")] {
                            x86_64::instructions::port::Port::<u8>::new((uart.base + reg) as _)  .write(val as _);
                        } else {
                            todo!();
                        }
                    }
                }
                IoKind::Mmio16 => {
                    uart.reg::<u16>(reg).write_volatile(val as _);
                }
                IoKind::Mmio32 | IoKind::Mmio => {
                    uart.reg::<u32>(reg).write_volatile(val);
                }
                IoKind::Mmio32be => {
                    uart.reg::<u32>(reg).write_volatile(val.to_be());
                }
            }
        }
    }

    fn read(uart: UartData, reg: usize) -> u32 {
        unsafe {
            match uart.io_kind {
                IoKind::Port => {
                    cfg_if! {
                        if #[cfg(target_arch = "x86_64")] {
                            x86_64::instructions::port::Port::<u8>::new((uart.base + reg) as _)
                                .read() as u32
                        } else {
                            todo!();
                        }
                    }
                }
                IoKind::Mmio16 => uart.reg::<u16>(reg).read_volatile() as _,
                IoKind::Mmio32 | IoKind::Mmio => uart.reg::<u32>(reg).read_volatile(),
                IoKind::Mmio32be => {
                    let reg = uart.reg::<u32>(reg);
                    let val = reg.read_volatile();
                    u32::from_be(val)
                }
            }
        }
    }
}

impl Console for Ns16550 {
    fn put(uart: UartData, c: u8) -> Result<(), ErrorKind> {
        Self::write(uart, 0, c as _);
        Ok(())
    }

    fn get(uart: UartData) -> Result<u8, ErrorKind> {
        Ok(Self::read(uart, 0) as _)
    }

    fn set_irq_enable(uart: UartData, enable: bool) {
        let val = if enable { 1 | 1 << 1 } else { 0 };

        Self::write(uart, 1, val);
    }

    fn get_irq_enable(uart: UartData) -> bool {
        Self::read(uart, 1) != 0
    }

    fn clean_irq_event(_uart: UartData, _event: IrqEvent) {}

    fn can_put(uart: UartData) -> bool {
        // Xmitter empty
        const LSR_TEMT: u32 = 1 << 6;
        Self::sts(uart) & LSR_TEMT != 0
    }

    fn can_get(uart: UartData) -> bool {
        const LSR_DR: u32 = 1;

        Self::sts(uart) & LSR_DR != 0
    }

    fn get_irq_event(uart: UartData) -> IrqEvent {
        let sts = Self::read(uart, 2);
        let mut event = IrqEvent::default();

        if sts & 1 != 0 {
            event.rx = true;
        }

        if sts & 1 << 1 != 0 {
            event.tx = true;
        }

        event
    }

    fn open(_uart: UartData) {}
}
