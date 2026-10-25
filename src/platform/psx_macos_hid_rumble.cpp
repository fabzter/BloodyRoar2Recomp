// macOS DualShock 4 rumble over Bluetooth, written directly to IOKit HID.
//
// WHY THIS EXISTS: SDL's HIDAPI PS4 driver passes the Bluetooth effects report
// id to IOHIDDeviceSetReport as a separate argument and strips it from the
// payload (hidapi's convention). The DS4-compatible pads used here accept every
// such write at the API level (IOReturn 0) and ignore it, so rumble never
// starts. The convention these pads DO obey -- verified variant by variant
// against the hardware, including that a frame with a zeroed CRC leaves the
// motor running -- is: report id 0 passed to IOHIDDeviceSetReport, with the
// report id byte (0x11) inside a 78-byte buffer:
//
//   frame[0]      = 0x11   Bluetooth effects report id
//   frame[1]      = 0xC0   HID output + CRC present
//   frame[3]      = 0x03   effect mask (rumble | led)
//   frame[6]      = small / high-frequency motor (0..255)
//   frame[7]      = large / low-frequency motor  (0..255)
//   frame[74..77] = CRC32 over the byte 0xA2 followed by frame[0..73]
//
// Scope: only DS4-family pads (VID 0x054c, PID 0x05c4 / 0x09cc). Everything
// else keeps SDL's rumble path, which is correct for it.
//
// Built into the game targets by CMake (br2_macos_hid_rumble) with
// PSX_TITLE_HID_RUMBLE defined; the runtime's rumble forwarder calls these when
// that macro is present and attach() said it will drive the pad.

#include <stdint.h>
#include <string.h>

#if defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDManager.h>

namespace {

IOHIDDeviceRef g_dev = nullptr;
uint8_t g_last_small = 0;
uint8_t g_last_large = 0;

uint32_t crc32_ieee(const uint8_t *data, size_t len) {
  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < len; ++i) {
    crc ^= (uint32_t)data[i];
    for (int b = 0; b < 8; ++b)
      crc = (crc & 1u) ? ((crc >> 1) ^ 0xEDB88320u) : (crc >> 1);
  }
  return ~crc;
}

void build_frame(uint8_t small, uint8_t large, uint8_t out[78]) {
  memset(out, 0, 78);
  out[0] = 0x11;
  out[1] = 0xC0;
  out[3] = 0x03;
  out[6] = small;
  out[7] = large;
  uint8_t crc_input[75];
  crc_input[0] = 0xA2;
  memcpy(&crc_input[1], out, 74);
  const uint32_t crc = crc32_ieee(crc_input, sizeof(crc_input));
  out[74] = (uint8_t)(crc & 0xFFu);
  out[75] = (uint8_t)((crc >> 8) & 0xFFu);
  out[76] = (uint8_t)((crc >> 16) & 0xFFu);
  out[77] = (uint8_t)((crc >> 24) & 0xFFu);
}

bool write_frame(const uint8_t frame[78]) {
  if (!g_dev)
    return false;
  uint8_t buf[78];
  memcpy(buf, frame, 78);
  const IOReturn r = IOHIDDeviceSetReport(g_dev, kIOHIDReportTypeOutput,
                                          0 /* report id */, buf, sizeof(buf));
  return r == kIOReturnSuccess;
}

bool ds4_family(uint16_t vid, uint16_t pid) {
  /* DualShock 4 v1/v2 only. DualSense uses a different frame layout and is
   * deliberately left on SDL's path. */
  return vid == 0x054C && (pid == 0x05C4 || pid == 0x09CC);
}

} // namespace

extern "C" {

int psx_macos_hid_rumble_attach(uint16_t vid, uint16_t pid) {
  if (!ds4_family(vid, pid))
    return 0;
  if (g_dev)
    return 1;

  IOHIDManagerRef mgr =
      IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
  if (!mgr)
    return 0;

  int vid_i = (int)vid, pid_i = (int)pid;
  CFNumberRef vid_n =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid_i);
  CFNumberRef pid_n =
      CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pid_i);
  const void *keys[] = {CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey)};
  const void *vals[] = {vid_n, pid_n};
  CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 2,
                                             &kCFTypeDictionaryKeyCallBacks,
                                             &kCFTypeDictionaryValueCallBacks);
  IOHIDManagerSetDeviceMatching(mgr, match);
  IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);

  int attached = 0;
  CFSetRef devices = IOHIDManagerCopyDevices(mgr);
  if (devices) {
    const CFIndex count = CFSetGetCount(devices);
    if (count > 0) {
      const void **list = (const void **)calloc((size_t)count, sizeof(void *));
      if (list) {
        CFSetGetValues(devices, list);
        IOHIDDeviceRef dev = (IOHIDDeviceRef)list[0];
        if (IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone) == kIOReturnSuccess) {
          g_dev = dev;
          attached = 1;
        }
        free(list);
      }
    }
    CFRelease(devices);
  }
  if (!attached) {
    IOHIDManagerClose(mgr, kIOHIDOptionsTypeNone);
    CFRelease(mgr);
  }
  CFRelease(match);
  CFRelease(vid_n);
  CFRelease(pid_n);
  return attached;
}

void psx_macos_hid_rumble_update(uint8_t small, uint8_t large) {
  if (!g_dev)
    return;
  if (small == g_last_small && large == g_last_large && !small && !large)
    return;
  uint8_t frame[78];
  build_frame(small, large, frame);
  (void)write_frame(frame);
  g_last_small = small;
  g_last_large = large;
}

void psx_macos_hid_rumble_detach(void) {
  if (!g_dev)
    return;
  uint8_t frame[78];
  build_frame(0, 0, frame);
  (void)write_frame(frame);
  IOHIDDeviceClose(g_dev, kIOHIDOptionsTypeNone);
  g_dev = nullptr;
  g_last_small = g_last_large = 0;
}

} // extern "C"

#else /* !__APPLE__ */

extern "C" {
int psx_macos_hid_rumble_attach(uint16_t vid, uint16_t pid) {
  (void)vid;
  (void)pid;
  return 0;
}
void psx_macos_hid_rumble_update(uint8_t small, uint8_t large) {
  (void)small;
  (void)large;
}
void psx_macos_hid_rumble_detach(void) {}
}

#endif /* __APPLE__ */