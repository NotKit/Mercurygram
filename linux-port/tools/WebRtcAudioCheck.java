import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.media.audiofx.AcousticEchoCanceler;
import android.media.audiofx.AudioEffect;
import android.media.audiofx.NoiseSuppressor;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Drives android.media the way org.webrtc's Java audio device does.
 *
 * webrtc builds a 48 kHz mono 16-bit AudioTrack through AudioTrack.Builder,
 * writes 10 ms direct ByteBuffers into it and treats a short write as a fatal
 * error; it builds an AudioRecord the same way and reads 10 ms at a time. Both
 * refuse to start unless getState() is STATE_INITIALIZED, so the accessors have
 * to be honest either way: with no ALSA device this asserts the failure path
 * (STATE_UNINITIALIZED, no exception) instead.
 */
public class WebRtcAudioCheck {

	private static final int SAMPLE_RATE = 48000;
	private static final int FRAMES_PER_10MS = SAMPLE_RATE / 100;
	private static final int BYTES_PER_10MS = FRAMES_PER_10MS * 2; // mono PCM16
	private static final int BUFFERS = 5;

	private static int failures = 0;

	public static void main(String[] args) {
		checkAudioManager();
		checkEffects();
		checkAudioTrack();
		checkAudioRecord();

		if (failures != 0) {
			System.out.println("webrtc audio check: " + failures + " failure(s)");
			return;
		}
		System.out.println("webrtc audio check: passed");
	}

