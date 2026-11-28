// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0
// ZipArchiveEntry exposes the stored CRC but some supported .NET versions
// do not check it when reading an entry stream.
public static class DarktideArchiveCrc
{
    private static readonly uint[] Table = BuildTable();

    private static uint[] BuildTable()
    {
        var table = new uint[256];
        for (uint i = 0; i < table.Length; i++)
        {
            uint value = i;
            for (int bit = 0; bit < 8; bit++)
                value = (value & 1) == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320U;
            table[i] = value;
        }
        return table;
    }

    public static uint Append(uint crc, byte[] bytes, int count)
    {
        for (int i = 0; i < count; i++)
            crc = Table[(crc ^ bytes[i]) & 255] ^ (crc >> 8);
        return crc;
    }
}
