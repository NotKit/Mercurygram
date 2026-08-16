import android.graphics.Bitmap;
import android.graphics.SurfaceTexture;
import android.opengl.GLES20;
import android.opengl.GLUtils;
import javax.microedition.khronos.egl.EGL10;
import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.egl.EGLContext;
import javax.microedition.khronos.egl.EGLDisplay;
import javax.microedition.khronos.egl.EGLSurface;

/**
 * Renders into a SurfaceTexture with EGL and checks the frames come back out.
 *
 * This is the producer half TextureView needs: an app's GL thread asks for
 * eglCreateWindowSurface(SurfaceTexture) and swaps frames into it, and the view
 * takes them as bitmaps (getLatestFrameBitmap). Telegram's intro logo, the
 * camera preview, the photo editor and the spoiler and delete effects all
 * render this way. Uses the same EGL config IntroActivity asks for.
 */
public class SurfaceTextureGLCheck {

	private static final int WIDTH = 64, HEIGHT = 48;
	private static final int EGL_CONTEXT_CLIENT_VERSION = 0x3098;
	private static final int EGL_OPENGL_ES2_BIT = 4;
	private static int failures = 0;

	public static void main(String[] args) throws InterruptedException {
		/* on its own thread, the way every GL view in the app does it: the
		 * main thread is the one atlas draws the window from, and a GL context
		 * is current on it -- eglMakeCurrent from there fails with
		 * EGL_BAD_ACCESS */
		Thread renderer = new Thread(() -> {
			try {
				render();
			} catch (Throwable t) {
				t.printStackTrace(System.out);
				report("the render thread died");
			}
		}, "check-gl");
		renderer.start();
		renderer.join();

		if (failures != 0) {
			System.out.println("surface texture GL check: " + failures + " failure(s)");
			System.exit(1);
		}
		System.out.println("surface texture GL check: passed");
	}

	private static void render() {
		EGL10 egl = (EGL10)EGLContext.getEGL();

		EGLDisplay display = egl.eglGetDisplay(EGL10.EGL_DEFAULT_DISPLAY);
		if (display == EGL10.EGL_NO_DISPLAY)
			fail("eglGetDisplay: no display (" + error(egl) + ")");

		if (!egl.eglInitialize(display, new int[2]))
			fail("eglInitialize failed (" + error(egl) + ")");

		int[] configSpec = { /* IntroActivity.EGLThread.initGL() */
			EGL10.EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
			EGL10.EGL_RED_SIZE, 8,
			EGL10.EGL_GREEN_SIZE, 8,
			EGL10.EGL_BLUE_SIZE, 8,
			EGL10.EGL_ALPHA_SIZE, 8,
			EGL10.EGL_DEPTH_SIZE, 24,
			EGL10.EGL_STENCIL_SIZE, 0,
			EGL10.EGL_SAMPLE_BUFFERS, 1,
			EGL10.EGL_SAMPLES, 2,
			EGL10.EGL_NONE
		};
		EGLConfig[] configs = new EGLConfig[1];
		int[] configCount = new int[1];
		if (!egl.eglChooseConfig(display, configSpec, configs, 1, configCount) || configCount[0] < 1)
			fail("eglChooseConfig found no config (" + error(egl) + ")");

		EGLContext context = egl.eglCreateContext(display, configs[0], EGL10.EGL_NO_CONTEXT,
			new int[] {EGL_CONTEXT_CLIENT_VERSION, 2, EGL10.EGL_NONE});
		if (context == null || context == EGL10.EGL_NO_CONTEXT)
			fail("eglCreateContext failed (" + error(egl) + ")");

		/* detached, the way TextureView makes one: nothing samples it from GL */
		SurfaceTexture texture = new SurfaceTexture(false);
		texture.setDefaultBufferSize(WIDTH, HEIGHT);

		EGLSurface surface = egl.eglCreateWindowSurface(display, configs[0], texture, null);
		if (surface == null || surface == EGL10.EGL_NO_SURFACE)
			fail("eglCreateWindowSurface(SurfaceTexture) failed (" + error(egl) + ")");
		System.out.println("surface: created for a " + WIDTH + "x" + HEIGHT + " SurfaceTexture");

		if (!egl.eglMakeCurrent(display, surface, surface, context))
			fail("eglMakeCurrent failed (" + error(egl) + ")");

		/* the surface the app just made current must be the one EGL reports */
		if (!surface.equals(egl.eglGetCurrentSurface(EGL10.EGL_DRAW)))
			report("eglGetCurrentSurface does not report the surface that was made current");
		if (!context.equals(egl.eglGetCurrentContext()))
			report("eglGetCurrentContext does not report the context that was made current");

		/*
		 * Two frames, so the second proves the mailbox keeps moving. What is
		 * not checked here is onFrameAvailable: it is delivered on the main
		 * loop, which --run-class does not run. The boot run is what proves
		 * that half -- an intro logo that animates has gone all the way from
		 * the swap through the listener to TextureView.onDraw.
		 */
		checkFrame(egl, display, surface, texture, 0xff, 0x80, 0x00, "first");
		checkFrame(egl, display, surface, texture, 0x00, 0x40, 0xc0, "second");

		/*
		 * And a textured frame: every GL view here paints bitmaps (the intro's
		 * 24 logo textures, a camera frame, a sticker), and a texture upload
		 * that quietly lands nothing is invisible in exactly the same way an
		 * unimplemented surface is -- the app draws, no GL error, nothing
		 * appears (BRINGUP_NOTES.md).
		 */
		checkTexturedFrame(egl, display, surface, texture);

		egl.eglMakeCurrent(display, EGL10.EGL_NO_SURFACE, EGL10.EGL_NO_SURFACE, EGL10.EGL_NO_CONTEXT);
		egl.eglDestroySurface(display, surface);
		egl.eglDestroyContext(display, context);
		texture.release();
	}