	/** AudioManager holds no state from its Context, so the check can build one. */
	private static void checkAudioManager() {
		AudioManager am = new AudioManager();

		expect("48000".equals(am.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)),
		    "PROPERTY_OUTPUT_SAMPLE_RATE=" + am.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE));
		expect("480".equals(am.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)),
		    "PROPERTY_OUTPUT_FRAMES_PER_BUFFER=" + am.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER));

		am.setMode(AudioManager.MODE_IN_COMMUNICATION);
		expect(am.getMode() == AudioManager.MODE_IN_COMMUNICATION, "getMode=" + am.getMode());
		am.setMode(AudioManager.MODE_NORMAL);
		expect(am.getMode() == AudioManager.MODE_NORMAL, "getMode back to " + am.getMode());

		expect(!am.isVolumeFixed(), "isVolumeFixed=" + am.isVolumeFixed());
		int max = am.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL);
		int volume = am.getStreamVolume(AudioManager.STREAM_VOICE_CALL);
		expect(max > 0, "getStreamMaxVolume=" + max);
		expect(volume >= 0 && volume <= max, "getStreamVolume=" + volume);
		expect(am.getActiveRecordingConfigurations() != null, "getActiveRecordingConfigurations is null");
		expect(am.generateAudioSessionId() != am.generateAudioSessionId(), "session ids repeat");

		System.out.println("AudioManager: rate=" + am.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)
		    + ", frames=" + am.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)
		    + ", volume=" + volume + "/" + max);
	}

	/** WebRtcAudioEffects must reach its "not available" path without throwing. */
	private static void checkEffects() {
		expect(!AcousticEchoCanceler.isAvailable(), "AEC claims to be available");
		expect(!NoiseSuppressor.isAvailable(), "NS claims to be available");
		expect(AcousticEchoCanceler.create(1) == null, "AEC.create returned an effect");
		expect(NoiseSuppressor.create(1) == null, "NS.create returned an effect");

		AudioEffect.Descriptor[] effects = AudioEffect.queryEffects();
		expect(effects != null && effects.length == 0, "queryEffects is not an empty array");
		// WebRtcAudioEffects compares descriptor types against these
		expect(AudioEffect.EFFECT_TYPE_AEC != null && AudioEffect.EFFECT_TYPE_NS != null,
		    "effect type UUIDs are null");

		System.out.println("audiofx: no effects, AEC/NS unavailable");
	}

	private static void checkAudioTrack() {
		int minBufferSize = AudioTrack.getMinBufferSize(
		    SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT);
		expect(minBufferSize >= BYTES_PER_10MS, "AudioTrack.getMinBufferSize=" + minBufferSize);

		AudioTrack track = new AudioTrack.Builder()
		    .setAudioAttributes(new AudioAttributes.Builder()
		        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
		        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
		        .build())
		    .setAudioFormat(new AudioFormat.Builder()
		        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
		        .setSampleRate(SAMPLE_RATE)
		        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
		        .build())
		    .setBufferSizeInBytes(Math.max(minBufferSize, BYTES_PER_10MS))
		    .setTransferMode(AudioTrack.MODE_STREAM)
		    .setSessionId(AudioManager.AUDIO_SESSION_ID_GENERATE)
		    .build();

		System.out.println("AudioTrack: state=" + track.getState()
		    + ", rate=" + track.getSampleRate() + ", channels=" + track.getChannelCount()
		    + ", buffer=" + track.getBufferSizeInFrames() + " frames"
		    + ", session=" + track.getAudioSessionId()
		    + ", maxVolume=" + AudioTrack.getMaxVolume());

		// true whether or not a PCM opened: these come from the construction parameters
		expect(track.getSampleRate() == SAMPLE_RATE, "getSampleRate=" + track.getSampleRate());
		expect(track.getChannelCount() == 1, "getChannelCount=" + track.getChannelCount());
		expect(track.getPlaybackRate() == SAMPLE_RATE, "getPlaybackRate=" + track.getPlaybackRate());
		expect(track.getBufferSizeInFrames() > 0, "getBufferSizeInFrames=" + track.getBufferSizeInFrames());
		expect(track.getBufferCapacityInFrames() >= track.getBufferSizeInFrames(), "capacity < size");
		expect(AudioTrack.getMaxVolume() == 1.0f, "getMaxVolume=" + AudioTrack.getMaxVolume());
		expect(track.getAudioSessionId() != 0, "getAudioSessionId=" + track.getAudioSessionId());

		if (track.getState() != AudioTrack.STATE_INITIALIZED) {
			// no ALSA device: the honest failure path, which is what webrtc reads
			expect(track.getState() == AudioTrack.STATE_UNINITIALIZED, "getState=" + track.getState());
			System.out.println("AudioTrack: no PCM, reported STATE_UNINITIALIZED");
			track.release();
			return;
		}

		track.play();
		expect(track.getPlayState() == AudioTrack.PLAYSTATE_PLAYING, "getPlayState=" + track.getPlayState());

		ByteBuffer buffer = ByteBuffer.allocateDirect(BYTES_PER_10MS);
		buffer.order(ByteOrder.nativeOrder());
		for (int i = 0; i < BUFFERS; i++) {
			buffer.rewind();
			int written = track.write(buffer, BYTES_PER_10MS, AudioTrack.WRITE_BLOCKING);
			expect(written == BYTES_PER_10MS, "write #" + i + " returned " + written);
			expect(buffer.position() == written, "write #" + i + " left position at " + buffer.position());
		}
		expect(track.getPlaybackHeadPosition() >= 0,
		    "getPlaybackHeadPosition=" + track.getPlaybackHeadPosition());

		System.out.println("AudioTrack: wrote " + BUFFERS + " x " + BYTES_PER_10MS + " bytes"
		    + ", head=" + track.getPlaybackHeadPosition()
		    + ", underruns=" + track.getUnderrunCount());

		track.stop();
		track.release();
		expect(track.getState() == AudioTrack.STATE_UNINITIALIZED, "released track still initialized");
	}

	private static void checkAudioRecord() {
		int minBufferSize = AudioRecord.getMinBufferSize(
		    SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
		expect(minBufferSize > 0, "AudioRecord.getMinBufferSize=" + minBufferSize);

		AudioRecord record = new AudioRecord.Builder()
		    .setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
		    .setAudioFormat(new AudioFormat.Builder()
		        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
		        .setSampleRate(SAMPLE_RATE)
		        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
		        .build())
		    .setBufferSizeInBytes(Math.max(2 * minBufferSize, BYTES_PER_10MS))
		    .build();

		System.out.println("AudioRecord: state=" + record.getState()
		    + ", rate=" + record.getSampleRate() + ", channels=" + record.getChannelCount()
		    + ", format=" + record.getAudioFormat()
		    + ", buffer=" + record.getBufferSizeInFrames() + " frames"
		    + ", source=" + record.getAudioSource());

		expect(record.getSampleRate() == SAMPLE_RATE, "getSampleRate=" + record.getSampleRate());
		expect(record.getChannelCount() == 1, "getChannelCount=" + record.getChannelCount());
		expect(record.getAudioFormat() == AudioFormat.ENCODING_PCM_16BIT,
		    "getAudioFormat=" + record.getAudioFormat());
		expect(record.getAudioSource() == MediaRecorder.AudioSource.VOICE_COMMUNICATION,
		    "getAudioSource=" + record.getAudioSource());
		expect(record.getBufferSizeInFrames() > 0, "getBufferSizeInFrames=" + record.getBufferSizeInFrames());

		AudioFormat format = record.getFormat();
		expect(format != null && format.getSampleRate() == SAMPLE_RATE && format.getChannelCount() == 1
		    && format.getEncoding() == AudioFormat.ENCODING_PCM_16BIT, "getFormat does not match");

		record.startRecording();
		if (record.getState() != AudioRecord.STATE_INITIALIZED) {
			// no capture device (or ATL_UGLY_ENABLE_MICROPHONE unset): the honest path
			expect(record.getState() == AudioRecord.STATE_UNINITIALIZED, "getState=" + record.getState());
			expect(record.getRecordingState() == AudioRecord.RECORDSTATE_STOPPED,
			    "uninitialized recorder claims to be recording");
			System.out.println("AudioRecord: no PCM, reported STATE_UNINITIALIZED");
			record.release();
			return;
		}

		expect(record.getRecordingState() == AudioRecord.RECORDSTATE_RECORDING,
		    "getRecordingState=" + record.getRecordingState());

		ByteBuffer buffer = ByteBuffer.allocateDirect(BYTES_PER_10MS);
		buffer.order(ByteOrder.nativeOrder());
		int read = record.read(buffer, buffer.capacity());
		expect(read == buffer.capacity(), "read returned " + read + " of " + buffer.capacity());
		System.out.println("AudioRecord: read " + read + " bytes");

		record.stop();
		record.release();
		expect(record.getState() == AudioRecord.STATE_UNINITIALIZED, "released recorder still initialized");
	}

	private static void expect(boolean ok, String message) {
		if (!ok) {
			failures++;
			System.out.println("FAIL: " + message);
		}
	}
}
