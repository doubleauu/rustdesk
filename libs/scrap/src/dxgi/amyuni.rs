use std::mem;
use winapi::{
    shared::{devpkey::DEVPKEY_Device_InstanceId, devpropdef::DEVPROP_TYPE_STRING, ntdef::WCHAR},
    um::{
        cfgmgr32::{
            CM_Get_DevNode_Registry_PropertyW, CM_Get_Device_Interface_PropertyW, CM_Get_Parent,
            CM_Locate_DevNodeW, CM_DRP_HARDWAREID, CR_SUCCESS, MAX_DEVICE_ID_LEN,
        },
        wingdi::{DISPLAY_DEVICEW, DISPLAY_DEVICE_ACTIVE},
        winnt::REG_MULTI_SZ,
        winuser::{EnumDisplayDevicesW, EDD_GET_DEVICE_INTERFACE_NAME},
    },
};

pub(super) fn has_monitor(display_name: &[WCHAR; 32]) -> bool {
    // A clone of an Amyuni monitor can be exposed under the physical adapter's
    // GDI name. The monitor's PnP parent still identifies the actual driver.
    unsafe {
        for index in 0.. {
            let mut monitor: DISPLAY_DEVICEW = mem::zeroed();
            monitor.cb = mem::size_of_val(&monitor) as _;
            if EnumDisplayDevicesW(
                display_name.as_ptr(),
                index,
                &mut monitor,
                EDD_GET_DEVICE_INTERFACE_NAME,
            ) == 0
            {
                break;
            }
            if monitor.StateFlags & DISPLAY_DEVICE_ACTIVE != 0
                && is_amyuni_monitor(&monitor.DeviceID)
            {
                return true;
            }
        }
    }
    false
}

unsafe fn is_amyuni_monitor(interface: &[WCHAR; 128]) -> bool {
    let mut instance_id = [0u16; MAX_DEVICE_ID_LEN];
    let mut property_type = 0;
    let mut size = mem::size_of_val(&instance_id) as _;
    if CM_Get_Device_Interface_PropertyW(
        interface.as_ptr(),
        &DEVPKEY_Device_InstanceId,
        &mut property_type,
        instance_id.as_mut_ptr().cast(),
        &mut size,
        0,
    ) != CR_SUCCESS
        || property_type != DEVPROP_TYPE_STRING
    {
        return false;
    }

    let mut monitor = 0;
    let mut parent = 0;
    if CM_Locate_DevNodeW(&mut monitor, instance_id.as_mut_ptr(), 0) != CR_SUCCESS
        || CM_Get_Parent(&mut parent, monitor, 0) != CR_SUCCESS
    {
        return false;
    }

    let mut hardware_ids = [0u16; 512];
    let mut size = mem::size_of_val(&hardware_ids) as _;
    CM_Get_DevNode_Registry_PropertyW(
        parent,
        CM_DRP_HARDWAREID,
        &mut property_type,
        hardware_ids.as_mut_ptr().cast(),
        &mut size,
        0,
    ) == CR_SUCCESS
        && property_type == REG_MULTI_SZ
        && has_amyuni_hardware_id(&hardware_ids)
}

fn has_amyuni_hardware_id(hardware_ids: &[WCHAR]) -> bool {
    hardware_ids
        .split(|&c| c == 0)
        .take_while(|id| !id.is_empty())
        .any(|id| String::from_utf16_lossy(id).eq_ignore_ascii_case("usbmmidd"))
}

#[cfg(test)]
mod tests {
    use super::has_amyuni_hardware_id;

    #[test]
    fn recognizes_only_the_amyuni_hardware_id() {
        let hardware_ids = |ids: &str| ids.encode_utf16().collect::<Vec<_>>();
        assert!(has_amyuni_hardware_id(&hardware_ids("other\0USBMMIDD\0\0")));
        assert!(!has_amyuni_hardware_id(&hardware_ids("usbmmidd2\0\0")));
    }
}
