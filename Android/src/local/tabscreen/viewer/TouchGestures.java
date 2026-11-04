package local.tabscreen.viewer;

import android.view.MotionEvent;

import java.util.Locale;

/**
 * Turns touches on the picture into mouse actions for the Mac. With a finger: tap to click, touch and drag to drag,
 * touch and hold or tap with two fingers to right-click, drag with two fingers to scroll. A pen or mouse works
 * directly: the pointer follows it while it hovers, and it presses where it touches (its side button right-clicks).
 * Positions go from 0 to 1 across the extra display. Runs on the UI thread.
 */
final class TouchGestures {
    /** What the gestures need from the screen they run on. */
    interface Host {
        /** Whether the Mac takes touches now. If not, a touch calls {@link #touchedWhileOff} instead. */
        boolean touchEnabled();

        void touchedWhileOff();

        void send(String json);

        /** Runs the action after a delay on the UI thread, unless {@link #cancel} comes first. */
        void later(Runnable action, long delayMillis);

        void cancel(Runnable action);

        /** A short vibration, so a long press is felt. */
        void tick();
    }

    private static final int IDLE = 0;
    private static final int PENDING = 1;     // one finger down: tap, drag or long press isn't clear yet
    private static final int DRAGGING = 2;    // the left button is down and follows the finger
    private static final int HELD = 3;        // a long press right-clicked; the rest of this touch is ignored
    private static final int SCROLLING = 4;   // two fingers
    private static final int DIRECT = 5;      // a pen or mouse is pressing
    private static final int IGNORED = 6;     // touch control is off, or the touch began outside the picture

    private static final long TWO_FINGER_TAP_MILLIS = 300;

    private final Host host;
    private final float slop;                 // how far a finger may wander and still tap, in pixels
    private final long longPressMillis;

    private float left;                       // the picture on the screen, in pixels
    private float top;
    private float width;
    private float height;

    private int state = IDLE;
    private float downX;                      // where the touch began
    private float downY;
    private float lastX;                      // where the pointer was sent last
    private float lastY;
    private int directButton;                 // 0 left, 1 right: what a pen or mouse presses
    private float scrollX;                    // the two fingers' midpoint when the last scroll was sent
    private float scrollY;
    private float scrollStartX;
    private float scrollStartY;
    private long scrollStartTime;
    private boolean scrollMoved;
    private boolean scrollPlaceSent;
    private boolean anchorScroll;             // a finger lifted: the next midpoint is the new starting point

    TouchGestures(Host host, float slop, long longPressMillis) {
        this.host = host;
        this.slop = slop;
        this.longPressMillis = longPressMillis;
    }

    /** Where the picture is on the screen, in pixels. */
    void setVideoArea(float left, float top, float width, float height) {
        this.left = left;
        this.top = top;
        this.width = width;
        this.height = height;
    }

    /** Forgets a touch in progress (the connection is going away). */
    void reset() {
        host.cancel(longPress);
        state = IDLE;
    }

    boolean onTouch(MotionEvent event) {
        int pointers = event.getPointerCount();
        float x2 = pointers > 1 ? event.getX(1) : event.getX(0);
        float y2 = pointers > 1 ? event.getY(1) : event.getY(0);
        return touch(event.getActionMasked(), pointers, event.getX(0), event.getY(0), x2, y2, event.getEventTime(),
                event.getToolType(0), event.getButtonState());
    }

    /** A pen or mouse moving above the screen: the pointer follows it. */
    boolean onHover(MotionEvent event) {
        int action = event.getActionMasked();
        if (action != MotionEvent.ACTION_HOVER_MOVE && action != MotionEvent.ACTION_HOVER_ENTER) return false;
        return hover(event.getX(), event.getY());
    }

    /**
     * One step of a touch. x and y are the first finger, x2 and y2 the second (the same as the first when there is
     * only one), in pixels on the screen.
     */
    boolean touch(int action, int pointers, float x, float y, float x2, float y2, long time, int tool, int buttons) {
        switch (action) {
            case MotionEvent.ACTION_DOWN:
                begin(x, y, tool, buttons);
                return true;
            case MotionEvent.ACTION_POINTER_DOWN:
                if (state == PENDING || state == DRAGGING || state == HELD) startScrolling((x + x2) / 2, (y + y2) / 2, time);
                return true;
            case MotionEvent.ACTION_MOVE:
                move(pointers, x, y, x2, y2);
                return true;
            case MotionEvent.ACTION_POINTER_UP:
                if (state == SCROLLING) anchorScroll = true;
                return true;
            case MotionEvent.ACTION_UP:
                end(x, y, time);
                return true;
            case MotionEvent.ACTION_CANCEL:
                cancelTouch();
                return true;
            default:
                return false;
        }
    }

    boolean hover(float x, float y) {
        if (state != IDLE || !inside(x, y) || !host.touchEnabled()) return false;
        lastX = x;
        lastY = y;
        mouse("move", 0, x, y);
        return true;
    }

