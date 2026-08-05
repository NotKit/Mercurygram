package org.telegram.ui.Components;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.recyclerview.widget.GridLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import org.telegram.messenger.AndroidUtilities;
import org.telegram.messenger.ContentHub;
import org.telegram.messenger.LocaleController;
import org.telegram.messenger.R;
import org.telegram.messenger.Utilities;
import org.telegram.ui.ActionBar.ActionBar;
import org.telegram.ui.ActionBar.Theme;

import java.util.ArrayList;
import java.util.Locale;

/**
 * The attach sheet's Gallery and File tabs on Ubuntu Touch, where a confined app
 * has no gallery to enumerate and no filesystem to browse. Instead of a media
 * grid this shows the apps content-hub says can supply the content — the same
 * source list Lomiri's own picker draws — and hands what they return to the
 * photo or document layout.
 */
public class ChatAttachAlertContentHubLayout extends ChatAttachAlert.AttachAlertLayout {

    public static final int MODE_MEDIA = 0;
    public static final int MODE_FILES = 1;

    // 12 + 64 icon + 8 + one line of label + 12, enough to guess the sheet height
    private static final int ROW_HEIGHT = 114;

    private final RecyclerListView listView;
    private final GridLayoutManager layoutManager;
    private final Adapter adapter;
    private final TextView emptyView;
    private final FrameLayout progressView;
    private final TextView progressTextView;

    private final ArrayList<ContentHub.Source> sources = new ArrayList<>();

    private int mode = MODE_MEDIA;
    private int itemsPerRow = 3;
    private boolean loading;
    private boolean loaded;
    /** An import is running: the source app has the screen, we only wait. */
    private boolean importing;

    public ChatAttachAlertContentHubLayout(ChatAttachAlert alert, Context context, Theme.ResourcesProvider resourcesProvider) {
        super(alert, context, resourcesProvider);

        listView = new RecyclerListView(context, resourcesProvider) {
            @Override
            public boolean onTouchEvent(MotionEvent e) {
                if (e.getAction() == MotionEvent.ACTION_DOWN && e.getY() < parentAlert.scrollOffsetY[0] - AndroidUtilities.dp(80)) {
                    return false;
                }
                return super.onTouchEvent(e);
            }

            @Override
            public boolean onInterceptTouchEvent(MotionEvent e) {
                if (e.getAction() == MotionEvent.ACTION_DOWN && e.getY() < parentAlert.scrollOffsetY[0] - AndroidUtilities.dp(80)) {
                    return false;
                }
                return super.onInterceptTouchEvent(e);
            }
        };
        listView.setAdapter(adapter = new Adapter());
        listView.setClipToPadding(false);
        listView.setItemAnimator(null);
        listView.setLayoutAnimation(null);
        listView.setVerticalScrollBarEnabled(false);
        listView.setGlowColor(getThemedColor(Theme.key_dialogScrollGlow));
        listView.setLayoutManager(layoutManager = new GridLayoutManager(context, itemsPerRow));
        listView.setOnScrollListener(new RecyclerView.OnScrollListener() {
            @Override
            public void onScrolled(RecyclerView recyclerView, int dx, int dy) {
                if (listView.getChildCount() <= 0) {
                    return;
                }
                parentAlert.updateLayout(ChatAttachAlertContentHubLayout.this, true, dy);
            }
        });
        listView.setOnItemClickListener((view, position) -> {
            if (importing || position < 0 || position >= sources.size()) {
                return;
            }
            startImport(sources.get(position));
        });
        addView(listView, LayoutHelper.createFrame(LayoutHelper.MATCH_PARENT, LayoutHelper.MATCH_PARENT));

        emptyView = new TextView(context);
        emptyView.setText(LocaleController.getString(R.string.MercurygramContentHubEmpty));
        emptyView.setTextSize(TypedValue.COMPLEX_UNIT_DIP, 16);
        emptyView.setTextColor(getThemedColor(Theme.key_dialogTextGray2));
        emptyView.setGravity(Gravity.CENTER);
        emptyView.setPadding(AndroidUtilities.dp(24), 0, AndroidUtilities.dp(24), 0);
        emptyView.setVisibility(GONE);
        addView(emptyView, LayoutHelper.createFrame(LayoutHelper.MATCH_PARENT, LayoutHelper.WRAP_CONTENT, Gravity.CENTER));

        progressView = new FrameLayout(context);
        progressView.setVisibility(GONE);
        addView(progressView, LayoutHelper.createFrame(LayoutHelper.MATCH_PARENT, LayoutHelper.MATCH_PARENT));

        LinearLayout progressContent = new LinearLayout(context);
        progressContent.setOrientation(LinearLayout.VERTICAL);
        progressContent.setGravity(Gravity.CENTER_HORIZONTAL);
        progressView.addView(progressContent, LayoutHelper.createFrame(LayoutHelper.WRAP_CONTENT, LayoutHelper.WRAP_CONTENT, Gravity.CENTER));

        RadialProgressView progress = new RadialProgressView(context, resourcesProvider);
        progressContent.addView(progress, LayoutHelper.createLinear(48, 48, Gravity.CENTER_HORIZONTAL));

        progressTextView = new TextView(context);
        progressTextView.setTextSize(TypedValue.COMPLEX_UNIT_DIP, 15);
        progressTextView.setTextColor(getThemedColor(Theme.key_dialogTextGray2));
        progressTextView.setGravity(Gravity.CENTER_HORIZONTAL);
        progressContent.addView(progressTextView, LayoutHelper.createLinear(LayoutHelper.WRAP_CONTENT, LayoutHelper.WRAP_CONTENT, Gravity.CENTER_HORIZONTAL, 0, 16, 0, 0));
    }

