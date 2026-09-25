# The PlugSense protocol (v1)

How a Mac decides, for each port, what a plugged-in device is doing: powering the Mac, drawing
power from it, moving data, driving a display, or several at once.

The protocol is a pure function, `Classifier.classify(Snapshot) → [PortVerdict]`. Everything it
knows comes from one snapshot of the I/O Registry and IOPowerSources (`Probe.swift`), which needs
no privileges and no TCC grants. Every verdict carries `reasons`: the rules below that fired, and
the evidence each one used.

## Signals

| Signal | Source | Meaning |
|---|---|---|
| Attachment | `IOPort` → `ConnectionActive` | The port's CC logic sees a partner, even over a charge-only cable where nothing enumerates. |
| New connection | `IOPort` → `ConnectionUUID` | Changes with every new connection; starts the settle window. |
| Links | `IOPort` → `TransportsActive` | Live transports: `CC`, `USB2`, `USB3`, `CIO` (Thunderbolt/USB4), `DisplayPort`. `CC` alone means no data link. |
| Held links | `IOPort` → `TransportsUnauthorized`, `AuthorizationPending`, `UserAuthorizationPending` | Links macOS holds until the user allows the accessory. |
| Display | `IOPort` → `HPDAsserted` | A DisplayPort sink raised hot-plug detect. |
| Power into the Mac | `IOPortFeaturePowerSource` → `WinningPowerSourceOption` | The offer the Mac accepted (mV, mA, mW). Offers with no winner mean a charger on standby. |
| Mac battery | `AppleSmartBattery` → `IsCharging` | Whether incoming power is filling the battery or only running the Mac. |
| Power out of the Mac | `AppleSmartBattery` → `PowerOutDetails[PortIndex]` | Metered power per USB-C port. Its `Watts` key is really mW. Laptops only. A sample-and-hold refreshed about every 20 s, so one reading can be a plug-in spike: 10.8 W was held for ~17 s on a full phone whose next reading was 2.2 W. |
| Device battery | lockdown `com.apple.mobile.battery`, through MobileDevice.framework (`AMDeviceCopyValue`) | An iPhone's or iPad's own `BatteryCurrentCapacity`, `BatteryIsCharging`, `FullyCharged`. Only for devices that already trust this Mac; PlugSense never pairs. Matched to its port by USB serial number = UDID without the dash. |
| Charger state | the device's `AppleSmartBattery` → `ChargerData`, through the diagnostics relay (only `IORegistry` and `Goodbye` are sent) | `TimeChargingThermallyLimited` counts seconds of charging held or slowed for heat, in ~20 s steps; `NotChargingReason` is the charger's own undocumented code (256 while held for heat). Read only while the device is below full and not charging. |
| Device model | lockdown `ProductType`, named by CoreTypes' `com.apple.device-model-code` UTType tags | `iPhone18,2` → "iPhone 17 Pro Max". Keys the USB-speed table in `AppleDevices.swift`. |
| Power budget | `IOUSBHostDevice` → `UsbPowerSinkAllocation` | mA at 5 V the USB stack granted (per the SDK header). Stands in when there is no meter reading. |
| Device → port | root port → `UsbIOPort`, found by searching up from the device | Registry path of the physical port, through any number of hubs. |
| Tunneled | `IOUSBHostDevice` → `UsbTunnel` | Arrived through a USB4/Thunderbolt tunnel. |
| Function | `IOUSBHostInterface` class/subclass/protocol, vendor and product ID | What the data link is for (`USBFunctions.swift`). |
| Adapter | `IOPSCopyExternalPowerAdapterDetails()` | Name and wattage of the charger powering the Mac. |

## Decision procedure (per port)

- **R0 Attachment.** Attached if `ConnectionActive`, or if USB devices trace to the port. Otherwise
  the port is *empty* and no further rules run.
- **R1 Power into the Mac.** A power source with `WinningPowerSourceOption`: power flows *into the
  Mac* at the negotiated contract.
- **R1b Standby charger.** Offers but no winner: a charger the Mac isn't drawing from, because
  another port won.
- **R2 Power out of the Mac.** A `PowerOutDetails` entry for this USB-C port: power flows *out*,
  metered.