    private void begin(float x, float y, int tool, int buttons) {
        host.cancel(longPress);
        if (!inside(x, y)) {
            state = IGNORED;
            return;
        }
        if (!host.touchEnabled()) {
            state = IGNORED;
            host.touchedWhileOff();
            return;
        }
        downX = x;
        downY = y;
        lastX = x;
        lastY = y;
        if (tool == MotionEvent.TOOL_TYPE_STYLUS || tool == MotionEvent.TOOL_TYPE_MOUSE
                || tool == MotionEvent.TOOL_TYPE_ERASER) {
            directButton = (buttons & (MotionEvent.BUTTON_SECONDARY | MotionEvent.BUTTON_STYLUS_PRIMARY)) != 0 ? 1 : 0;
            state = DIRECT;
            mouse("down", directButton, x, y);
            return;
        }
        state = PENDING;
        host.later(longPress, longPressMillis);
    }

    private void move(int pointers, float x, float y, float x2, float y2) {
        switch (state) {
            case PENDING:
                if (distance(x - downX, y - downY) > slop) {
                    host.cancel(longPress);
                    state = DRAGGING;
                    mouse("down", 0, downX, downY);
                    lastX = x;
                    lastY = y;
                    mouse("move", 0, x, y);
                }
                break;
            case DRAGGING:
            case DIRECT:
                if (x != lastX || y != lastY) {
                    lastX = x;
                    lastY = y;
                    mouse("move", state == DIRECT ? directButton : 0, x, y);
                }
                break;
            case SCROLLING:
                if (pointers < 2) break;
                float midX = (x + x2) / 2;
                float midY = (y + y2) / 2;
                if (anchorScroll) {
                    anchorScroll = false;
                    scrollX = midX;
                    scrollY = midY;
                    break;
                }
                if (!scrollMoved) {
                    if (distance(midX - scrollStartX, midY - scrollStartY) <= slop) break;
                    scrollMoved = true;
                }
                if (midX != scrollX || midY != scrollY) {
                    scroll(midX - scrollX, midY - scrollY, midX, midY);
                    scrollX = midX;
                    scrollY = midY;
                }
                break;
            default:
                break;
        }
    }

    private void startScrolling(float midX, float midY, long time) {
        host.cancel(longPress);
        if (state == DRAGGING) mouse("up", 0, lastX, lastY);   // a second finger ends the drag
        state = SCROLLING;
        scrollX = midX;
        scrollY = midY;
        scrollStartX = midX;
        scrollStartY = midY;
        scrollStartTime = time;
        scrollMoved = false;
        scrollPlaceSent = false;
        anchorScroll = false;
    }

    private void end(float x, float y, long time) {
        host.cancel(longPress);
        switch (state) {
            case PENDING:   // a tap
                mouse("down", 0, downX, downY);
                mouse("up", 0, downX, downY);
                break;
            case DRAGGING:
                mouse("up", 0, x, y);
                break;
            case DIRECT:
                mouse("up", directButton, x, y);
                break;
            case SCROLLING:
                if (!scrollMoved && time - scrollStartTime <= TWO_FINGER_TAP_MILLIS) {   // a two-finger tap
                    mouse("down", 1, scrollStartX, scrollStartY);
                    mouse("up", 1, scrollStartX, scrollStartY);
                }
                break;
            default:
                break;
        }
        state = IDLE;
    }

    private void cancelTouch() {
        host.cancel(longPress);
        if (state == DRAGGING) {
            mouse("up", 0, lastX, lastY);
        } else if (state == DIRECT) {
            mouse("up", directButton, lastX, lastY);
        }
        state = IDLE;
    }

    private final Runnable longPress = new Runnable() {
        @Override
        public void run() {
            if (state != PENDING) return;
            state = HELD;
            host.tick();
            mouse("down", 1, downX, downY);
            mouse("up", 1, downX, downY);
        }
    };

    private void mouse(String action, int button, float x, float y) {
        host.send(String.format(Locale.US, "{\"type\":\"mouse\",\"a\":\"%s\",\"b\":%d,\"x\":%.5f,\"y\":%.5f}",
                action, button, across(x, left, width), across(y, top, height)));
    }

    /** Scrolls by the fingers' movement, as a share of the picture's size. The first one also says where they are. */
    private void scroll(float dx, float dy, float midX, float midY) {
        String place = "";
        if (!scrollPlaceSent) {
            scrollPlaceSent = true;
            place = String.format(Locale.US, ",\"x\":%.5f,\"y\":%.5f", across(midX, left, width), across(midY, top, height));
        }
        host.send(String.format(Locale.US, "{\"type\":\"scroll\",\"dx\":%.6f,\"dy\":%.6f%s}",
                dx / width, dy / height, place));
    }

    private boolean inside(float x, float y) {
        return width > 0 && height > 0 && x >= left && y >= top && x < left + width && y < top + height;
    }

    private static float across(float value, float start, float size) {
        float share = (value - start) / size;
        return share < 0 ? 0 : share > 1 ? 1 : share;
    }

    private static float distance(float dx, float dy) {
        return (float) Math.sqrt(dx * dx + dy * dy);
    }
}
