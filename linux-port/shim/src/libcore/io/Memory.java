package libcore.io;

import java.nio.ByteOrder;

/** The two byte[] accessors ParcelFileDescriptor uses. */
public final class Memory {
	private Memory() {}

	public static int peekInt(byte[] src, int offset, ByteOrder order) {
		if (order == ByteOrder.BIG_ENDIAN) {
			return ((src[offset] & 0xff) << 24) | ((src[offset + 1] & 0xff) << 16)
			    | ((src[offset + 2] & 0xff) << 8) | (src[offset + 3] & 0xff);
		}
		return (src[offset] & 0xff) | ((src[offset + 1] & 0xff) << 8)
		    | ((src[offset + 2] & 0xff) << 16) | ((src[offset + 3] & 0xff) << 24);
	}

	public static void pokeInt(byte[] dst, int offset, int value, ByteOrder order) {
		if (order == ByteOrder.BIG_ENDIAN) {
			dst[offset] = (byte)(value >> 24);
			dst[offset + 1] = (byte)(value >> 16);
			dst[offset + 2] = (byte)(value >> 8);
			dst[offset + 3] = (byte)value;
		} else {
			dst[offset] = (byte)value;
			dst[offset + 1] = (byte)(value >> 8);
			dst[offset + 2] = (byte)(value >> 16);
			dst[offset + 3] = (byte)(value >> 24);
		}
	}
}
