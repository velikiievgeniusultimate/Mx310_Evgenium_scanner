// Native USB transport for Canon MX310 on Windows ARM64.
// Uses the official ARM64 libusb build over Microsoft's WinUSB driver.
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace MX310Native
{
    internal sealed class LibUsbTransport : IDisposable
    {
        private const ushort CanonVid = 0x04A9;
        private const ushort Mx310Pid = 0x1728;
        private const int ScannerInterface = 0;
        private const int LibUsbErrorTimeout = -7;
        private const int LibUsbErrorNotSupported = -12;

        private IntPtr context;
        private IntPtr handle;
        private bool claimed;
        private byte bulkIn;
        private byte bulkOut;
        private byte interruptIn;
        private readonly Action<string> log;

        public byte BulkIn { get { return bulkIn; } }
        public byte BulkOut { get { return bulkOut; } }
        public byte InterruptIn { get { return interruptIn; } }

        public LibUsbTransport(Action<string> logger)
        {
            log = logger ?? delegate { };
            PrepareNativeLibrary();

            int rc = Native.libusb_init(out context);
            Check(rc, "libusb_init");
            try
            {
                handle = Native.libusb_open_device_with_vid_pid(context, CanonVid, Mx310Pid);
                if (handle == IntPtr.Zero)
                {
                    throw new InvalidOperationException(
                        "MX310 Ð½Ðµ Ð¾Ñ‚ÐºÑ€Ñ‹Ð»ÑÑ Ñ‡ÐµÑ€ÐµÐ· WinUSB. ÐŸÑ€Ð¾Ð²ÐµÑ€ÑŒÑ‚Ðµ ÑƒÑÑ‚Ð°Ð½Ð¾Ð²ÐºÑƒ Mx310_Evgenium_scanner Ð´Ð»Ñ Interface 0 / MI_00.");
                }

                DiscoverEndpoints();

                rc = Native.libusb_set_auto_detach_kernel_driver(handle, 1);
                if (rc != 0 && rc != LibUsbErrorNotSupported)
                    log("libusb_set_auto_detach_kernel_driver: " + ErrorText(rc));

                rc = Native.libusb_claim_interface(handle, ScannerInterface);
                Check(rc, "libusb_claim_interface(0)");
                claimed = true;
                log(string.Format("USB Ð¾Ñ‚ÐºÑ€Ñ‹Ñ‚: OUT=0x{0:X2}, IN=0x{1:X2}, INTERRUPT=0x{2:X2}", bulkOut, bulkIn, interruptIn));
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        public void Write(byte[] data, int timeoutMs)
        {
            if (data == null) throw new ArgumentNullException("data");
            int transferred;
            int rc = Native.libusb_bulk_transfer(handle, bulkOut, data, data.Length, out transferred, (uint)timeoutMs);
            Check(rc, "USB bulk OUT");
            if (transferred != data.Length)
                throw new IOException(string.Format("ÐÐµÐ¿Ð¾Ð»Ð½Ð°Ñ USB-Ð·Ð°Ð¿Ð¸ÑÑŒ: {0} Ð¸Ð· {1} Ð±Ð°Ð¹Ñ‚.", transferred, data.Length));
        }

        public byte[] Read(int maximumBytes, int timeoutMs)
        {
            byte[] buffer = new byte[maximumBytes];
            int transferred;
            int rc = Native.libusb_bulk_transfer(handle, bulkIn, buffer, buffer.Length, out transferred, (uint)timeoutMs);
            Check(rc, "USB bulk IN");
            if (transferred == buffer.Length) return buffer;
            byte[] result = new byte[transferred];
            Buffer.BlockCopy(buffer, 0, result, 0, transferred);
            return result;
        }

        public void DrainInterrupts()
        {
            if (interruptIn == 0) return;
            byte[] buffer = new byte[64];
            for (int i = 0; i < 16; i++)
            {
                int transferred;
                int rc = Native.libusb_interrupt_transfer(handle, interruptIn, buffer, buffer.Length, out transferred, 30);
                if (rc == LibUsbErrorTimeout) break;
                if (rc != 0)
                {
                    log("ÐžÑ‡Ð¸ÑÑ‚ÐºÐ° interrupt endpoint: " + ErrorText(rc));
                    break;
                }
                log("Ð£Ð´Ð°Ð»Ñ‘Ð½ Ð¾Ð¶Ð¸Ð´Ð°Ð²ÑˆÐ¸Ð¹ interrupt-Ð¿Ð°ÐºÐµÑ‚: " + transferred + " Ð±Ð°Ð¹Ñ‚.");
            }
        }

        public void ClearBulkHalts()
        {
            if (handle == IntPtr.Zero) return;
            Native.libusb_clear_halt(handle, bulkIn);
            Native.libusb_clear_halt(handle, bulkOut);
        }

        public void Dispose()
        {
            if (handle != IntPtr.Zero)
            {
                if (claimed)
                {
                    Native.libusb_release_interface(handle, ScannerInterface);
                    claimed = false;
                }
                Native.libusb_close(handle);
                handle = IntPtr.Zero;
            }
            if (context != IntPtr.Zero)
            {
                Native.libusb_exit(context);
                context = IntPtr.Zero;
            }
        }

        private void DiscoverEndpoints()
        {
            IntPtr device = Native.libusb_get_device(handle);
            if (device == IntPtr.Zero) throw new InvalidOperationException("libusb_get_device Ð²ÐµÑ€Ð½ÑƒÐ» NULL.");

            IntPtr configPointer;
            int rc = Native.libusb_get_active_config_descriptor(device, out configPointer);
            Check(rc, "libusb_get_active_config_descriptor");
            try
            {
                LibUsbConfigDescriptor config = (LibUsbConfigDescriptor)Marshal.PtrToStructure(
                    configPointer, typeof(LibUsbConfigDescriptor));
                int interfaceSize = Marshal.SizeOf(typeof(LibUsbInterface));
                int altSize = Marshal.SizeOf(typeof(LibUsbInterfaceDescriptor));
                int endpointSize = Marshal.SizeOf(typeof(LibUsbEndpointDescriptor));

                for (int i = 0; i < config.bNumInterfaces; i++)
                {
                    IntPtr interfacePointer = Add(config.interfaces, i * interfaceSize);
                    LibUsbInterface usbInterface = (LibUsbInterface)Marshal.PtrToStructure(
                        interfacePointer, typeof(LibUsbInterface));
                    for (int a = 0; a < usbInterface.num_altsetting; a++)
                    {
                        IntPtr altPointer = Add(usbInterface.altsetting, a * altSize);
                        LibUsbInterfaceDescriptor alt = (LibUsbInterfaceDescriptor)Marshal.PtrToStructure(
                            altPointer, typeof(LibUsbInterfaceDescriptor));
                        if (alt.bInterfaceNumber != ScannerInterface) continue;

                        for (int e = 0; e < alt.bNumEndpoints; e++)
                        {
                            IntPtr endpointPointer = Add(alt.endpoint, e * endpointSize);
                            LibUsbEndpointDescriptor endpoint = (LibUsbEndpointDescriptor)Marshal.PtrToStructure(
                                endpointPointer, typeof(LibUsbEndpointDescriptor));
                            int type = endpoint.bmAttributes & 0x03;
                            bool input = (endpoint.bEndpointAddress & 0x80) != 0;
                            if (type == 2 && input) bulkIn = endpoint.bEndpointAddress;
                            if (type == 2 && !input) bulkOut = endpoint.bEndpointAddress;
                            if (type == 3 && input) interruptIn = endpoint.bEndpointAddress;
                            log(string.Format("Endpoint: address=0x{0:X2}, type={1}, maxPacket={2}",
                                endpoint.bEndpointAddress, type, endpoint.wMaxPacketSize));
                        }
                    }
                }
            }
            finally
            {
                Native.libusb_free_config_descriptor(configPointer);
            }

            if (bulkIn == 0 || bulkOut == 0)
                throw new InvalidOperationException("Ð£ Ð¸Ð½Ñ‚ÐµÑ€Ñ„ÐµÐ¹ÑÐ° MI_00 Ð½Ðµ Ð½Ð°Ð¹Ð´ÐµÐ½Ñ‹ bulk IN/OUT endpoints.");
        }

        private static IntPtr Add(IntPtr pointer, int offset)
        {
            return new IntPtr(pointer.ToInt64() + offset);
        }

        private static void Check(int rc, string operation)
        {
            if (rc != 0) throw new IOException(operation + ": " + ErrorText(rc));
        }

        private static string ErrorText(int rc)
        {
            try
            {
                IntPtr text = Native.libusb_error_name(rc);
                string name = Marshal.PtrToStringAnsi(text);
                return string.Format("{0} ({1})", name, rc);
            }
            catch
            {
                return "libusb error " + rc;
            }
        }

        private static void PrepareNativeLibrary()
        {
            string appRoot = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string architecture = GetProcessArchitecture();
            string nativeRoot = Path.Combine(appRoot, architecture);
            string dll = Path.Combine(nativeRoot, "libusb-1.0.dll");
            if (!File.Exists(dll))
                throw new FileNotFoundException("ÐÐµ Ð½Ð°Ð¹Ð´ÐµÐ½ Ð½Ð°Ñ‚Ð¸Ð²Ð½Ñ‹Ð¹ libusb: " + dll, dll);
            if (!Native.SetDllDirectory(nativeRoot))
                throw new InvalidOperationException("SetDllDirectory Ð½Ðµ ÑÐ¼Ð¾Ð³ Ð¿Ð¾Ð´ÐºÐ»ÑŽÑ‡Ð¸Ñ‚ÑŒ: " + nativeRoot);
        }

        private static string GetProcessArchitecture()
        {
            // On Windows 11 ARM64 an emulated x64 .NET Framework process can
            // report nativeMachine=ARM64 and processMachine=0 through
            // IsWow64Process2. PROCESSOR_ARCHITECTURE describes the current
            // process environment and must win before the native-machine
            // fallback, otherwise an ARM64 DLL is loaded into an x64 process.
            string environmentArchitecture = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE");
            if (string.Equals(environmentArchitecture, "AMD64", StringComparison.OrdinalIgnoreCase)) return "x64";
            if (string.Equals(environmentArchitecture, "ARM64", StringComparison.OrdinalIgnoreCase)) return "arm64";

            ushort processMachine;
            ushort nativeMachine;
            if (Native.IsWow64Process2(Native.GetCurrentProcess(), out processMachine, out nativeMachine))
            {
                ushort effective = processMachine == 0 ? nativeMachine : processMachine;
                if (effective == 0xAA64) return "arm64";
                if (effective == 0x8664) return "x64";
            }
            return IntPtr.Size == 8 ? "x64" : "x86";
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LibUsbConfigDescriptor
        {
            public byte bLength;
            public byte bDescriptorType;
            public ushort wTotalLength;
            public byte bNumInterfaces;
            public byte bConfigurationValue;
            public byte iConfiguration;
            public byte bmAttributes;
            public byte MaxPower;
            public IntPtr interfaces;
            public IntPtr extra;
            public int extra_length;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LibUsbInterface
        {
            public IntPtr altsetting;
            public int num_altsetting;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LibUsbInterfaceDescriptor
        {
            public byte bLength;
            public byte bDescriptorType;
            public byte bInterfaceNumber;
            public byte bAlternateSetting;
            public byte bNumEndpoints;
            public byte bInterfaceClass;
            public byte bInterfaceSubClass;
            public byte bInterfaceProtocol;
            public byte iInterface;
            public IntPtr endpoint;
            public IntPtr extra;
            public int extra_length;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct LibUsbEndpointDescriptor
        {
            public byte bLength;
            public byte bDescriptorType;
            public byte bEndpointAddress;
            public byte bmAttributes;
            public ushort wMaxPacketSize;
            public byte bInterval;
            public byte bRefresh;
            public byte bSynchAddress;
            public IntPtr extra;
            public int extra_length;
        }

        private static class Native
        {
            private const string LibUsb = "libusb-1.0.dll";

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern int libusb_init(out IntPtr context);

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern void libusb_exit(IntPtr context);

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern IntPtr libusb_open_device_with_vid_pid(IntPtr context, ushort vendorId, ushort productId);

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern void libusb_close(IntPtr deviceHandle);

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern IntPtr libusb_get_device(IntPtr deviceHandle);

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern int libusb_get_active_config_descriptor(IntPtr device, out IntPtr config);

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern void libusb_free_config_descriptor(IntPtr config);

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern int libusb_set_auto_detach_kernel_driver(IntPtr deviceHandle, int enable);

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern int libusb_claim_interface(IntPtr deviceHandle, int interfaceNumber);

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern int libusb_release_interface(IntPtr deviceHandle, int interfaceNumber);

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern int libusb_bulk_transfer(IntPtr deviceHandle, byte endpoint, byte[] data,
                int length, out int transferred, uint timeout);

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern int libusb_interrupt_transfer(IntPtr deviceHandle, byte endpoint, byte[] data,
                int length, out int transferred, uint timeout);

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern int libusb_clear_halt(IntPtr deviceHandle, byte endpoint);

            [DllImport(LibUsb, CallingConvention = CallingConvention.Cdecl)]
            internal static extern IntPtr libusb_error_name(int errorCode);

            [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
            internal static extern bool SetDllDirectory(string pathName);

            [DllImport("kernel32.dll")]
            internal static extern IntPtr GetCurrentProcess();

            [DllImport("kernel32.dll", SetLastError = true)]
            internal static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
        }
    }
}

