package local.tabscreen.viewer;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Rect;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.text.InputType;
import android.util.DisplayMetrics;
import android.util.TypedValue;
import android.view.Display;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONException;
import org.json.JSONObject;

import java.util.Locale;
import java.util.regex.Pattern;

/**
 * Shows the Mac's extra display full screen. TabScreen on the Mac opens this app when the tablet is plugged in over
 * USB; over Wi-Fi it connects once the Mac allows Wi-Fi connections.
 */
public final class MainActivity extends Activity implements SurfaceHolder.Callback {
    private static final String PREFS = "tabscreen";
    private static final String VERSION = "1.2";
    private static final Pattern KEY = Pattern.compile("[a-z0-9]{4,32}");
    private static final Pattern HOST = Pattern.compile("[A-Za-z0-9.-]{1,253}");

    private final Handler ui = new Handler(Looper.getMainLooper());

    private FrameLayout root;
    private SurfaceView videoView;
    private ImageView pointerView;
    private LinearLayout statusPanel;
    private TextView statusTitle;
    private TextView statusDetail;
    private Button primaryButton;
    private Button secondaryButton;
    private TextView badge;

    private VideoDecoder decoder;
    private StreamClient client;
    private int generation;          // tells events from an old connection apart from the current one
    private boolean resumed;
    private boolean surfaceReady;
    private boolean showingVideo;
    private boolean connectedOverUsb;
    private int problem;             // StreamClient.PROBLEM_… shown until something changes
    private float refreshRate = 60;

    private int videoWidth = 2304;
    private int videoHeight = 1440;
    private final Rect videoRect = new Rect();

    // Touches on the picture become clicks, drags and scrolling on the Mac once it allows them.
    private TouchGestures gestures;
    private String touchState = "";   // from the Mac: "on", "off", "permission", "nokey"; "" until it says
    private long lastTouchHint;

    // The pointer is drawn here, on top of the video, so it moves without waiting for new pictures.
    private boolean pointerVisible;
    private float pointerX;
    private float pointerY;
    private float displayPoints = 1152;
    private float hotX = 1.5f;
    private float hotY = 1.5f;
    private float pointerWidth = 17;
    private float pointerHeight = 25;
    private final Object pointerLock = new Object();
    private boolean pointerUpdatePending;
    private boolean nextVisible;
    private float nextX;
    private float nextY;
    private float nextDisplayPoints;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        configureWindow();
        buildViews();
        // Only a fresh start: a restored activity would re-apply the Mac's old values over newer ones.
        if (savedInstanceState == null) takeSettingsFrom(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        takeSettingsFrom(intent);
        // The Mac opened the app (the tablet was just plugged in): start over, cable first.
        problem = 0;
        if (client != null) reconnect();
    }

    @Override
    protected void onResume() {
        super.onResume();
        resumed = true;
        if (problem == StreamClient.PROBLEM_REPLACED) problem = 0;
        hideSystemBars();
        startIfReady();
    }

    @Override
    protected void onPause() {
        resumed = false;
        stopStreaming();
        super.onPause();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideSystemBars();
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        surfaceReady = true;
        suggestFrameRate(holder.getSurface());
        startIfReady();
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        // The decoder scales its pictures to whatever size the surface has.
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        surfaceReady = false;
        stopStreaming();   // the decoder must stop drawing before the surface goes away
    }

    // MARK: - Connection

    private void startIfReady() {
        if (!resumed || !surfaceReady || client != null) return;
        int id = ++generation;
        Events events = new Events(id);
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        String host = prefs.getString("wifiHost", null);
        String key = prefs.getString("wifiKey", null);
        if (problem == StreamClient.PROBLEM_WRONG_KEY || problem == StreamClient.PROBLEM_BLOCKED) {
            key = null;   // USB only until the key is fixed, so the Mac doesn't count more wrong keys
        }
        decoder = new VideoDecoder(videoView.getHolder().getSurface(), events, Math.round(refreshRate));
        client = new StreamClient(events, decoder, host, key, userAgent(), screenInfo());
        events.client = client;
        client.start();
        if (problem != 0) {
            showProblem(problem);
        } else {
            showStatus("Connecting to your Mac…", null, null, null, null, null);
        }
    }