    public void setMode(int mode) {
        if (this.mode == mode) {
            return;
        }
        this.mode = mode;
        loaded = false;
        sources.clear();
        adapter.notifyDataSetChanged();
        // switching tabs while already up: there is no onShow to reload us
        if (parentAlert.getCurrentAttachLayout() == this) {
            applyTitle();
            loadSources();
        }
    }

    private void applyTitle() {
        parentAlert.actionBar.setTitle(LocaleController.getString(mode == MODE_FILES
            ? R.string.MercurygramContentHubFileTitle : R.string.MercurygramContentHubMediaTitle));
    }

    private void loadSources() {
        if (loading || loaded) {
            return;
        }
        loading = true;
        updateState();
        final int iconSize = AndroidUtilities.dp(72);
        final String[] types = mode == MODE_FILES
            ? new String[]{ContentHub.TYPE_DOCUMENTS, ContentHub.TYPE_ALL}
            : new String[]{ContentHub.TYPE_PICTURES, ContentHub.TYPE_VIDEOS};
        Utilities.globalQueue.postRunnable(() -> {
            ArrayList<ContentHub.Source> found = ContentHub.listSources(iconSize, types);
            AndroidUtilities.runOnUIThread(() -> {
                loading = false;
                loaded = true;
                sources.clear();
                sources.addAll(found);
                adapter.notifyDataSetChanged();
                updateState();
                if (!ContentHub.isEnabled() && !parentAlert.isDismissed()) {
                    parentAlert.onContentHubUnavailable(mode);
                }
            });
        });
    }

    private void startImport(ContentHub.Source source) {
        importing = true;
        progressTextView.setText(LocaleController.formatString(R.string.MercurygramContentHubWaiting, source.name));
        updateState();
        ContentHub.importFrom(source, paths -> {
            importing = false;
            updateState();
            if (parentAlert.isDismissed() || paths.isEmpty()) {
                return;
            }
            parentAlert.onContentHubImported(mode, paths);
        });
    }

    private void updateState() {
        progressView.setVisibility(loading || importing ? VISIBLE : GONE);
        listView.setVisibility(loading || importing ? GONE : VISIBLE);
        emptyView.setVisibility(!loading && !importing && sources.isEmpty() ? VISIBLE : GONE);
        if (loading) {
            progressTextView.setText(LocaleController.getString(R.string.Loading));
        }
    }

    @Override
    public void onShow(ChatAttachAlert.AttachAlertLayout previousLayout) {
        applyTitle();
        layoutManager.scrollToPositionWithOffset(0, 0);
        loadSources();
    }

    @Override
    public void scrollToTop() {
        listView.smoothScrollToPosition(0);
    }

    @Override
    public int needsActionBar() {
        return 1;
    }

    @Override
    public int getListTopPadding() {
        return listView.getPaddingTop();
    }

    @Override
    public int getCurrentItemTop() {
        if (listView.getChildCount() <= 0) {
            listView.setTopGlowOffset(listView.getPaddingTop());
            return Integer.MAX_VALUE;
        }
        View child = listView.getChildAt(0);
        RecyclerListView.Holder holder = (RecyclerListView.Holder) listView.findContainingViewHolder(child);
        int top = child.getTop();
        int newOffset = AndroidUtilities.dp(7);
        if (top >= AndroidUtilities.dp(7) && holder != null && holder.getAdapterPosition() == 0) {
            newOffset = top;
        }
        listView.setTopGlowOffset(newOffset);
        return newOffset;
    }

    @Override
    public int getFirstOffset() {
        return getListTopPadding() + AndroidUtilities.dp(56);
    }

    @Override
    public void setTranslationY(float translationY) {
        super.setTranslationY(translationY);
        parentAlert.getSheetContainer().invalidate();
        invalidate();
    }

