// Pull a file from the board over the serial console in verified chunks.
//
//   csc /nologo /out:serial_pull.exe tools/serial_pull_chunked.cs
//   serial_pull.exe COM9 /mnt/boot/BOOT.BIN boot.bin 512 32 20
//
// Each chunk is `dd`-ed on the board, md5-summed, base64-ed with a small
// pacing pause, and read until a sentinel.  The host verifies the md5 before
// accepting the chunk; a corrupt chunk is retried.
using System;
using System.Globalization;
using System.IO;
using System.IO.Ports;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

static class Puller {
    static SerialPort sp;

    static void Send(string s) { sp.Write(s + "\r"); }

    static byte[] ReadUntil(string marker, int ms) {
        var outp = new MemoryStream();
        var buf = new byte[1 << 20];
        var tail = new StringBuilder();
        var end = DateTime.UtcNow.AddMilliseconds(ms);
        while (DateTime.UtcNow < end) {
            int n;
            try { n = sp.BaseStream.Read(buf, 0, buf.Length); }
            catch (TimeoutException) { continue; }
            catch (Exception) { break; }
            if (n <= 0) { Thread.Sleep(1); continue; }
            outp.Write(buf, 0, n);
            tail.Append(Encoding.ASCII.GetString(buf, 0, n));
            if (tail.Length > 64) tail.Remove(0, tail.Length - 64);
            if (tail.ToString().Contains(marker)) break;
        }
        return outp.ToArray();
    }

    static bool IsB64(string line) {
        foreach (char c in line)
            if (!(char.IsLetterOrDigit(c) || c == '+' || c == '/' || c == '=')) return false;
        return true;
    }

    static string Md5Hex(byte[] b) {
        using (var md5 = MD5.Create()) {
            var h = md5.ComputeHash(b);
            var sb = new StringBuilder();
            foreach (byte x in h) sb.Append(x.ToString("x2"));
            return sb.ToString();
        }
    }

    static int Main(string[] args) {
        if (args.Length < 6) {
            Console.Error.WriteLine("usage: serial_pull.exe <port> <remote> <local> <chunkKB> <paceLines> <paceMs>");
            return 2;
        }
        string port = args[0], remote = args[1], local = args[2];
        int chunkKB = int.Parse(args[3]);
        int paceLines = int.Parse(args[4]);
        int paceMs = int.Parse(args[5]);
        string pause = (paceMs / 1000.0).ToString("0.###", CultureInfo.InvariantCulture);
        int maxChunks = args.Length >= 7 ? int.Parse(args[6]) : 0;

        sp = new SerialPort(port, 921600, Parity.None, 8, StopBits.One);
        sp.Handshake = Handshake.None;
        sp.ReadTimeout = 300000;
        sp.WriteTimeout = 20000;
        sp.ReadBufferSize = 1 << 20;
        sp.Open();
        Thread.Sleep(300);
        sp.DiscardInBuffer();

        sp.Write("\x03\r");
        Thread.Sleep(400);
        sp.DiscardInBuffer();
        Send("stty -echo ixon ixoff");
        ReadUntil("#", 8000);

        var all = new MemoryStream();
        int total = 0;
        for (int i = 0; ; i++) {
            bool ok = false;
            byte[] bytes = null;
            for (int attempt = 0; attempt < 4 && !ok; attempt++) {
                sp.DiscardInBuffer();
                string cmd = "dd if=" + remote + " bs=" + chunkKB + "K skip=" + i +
                    " count=1 2>/dev/null of=/tmp/pullchunk.bin; md5sum /tmp/pullchunk.bin; " +
                    "openssl base64 -in /tmp/pullchunk.bin | { n=0; while read l; do echo \"$l\"; " +
                    "n=$((n+1)); [ $((n % " + paceLines + ")) -eq 0 ] && sleep " + pause + "; done; }; echo __END__";
                Send(cmd);
                string text = Encoding.ASCII.GetString(ReadUntil("__END__", 600000));
                text = Regex.Replace(text, "\x1b\\[[0-9;?]*[A-Za-z]", "");
                string want = null;
                var sb = new StringBuilder();
                foreach (string rawLine in text.Split('\n')) {
                    string line = rawLine.TrimEnd('\r');
                    if (line.Length > 32 && line.Substring(32).StartsWith("  /tmp/pullchunk"))
                        want = line.Substring(0, 32).Trim();
                    else if (line.Length >= 4 && IsB64(line))
                        sb.Append(line);
                }
                if (want == null) { Console.WriteLine("  attempt " + attempt + ": no md5 line (raw " + text.Length + ")"); continue; }
                try { bytes = Convert.FromBase64String(sb.ToString()); }
                catch (FormatException) { continue; }
                if (Md5Hex(bytes) == want) ok = true;
                else Console.WriteLine("  attempt " + attempt + ": raw " + text.Length + " b64 " + sb.Length + " bytes " + bytes.Length + " want " + want);
                else Console.WriteLine("chunk " + i + " attempt " + attempt + ": md5 mismatch (" + bytes.Length + " bytes)");
            }
            if (!ok) { Console.WriteLine("chunk " + i + " failed"); return 1; }
            all.Write(bytes, 0, bytes.Length);
            total += bytes.Length;
            Console.WriteLine("chunk " + i + ": " + bytes.Length + " bytes (total " + total + ")");
            if (maxChunks > 0 && i + 1 >= maxChunks) break;
            if (bytes.Length < chunkKB * 1024) break;
        }
        File.WriteAllBytes(local, all.ToArray());
        Console.WriteLine("wrote " + local + " (" + total + " bytes)");
        sp.Close();
        return 0;
    }
}