- **R2b Budget fallback.** No meter reading (desktop Macs, or before the meter's next refresh):
  the sum of `UsbPowerSinkAllocation` × 5 V. This is the most the device is *allowed* to draw, so
  it is always shown as an allowance ("up to 12.0 W allowed"), never as a flow.
- **R3 Data.** A USB link is live if `USB2` or `USB3` is active or devices enumerated. Each
  interface maps to a function: phone sync (Apple usbmux), restore/DFU (Apple restore-mode product
  IDs, per libirecovery), photo import (PTP, MTP), storage, network (CDC ECM/NCM/EEM/MBIM, RNDIS,
  Apple private Ethernet), debug bridge (ADB, fastboot), input, audio, video, serial, printer,
  smart card, billboard.
  - **R3a.** Untraceable devices belong to the one port with a `CIO` link, if exactly one has one;
    otherwise they are reported under *USB (other)*.
  - **R3b Speed limit.** When a device's model is known and its link is below USB 3: a USB 2.0-only
    model "tops out at USB 2.0"; a USB 3 model on a port that supports `USB3` is *cable-limited*
    (only the cable's USB 2 wires linked); on a USB 2.0-only port it is *port-limited*.
- **R4 Display.** `DisplayPort` active, or `HPDAsserted`.
- **R5 Thunderbolt/USB4.** `CIO` active.
- **R6 Held for approval.** Any held link, or authorization pending: *data held for approval*.
  This is never read as "charge only".
- **R7 Charging.** Measured wherever a battery reports itself. Into the Mac, `IsCharging` decides
  *charging* or *powered only*. Out of the Mac, a trusting iPhone's or iPad's `BatteryIsCharging`
  decides *charging* or *full / not charging*. Otherwise `assessCharge` (`Charging.swift`) infers
  *charging*, *powered only*, *idle* or *unknown* from the outside. A device's report beats the
  meter: the meter is one slow sample, the report is the battery itself.
  - **R7b Why charging is held.** Below full and not charging, the device's heat counter is read
    twice, at least 21 s apart. Still counting: *too warm*. Flat: another hold, such as a charge
    limit or optimized charging, which the device doesn't tell apart. Until the second reading:
    *checking*.
- **R8 Settling.** Plugged in less than the settle window (3 s) ago, with no data, display,
  Thunderbolt or held link yet: *connecting…*, since a link may still be enumerating.

## Timing

Triggers: IOKit first-match and terminate notifications for `IOUSBHostDevice`,
`IOPortTransportState` and `IOPortFeaturePowerSource`; general-interest messages from each
`IOPort`; `kIOPSNotifyAnyPowerSource`; a 2 s poll; and a re-check when a settle window closes.
Triggers are debounced by 300 ms, and every one does the same thing: snapshot, classify, diff.
Events fire when a port's *decision* changes, never on meter drift alone.

## The charge-or-data question (menu bar app)

The protocol only observes. The app adds one interaction on top of it:

- **When it asks.** Once per plug-in, within 60 s, as soon as power is flowing out of the Mac to a
  device with a data link *and* it is known whether that device is charging: measured for a trusting
  iPhone or iPad, inferred once `assessCharge` can decide. A device whose charge state can't be seen
  is never asked, because the promise that comes with *Data only* couldn't be kept.
- **What it remembers.** The answer, per device model (`PortVerdict.deviceKey`: `apple:iPhone18,2`,
  or `usb:<vendor>:<product>`), in the app's preferences. No serial number or UDID is stored.
  Choosing *Ask* in the device's expanded card forgets the answer.
- **What *Data only* does.** It can't remove the power (see Limits). PlugSense marks the device's
  card *Data only* and pops up a warning whenever the device starts charging, pointing to the
  phone's Charge Limit.
- ***Finished charging*** pops up only when a device reaches 100%. A stop below full can be heat
  rather than completion, so the card labels the hold instead (R7b).

## Limits

- PlugSense observes; it can't switch a port's power off or cap it. macOS offers no API for that,
  and it isn't needed: a USB device pulls the current it wants, and a full device stops charging by
  itself. To make an iPhone stop earlier, set its own Charge Limit (Settings → Battery → Charging).
- Device reports come from MobileDevice.framework, which is private. If it changes or is missing,
  PlugSense falls back to R7's inference.
- USB-A ports have no CC logic, so charge-only attachments are invisible there, and their devices
  can't be traced to a port (they appear under *USB (other)*).
- Desktop Macs have no `AppleSmartBattery`, so power out is the USB budget, not a measurement.
- An iPhone's "Trust This Computer" state lives in usbmuxd/lockdownd, not the registry.
- R6 is built from the property names and the *approved* state; the held state itself has not
  been observed yet.
- `PortIndex` = USB-C port number is verified on Mac14,7 only.

## Verified on

Mac14,7 (M2 MacBook Pro 13-inch, two USB-C ports), macOS 27.2 (26B5091g), 2026-09-25. A 96W
Apple USB-C adapter on USB-C 1 negotiated 94 W (20 V × 4.7 A); as the battery filled, `IsCharging`
went from Yes to No and PlugSense reported *powering the Mac*. An iPhone 17 Pro Max (`iPhone18,2`,
iOS 27.0) on USB-C 2 carried data (phone sync, photo import, network) over USB 2.0 at 480 Mb/s:
only `CC` and `USB2` were active and the cable had no e-marker, while phone and port both support
10 Gb/s, so R3b reports a USB 2.0-only cable. The phone reported 100% and not charging throughout;
the meter read 1.0–2.3 W apart from one 10.8 W sample just after a replug. Unplugging and replugging
it raised the popup; plugging it in again raised the charge-or-data question, and one click on
*Data only* saved the answer. The phone then reported 86% and not charging, so no warning followed,
while its own Battery screen said "Charging, 1h 2m to 100%". Its battery controller (read through
the diagnostics relay) sided with PlugSense: 0–1 mA into the battery, `NotChargingReason` 256, and
`TimeChargingThermallyLimited` counting up about once a second, so charging was held for heat. The
phone ran on the ~1.4 W it drew from the Mac. The Battery screen's "Charging" means *plugged in and
set to charge*, not *current is flowing*; lockdown's `BatteryIsCharging` follows the controller.
With R7b in place, PlugSense reported *checking* when the phone's report arrived and *charging held
(too warm)* 24 s later, at the second heat-counter reading.