    @Override
    public void onPreMeasure(int availableWidth, int availableHeight) {
        itemsPerRow = AndroidUtilities.isTablet() || availableWidth > availableHeight ? 4 : 3;
        layoutManager.setSpanCount(itemsPerRow);
        parentAlert.setAllowNestedScroll(true);

        // where the other layouts open, and as far down as this one may open
        int padding = !AndroidUtilities.isTablet() && AndroidUtilities.displaySize.x > AndroidUtilities.displaySize.y
            ? (int) (availableHeight / 3.5f) : (availableHeight / 5 * 2);
        // a handful of source apps fits without scrolling: open exactly that tall
        int rows = (int) Math.ceil(Math.max(1, sources.size()) / (float) itemsPerRow);
        padding = Math.max(0, Math.min(padding, availableHeight - rows * AndroidUtilities.dp(ROW_HEIGHT) - listPaddingBottom));
        padding += AndroidUtilities.statusBarHeight;
        listView.setPaddingWithoutRequestLayout(0, padding, 0, listPaddingBottom);
    }

    @Override
    public void checkColors() {
        emptyView.setTextColor(getThemedColor(Theme.key_dialogTextGray2));
        progressTextView.setTextColor(getThemedColor(Theme.key_dialogTextGray2));
        listView.setGlowColor(getThemedColor(Theme.key_dialogScrollGlow));
        adapter.notifyDataSetChanged();
    }

    private class Adapter extends RecyclerListView.SelectionAdapter {

        @Override
        public boolean isEnabled(RecyclerView.ViewHolder holder) {
            return true;
        }

        @Override
        public int getItemCount() {
            return sources.size();
        }

        @Override
        public RecyclerView.ViewHolder onCreateViewHolder(ViewGroup parent, int viewType) {
            SourceCell cell = new SourceCell(parent.getContext());
            cell.setLayoutParams(new RecyclerView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
            return new RecyclerListView.Holder(cell);
        }

        @Override
        public void onBindViewHolder(RecyclerView.ViewHolder holder, int position) {
            ((SourceCell) holder.itemView).setSource(sources.get(position));
        }
    }

    /** One source app: its icon over its name, sized to fill a grid cell. */
    private class SourceCell extends LinearLayout {

        private final IconView iconView;
        private final TextView nameView;

        public SourceCell(Context context) {
            super(context);
            setOrientation(VERTICAL);
            setGravity(Gravity.CENTER_HORIZONTAL);

            iconView = new IconView(context);
            addView(iconView, LayoutHelper.createLinear(64, 64, Gravity.CENTER_HORIZONTAL, 0, 12, 0, 0));

            nameView = new TextView(context);
            nameView.setTextSize(TypedValue.COMPLEX_UNIT_DIP, 14);
            nameView.setTextColor(getThemedColor(Theme.key_dialogTextBlack));
            nameView.setGravity(Gravity.CENTER_HORIZONTAL);
            nameView.setMaxLines(2);
            nameView.setPadding(AndroidUtilities.dp(4), 0, AndroidUtilities.dp(4), 0);
            addView(nameView, LayoutHelper.createLinear(LayoutHelper.MATCH_PARENT, LayoutHelper.WRAP_CONTENT, Gravity.CENTER_HORIZONTAL, 0, 8, 0, 12));
        }

        public void setSource(ContentHub.Source source) {
            iconView.setSource(source);
            nameView.setTextColor(getThemedColor(Theme.key_dialogTextBlack));
            nameView.setText(source.name);
        }
    }

    /** The peer's icon, rounded off the way Lomiri rounds app icons. */
    private class IconView extends View {

        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint textPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF bounds = new RectF();
        private final Path shape = new Path();

        private ContentHub.Source source;
        private String letter = "?";

        public IconView(Context context) {
            super(context);
            textPaint.setTextAlign(Paint.Align.CENTER);
            textPaint.setTypeface(AndroidUtilities.bold());
        }

        public void setSource(ContentHub.Source source) {
            this.source = source;
            letter = source.name == null || source.name.isEmpty()
                ? "?" : source.name.substring(0, 1).toUpperCase(Locale.ROOT);
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            if (source == null) {
                return;
            }
            bounds.set(0, 0, getWidth(), getHeight());
            float radius = getWidth() / 6f;
            if (source.icon != null) {
                shape.reset();
                shape.addRoundRect(bounds, radius, radius, Path.Direction.CW);
                canvas.save();
                canvas.clipPath(shape);
                canvas.drawBitmap(source.icon, null, bounds, paint);
                canvas.restore();
                return;
            }
            paint.setColor(getThemedColor(Theme.key_chat_attachEmptyImage));
            canvas.drawRoundRect(bounds, radius, radius, paint);
            textPaint.setColor(getThemedColor(Theme.key_dialogTextGray2));
            textPaint.setTextSize(getHeight() * 0.45f);
            Paint.FontMetrics metrics = textPaint.getFontMetrics();
            canvas.drawText(letter, getWidth() / 2f, (getHeight() - metrics.ascent - metrics.descent) / 2f, textPaint);
        }
    }
}
