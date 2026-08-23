// Canon PIXMA generation-3 protocol implementation for the MX310.
// Protocol sequence is based on the free SANE PIXMA backend.
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace MX310Native
{
    internal sealed class PixmaMx310
    {
        private const ushort CmdStartSession = 0xDB20;
        private const ushort CmdGamma = 0xEE20;
        private const ushort CmdStatus = 0xF320;
        private const ushort CmdAbortSession = 0xEF20;
        private const ushort CmdReadImage = 0xD420;
        private const ushort CmdScanParam3 = 0xD820;
        private const ushort CmdScanStart3 = 0xD920;
        private const ushort CmdStatus3 = 0xDA20;
        private const int ImageBlockSize = 512 * 1024;

        private readonly LibUsbTransport usb;
        private readonly Action<string> log;
        private readonly Action<string, int> progress;
        private bool sessionStarted;

        public PixmaMx310(LibUsbTransport transport, Action<string> logger, Action<string, int> progressReporter)
        {
            usb = transport;
            log = logger ?? delegate { };
            progress = progressReporter ?? delegate { };
        }

        public void Probe()
        {
            usb.DrainInterrupts();
            byte[] status = Execute(CmdStatus, 0, 16, null);
            log("F320 status payload: " + Hex(status, 8, 16));
        }

        public string ScanFlatbed(int dpi, string outputPath)
        {
            if (dpi != 75 && dpi != 150 && dpi != 300)
                throw new ArgumentOutOfRangeException("dpi", "Поддерживаются 75, 150 и 300 dpi.");

            int width = 2480 * dpi / 300;
            int height = 3508 * dpi / 300;
            int rawWidth = AlignUp(width, 32);
            int rawLineSize = rawWidth * 3;
            log(string.Format("Scan geometry: dpi={0}, output={1}x{2}, rawWidth={3}, rawLine={4}",
                dpi, width, height, rawWidth, rawLineSize));

            MemoryStream raw = new MemoryStream(rawLineSize * Math.Min(height, 1000));
            int lastFlags = 0;
            try
            {
                progress("Проверка состояния MX310...", 2);
                usb.DrainInterrupts();
                byte[] oldStatus = Execute(CmdStatus, 0, 16, null);
                log("Initial status: " + Hex(oldStatus, 8, 16));

                progress("Запуск сессии...", 5);
                StartSessionWithRetry();
                sessionStarted = true;

                for (int i = 0; i < 3; i++)
                {
                    progress("Передача гамма-таблицы " + (i + 1) + "/3...", 8 + i * 3);
                    SendGammaTable(2.2);
                }

                progress("Передача параметров сканирования...", 18);
                SendScanParameters(dpi, rawWidth, height);
                Execute(CmdScanStart3, 0, 0, null);

                WaitUntilReady();
                Thread.Sleep(1000);

                progress("Получение изображения...", 25);
                int expectedBytes = rawLineSize * height;
                int blockNumber = 0;
                do
                {
                    ImageBlock block = ReadImageBlock(lastFlags);
                    lastFlags = block.Flags;
                    if (block.Data.Length > 0)
                        raw.Write(block.Data, 0, block.Data.Length);
                    blockNumber++;
                    int percent = 25 + (int)Math.Min(65L, raw.Length * 65L / Math.Max(1, expectedBytes));
                    progress(string.Format("Получение изображения: {0:N1} МБ", raw.Length / 1048576.0), percent);
                    log(string.Format("Image block {0}: flags=0x{1:X2}, bytes={2}, total={3}",
                        blockNumber, block.Flags, block.Data.Length, raw.Length));
                }
                while ((lastFlags & 0x28) != 0x28);

                progress("Преобразование RGB в PNG...", 92);
                byte[] rawBytes = raw.ToArray();
                int receivedLines = rawBytes.Length / rawLineSize;
                int outputHeight = Math.Min(height, receivedLines);
                int remainder = rawBytes.Length % rawLineSize;
                log(string.Format("Raw complete: bytes={0}, lines={1}, remainder={2}", rawBytes.Length, receivedLines, remainder));
                if (outputHeight <= 0)
                    throw new InvalidDataException("Сканер не вернул ни одной полной строки изображения.");
                if (receivedLines < height)
                    log(string.Format("Предупреждение: ожидалось {0} строк, получено {1}.", height, receivedLines));

                SaveRgbToPng(rawBytes, rawLineSize, width, outputHeight, dpi, outputPath);
                progress("Готово.", 100);
                return outputPath;
            }
            finally
            {
                raw.Dispose();
                if (sessionStarted)
                {
                    try
                    {
                        Execute(CmdAbortSession, 0, 0, null);
                        log("Сессия сканирования закрыта.");
                    }
                    catch (Exception ex)
                    {
                        log("Не удалось отправить abort-session: " + ex.Message);
                        usb.ClearBulkHalts();
                    }
                    sessionStarted = false;
                }
            }
        }

        private void StartSessionWithRetry()
        {
            Exception last = null;
            for (int attempt = 1; attempt <= 11; attempt++)
            {
                try
                {
                    Execute(CmdStartSession, 0, 0, null);
                    return;
                }
                catch (PixmaBusyException ex)
                {
                    last = ex;
                    log("MX310 занят, попытка " + attempt + "/11.");
                    Thread.Sleep(1000);
                }
            }
            throw new InvalidOperationException("MX310 оставался занятым более 10 секунд.", last);
        }

        private void SendGammaTable(double gamma)
        {
            byte[] payload = new byte[1024 * 2 + 8];
            payload[0] = 0x10;
            SetBe16(payload, 2, 0x0804);
            double reciprocal = 1.0 / gamma;
            for (int i = 0; i < 1024; i++)
            {
                ushort value = (ushort)(65535.0 * Math.Pow(i / 1023.0, reciprocal) + 0.5);
                payload[4 + i * 2] = (byte)(value & 0xFF);
                payload[5 + i * 2] = (byte)(value >> 8);
            }
            Execute(CmdGamma, payload.Length, 0, payload);
        }

        private void SendScanParameters(int dpi, int rawWidth, int height)
        {
            byte[] payload = new byte[0x38];
            payload[0x00] = 0x01; // flatbed
            payload[0x01] = 0x01;
            payload[0x02] = 0x01;
            payload[0x05] = 0x01; // calibrate on first flatbed scan
            SetBe16(payload, 0x08, (ushort)(dpi | 0x8000));
            SetBe16(payload, 0x0A, (ushort)(dpi | 0x8000));
            SetBe32(payload, 0x0C, 0); // x
            SetBe32(payload, 0x10, 0); // y
            SetBe32(payload, 0x14, (uint)rawWidth);
            SetBe32(payload, 0x18, (uint)height);
            payload[0x1C] = 0x08; // color
            payload[0x1D] = 24;   // 8 bits x RGB
            payload[0x1F] = 0x01;
            payload[0x20] = 0xFF;
            payload[0x21] = 0x81;
            payload[0x23] = 0x02;
            payload[0x24] = 0x01;
            payload[0x30] = 0x01;
            Execute(CmdScanParam3, payload.Length, 0, payload);
        }

        private void WaitUntilReady()
        {
            for (int second = 0; second < 120; second++)
            {
                byte[] status = Execute(CmdStatus3, 0, 8, null);
                byte calibration = status[8];
                log("DA20 status: " + Hex(status, 8, 8));
                if ((calibration & 0x03) != 0)
                {
                    progress("Калибровка завершена.", 23);
                    return;
                }
                progress("Калибровка сканера... " + (second + 1) + " с", 20);
                usb.DrainInterrupts();
                Thread.Sleep(1000);
            }
            throw new TimeoutException("Калибровка MX310 не завершилась за 120 секунд.");
        }

        private ImageBlock ReadImageBlock(int previousFlags)
        {
            byte[] command = new byte[16];
            SetBe16(command, 0, CmdReadImage);
            uint request = (previousFlags & 0x20) == 0 ? (uint)(ImageBlockSize + 8) : 40U;
            SetBe32(command, 12, request);
            usb.Write(command, 8000);

            byte[] first = usb.Read(512, 8000);
            if (first.Length < 16)
                throw new InvalidDataException("Короткий заголовок блока изображения: " + first.Length + " байт.");
            CheckStatus(first);
            int flags = first[8] & 0x38;
            uint declared = GetBe32(first, 12);
            if (declared > ImageBlockSize)
                throw new InvalidDataException("MX310 объявил слишком большой блок: " + declared + " байт.");

            int inFirst = Math.Min((int)declared, first.Length - 16);
            byte[] data = new byte[(int)declared];
            if (inFirst > 0) Buffer.BlockCopy(first, 16, data, 0, inFirst);
            int remaining = (int)declared - inFirst;
            if (remaining > 0)
            {
                byte[] tail = usb.Read(remaining, 30000);
                if (tail.Length != remaining)
                    throw new InvalidDataException(string.Format("Неполный блок изображения: {0} из {1} байт.",
                        inFirst + tail.Length, declared));
                Buffer.BlockCopy(tail, 0, data, inFirst, remaining);
            }
            return new ImageBlock(flags, data);
        }

        private byte[] Execute(ushort commandCode, int dataOutLength, int dataInLength, byte[] payload)
        {
            byte[] command = new byte[16 + dataOutLength];
            SetBe16(command, 0, commandCode);
            SetBe16(command, 14, (ushort)(dataOutLength + dataInLength));
            if (dataOutLength > 0)
            {
                if (payload == null || payload.Length != dataOutLength)
                    throw new ArgumentException("Неверная длина payload для команды 0x" + commandCode.ToString("X4"));
                Buffer.BlockCopy(payload, 0, command, 16, payload.Length);
                FillChecksum(command, 16, command.Length - 1);
            }

            log("OUT " + commandCode.ToString("X4") + " (" + command.Length + " bytes): " + Hex(command, 0, Math.Min(command.Length, 64)));
            usb.Write(command, 8000);
            byte[] response = usb.Read(8 + dataInLength, 8000);
            log("IN  " + commandCode.ToString("X4") + " (" + response.Length + " bytes): " + Hex(response, 0, Math.Min(response.Length, 64)));
            if (response.Length < 8)
                throw new InvalidDataException("Короткий ответ на команду 0x" + commandCode.ToString("X4"));
            CheckStatus(response);
            if (dataInLength > 0)
            {
                if (response.Length != 8 + dataInLength)
                    throw new InvalidDataException(string.Format("Ответ 0x{0:X4}: {1} байт вместо {2}.",
                        commandCode, response.Length, 8 + dataInLength));
                if (Sum(response, 8, dataInLength) != 0)
                    throw new InvalidDataException("Ошибка контрольной суммы ответа 0x" + commandCode.ToString("X4"));
            }
            return response;
        }

        private static void CheckStatus(byte[] response)
        {
            ushort status = GetBe16(response, 0);
            if (status == 0x0606) return;
            if (status == 0x1414) throw new PixmaBusyException();
            if (status == 0x1515) throw new InvalidOperationException("MX310 отменил команду (PIXMA status 0x1515).");
            throw new InvalidDataException("Неизвестный PIXMA status 0x" + status.ToString("X4"));
        }

        private static void FillChecksum(byte[] buffer, int start, int checksumOffset)
        {
            int sum = 0;
            for (int i = start; i < checksumOffset; i++) sum += buffer[i];
            buffer[checksumOffset] = unchecked((byte)(-sum));
        }

        private static int Sum(byte[] buffer, int offset, int count)
        {
            int sum = 0;
            for (int i = 0; i < count; i++) sum += buffer[offset + i];
            return sum & 0xFF;
        }

        private static void SetBe16(byte[] buffer, int offset, ushort value)
        {
            buffer[offset] = (byte)(value >> 8);
            buffer[offset + 1] = (byte)value;
        }

        private static void SetBe32(byte[] buffer, int offset, uint value)
        {
            buffer[offset] = (byte)(value >> 24);
            buffer[offset + 1] = (byte)(value >> 16);
            buffer[offset + 2] = (byte)(value >> 8);
            buffer[offset + 3] = (byte)value;
        }

        private static ushort GetBe16(byte[] buffer, int offset)
        {
            return (ushort)((buffer[offset] << 8) | buffer[offset + 1]);
        }

        private static uint GetBe32(byte[] buffer, int offset)
        {
            return ((uint)buffer[offset] << 24) | ((uint)buffer[offset + 1] << 16) |
                   ((uint)buffer[offset + 2] << 8) | buffer[offset + 3];
        }

        private static int AlignUp(int value, int alignment)
        {
            return ((value + alignment - 1) / alignment) * alignment;
        }

        private static string Hex(byte[] data, int offset, int count)
        {
            int actual = Math.Min(count, data.Length - offset);
            char[] chars = new char[actual * 3];
            const string digits = "0123456789ABCDEF";
            for (int i = 0; i < actual; i++)
            {
                byte value = data[offset + i];
                chars[i * 3] = digits[value >> 4];
                chars[i * 3 + 1] = digits[value & 0x0F];
                chars[i * 3 + 2] = ' ';
            }
            return new string(chars).TrimEnd();
        }

        private static void SaveRgbToPng(byte[] raw, int rawLineSize, int width, int height, int dpi, string outputPath)
        {
            using (Bitmap bitmap = new Bitmap(width, height, PixelFormat.Format24bppRgb))
            {
                Rectangle rectangle = new Rectangle(0, 0, width, height);
                BitmapData bits = bitmap.LockBits(rectangle, ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
                try
                {
                    int stride = Math.Abs(bits.Stride);
                    byte[] row = new byte[stride];
                    for (int y = 0; y < height; y++)
                    {
                        Array.Clear(row, 0, row.Length);
                        int source = y * rawLineSize;
                        for (int x = 0; x < width; x++)
                        {
                            int s = source + x * 3;
                            int d = x * 3;
                            row[d] = raw[s + 2];
                            row[d + 1] = raw[s + 1];
                            row[d + 2] = raw[s];
                        }
                        IntPtr destination = new IntPtr(bits.Scan0.ToInt64() + (long)y * bits.Stride);
                        Marshal.Copy(row, 0, destination, stride);
                    }
                }
                finally
                {
                    bitmap.UnlockBits(bits);
                }
                bitmap.SetResolution(dpi, dpi);
                bitmap.Save(outputPath, ImageFormat.Png);
            }
        }

        private sealed class PixmaBusyException : Exception
        {
            public PixmaBusyException() : base("MX310 занят (PIXMA status 0x1414).") { }
        }

        private sealed class ImageBlock
        {
            public readonly int Flags;
            public readonly byte[] Data;
            public ImageBlock(int flags, byte[] data)
            {
                Flags = flags;
                Data = data;
            }
        }
    }
}