	/** Fills the surface from a Bitmap through GLUtils.texImage2D. */
	private static void checkTexturedFrame(EGL10 egl, EGLDisplay display, EGLSurface surface,
	                                       SurfaceTexture texture) {
		final int color = 0xff20c040;
		Bitmap source = Bitmap.createBitmap(16, 16, Bitmap.Config.ARGB_8888);
		source.eraseColor(color);

		int[] names = new int[1];
		GLES20.glGenTextures(1, names, 0);
		GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, names[0]);
		GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_NEAREST);
		GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_NEAREST);
		GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, source, 0);

		int program = program(
			"attribute vec2 pos;\n" +
			"varying vec2 uv;\n" +
			"void main() { uv = pos * 0.5 + 0.5; gl_Position = vec4(pos, 0.0, 1.0); }\n",
			"precision mediump float;\n" +
			"uniform sampler2D tex;\n" +
			"varying vec2 uv;\n" +
			"void main() { gl_FragColor = texture2D(tex, uv); }\n");
		if (program == 0)
			return;

		java.nio.FloatBuffer quad = java.nio.ByteBuffer.allocateDirect(8 * 4)
			.order(java.nio.ByteOrder.nativeOrder()).asFloatBuffer();
		quad.put(new float[] {-1, -1, 1, -1, -1, 1, 1, 1}).position(0);

		GLES20.glUseProgram(program);
		GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "tex"), 0);
		GLES20.glViewport(0, 0, WIDTH, HEIGHT);
		GLES20.glClearColor(1f, 1f, 1f, 1f);
		GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
		int pos = GLES20.glGetAttribLocation(program, "pos");
		GLES20.glEnableVertexAttribArray(pos);
		GLES20.glVertexAttribPointer(pos, 2, GLES20.GL_FLOAT, false, 0, quad);
		GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4);

		int error = GLES20.glGetError();
		if (error != 0) {
			report("textured frame: GL error 0x" + Integer.toHexString(error));
			return;
		}
		if (!egl.eglSwapBuffers(display, surface)) {
			report("textured frame: eglSwapBuffers failed (" + error(egl) + ")");
			return;
		}

		Bitmap frame = texture.getLatestFrameBitmap();
		if (frame == null) {
			report("textured frame: nothing reached the SurfaceTexture");
			return;
		}
		int drawn = frame.getPixel(WIDTH / 2, HEIGHT / 2);
		if (!close(drawn, color)) {
			report("textured frame: the texture drew " + hex(drawn) + ", not the bitmap's " + hex(color)
				+ " (GLUtils.texImage2D uploading nothing?)");
			return;
		}
		System.out.println("textured frame: a " + hex(color) + " bitmap came back through GL");
	}

	/** A linked program, or 0 with the failure reported. */
	private static int program(String vertexSource, String fragmentSource) {
		int vertex = shader(GLES20.GL_VERTEX_SHADER, vertexSource);
		int fragment = shader(GLES20.GL_FRAGMENT_SHADER, fragmentSource);
		if (vertex == 0 || fragment == 0)
			return 0;

		int program = GLES20.glCreateProgram();
		GLES20.glAttachShader(program, vertex);
		GLES20.glAttachShader(program, fragment);
		GLES20.glLinkProgram(program);
		int[] linked = new int[1];
		GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linked, 0);
		if (linked[0] == 0) {
			report("link failed: " + GLES20.glGetProgramInfoLog(program));
			return 0;
		}
		return program;
	}

	private static int shader(int type, String source) {
		int shader = GLES20.glCreateShader(type);
		GLES20.glShaderSource(shader, source);
		GLES20.glCompileShader(shader);
		int[] compiled = new int[1];
		GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compiled, 0);
		if (compiled[0] == 0) {
			report("shader failed to compile: " + GLES20.glGetShaderInfoLog(shader));
			return 0;
		}
		return shader;
	}

	/** Clears the surface to one colour, swaps, and reads the frame back out. */
	private static void checkFrame(EGL10 egl, EGLDisplay display, EGLSurface surface,
	                               SurfaceTexture texture, int r, int g, int b, String which) {
		GLES20.glViewport(0, 0, WIDTH, HEIGHT);
		GLES20.glClearColor(r / 255f, g / 255f, b / 255f, 1f);
		GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT);
		if (!egl.eglSwapBuffers(display, surface)) {
			report(which + " frame: eglSwapBuffers failed (" + error(egl) + ")");
			return;
		}

		Bitmap frame = texture.getLatestFrameBitmap();
		if (frame == null) {
			report(which + " frame: nothing reached the SurfaceTexture");
			return;
		}
		if (frame.getWidth() != WIDTH || frame.getHeight() != HEIGHT) {
			report(which + " frame: " + frame.getWidth() + "x" + frame.getHeight()
				+ ", expected " + WIDTH + "x" + HEIGHT);
			return;
		}

		int expected = 0xff000000 | (r << 16) | (g << 8) | b;
		int wrong = 0, sample = 0;
		for (int y = 0; y < HEIGHT; y++) {
			for (int x = 0; x < WIDTH; x++) {
				int pixel = frame.getPixel(x, y);
				if (!close(pixel, expected)) {
					if (wrong == 0)
						sample = pixel;
					wrong++;
				}
			}
		}
		if (wrong != 0) {
			report(which + " frame: " + wrong + " of " + (WIDTH * HEIGHT) + " px wrong, e.g. "
				+ hex(sample) + " where " + hex(expected) + " was drawn");
			return;
		}
		System.out.println(which + " frame: " + WIDTH + "x" + HEIGHT + " of " + hex(expected) + " came back");
	}

	/** GL rounds through the framebuffer's bit depth, so allow a channel to be off by one. */
	private static boolean close(int actual, int expected) {
		for (int shift = 0; shift <= 24; shift += 8) {
			int diff = ((actual >> shift) & 0xff) - ((expected >> shift) & 0xff);
			if (diff < -1 || diff > 1)
				return false;
		}
		return true;
	}

	private static String error(EGL10 egl) {
		return "EGL error 0x" + Integer.toHexString(egl.eglGetError());
	}

	private static String hex(int color) {
		return String.format("#%08x", color);
	}

	private static void report(String message) {
		System.out.println("FAIL: " + message);
		failures++;
	}

	private static void fail(String message) {
		System.out.println("FAIL: " + message);
		System.out.println("surface texture GL check: 1 failure(s)");
		System.exit(1);
	}
}
