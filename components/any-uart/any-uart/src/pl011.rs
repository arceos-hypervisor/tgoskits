use bitflags::bitflags;

use crate::{Console, ErrorKind, IrqEvent, UartData};

bitflags! {
    struct Interrupts: u32 {
        /// Overrun error interrupt.
        const OEI = 1 << 10;
        /// Break error interrupt.
        const BEI = 1 << 9;
        /// Parity error interrupt.
        const PEI = 1 << 8;
        /// Framing error interrupt.
        const FEI = 1 << 7;
        /// Receive timeout interrupt.
        const RTI = 1 << 6;
        /// Transmit interrupt.
        const TXI = 1 << 5;
        /// Receive interrupt.
        const RXI = 1 << 4;
        /// nUARTDSR modem interrupt.
        const DSRMI = 1 << 3;
        /// nUARTDCD modem interrupt.
        const DCDMI = 1 << 2;
        /// nUARTCTS modem interrupt.
        const CTSMI = 1 << 1;
        /// nUARTRI modem interrupt.
        const RIMI = 1 << 0;
    }
}

const UARTCR: usize = 0x030 / 4;
const IMSC: usize = 0x038 / 4;
const RIS: usize = 0x03C / 4;
const MIS: usize = 0x040 / 4;
const ICR: usize = 0x044 / 4;

pub struct Pl011 {}

impl Console for Pl011 {
    fn put(uart: UartData, byte: u8) -> Result<(), ErrorKind> {
        unsafe {
            let put = uart.reg_u8(0);
            put.write_volatile(byte);
            Ok(())
        }
    }

    fn get(uart: UartData) -> Result<u8, ErrorKind> {
        unsafe {
            let data = uart.reg::<u32>(0).read_volatile();

            if data & 0xFFFFFF00 != 0 {
                // Clear the error
                uart.reg::<u32>(1).write_volatile(0xFFFFFFFF);
                return Err(ErrorKind::Other);
            }

            Ok(data as _)
        }
    }

    fn set_irq_enable(uart: UartData, enable: bool) {
        unsafe {
            let imsc = uart.reg::<u32>(IMSC);
            if enable {
                imsc.write_volatile((Interrupts::RXI | Interrupts::TXI).bits());
            } else {
                imsc.write_volatile(0);
            }
        }
    }

    fn get_irq_enable(uart: UartData) -> bool {
        unsafe {
            let imsc = uart.reg::<u32>(IMSC);
            imsc.read_volatile() != 0
        }
    }

    fn clean_irq_event(uart: UartData, event: IrqEvent) {
        let mut irqs = Interrupts::empty();
        if event.rx {
            irqs |= Interrupts::RXI
        }

        if event.tx {
            irqs |= Interrupts::TXI
        }

        unsafe {
            let icr = uart.reg::<u32>(ICR);
            icr.write_volatile(irqs.bits());
        }
    }

    fn can_put(uart: UartData) -> bool {
        const TXFF: u8 = 1 << 5;
        unsafe { uart.reg_u8(0x18).read_volatile() & TXFF == 0 }
    }

    fn can_get(uart: UartData) -> bool {
        const RXFE: u8 = 0x10;
        unsafe { uart.reg_u8(0x18).read_volatile() & RXFE == 0 }
    }

    fn get_irq_event(uart: UartData) -> IrqEvent {
        let mut event = IrqEvent::default();

        unsafe {
            let ris = uart.reg::<u32>(RIS).read_volatile();
            let mis = uart.reg::<u32>(MIS).read_volatile();

            let sts = Interrupts::from_bits_retain(ris & mis);

            if sts.contains(Interrupts::RXI) {
                event.rx = true;
            }

            if sts.contains(Interrupts::TXI) {
                event.tx = true;
            }
        }
        event
    }

    fn open(uart: UartData) {
        unsafe {
            // 启用 UART，设置 TXE (bit 8) 和 UARTEN (bit 0)
            let cr = uart.reg::<u32>(UARTCR);
            let current_value = cr.read_volatile();
            // TXE = bit 8, UARTEN = bit 0
            cr.write_volatile(current_value | (1 << 8) | (1 << 0));
        }
    }
}
