use crate::{Console, ErrorKind, IrqEvent, UartData};

pub struct AuxMini {}

impl Console for AuxMini {
    fn put(uart: UartData, byte: u8) -> Result<(), ErrorKind> {
        unsafe {
            let data = uart.reg::<u32>(0);
            data.write_volatile(byte as _);
            Ok(())
        }
    }

    fn get(uart: UartData) -> Result<u8, ErrorKind> {
        unsafe {
            let data = uart.reg::<u32>(0);

            Ok(data.read_volatile() as _)
        }
    }

    fn set_irq_enable(_uart: UartData, _enable: bool) {}

    fn get_irq_enable(_uart: UartData) -> bool {
        todo!()
    }

    fn clean_irq_event(_uart: UartData, _event: IrqEvent) {}

    fn can_put(uart: UartData) -> bool {
        const TXFF: u32 = 1 << 5;
        let state = uart.reg_u8(0x24) as *const u32;
        unsafe { state.read_volatile() & TXFF == 0 }
    }

    fn can_get(uart: UartData) -> bool {
        const RX_READY: u32 = 1 << 0;
        let state = uart.reg_u8(0x24) as *const u32;
        unsafe { state.read_volatile() & RX_READY != 0 }
    }

    fn get_irq_event(_uart: UartData) -> IrqEvent {
        todo!()
    }

    fn open(_uart: UartData) {}
}