    private void stopStreaming() {
        generation++;   // ignore whatever the old connection still reports
        StreamClient oldClient = client;
        VideoDecoder oldDecoder = decoder;
        client = null;
        decoder = null;
        if (oldClient != null) oldClient.stop();   // closes the connection; its thread ends by itself
        if (oldDecoder != null) oldDecoder.release();
        showingVideo = false;
        touchState = "";   // the next connection says again
        gestures.reset();
        pointerView.setVisibility(View.INVISIBLE);
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    private void reconnect() {
        stopStreaming();
        startIfReady();
    }

    private final Runnable reconnectAction = new Runnable() {
        @Override
        public void run() {
            problem = 0;
            reconnect();
        }
    };

    private final Runnable wifiSettingsAction = new Runnable() {
        @Override
        public void run() {
            showWifiDialog();
        }
    };

    /** Receives what the connection and the decoder report, and hands it to the UI thread. */
    private final class Events implements StreamClient.Listener, VideoDecoder.Callback {
        final int id;
        volatile StreamClient client;

        Events(int id) {
            this.id = id;
        }

        private void onUi(final Runnable action) {
            ui.post(new Runnable() {
                @Override
                public void run() {
                    if (id == generation) action.run();
                }
            });
        }

        @Override
        public void onSearching() {
            onUi(new Runnable() {
                @Override
                public void run() {
                    getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                    showSearching();
                }
            });
        }

        @Override
        public void onConnected(final boolean overUsb) {
            onUi(new Runnable() {
                @Override
                public void run() {
                    problem = 0;
                    connectedOverUsb = overUsb;
                    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                    showStatus("Connected", "Waiting for the picture…", null, null, null, null);
                }
            });
        }

        @Override
        public void onDisconnected() {
            onUi(new Runnable() {
                @Override
                public void run() {
                    showStatus("Connecting to your Mac…", null, null, null, null, null);
                }
            });
        }

        @Override
        public void onProblem(final int which) {
            onUi(new Runnable() {
                @Override
                public void run() {
                    problem = which;
                    getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                    showProblem(which);
                }
            });
        }

        @Override
        public void onVideoSize(final int width, final int height) {
            onUi(new Runnable() {
                @Override
                public void run() {
                    videoWidth = width;
                    videoHeight = height;
                    layoutVideo();
                }
            });
        }

        @Override
        public void onCursor(boolean visible, float x, float y, float displayWidth) {
            synchronized (pointerLock) {
                nextVisible = visible;
                nextX = x;
                nextY = y;
                if (displayWidth > 0) nextDisplayPoints = displayWidth;
                if (pointerUpdatePending) return;   // the UI thread picks up the newest position
                pointerUpdatePending = true;
            }
            ui.post(applyPointer);
        }

        @Override
        public void onCursorImage(final Bitmap image, final float hx, final float hy, final float width, final float height) {
            onUi(new Runnable() {
                @Override
                public void run() {
                    pointerView.setImageBitmap(image);
                    hotX = hx;
                    hotY = hy;
                    pointerWidth = width > 0 ? width : 17;
                    pointerHeight = height > 0 ? height : 25;
                    placePointer();
                }
            });
        }

        @Override
        public void onInputState(final String state) {
            onUi(new Runnable() {
                @Override
                public void run() {
                    touchState = state;
                }
            });
        }

        @Override
        public void onFirstFrame() {
            onUi(new Runnable() {
                @Override
                public void run() {
                    statusPanel.setVisibility(View.GONE);
                    showingVideo = true;
                    placePointer();
                    showBadge(connectedOverUsb ? "Connected over USB" : "Connected over Wi-Fi");
                }
            });
        }

        @Override
        public void onReport(String text) {
            StreamClient owner = client;
            if (owner != null) owner.sendLog(text);
        }

        @Override
        public void onDecoderFailed() {
            onUi(new Runnable() {
                @Override
                public void run() {
                    showStatus("Can’t show the video",
                            "This tablet’s video decoder didn’t start. Try again, or restart the tablet.",
                            "Try again", reconnectAction, null, null);
                }
            });
        }
    }

    private final Runnable applyPointer = new Runnable() {
        @Override
        public void run() {
            synchronized (pointerLock) {
                pointerUpdatePending = false;
                pointerVisible = nextVisible;
                pointerX = nextX;
                pointerY = nextY;
                if (nextDisplayPoints > 0) displayPoints = nextDisplayPoints;
            }
            placePointer();
        }
    };

    // MARK: - Screen

    private void configureWindow() {
        Window window = getWindow();
        window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN);
        WindowManager.LayoutParams attributes = window.getAttributes();
        if (Build.VERSION.SDK_INT >= 28) {
            try {
                // Use the whole screen, including any camera cutout (ALWAYS on Android 11+, SHORT_EDGES before).
                WindowManager.LayoutParams.class.getField("layoutInDisplayCutoutMode")
                        .setInt(attributes, Build.VERSION.SDK_INT >= 30 ? 3 : 1);
            } catch (Exception ignored) {
                // older layout rules
            }
        }
        try {
            // Run the screen at its fastest refresh rate (90 Hz on the Galaxy Tab S10 FE) so pictures show up sooner.
            Display display = getWindowManager().getDefaultDisplay();
            Display.Mode current = display.getMode();
            Display.Mode best = current;
            for (Display.Mode mode : display.getSupportedModes()) {
                if (mode.getPhysicalWidth() == current.getPhysicalWidth()
                        && mode.getPhysicalHeight() == current.getPhysicalHeight()
                        && mode.getRefreshRate() > best.getRefreshRate() + 0.5f) {
                    best = mode;
                }
            }
            attributes.preferredDisplayModeId = best.getModeId();
            refreshRate = best.getRefreshRate();
        } catch (Exception ignored) {
            // keep the default mode
        }
        window.setAttributes(attributes);
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                Window.class.getMethod("setDecorFitsSystemWindows", boolean.class).invoke(window, false);
            } catch (Exception ignored) {
                // older layout rules
            }
        }
    }

    private void hideSystemBars() {
        Window window = getWindow();
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                Object controller = Window.class.getMethod("getInsetsController").invoke(window);
                if (controller != null) {
                    Class<?> controllerClass = Class.forName("android.view.WindowInsetsController");
                    int systemBars = (Integer) Class.forName("android.view.WindowInsets$Type").getMethod("systemBars").invoke(null);
                    // Swiping from an edge shows the bars for a moment; they hide again by themselves.
                    controllerClass.getMethod("setSystemBarsBehavior", int.class).invoke(controller, 2);
                    controllerClass.getMethod("hide", int.class).invoke(controller, systemBars);
                    return;
                }
            } catch (Exception ignored) {
                // fall back to the older flags
            }
        }
        window.getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                | View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN);
    }

    /** Tells Android the video's frame rate, so the screen stays at its fastest refresh rate (Android 11+). */
    private void suggestFrameRate(Surface surface) {
        if (Build.VERSION.SDK_INT < 30 || surface == null) return;
        try {
            Surface.class.getMethod("setFrameRate", float.class, int.class).invoke(surface, refreshRate, 0);
        } catch (Exception ignored) {
            // only a hint
        }
    }

    private void buildViews() {
        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);

        videoView = new SurfaceView(this);
        videoView.getHolder().addCallback(this);
        root.addView(videoView, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT, Gravity.CENTER));

        pointerView = new ImageView(this);
        pointerView.setScaleType(ImageView.ScaleType.FIT_XY);
        pointerView.setImageBitmap(defaultPointer());
        pointerView.setVisibility(View.INVISIBLE);
        root.addView(pointerView, new FrameLayout.LayoutParams(dp(17), dp(25), Gravity.TOP | Gravity.LEFT));

        statusPanel = new LinearLayout(this);
        statusPanel.setOrientation(LinearLayout.VERTICAL);
        statusPanel.setGravity(Gravity.CENTER);
        statusPanel.setBackgroundColor(Color.BLACK);
        statusPanel.setPadding(dp(32), dp(32), dp(32), dp(32));
        statusPanel.setClickable(true);

        ImageView logo = new ImageView(this);
        logo.setImageResource(R.mipmap.ic_launcher);
        statusPanel.addView(logo, new LinearLayout.LayoutParams(dp(96), dp(96)));

        statusTitle = label(26, Color.WHITE);
        statusTitle.setPadding(0, dp(24), 0, 0);
        statusPanel.addView(statusTitle, wrap());

        statusDetail = label(17, 0xFFB4B4B4);
        statusDetail.setPadding(0, dp(12), 0, 0);
        statusDetail.setMaxWidth(dp(600));
        statusDetail.setLineSpacing(0, 1.25f);
        statusPanel.addView(statusDetail, wrap());

        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.HORIZONTAL);
        buttons.setGravity(Gravity.CENTER);
        buttons.setPadding(0, dp(24), 0, 0);
        primaryButton = new Button(this);
        secondaryButton = new Button(this);
        LinearLayout.LayoutParams spacing = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
        spacing.setMargins(dp(8), 0, dp(8), 0);
        buttons.addView(primaryButton, spacing);
        buttons.addView(secondaryButton, new LinearLayout.LayoutParams(spacing));
        statusPanel.addView(buttons, wrap());
        root.addView(statusPanel, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));

        badge = label(15, Color.WHITE);
        GradientDrawable pill = new GradientDrawable();
        pill.setColor(0xD9323232);
        pill.setCornerRadius(dp(999));
        badge.setBackground(pill);
        badge.setPadding(dp(18), dp(10), dp(18), dp(10));
        badge.setAlpha(0f);
        FrameLayout.LayoutParams badgePlace = new FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        badgePlace.bottomMargin = dp(28);
        root.addView(badge, badgePlace);

        root.addOnLayoutChangeListener(new View.OnLayoutChangeListener() {
            @Override
            public void onLayoutChange(View view, int left, int top, int right, int bottom,
                                       int oldLeft, int oldTop, int oldRight, int oldBottom) {
                if (right - left != oldRight - oldLeft || bottom - top != oldBottom - oldTop) {
                    root.post(new Runnable() {
                        @Override
                        public void run() {
                            layoutVideo();
                        }
                    });
                }
            }
        });
        gestures = new TouchGestures(new TouchGestures.Host() {
            @Override
            public boolean touchEnabled() {
                return showingVideo && client != null && "on".equals(touchState);
            }

            @Override
            public void touchedWhileOff() {
                showTouchHint();
            }

            @Override
            public void send(String json) {
                StreamClient current = client;
                if (current != null) current.sendInput(json);
            }

            @Override
            public void later(Runnable action, long delayMillis) {
                ui.postDelayed(action, delayMillis);
            }

            @Override
            public void cancel(Runnable action) {
                ui.removeCallbacks(action);
            }

            @Override
            public void tick() {
                root.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS);
            }
        }, ViewConfiguration.get(this).getScaledTouchSlop(), ViewConfiguration.getLongPressTimeout());
        root.setOnTouchListener(new View.OnTouchListener() {
            @Override
            public boolean onTouch(View view, MotionEvent event) {
                if (event.getActionMasked() == MotionEvent.ACTION_UP) hideSystemBars();   // if an edge swipe showed them
                return gestures.onTouch(event);
            }
        });
        root.setOnHoverListener(new View.OnHoverListener() {
            @Override
            public boolean onHover(View view, MotionEvent event) {
                return gestures.onHover(event);
            }
        });
        setContentView(root);
        showStatus("Connecting to your Mac…", null, null, null, null, null);
    }

    /** Fits the picture to the screen, keeping its shape. */
    private void layoutVideo() {
        int width = root.getWidth();
        int height = root.getHeight();
        if (width == 0 || height == 0 || videoWidth <= 0 || videoHeight <= 0) return;
        float ratio = (float) videoWidth / videoHeight;
        int w = width;
        int h = Math.round(width / ratio);
        if (h > height) {
            h = height;
            w = Math.round(height * ratio);
        }
        int left = (width - w) / 2;
        int top = (height - h) / 2;
        videoRect.set(left, top, left + w, top + h);
        gestures.setVideoArea(left, top, w, h);
        FrameLayout.LayoutParams place = (FrameLayout.LayoutParams) videoView.getLayoutParams();
        if (place.width != w || place.height != h) {
            place.width = w;
            place.height = h;
            place.gravity = Gravity.CENTER;
            videoView.setLayoutParams(place);
        }
        placePointer();
    }

    private void placePointer() {
        if (!pointerVisible || !showingVideo || videoRect.isEmpty()) {
            if (pointerView.getVisibility() != View.INVISIBLE) pointerView.setVisibility(View.INVISIBLE);
            return;
        }
        float scale = videoRect.width() / (displayPoints > 0 ? displayPoints : 1152f);
        int w = Math.max(1, Math.round(pointerWidth * scale));
        int h = Math.max(1, Math.round(pointerHeight * scale));
        ViewGroup.LayoutParams size = pointerView.getLayoutParams();
        if (size.width != w || size.height != h) {
            size.width = w;
            size.height = h;
            pointerView.setLayoutParams(size);
        }
        pointerView.setTranslationX(videoRect.left + pointerX * videoRect.width() - hotX * scale);
        pointerView.setTranslationY(videoRect.top + pointerY * videoRect.height() - hotY * scale);
        if (pointerView.getVisibility() != View.VISIBLE) pointerView.setVisibility(View.VISIBLE);
    }

    // MARK: - Messages

    private void showStatus(String title, String detail, String primary, Runnable primaryAction,
                            String secondary, Runnable secondaryAction) {
        statusTitle.setText(title);
        statusDetail.setText(detail);
        statusDetail.setVisibility(detail == null ? View.GONE : View.VISIBLE);
        setButton(primaryButton, primary, primaryAction);
        setButton(secondaryButton, secondary, secondaryAction);
        statusPanel.setVisibility(View.VISIBLE);
        showingVideo = false;
        placePointer();
    }

    private void setButton(Button button, String label, final Runnable action) {
        if (label == null) {
            button.setVisibility(View.GONE);
            return;
        }
        button.setText(label);
        button.setVisibility(View.VISIBLE);
        button.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View view) {
                action.run();
            }
        });
    }

    private void showSearching() {
        if (problem != 0) {
            showProblem(problem);
            return;
        }
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        String host = prefs.getString("wifiHost", null);
        String key = prefs.getString("wifiKey", null);
        String detail = "Plug this tablet into your Mac with a USB cable and make sure TabScreen is running on the Mac. "
                + "The Mac’s extra screen shows up here by itself.";
        if (host != null && key != null) {
            detail += "\n\nOver Wi-Fi: turn on “Allow Wi-Fi connection” in the TabScreen menu on your Mac "
                    + "(this tablet looks for it at " + host + ").";
        } else if (host != null) {
            detail += "\n\nOver Wi-Fi: the key is missing. Tap Wi-Fi settings and type the key shown in the TabScreen menu on your Mac.";
        }
        showStatus("Waiting for your Mac", detail, "Wi-Fi settings", wifiSettingsAction, null, null);
    }

    private void showProblem(int which) {
        if (which == StreamClient.PROBLEM_WRONG_KEY) {
            showStatus("The Wi-Fi key didn’t work",
                    "Open the TabScreen menu on your Mac, turn on “Allow Wi-Fi connection”, and type the key it shows. "
                            + "Or plug the tablet into the Mac once with a USB cable: that fills in the key by itself.",
                    "Wi-Fi settings", wifiSettingsAction, null, null);
        } else if (which == StreamClient.PROBLEM_BLOCKED) {
            showStatus("Too many wrong keys",
                    "Your Mac stopped accepting this tablet over Wi-Fi for 10 minutes. The USB cable still works.",
                    "Try again", reconnectAction, "Wi-Fi settings", wifiSettingsAction);
        } else if (which == StreamClient.PROBLEM_REPLACED) {
            showStatus("Showing somewhere else",
                    "Your Mac’s extra screen is open in another TabScreen window on this tablet (maybe Chrome).",
                    "Show it here", reconnectAction, null, null);
        }
    }

    private void showBadge(String text) {
        showBadge(text, 1800);
    }

    private void showBadge(String text, long showMillis) {
        badge.setText(text);
        badge.animate().cancel();
        badge.setAlpha(1f);
        badge.animate().alpha(0f).setStartDelay(showMillis).setDuration(500).start();
    }

    /** Says why touching the picture does nothing, at most every few seconds. */
    private void showTouchHint() {
        long now = SystemClock.uptimeMillis();
        if (now - lastTouchHint < 5000) return;
        lastTouchHint = now;
        String hint;
        if ("off".equals(touchState)) {
            hint = "To use touch, turn on Touch control in TabScreen’s menu on your Mac";
        } else if ("permission".equals(touchState)) {
            hint = "To use touch, allow TabScreen under Accessibility on your Mac";
        } else if ("nokey".equals(touchState)) {
            hint = "To use touch, unplug the cable and plug it in again";
        } else {
            hint = "Touch needs the newest TabScreen on your Mac";
        }
        showBadge(hint, 3500);
    }

    // MARK: - Wi-Fi settings

    private void showWifiDialog() {
        final SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        LinearLayout form = new LinearLayout(this);
        form.setOrientation(LinearLayout.VERTICAL);
        form.setPadding(dp(24), dp(8), dp(24), 0);

        TextView help = new TextView(this);
        help.setText("On your Mac, open the TabScreen menu and turn on “Allow Wi-Fi connection”. "
                + "It shows the Mac’s address and key.\n\n"
                + "Plugging this tablet into the Mac once with a USB cable fills these in by itself.");
        help.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        help.setPadding(0, 0, 0, dp(12));
        form.addView(help);

        final EditText hostField = new EditText(this);
        hostField.setHint("Mac address, like 192.168.1.20");
        hostField.setSingleLine(true);
        hostField.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        hostField.setText(prefs.getString("wifiHost", ""));
        form.addView(hostField);

        final EditText keyField = new EditText(this);
        keyField.setHint("Key, like k7m2xq");
        keyField.setSingleLine(true);
        keyField.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        keyField.setText(prefs.getString("wifiKey", ""));
        form.addView(keyField);

        AlertDialog dialog = new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert)
                .setTitle("Connect over Wi-Fi")
                .setView(form)
                .setPositiveButton("Save", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int which) {
                        saveWifiSettings(hostField.getText().toString(), keyField.getText().toString());
                    }
                })
                .setNeutralButton("Forget", new DialogInterface.OnClickListener() {
                    @Override
                    public void onClick(DialogInterface d, int which) {
                        prefs.edit().remove("wifiHost").remove("wifiKey").apply();
                        problem = 0;
                        reconnect();
                    }
                })
                .setNegativeButton("Cancel", null)
                .create();
        dialog.setOnDismissListener(new DialogInterface.OnDismissListener() {
            @Override
            public void onDismiss(DialogInterface d) {
                hideSystemBars();
            }
        });
        dialog.show();
    }

    private void saveWifiSettings(String hostText, String keyText) {
        String host = hostText.trim();
        String key = keyText.trim().toLowerCase(Locale.ROOT);
        // The browser address from the Mac's menu works too: http://192.168.1.20:7171/?k=k7m2xq
        if (host.contains("://") || host.contains("?")) {
            Uri address = Uri.parse(host.contains("://") ? host : "http://" + host);
            String k = address.getQueryParameter("k");
            if (k != null && key.isEmpty()) key = k.trim().toLowerCase(Locale.ROOT);
            host = address.getHost() != null ? address.getHost() : "";
        }
        int colon = host.indexOf(':');
        if (colon > 0) host = host.substring(0, colon);   // "192.168.1.20:7171"
        SharedPreferences.Editor editor = getSharedPreferences(PREFS, MODE_PRIVATE).edit();
        if (HOST.matcher(host).matches()) {
            editor.putString("wifiHost", host);
        } else {
            editor.remove("wifiHost");
        }
        if (!key.isEmpty()) {
            editor.putString("wifiKey", key);
        } else {
            editor.remove("wifiKey");
        }
        editor.apply();
        problem = 0;
        reconnect();
    }

    /** TabScreen on the Mac passes its Wi-Fi address and key when it opens the app over USB. */
    private void takeSettingsFrom(Intent intent) {
        if (intent == null) return;
        String host = intent.getStringExtra("wifiHost");
        String key = intent.getStringExtra("wifiKey");
        intent.removeExtra("wifiHost");   // used once; don't let a later restore apply them again
        intent.removeExtra("wifiKey");
        if (host == null || key == null || !isLocalNetworkAddress(host) || !KEY.matcher(key).matches()) return;
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        if (host.equals(prefs.getString("wifiHost", null)) && key.equals(prefs.getString("wifiKey", null))) return;
        prefs.edit().putString("wifiHost", host).putString("wifiKey", key).apply();
    }

    /** Only home/office network addresses are accepted from outside (10.x, 172.16–31.x, 192.168.x, 100.64–127.x). */
    private static boolean isLocalNetworkAddress(String host) {
        String[] parts = host.split("\\.");
        if (parts.length != 4) return false;
        int[] octets = new int[4];
        for (int i = 0; i < 4; i++) {
            if (parts[i].isEmpty() || parts[i].length() > 3) return false;
            try {
                octets[i] = Integer.parseInt(parts[i]);
            } catch (NumberFormatException e) {
                return false;
            }
            if (octets[i] < 0 || octets[i] > 255) return false;
        }
        return octets[0] == 10
                || (octets[0] == 172 && octets[1] >= 16 && octets[1] <= 31)
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127);
    }

    // MARK: - Helpers

    private String userAgent() {
        return "TabScreen app " + VERSION + " (Android " + Build.VERSION.RELEASE + "; " + Build.MANUFACTURER + " " + Build.MODEL + ")";
    }

    /**
     * This screen as the Mac needs it to shape the extra display: pixels (landscape), refresh rate, physical size,
     * a name, and the largest video the hardware decoder handles.
     */
    private JSONObject screenInfo() {
        JSONObject info = new JSONObject();
        try {
            DisplayMetrics metrics = new DisplayMetrics();
            getWindowManager().getDefaultDisplay().getRealMetrics(metrics);
            int width = Math.max(metrics.widthPixels, metrics.heightPixels);
            int height = Math.min(metrics.widthPixels, metrics.heightPixels);
            int refresh = Math.round(refreshRate);
            info.put("w", width);
            info.put("h", height);
            info.put("refresh", refresh);
            info.put("name", deviceName());
            float dpi = (metrics.xdpi + metrics.ydpi) / 2;
            boolean dpiLooksReal = Math.abs(metrics.xdpi - metrics.densityDpi) > 0.5f
                    || Math.abs(metrics.ydpi - metrics.densityDpi) > 0.5f;   // some devices just repeat the density bucket
            if (dpi > 50 && dpi < 1000 && dpiLooksReal) {
                info.put("mmW", Math.round(width / dpi * 25.4f));
                info.put("mmH", Math.round(height / dpi * 25.4f));
            }
            int[] video = VideoDecoder.largestVideo(width, height, refresh);
            if (video != null) {
                info.put("maxW", video[0]);
                info.put("maxH", video[1]);
                info.put("maxFps", video[2]);
            }
        } catch (JSONException ignored) {
            // only plain values go in
        }
        return info;
    }

    /** The name people know this device by ("Galaxy Tab S10 FE"), or its model. */
    private String deviceName() {
        String name = null;
        try {
            name = Settings.Global.getString(getContentResolver(), "device_name");
        } catch (Exception ignored) {
            // not available on this device
        }
        if (name == null || name.trim().isEmpty()) name = Build.MODEL;
        name = name.trim();
        return name.length() > 40 ? name.substring(0, 40) : name;
    }

    private TextView label(float sizeSp, int color) {
        TextView view = new TextView(this);
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, sizeSp);
        view.setTextColor(color);
        view.setGravity(Gravity.CENTER);
        return view;
    }

    private static LinearLayout.LayoutParams wrap() {
        return new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    private int dp(float value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    /** The arrow shown until the Mac sends the real pointer (same shape as the browser viewer's). */
    private static Bitmap defaultPointer() {
        float scale = 4;
        Bitmap bitmap = Bitmap.createBitmap(Math.round(17 * scale), Math.round(25 * scale), Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        canvas.scale(scale, scale);
        Path arrow = new Path();
        arrow.moveTo(1.5f, 1.5f);
        arrow.lineTo(1.5f, 20f);
        arrow.lineTo(6f, 15.8f);
        arrow.lineTo(9.2f, 23.2f);
        arrow.lineTo(12.2f, 21.9f);
        arrow.lineTo(9f, 14.6f);
        arrow.lineTo(15f, 14.6f);
        arrow.close();
        Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        fill.setColor(Color.BLACK);
        canvas.drawPath(arrow, fill);
        Paint outline = new Paint(Paint.ANTI_ALIAS_FLAG);
        outline.setStyle(Paint.Style.STROKE);
        outline.setStrokeWidth(1.5f);
        outline.setStrokeJoin(Paint.Join.ROUND);
        outline.setColor(Color.WHITE);
        canvas.drawPath(arrow, outline);
        return bitmap;
    }
}
