import android.accessibilityservice.AccessibilityService;
import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Base64;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.concurrent.ThreadLocalRandom;
import java.io.File;

public final class ThreadsReader {
    private static final String PACKAGE = "com.instagram.barcelona";
    private static final int LIMIT = 10;
    private static final int MAX_SWIPES = 24;
    private static final int AUTO_MAX_SWIPES = 90;

    public static void main(String[] args) throws Exception {
        boolean scrollOnly = args.length > 0 && args[0].equals("scroll");
        boolean autoFeed = args.length > 0 && args[0].equals("auto_feed");
        boolean refresh = args.length > 0 && args[0].equals("refresh");
        boolean afterPost = args.length > 0 && args[0].equals("home_after_post");
        boolean action = args.length == 2 && args[0].equals("action");
        boolean profile = args.length == 2 && args[0].equals("profile");
        AccessibilitySession.run(automation -> {
            JSONObject result;
            if (action || profile) {
                JSONObject request = new JSONObject(new String(Base64.decode(args[1], Base64.DEFAULT), StandardCharsets.UTF_8));
                result = profile ? updateProfile(automation, request) : perform(automation, request);
            } else {
                if (autoFeed) openFeed(automation);
                if (afterPost) result = homeAfterPost(automation);
                else if (refresh) result = refreshFeed(automation);
                else if (scrollOnly) result = scroll(automation);
                else result = read(automation, ThreadLocalRandom.current().nextInt(5, 11));
            }
            System.out.println(result);
        });
    }

    private static JSONObject perform(UiAutomation automation, JSONObject request) throws Exception {
        String action = request.getString("action");
        if (action.equals("submit_reply")) return submitReply(automation, request);
        if (action.equals("attach_reply")) return attachReply(automation, request);
        if (action.equals("select_reply_photos")) return selectReplyPhotos(automation, request);
        String target = request.getString("id");
        boolean stable = request.optBoolean("stable");
        boolean forward = request.optBoolean("forward");
        String reply = request.optString("reply").trim();
        String control;
        switch (action) {
            case "like": control = "like"; break;
            case "repost": control = "repost"; break;
            case "reply": control = "reply"; break;
            case "photo_reply": control = "reply"; break;
            case "locate": control = ""; break;
            default: return outcome("unsupported");
        }
        if (action.equals("reply") && (reply.isEmpty() || reply.codePointCount(0, reply.length()) > 500)) {
            return outcome("invalid_reply");
        }
        if (stable) openFeed(automation);

        int legLimit = stable ? AUTO_MAX_SWIPES : MAX_SWIPES;
        int maxSwipes = stable ? legLimit * 2 : legLimit;
        long deadline = SystemClock.uptimeMillis() + 100_000;
        String previousViewport = "";
        int unchanged = 0;
        boolean reversed = false;
        for (int step = 0; step <= maxSwipes; step++) {
            if (SystemClock.uptimeMillis() >= deadline) break;
            AccessibilityNodeInfo feed = getFeed(automation);
            if (feed == null) return outcome("feed_unavailable");
            Post match = null;
            for (Post candidate : visiblePosts(feed)) {
                if (!candidate.isReadable() || (stable && (candidate.isReply || candidate.text.isEmpty()))
                        || !candidate.token(stable).equals(target)) continue;
                if (match != null) return outcome("ambiguous");
                match = candidate;
            }
            if (match != null) {
                if (action.equals("locate")) return outcome("located").put("controls", new JSONArray(match.controls.keySet()));
                AccessibilityNodeInfo button = match.controls.get(control);
                if (button == null && match.body != null && click(match.body)) {
                    SystemClock.sleep(550);
                    Post detail = detailPost(automation);
                    if (detail == null || !match.sameContent(detail)) return outcome("target_changed");
                    button = detail.controls.get(control);
                }
                if (button == null) return outcome("control_unavailable");
                if (action.equals("like")) return like(automation, match, button);
                if (action.equals("repost")) return repost(automation, button);
                progress("opening_composer", 0, 0);
                return prepareReply(automation, match, button);
            }
            String currentViewport = viewport(feed);
            unchanged = !currentViewport.isEmpty() && currentViewport.equals(previousViewport) ? unchanged + 1 : 0;
            previousViewport = currentViewport;
            boolean atTop = !forward && isFeedAtTop(feed);
            if (atTop || unchanged >= 2 || (stable && step == legLimit && !reversed)) {
                if (reversed) break;
                forward = !forward;
                reversed = true;
                unchanged = 0;
                previousViewport = "";
            }
            if (step == maxSwipes || !swipe(automation, bounds(feed), forward)) break;
            progress(action.equals("like") ? "locating_like" : "locating_reply", step + 1, 0);
            SystemClock.sleep(ThreadLocalRandom.current().nextLong(300, 601));
        }
        return outcome("not_found");
    }

    private static JSONObject like(UiAutomation automation, Post target, AccessibilityNodeInfo button) throws JSONException {
        if (liked(button)) return outcome("already_liked");
        progress("liking", 0, 0);
        String label = string(button.getContentDescription()).toLowerCase(Locale.ROOT);
        if (!label.startsWith("like") && !label.startsWith("thích")) return outcome("control_unavailable");
        if (!press(automation, button)) return outcome("control_unavailable");
        for (int attempt = 0; attempt < 6; attempt++) {
            SystemClock.sleep(160);
            if (button.refresh() && liked(button)) return outcome("liked");
            AccessibilityNodeInfo feed = getFeed(automation);
            Post detail = feed == null ? detailPost(automation) : null;
            List<Post> posts = feed != null ? visiblePosts(feed)
                : detail == null ? java.util.Collections.emptyList() : java.util.Collections.singletonList(detail);
            for (Post post : posts) {
                AccessibilityNodeInfo current = post.controls.get("like");
                if (current != null && target.sameContent(post) && liked(current)) return outcome("liked");
            }
        }
        return outcome("unverified");
    }

    private static boolean liked(AccessibilityNodeInfo button) {
        String label = string(button.getContentDescription()).toLowerCase(Locale.ROOT);
        return label.startsWith("unlike") || label.startsWith("bỏ thích") || label.startsWith("đã thích");
    }

    private static JSONObject repost(UiAutomation automation, AccessibilityNodeInfo button) throws JSONException {
        if (!press(automation, button)) return outcome("control_unavailable");
        for (int attempt = 0; attempt < 6; attempt++) {
            SystemClock.sleep(180);
            AccessibilityNodeInfo root = threadsRoot(automation);
            AccessibilityNodeInfo option = find(root, "repost_menu_repost_button");
            if (option == null) continue;
            if (findLabel(option, "Remove repost", "Undo repost", "Gỡ bài đăng lại") != null) {
                automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK);
                return outcome("already_reposted");
            }
            if (findLabel(option, "Repost only", "Repost", "Đăng lại") != null
                    && press(automation, option)) return outcome("repost_requested");
        }
        return outcome("repost_menu_unavailable");
    }

    private static JSONObject prepareReply(UiAutomation automation, Post match, AccessibilityNodeInfo button)
            throws Exception {
        if (!press(automation, button)) return outcome("control_unavailable");
        AccessibilityNodeInfo editor = null;
        for (int attempt = 0; attempt < 10 && editor == null; attempt++) {
            SystemClock.sleep(160);
            AccessibilityNodeInfo root = threadsRoot(automation);
            if (fullReplyScreen(root)) {
                return prepareFullReply(automation, match);
            }
            AccessibilityNodeInfo detail = find(root, "PermalinkScreen");
            Post displayed = detailPost(detail);
            if (displayed != null && match.sameContent(displayed)) editor = find(detail, "permalink_inline_composer");
        }
        if (editor == null) return outcome("composer_unavailable");
        if (!string(editor.getText()).isEmpty()) return outcome("draft_exists");
        if (!press(automation, editor)) return outcome("control_unavailable");
        for (int attempt = 0; attempt < 12; attempt++) {
            SystemClock.sleep(180);
            AccessibilityNodeInfo root = threadsRoot(automation);
            if (fullReplyScreen(root)) return prepareFullReply(automation, match);
            AccessibilityNodeInfo detail = find(root, "PermalinkScreen");
            editor = find(detail, "permalink_inline_composer");
            if (editor == null) continue;
            if (!string(editor.getText()).isEmpty()) return outcome("draft_exists");
            String context = replyContext(detail, match.author);
            if (context != null) {
                return outcome("reply_ready").put("target", context).put("author", match.author).put("composer", "inline")
                    .put("postID", match.token(true));
            }
        }
        return outcome("target_changed");
    }

    private static JSONObject prepareFullReply(UiAutomation automation, Post match) throws Exception {
        // Large quoted photos can put the editor below the keyboard's visible viewport.
        hideKeyboard(automation);
        AccessibilityNodeInfo editor = waitFor(automation, "new_thread_screen_composer");
        if (editor == null) return outcome("composer_unavailable");
        if (!string(editor.getText()).isEmpty()) return outcome("draft_exists");
        if (composerCarousel(editor) != null) return outcome("draft_exists");
        Post quoted = inspectFullReplyPost(automation);
        for (int attempt = 0; attempt < 6 && (quoted == null || !match.sameContent(quoted)); attempt++) {
            SystemClock.sleep(180);
            quoted = fullReplyPost(threadsRoot(automation));
        }
        if (quoted == null || !match.sameContent(quoted)) return targetMismatch("prepare_full", match, quoted);
        editor = revealFullReplyEditor(automation);
        if (editor == null || !press(automation, editor)) return outcome("composer_unavailable");
        editor = waitFor(automation, "new_thread_screen_composer");
        if (editor == null) return outcome("composer_unavailable");
        if (!string(editor.getText()).isEmpty()) return outcome("draft_exists");
        return outcome("reply_ready").put("target", quoted.token(true)).put("author", quoted.author)
            .put("composer", "full").put("postID", quoted.token(true));
    }

    private static void hideKeyboard(UiAutomation automation) {
        for (AccessibilityWindowInfo window : automation.getWindows()) {
            if (window.getType() != AccessibilityWindowInfo.TYPE_INPUT_METHOD) continue;
            AccessibilityNodeInfo keyboard = window.getRoot();
            if (keyboard != null && keyboard.isVisibleToUser()) {
                automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK);
                SystemClock.sleep(450);
                return;
            }
        }
    }

    private static Post fullReplyPost(AccessibilityNodeInfo root) {
        if (!fullReplyScreen(root)) return null;
        List<Post> posts = visiblePosts(root);
        return posts.isEmpty() ? null : posts.get(0);
    }

    private static AccessibilityNodeInfo fullReplyScroll(AccessibilityNodeInfo node) {
        if (node == null || !node.isVisibleToUser()) return null;
        if (node.isScrollable() && string(node.getClassName()).equals("android.widget.ScrollView")) return node;
        for (int index = 0; index < node.getChildCount(); index++) {
            AccessibilityNodeInfo scroll = fullReplyScroll(node.getChild(index));
            if (scroll != null) return scroll;
        }
        return null;
    }

    private static Post inspectFullReplyPost(UiAutomation automation) {
        for (int attempt = 0; attempt < 10; attempt++) {
            AccessibilityNodeInfo root = threadsRoot(automation);
            if (!fullReplyScreen(root)) return null;
            AccessibilityNodeInfo scroll = fullReplyScroll(root);
            if (scroll == null || !scroll.performAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD)) break;
            SystemClock.sleep(250);
        }
        return fullReplyPost(threadsRoot(automation));
    }

    private static AccessibilityNodeInfo revealFullReplyEditor(UiAutomation automation) {
        for (int attempt = 0; attempt < 10; attempt++) {
            AccessibilityNodeInfo root = threadsRoot(automation);
            if (!fullReplyScreen(root)) return null;
            AccessibilityNodeInfo editor = find(root, "new_thread_screen_composer");
            if (editor != null) return editor;
            AccessibilityNodeInfo scroll = fullReplyScroll(root);
            if (scroll == null || !scroll.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)) return null;
            SystemClock.sleep(250);
        }
        return null;
    }

    private static boolean fullReplyScreen(AccessibilityNodeInfo root) {
        return findLabel(find(root, "navigation_bar_title"), "Reply", "Trả lời") != null
            && find(root, "PermalinkScreen") == null;
    }

    private static JSONObject submitReply(UiAutomation automation, JSONObject request) throws Exception {
        String reply = request.optString("reply").trim();
        boolean withPhoto = request.optBoolean("withPhoto");
        if ((!withPhoto && reply.isEmpty()) || reply.codePointCount(0, reply.length()) > 500) {
            return outcome("invalid_reply");
        }
        String target = request.getString("target");
        String author = request.getString("author");
        if (request.optString("composer").equals("full")) {
            AccessibilityNodeInfo editor = find(threadsRoot(automation), "new_thread_screen_composer");
            if (editor == null) return outcome("composer_unavailable");
            if (!hasDraft(editor, reply)) return outcome("draft_failed");
            hideKeyboard(automation);
            Post quoted = inspectFullReplyPost(automation);
            if (quoted == null || !quoted.author.equals(author) || !quoted.token(true).equals(target)) {
                return outcome("target_changed");
            }
            editor = revealFullReplyEditor(automation);
            if (editor == null || !hasDraft(editor, reply)) return outcome("draft_failed");
            if (request.optInt("photoCount") == 3 && !hasThreePhotos(automation)) return outcome("photos_changed");
            AccessibilityNodeInfo root = threadsRoot(automation);
            if (withPhoto) return openReplyGallery(automation, root);
            AccessibilityNodeInfo submit = find(root, "new_thread_screen_post_button");
            if (submit == null) return outcome("composer_unavailable");
            progress("sending_reply", 0, 0);
            if (!press(automation, submit)) return outcome("draft_failed");
            return outcome("reply_submitted");
        }
        for (int attempt = 0; attempt < 8; attempt++) {
            SystemClock.sleep(180);
            AccessibilityNodeInfo detail = find(threadsRoot(automation), "PermalinkScreen");
            AccessibilityNodeInfo editor = find(detail, "permalink_inline_composer");
            AccessibilityNodeInfo submit = find(detail, "permalink_inline_composer_post_button");
            if (editor == null || !target.equals(replyContext(detail, author))) return outcome("target_changed");
            if (withPhoto && hasDraft(editor, reply)) {
                return openReplyGallery(automation, detail);
            }
            if (submit != null && hasDraft(editor, reply)) {
                progress("sending_reply", 0, 0);
                if (!press(automation, submit)) return outcome("draft_failed");
                return outcome("reply_submitted");
            }
        }
        return outcome("draft_failed");
    }

    /** The composer holds typed text. Its exact content is not compared with the requested reply. */
    private static boolean hasDraft(AccessibilityNodeInfo editor, String reply) {
        boolean hint = android.os.Build.VERSION.SDK_INT >= 26 && editor.isShowingHintText();
        String text = hint ? "" : string(editor.getText()).trim();
        return reply.isEmpty() ? text.isEmpty() : !text.isEmpty();
    }

    private static AccessibilityNodeInfo composerCarousel(AccessibilityNodeInfo editor) {
        return editor == null ? null : find(editor.getParent(), "IgLazyRow");
    }

    private static boolean hasThreePhotos(UiAutomation automation) {
        AccessibilityNodeInfo editor = find(threadsRoot(automation), "new_thread_screen_composer");
        AccessibilityNodeInfo container = editor == null ? null : editor.getParent();
        for (int attempt = 0; attempt < 8; attempt++) {
            AccessibilityNodeInfo root = threadsRoot(automation);
            if (!fullReplyScreen(root)) return false;
            if (container == null || !container.refresh()) return false;
            AccessibilityNodeInfo row = find(container, "IgLazyRow");
            if (row != null) return row.getChildCount() == 3;
            AccessibilityNodeInfo scroll = fullReplyScroll(root);
            if (scroll == null || !scroll.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)) return false;
            SystemClock.sleep(250);
        }
        return false;
    }

    private static JSONObject attachReply(UiAutomation automation, JSONObject request) throws Exception {
        String reply = request.getString("reply");
        String author = request.getString("author");
        String postID = request.getString("postID");
        AccessibilityNodeInfo root = threadsRoot(automation);
        AccessibilityNodeInfo editor = replyEditor(root);
        if (editor == null || !hasDraft(editor, reply)) return outcome("draft_failed");
        if (composerCarousel(editor) != null) return outcome("draft_exists");
        if (fullReplyScreen(root)) {
            hideKeyboard(automation);
            Post quoted = inspectFullReplyPost(automation);
            if (quoted == null || !author.equals(quoted.author) || !postID.equals(quoted.token(true))) return outcome("target_changed");
            editor = revealFullReplyEditor(automation);
            root = threadsRoot(automation);
        } else if (!request.getString("target").equals(replyContext(root, author))) return outcome("target_changed");
        if (editor == null || !hasDraft(editor, reply)) return outcome("draft_failed");
        progress("opening_photos", 0, 3);
        return openReplyGallery(automation, root);
    }

    private static JSONObject selectReplyPhotos(UiAutomation automation, JSONObject request) throws Exception {
        String reply = request.getString("reply");
        String author = request.getString("author");
        String postID = request.getString("postID");
        if (request.getJSONObject("photos").getJSONArray("ids").length() != 3) return outcome("photos_changed");
        SystemClock.sleep(1_000);
        AccessibilityNodeInfo root = threadsRoot(automation);
        AccessibilityNodeInfo recents = findLabel(root, "Recents", "Gần đây");
        if (recents == null || findLabel(find(root, "navigation_bar_title"), "Gallery", "Thư viện") == null) return outcome("photos_changed");
        Rect screen = bounds(root);
        if (screen.width() >= screen.height() || screen.width() < 300) return outcome("photos_failed");
        int cell = screen.width() / 3;
        int gridTop = bounds(recents).bottom + screen.width() / 40;
        // Threads' native grid has no Accessibility children. Recents has a camera tile
        // followed by the three MediaStore IDs verified above. Select them in that order.
        for (int index = 0; index < 3; index++) {
            root = threadsRoot(automation);
            if (findLabel(find(root, "navigation_bar_title"), "Gallery", "Thư viện") == null) return outcome("photos_failed");
            int position = index + 1;
            int x = screen.left + position % 3 * cell + cell / 2;
            int y = gridTop + position / 3 * cell + cell / 2;
            if (!tapPoint(automation, x, y)) return outcome("photos_failed");
            progress("selecting_photos", index + 1, 3);
            SystemClock.sleep(ThreadLocalRandom.current().nextLong(300, 551));
        }
        AccessibilityNodeInfo done = findLabel(threadsRoot(automation), "Done", "Xong");
        if (done == null || !press(automation, done)) return outcome("photos_failed");
        for (int attempt = 0; attempt < 60; attempt++) {
            SystemClock.sleep(300);
            root = threadsRoot(automation);
            if (fullReplyScreen(root) && find(root, "new_thread_screen_composer") != null) break;
        }
        hideKeyboard(automation);
        Post quoted = inspectFullReplyPost(automation);
        if (quoted == null || !author.equals(quoted.author) || !postID.equals(quoted.token(true))) return outcome("target_changed");
        AccessibilityNodeInfo editor = revealFullReplyEditor(automation);
        if (editor == null || !hasDraft(editor, reply)) return outcome("draft_failed");
        if (!hasThreePhotos(automation)) return outcome("photos_failed");
        progress("photos_ready", 3, 3);
        return outcome("reply_ready").put("target", postID).put("postID", postID).put("author", author).put("composer", "full");
    }

    private static boolean tapPoint(UiAutomation automation, int x, int y) {
        if (cancelled()) return false;
        long time = SystemClock.uptimeMillis();
        MotionEvent down = MotionEvent.obtain(time, time, MotionEvent.ACTION_DOWN, x, y, 0);
        MotionEvent up = MotionEvent.obtain(time, time + 45, MotionEvent.ACTION_UP, x, y, 0);
        down.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        up.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        try {
            if (!automation.injectInputEvent(down, true)) return false;
            SystemClock.sleep(45);
            return automation.injectInputEvent(up, true);
        } finally { down.recycle(); up.recycle(); }
    }

    private static JSONObject openReplyGallery(UiAutomation automation, AccessibilityNodeInfo detail) throws JSONException {
        if (fullReplyScreen(detail)) {
            for (int attempt = 0; attempt < 8 && find(detail, "new_thread_screen_gallery_button") == null; attempt++) {
                AccessibilityNodeInfo scroll = fullReplyScroll(detail);
                if (scroll == null || !scroll.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)) break;
                SystemClock.sleep(250);
                detail = threadsRoot(automation);
            }
        }
        AccessibilityNodeInfo gallery = find(detail, "new_thread_screen_gallery_button");
        if (gallery == null) gallery = findLabel(detail, "Gallery", "Thư viện");
        if (gallery == null) {
            AccessibilityNodeInfo attachments = findLabel(detail, "Add attachment", "Thêm tệp đính kèm");
            if (attachments == null || !press(automation, attachments)) return outcome("gallery_unavailable");
            for (int attempt = 0; attempt < 8 && gallery == null; attempt++) {
                SystemClock.sleep(150);
                AccessibilityNodeInfo current = threadsRoot(automation);
                if (fullReplyScreen(current)) {
                    hideKeyboard(automation);
                    return openReplyGallery(automation, threadsRoot(automation));
                }
                gallery = find(current, "new_thread_screen_gallery_button");
                if (gallery == null) gallery = findLabel(current, "Gallery", "Photo", "Photos", "Thư viện", "Ảnh");
            }
        }
        if (gallery == null || !press(automation, gallery)) return outcome("gallery_unavailable");
        return waitForGallery(automation, "reply_picker_open");
    }

    private static boolean setText(AccessibilityNodeInfo editor, String value) {
        Bundle arguments = new Bundle();
        arguments.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, value);
        return editor.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments);
    }

    private static JSONObject updateProfile(UiAutomation automation, JSONObject request) throws JSONException {
        String action = request.getString("action");
        String bio = request.optString("bio").trim();
        if (action.equals("select_avatar")) {
            return request.optInt("photoID") > 0 ? selectAvatarPhoto(automation) : outcome("avatar_unavailable");
        }
        if (!action.equals("bio") && !action.equals("avatar")) return outcome("unsupported");
        if (action.equals("bio") && (bio.isEmpty() || bio.codePointCount(0, bio.length()) > 150)) {
            return outcome("invalid_bio");
        }
        AccessibilityNodeInfo root = threadsRoot(automation);
        if (find(root, "profile_editor_card_done_button") == null) {
            AccessibilityNodeInfo profile = find(root, "barcelona_tab_profile");
            if (profile == null && find(root, "PermalinkScreen") != null) {
                AccessibilityNodeInfo back = find(root, "navigation_bar_back_button");
                if (back != null && press(automation, back)) {
                    profile = waitFor(automation, "barcelona_tab_profile");
                }
            }
            if (profile == null || !press(automation, profile)) return outcome("profile_unavailable");
            AccessibilityNodeInfo edit = waitFor(automation, "profile_screen_edit_profile_button");
            if (edit == null || !press(automation, edit)
                    || waitFor(automation, "profile_editor_card_done_button") == null) {
                return outcome("profile_unavailable");
            }
        }
        return action.equals("bio") ? saveBio(automation, bio) : openAvatarPicker(automation);
    }

    private static JSONObject selectAvatarPhoto(UiAutomation automation) throws JSONException {
        // Swift verifies the prepared MediaStore ID through ADB immediately before this action.
        AccessibilityNodeInfo root = threadsRoot(automation);
        AccessibilityNodeInfo recents = find(root, "spinner_title_text");
        if (recents == null || !("Recents".equals(string(recents.getText())) || "Gần đây".equals(string(recents.getText())))) return outcome("photos_changed");
        AccessibilityNodeInfo grid = find(root, "media_picker_grid_view");
        if (grid == null || grid.getChildCount() == 0) return outcome("avatar_unavailable");
        AccessibilityNodeInfo first = find(grid.getChild(0), "gallery_grid_item_thumbnail");
        if (first == null || !press(automation, first)) return outcome("avatar_unavailable");
        for (int attempt = 0; attempt < 16; attempt++) {
            SystemClock.sleep(180);
            root = threadsRoot(automation);
            grid = find(root, "media_picker_grid_view");
            first = grid == null || grid.getChildCount() == 0 ? null : find(grid.getChild(0), "gallery_grid_item_thumbnail");
            String label = first == null ? "" : string(first.getContentDescription());
            if (find(root, "crop_image_view") != null && (label.startsWith("Selected ") || label.startsWith("Đã chọn"))) return outcome("avatar_ready");
        }
        return outcome("avatar_unavailable");
    }

    private static JSONObject saveBio(UiAutomation automation, String bio) throws JSONException {
        AccessibilityNodeInfo root = threadsRoot(automation);
        AccessibilityNodeInfo label = findLabel(root, "Bio", "Tiểu sử");
        if (label == null || label.getParent() == null) return outcome("bio_unavailable");
        AccessibilityNodeInfo row = label.getParent();
        AccessibilityNodeInfo value = null;
        for (int index = 0; index < row.getChildCount(); index++) {
            AccessibilityNodeInfo child = row.getChild(index);
            if (child != null && !child.equals(label) && !firstText(child).isEmpty()) {
                value = child;
                break;
            }
        }
        if (value == null || !press(automation, value)) return outcome("bio_unavailable");
        for (int attempt = 0; attempt < 12; attempt++) {
            SystemClock.sleep(180);
            root = threadsRoot(automation);
            if (findLabel(root, "Edit bio", "Chỉnh sửa tiểu sử") == null) continue;
            AccessibilityNodeInfo editor = findEditable(root);
            if (editor == null || !setText(editor, bio)) continue;
            SystemClock.sleep(250);
            root = threadsRoot(automation);
            editor = findEditable(root);
            AccessibilityNodeInfo next = findLabel(root, "Next", "Tiếp");
            if (editor == null || !bio.equals(string(editor.getText())) || next == null
                    || !press(automation, next)) return outcome("bio_unavailable");
            AccessibilityNodeInfo done = waitFor(automation, "profile_editor_card_done_button");
            if (done == null || findLabel(threadsRoot(automation), bio) == null
                    || !press(automation, done)) return outcome("bio_unavailable");
            for (int check = 0; check < 40; check++) {
                SystemClock.sleep(300);
                AccessibilityNodeInfo profile = find(threadsRoot(automation), "ProfileScreen");
                if (findLabel(profile, bio) != null) return outcome("bio_saved");
            }
            return outcome("bio_unverified");
        }
        return outcome("bio_unavailable");
    }

    private static JSONObject openAvatarPicker(UiAutomation automation) throws JSONException {
        for (int attempt = 0; attempt < 12; attempt++) {
            SystemClock.sleep(180);
            AccessibilityNodeInfo photo = findLabel(threadsRoot(automation),
                    "Add Profile Picture", "Edit Profile Picture", "Change Profile Picture", "Profile Picture",
                "Thêm ảnh đại diện", "Đổi ảnh đại diện");
            if (photo == null || !press(automation, photo)) continue;
            for (int check = 0; check < 8; check++) {
                SystemClock.sleep(150);
                AccessibilityNodeInfo newPhoto = findLabel(threadsRoot(automation),
                    "New profile picture", "Ảnh đại diện mới");
                if (newPhoto != null && press(automation, newPhoto)) {
                    return waitForGallery(automation, "avatar_picker_open");
                }
            }
            break;
        }
        return outcome("avatar_unavailable");
    }

    private static JSONObject waitForGallery(UiAutomation automation, String success) throws JSONException {
        for (int attempt = 0; attempt < 12; attempt++) {
            SystemClock.sleep(180);
            if (photoPermission(automation)) return outcome("permission_required");
            AccessibilityNodeInfo root = threadsRoot(automation);
            if (find(root, "media_picker_grid_view") != null ||
                    (findLabel(find(root, "navigation_bar_title"), "Gallery", "Thư viện") != null
                     && findLabel(root, "Done", "Xong") != null)) return outcome(success);
        }
        return outcome("gallery_unavailable");
    }

    private static AccessibilityNodeInfo waitFor(UiAutomation automation, String resourceID) {
        for (int attempt = 0; attempt < 16; attempt++) {
            AccessibilityNodeInfo node = find(threadsRoot(automation), resourceID);
            if (node != null) return node;
            SystemClock.sleep(160);
        }
        return null;
    }

    private static AccessibilityNodeInfo findEditable(AccessibilityNodeInfo node) {
        if (node == null || !node.isVisibleToUser()) return null;
        if (node.isEditable()) return node;
        for (int index = 0; index < node.getChildCount(); index++) {
            AccessibilityNodeInfo match = findEditable(node.getChild(index));
            if (match != null) return match;
        }
        return null;
    }

    private static boolean photoPermission(UiAutomation automation) {
        AccessibilityNodeInfo root = automation.getRootInActiveWindow();
        return root != null && root.getPackageName() != null &&
            ("com.android.permissioncontroller".contentEquals(root.getPackageName()) ||
             (find(root, "gallery_picker_view") != null && findLabel(root, "Turn on", "Bật") != null));
    }

    private static boolean replyingTo(AccessibilityNodeInfo detail, String author) {
        return findLabel(detail, "Replying to @" + author, "Reply to " + author,
            "Đang trả lời @" + author, "Trả lời " + author) != null;
    }

    private static String replyContext(AccessibilityNodeInfo detail, String author) {
        AccessibilityNodeInfo label = findLabel(detail, "Replying to @" + author, "Reply to " + author,
            "Đang trả lời @" + author, "Trả lời " + author);
        if (label == null || label.getParent() == null) return null;
        AccessibilityNodeInfo container = label.getParent();
        StringBuilder context = new StringBuilder(author);
        for (int index = 0; index < container.getChildCount(); index++) {
            AccessibilityNodeInfo child = container.getChild(index);
            if (find(child, "permalink_inline_composer") != null) continue;
            String text = postContent(firstText(child));
            if (!text.isEmpty()) context.append("\n").append(text);
        }
        return context.toString();
    }

    private static Post detailPost(UiAutomation automation) {
        return detailPost(find(threadsRoot(automation), "PermalinkScreen"));
    }

    private static Post detailPost(AccessibilityNodeInfo detail) {
        AccessibilityNodeInfo list = find(detail, "IgLazyColumn");
        if (list == null) return null;
        List<Post> posts = visiblePosts(list);
        return posts.isEmpty() ? null : posts.get(0);
    }

    private static AccessibilityNodeInfo replyEditor(AccessibilityNodeInfo root) {
        AccessibilityNodeInfo inline = find(root, "permalink_inline_composer");
        return inline != null ? inline : find(root, "new_thread_screen_composer");
    }

    private static JSONObject outcome(String status) throws JSONException {
        return new JSONObject().put("actionStatus", status);
    }

    private static JSONObject targetMismatch(String phase, Post expected, Post actual) throws Exception {
        String reason = actual == null ? "quote_not_visible"
            : !expected.author.equals(actual.author) ? "author_mismatch" : "content_mismatch";
        return outcome("target_changed").put("phase", phase).put("reason", reason)
            .put("expectedPostID", expected.token(true))
            .put("actualPostID", actual == null ? JSONObject.NULL : actual.token(true));
    }

    private static void progress(String stage, int completed, int total) throws JSONException {
        System.out.println(new JSONObject().put("event", "progress").put("stage", stage)
            .put("completed", completed).put("total", total));
        System.out.flush();
    }

    private static boolean click(AccessibilityNodeInfo node) {
        return node.isVisibleToUser() && node.isEnabled()
            && node.performAction(AccessibilityNodeInfo.ACTION_CLICK);
    }

    private static boolean press(UiAutomation automation, AccessibilityNodeInfo node) {
        if (cancelled()) return false;
        if (click(node)) return true;
        Rect rect = bounds(node);
        if (!node.isEnabled() || !node.isVisibleToUser() || rect.isEmpty()) return false;
        long time = SystemClock.uptimeMillis();
        MotionEvent.PointerProperties finger = new MotionEvent.PointerProperties();
        finger.id = 0;
        finger.toolType = MotionEvent.TOOL_TYPE_FINGER;
        MotionEvent.PointerCoords position = new MotionEvent.PointerCoords();
        position.x = rect.exactCenterX();
        position.y = rect.exactCenterY();
        position.pressure = 1;
        MotionEvent.PointerProperties[] pointers = {finger};
        MotionEvent.PointerCoords[] coordinates = {position};
        if (!touch(automation, time, MotionEvent.ACTION_DOWN, pointers, coordinates)) return false;
        position.pressure = 0;
        if (touch(automation, time, MotionEvent.ACTION_UP, pointers, coordinates)) return true;
        touch(automation, time, MotionEvent.ACTION_CANCEL, pointers, coordinates);
        return false;
    }

    private static AccessibilityNodeInfo findLabel(AccessibilityNodeInfo node, String... labels) {
        if (node == null || !node.isVisibleToUser()) return null;
        for (String label : labels) {
            if (label.equalsIgnoreCase(string(node.getText())) ||
                    label.equalsIgnoreCase(string(node.getContentDescription()))) return node;
        }
        for (int index = 0; index < node.getChildCount(); index++) {
            AccessibilityNodeInfo match = findLabel(node.getChild(index), labels);
            if (match != null) return match;
        }
        return null;
    }

    private static JSONObject scroll(UiAutomation automation) throws Exception {
        AccessibilityNodeInfo feed = getFeed(automation);
        if (feed == null) return new JSONObject().put("stopReason", "feed_unavailable");
        return new JSONObject().put("scrolled", swipe(automation, bounds(feed)));
    }

    private static JSONObject refreshFeed(UiAutomation automation) throws Exception {
        progress("opening_home", 0, 0);
        boolean homeTapped = openFeed(automation);
        AccessibilityNodeInfo feed = getFeed(automation);
        if (feed == null) {
            AccessibilityNodeInfo editor = replyEditor(threadsRoot(automation));
            return outcome(editor != null && !string(editor.getText()).isEmpty() ? "draft_exists" : "feed_unavailable");
        }
        String before = viewport(feed);
        if (!homeTapped) {
            AccessibilityNodeInfo home = find(threadsRoot(automation), "barcelona_tab_main_feed");
            if (home == null) home = headerHome(find(threadsRoot(automation), "MainFeedScreen"), bounds(feed).top);
            // Threads hides its bottom tabs when scrolling down. Reveal them before
            // selecting Home instead of treating a hidden tab as a loading failure.
            for (int attempt = 0; home == null && attempt < 2; attempt++) {
                feed = getFeed(automation);
                if (feed == null || isFeedAtTop(feed) || !swipe(automation, bounds(feed), false)) break;
                SystemClock.sleep(350);
                home = find(threadsRoot(automation), "barcelona_tab_main_feed");
            }
            if (home == null || !press(automation, home)) return outcome("feed_unavailable");
        }
        progress("waiting_feed", 0, 0);
        long started = SystemClock.uptimeMillis();
        long deadline = started + 20_000;
        String previous = "";
        int stable = 0;
        boolean loadingSeen = false;
        boolean changed = false;
        while (SystemClock.uptimeMillis() < deadline) {
            SystemClock.sleep(300);
            feed = getFeed(automation);
            if (feed == null) return outcome("feed_unavailable");
            boolean loading = loadingAtTop(threadsRoot(automation), bounds(feed));
            loadingSeen |= loading;
            String current = viewport(feed);
            changed |= !current.isEmpty() && !current.equals(before);
            stable = !loading && !current.isEmpty() && current.equals(previous) ? stable + 1 : 0;
            previous = current;
            if (SystemClock.uptimeMillis() - started >= 1_200 && stable >= 3) {
                progress("pausing_feed", 0, 0);
                SystemClock.sleep(ThreadLocalRandom.current().nextLong(800, 1_801));
                feed = getFeed(automation);
                if (feed == null) return outcome("feed_unavailable");
                progress("initial_swipe", 0, 0);
                if (!swipe(automation, bounds(feed), true)) return outcome("refresh_failed");
                SystemClock.sleep(ThreadLocalRandom.current().nextLong(300, 601));
                return outcome("home_ready")
                    .put("homeTaps", 1).put("upSwipes", 1).put("pulls", 0)
                    .put("loadingSeen", loadingSeen).put("feedChanged", changed)
                    .put("waitMilliseconds", SystemClock.uptimeMillis() - started);
            }
        }
        return outcome("refresh_timeout");
    }

    private static JSONObject homeAfterPost(UiAutomation automation) throws Exception {
        // Only wait for the compose screen's navigation transition, never search
        // for a posted comment or wait for server confirmation.
        for (int attempt = 0; attempt < 30; attempt++) {
            if (cancelled()) return outcome("cancelled");
            AccessibilityNodeInfo root = threadsRoot(automation);
            AccessibilityNodeInfo editor = replyEditor(root);
            boolean navigationReady = root != null && (editor != null || getFeed(automation) != null
                || find(root, "PermalinkScreen") != null || find(root, "barcelona_tab_main_feed") != null);
            if (navigationReady && (editor == null || string(editor.getText()).isEmpty())) return refreshFeed(automation);
            SystemClock.sleep(200);
        }
        return outcome("home_unavailable");
    }

    private static boolean cancelled() {
        String marker = System.getenv("CLASSPATH");
        return marker != null && !new File(marker).exists();
    }

    private static String viewport(AccessibilityNodeInfo feed) throws Exception {
        StringBuilder result = new StringBuilder();
        for (Post post : visiblePosts(feed)) {
            if (post.isReadable()) result.append(post.token(true)).append("\n");
            if (result.length() > 90) break;
        }
        return result.toString();
    }

    private static boolean isFeedAtTop(AccessibilityNodeInfo feed) {
        return findLabel(feed, "What’s new?", "What's new?", "Có gì mới?", "Bạn đang nghĩ gì?") != null;
    }

    private static AccessibilityNodeInfo headerHome(AccessibilityNodeInfo node, int feedTop) {
        if (node == null || !node.isVisibleToUser()) return null;
        // The Threads wordmark acts as Home when the bottom bar is collapsed.
        // Accessibility labels its artwork ProgressBar; the sibling button is
        // bounded to the same header area, above the feed.
        if (string(node.getClassName()).contains("ProgressBar") && bounds(node).bottom <= feedTop) {
            AccessibilityNodeInfo parent = node.getParent();
            if (parent != null) {
                for (int index = 0; index < parent.getChildCount(); index++) {
                    AccessibilityNodeInfo button = parent.getChild(index);
                    if (button != null && button.isVisibleToUser() && button.isEnabled()
                            && string(button.getClassName()).equals("android.widget.Button")
                            && bounds(button).bottom <= feedTop) return button;
                }
            }
        }
        for (int index = 0; index < node.getChildCount(); index++) {
            AccessibilityNodeInfo home = headerHome(node.getChild(index), feedTop);
            if (home != null) return home;
        }
        return null;
    }

    private static boolean loadingAtTop(AccessibilityNodeInfo node, Rect feed) {
        if (node == null || !node.isVisibleToUser()) return false;
        String label = string(node.getContentDescription()).toLowerCase(Locale.ROOT);
        Rect rect = bounds(node);
        // Threads exposes its static wordmark as a ProgressBar above the feed.
        // Only count a spinner inside the feed, or an explicit refresh label.
        boolean indicator = (string(node.getClassName()).contains("ProgressBar") && rect.bottom > feed.top)
            || label.equals("refreshing") || label.equals("đang làm mới");
        if (indicator && rect.top < feed.top + feed.height() / 4) return true;
        for (int index = 0; index < node.getChildCount(); index++) {
            if (loadingAtTop(node.getChild(index), feed)) return true;
        }
        return false;
    }

    private static JSONObject read(UiAutomation automation, int limit) throws Exception {
        Map<String, Post> posts = new LinkedHashMap<>();
        long deadline = SystemClock.uptimeMillis() + (limit == LIMIT ? 34_000 : limit * 5_000L);
        int maxSwipes = limit == LIMIT ? MAX_SWIPES : AUTO_MAX_SWIPES;
        String reason = "swipe_limit";
        int swipes = 0;
        int scansWithoutNewPosts = 0;
        progress("reading", 0, limit);
        while (true) {
            AccessibilityNodeInfo feed = getFeed(automation);
            if (feed == null) {
                AccessibilityNodeInfo editor = replyEditor(threadsRoot(automation));
                reason = editor != null && !string(editor.getText()).isEmpty() ? "draft_exists" : "feed_unavailable";
                break;
            }
            int previousCount = posts.size();
            List<Post> visible = visiblePosts(feed);
            for (Post post : visible) {
                if (!post.isReadable() || post.isReply) continue;
                String key = post.author + "\n" + (post.text.isEmpty() ? post.media : post.text);
                Post existing = posts.get(key);
                if (existing == null) posts.put(key, post);
                else existing.merge(post);
                if (posts.size() >= limit) break;
            }
            progress("reading", posts.size(), limit);
            if (posts.size() == limit) {
                reason = "limit_reached";
                break;
            }
            scansWithoutNewPosts = posts.size() > previousCount ? 0 : scansWithoutNewPosts + 1;
            if (scansWithoutNewPosts >= 5) {
                reason = "no_new_posts";
                break;
            }
            if (swipes == maxSwipes) break;
            pauseToRead(visible);
            if (SystemClock.uptimeMillis() >= deadline) {
                reason = "time_limit";
                break;
            }
            // Recheck the active window after the reading pause before injecting a gesture.
            feed = getFeed(automation);
            if (feed == null) {
                reason = "feed_unavailable";
                break;
            }
            if (!swipe(automation, bounds(feed))) {
                reason = "scroll_unavailable";
                break;
            }
            swipes++;
            progress("swiping", posts.size(), limit);
            SystemClock.sleep(ThreadLocalRandom.current().nextLong(220, 421));
        }
        JSONArray items = new JSONArray();
        for (Post post : posts.values()) items.put(post.json());
        return new JSONObject().put("requested", limit).put("count", posts.size())
            .put("swipes", swipes).put("stopReason", reason).put("posts", items);
    }

    private static AccessibilityNodeInfo getFeed(UiAutomation automation) {
        return find(find(threadsRoot(automation), "MainFeedScreen"), "IgLazyColumn");
    }

    private static boolean openFeed(UiAutomation automation) {
        for (int attempt = 0; attempt < 25 && getFeed(automation) == null; attempt++) {
            AccessibilityNodeInfo root = threadsRoot(automation);
            if (root == null) {
                SystemClock.sleep(200);
                continue;
            }
            // Wait for a temporarily missing list instead of tapping Home and refreshing.
            if (find(root, "MainFeedScreen") != null) {
                waitFor(automation, "IgLazyColumn");
                return false;
            }
            AccessibilityNodeInfo editor = replyEditor(root);
            if (editor == null && fullReplyScreen(root)) {
                hideKeyboard(automation);
                waitFor(automation, "new_thread_screen_composer");
                continue;
            }
            if (editor != null) {
                if (!string(editor.getText()).isEmpty()) return false;
                AccessibilityNodeInfo back = find(root, "navigation_bar_back_button");
                if (back == null || !press(automation, back)) {
                    automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK);
                }
                // Wait for the transition so another Back cannot close the app.
                waitFor(automation, "MainFeedScreen");
                continue;
            }
            AccessibilityNodeInfo home = find(root, "barcelona_tab_main_feed");
            if (home != null && press(automation, home)) {
                waitFor(automation, "MainFeedScreen");
                return true;
            }
            SystemClock.sleep(180);
        }
        return false;
    }

    private static AccessibilityNodeInfo threadsRoot(UiAutomation automation) {
        AccessibilityNodeInfo root = automation.getRootInActiveWindow();
        if (root == null || root.getPackageName() == null || !PACKAGE.contentEquals(root.getPackageName())) {
            return null;
        }
        return root;
    }

    private static List<Post> visiblePosts(AccessibilityNodeInfo feed) {
        List<AccessibilityNodeInfo> rows = new ArrayList<>();
        collectRows(feed, rows);
        // Threads exposes header rows separately and not always in visual order.
        rows.sort(Comparator.comparingInt(row -> bounds(row).top));
        List<Post> posts = new ArrayList<>();
        Post post = null;
        for (AccessibilityNodeInfo row : rows) {
            AccessibilityNodeInfo header = find(row, "feed_post_header");
            if (header != null) {
                post = new Post();
                readHeader(header, post);
                post.isReply = isReplyHeader(header, post.author, bounds(feed));
                posts.add(post);
            } else if (post != null) {
                readRow(row, post);
            }
        }
        return posts;
    }

    private static void collectRows(AccessibilityNodeInfo node, List<AccessibilityNodeInfo> rows) {
        if (node == null || !node.isVisibleToUser()) return;
        if (id(node).equals("FeedPostRow")) {
            rows.add(node);
            return;
        }
        for (int index = 0; index < node.getChildCount(); index++) collectRows(node.getChild(index), rows);
    }

    private static void readHeader(AccessibilityNodeInfo node, Post post) {
        if (node == null || !node.isVisibleToUser()) return;
        String label = string(node.getContentDescription());
        if (post.author.isEmpty()) {
            String author = label.endsWith(" posted") ? label.substring(0, label.length() - 7) : label;
            if (author.matches("[a-zA-Z0-9_.]+") && !author.equals("Verified")) post.author = author;
        }
        if (post.timeLabel.isEmpty() && label.matches("(?iu)\\d+\\s*(s|m|h|d|w|giây|phút|giờ|ngày|tuần)")) {
            post.timeLabel = label;
        }
        for (int index = 0; index < node.getChildCount(); index++) readHeader(node.getChild(index), post);
    }

    private static boolean isReplyHeader(AccessibilityNodeInfo node, String author, Rect container) {
        if (node == null || !node.isVisibleToUser()) return false;
        String label = string(node.getContentDescription()).trim();
        String lower = label.toLowerCase(Locale.ROOT);
        if (lower.startsWith("replying to ") || lower.contains(" replied to ")
                || lower.startsWith("đang trả lời ") || lower.contains(" đã trả lời ")) return true;
        // Inline replies are separate FeedPostRows too, but their author/avatar
        // are indented one level. Do not confuse their text with another root post.
        if (string(node.getClassName()).equals("android.widget.Button") && label.equals(author)
                && bounds(node).left > container.left + container.width() / 5) return true;
        for (int index = 0; index < node.getChildCount(); index++) {
            if (isReplyHeader(node.getChild(index), author, container)) return true;
        }
        return false;
    }

    private static void readRow(AccessibilityNodeInfo node, Post post) {
        if (node == null || !node.isVisibleToUser()) return;
        String id = id(node);
        String label = string(node.getContentDescription());
        if (id.equals("feed_post_text")) {
            String text = postContent(firstText(node));
            if (!text.isEmpty()) post.text.add(text);
            if (node.isClickable()) post.body = node;
            else if (node.getParent() != null && node.getParent().isClickable()) post.body = node.getParent();
            return;
        }
        if (id.startsWith("feed_post_ufi_") && id.endsWith("_button") && !label.isEmpty()) {
            String type = id.substring("feed_post_ufi_".length(), id.length() - "_button".length());
            post.engagement.put(type, label);
            post.controls.put(type, node);
        }
        switch (label.toLowerCase(Locale.ROOT)) {
            case "photo preview":
            case "xem trước ảnh":
                post.media.add("photo");
                break;
            case "video preview":
            case "xem trước video":
                post.media.add("video");
                break;
        }
        for (int index = 0; index < node.getChildCount(); index++) readRow(node.getChild(index), post);
    }

    private static String firstText(AccessibilityNodeInfo node) {
        if (node == null || !node.isVisibleToUser()) return "";
        String text = string(node.getText());
        if (!text.isEmpty()) return text;
        for (int index = 0; index < node.getChildCount(); index++) {
            text = firstText(node.getChild(index));
            if (!text.isEmpty()) return text;
        }
        return "";
    }

    private static String postContent(String text) {
        // Threads appends U+FFFD for some rich-text decorations in the feed but
        // omits it in the quoted reply. It is not part of the post's identity.
        // Keep real Unicode characters, including Vietnamese and valid emoji.
        return text.replace("\uFFFD", "").trim();
    }

    private static AccessibilityNodeInfo find(AccessibilityNodeInfo node, String target) {
        if (node == null || !node.isVisibleToUser()) return null;
        if (id(node).equals(target)) return node;
        for (int index = 0; index < node.getChildCount(); index++) {
            AccessibilityNodeInfo match = find(node.getChild(index), target);
            if (match != null) return match;
        }
        return null;
    }

    private static String id(AccessibilityNodeInfo node) {
        String name = string(node.getViewIdResourceName());
        return name.substring(name.lastIndexOf('/') + 1);
    }

    private static String string(CharSequence value) {
        return value == null ? "" : value.toString().trim();
    }

    private static Rect bounds(AccessibilityNodeInfo node) {
        Rect bounds = new Rect();
        node.getBoundsInScreen(bounds);
        return bounds;
    }

    private static void pauseToRead(List<Post> posts) {
        int characters = 0;
        for (Post post : posts) {
            for (String text : post.text) characters += text.length();
        }
        ThreadLocalRandom random = ThreadLocalRandom.current();
        long pause = random.nextLong(500, 1_101) + Math.min(800, characters * 2L);
        if (random.nextDouble() < .12) pause += random.nextLong(600, 1_201);
        SystemClock.sleep(pause);
    }

    private static boolean swipe(UiAutomation automation, Rect feed) {
        return swipe(automation, feed, true);
    }

    private static boolean swipe(UiAutomation automation, Rect feed, boolean forward) {
        if (cancelled()) return false;
        if (feed.height() < 100 || feed.width() < 100) return false;
        ThreadLocalRandom random = ThreadLocalRandom.current();
        float startX = feed.left + feed.width() * (float) random.nextDouble(.48, .74);
        float startY = feed.top + feed.height() * (float) random.nextDouble(.72, .85);
        // Mix small adjustments with longer reading swipes while keeping screen overlap.
        float fraction = (float) (random.nextDouble() < .24
            ? random.nextDouble(.18, .29) : random.nextDouble(.34, .54));
        float travel = feed.height() * fraction;
        if (!forward) {
            startY -= travel;
            travel = -travel;
        }
        float curve = feed.width() * (float) random.nextDouble(-.035, .035);
        float drift = feed.width() * (float) random.nextDouble(-.045, .045);
        float acceleration = (float) random.nextDouble(.04, .18);
        float deceleration = (float) random.nextDouble(.78, .96);
        long duration = 160 + (long) (fraction * random.nextLong(500, 901));
        long hold = random.nextLong(30, 76);
        float pressure = (float) random.nextDouble(.45, .70);
        float contactSize = (float) random.nextDouble(.035, .055);

        MotionEvent.PointerProperties finger = new MotionEvent.PointerProperties();
        finger.id = 0;
        finger.toolType = MotionEvent.TOOL_TYPE_FINGER;
        MotionEvent.PointerProperties[] pointers = {finger};
        MotionEvent.PointerCoords position = new MotionEvent.PointerCoords();
        position.x = startX;
        position.y = startY;
        position.pressure = pressure;
        position.size = contactSize;
        MotionEvent.PointerCoords[] coordinates = {position};

        long downTime = SystemClock.uptimeMillis();
        if (!touch(automation, downTime, MotionEvent.ACTION_DOWN, pointers, coordinates)) return false;

        boolean lifted = false;
        try {
            SystemClock.sleep(hold);
            long movementStart = SystemClock.uptimeMillis();
            long endTime = movementStart + duration;
            long now = SystemClock.uptimeMillis();
            while (now < endTime) {
                SystemClock.sleep(Math.min(16, endTime - now));
                now = SystemClock.uptimeMillis();
                float t = Math.min(1f, (float) (now - movementStart) / duration);
                float remaining = 1f - t;
                float distance = 3f * remaining * remaining * t * acceleration
                    + 3f * remaining * t * t * deceleration + t * t * t;
                float contact = (float) Math.sin(Math.PI * t);
                position.x = startX + drift * distance + curve * (float) Math.sin(Math.PI * distance);
                position.y = startY - travel * distance;
                position.pressure = pressure + .12f * contact;
                position.size = contactSize + .008f * contact;
                if (!touch(automation, downTime, MotionEvent.ACTION_MOVE, pointers, coordinates)) return false;
            }
            position.pressure = 0;
            lifted = touch(automation, downTime, MotionEvent.ACTION_UP, pointers, coordinates);
            return lifted;
        } finally {
            if (!lifted) {
                position.pressure = 0;
                touch(automation, downTime, MotionEvent.ACTION_CANCEL, pointers, coordinates);
            }
        }
    }

    private static boolean touch(UiAutomation automation, long downTime, int action,
                                 MotionEvent.PointerProperties[] pointers, MotionEvent.PointerCoords[] coordinates) {
        MotionEvent event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action, 1,
            pointers, coordinates, 0, 0, 1, 1, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
        try {
            return automation.injectInputEvent(event, action != MotionEvent.ACTION_MOVE);
        } finally {
            event.recycle();
        }
    }

    private static final class Post {
        boolean isReply;
        String author = "";
        String timeLabel = "";
        final LinkedHashSet<String> text = new LinkedHashSet<>();
        final LinkedHashSet<String> media = new LinkedHashSet<>();
        final Map<String, String> engagement = new LinkedHashMap<>();
        final Map<String, AccessibilityNodeInfo> controls = new LinkedHashMap<>();
        AccessibilityNodeInfo body;

        boolean isReadable() {
            return !author.isEmpty() && (!text.isEmpty() || !media.isEmpty());
        }

        String identity() {
            return author + "\n" + timeLabel + "\n" + (text.isEmpty() ? media : text);
        }

        String token(boolean stable) throws Exception {
            String value = stable ? author + "\n" + String.join("\n", text.isEmpty() ? media : text) : identity();
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            return Base64.encodeToString(digest, Base64.NO_WRAP);
        }

        boolean sameContent(Post other) {
            return author.equals(other.author) && text.equals(other.text)
                && (!text.isEmpty() || media.equals(other.media));
        }

        void merge(Post other) {
            media.addAll(other.media);
            engagement.putAll(other.engagement);
        }

        JSONObject json() throws Exception {
            return new JSONObject().put("id", token(false)).put("stableID", token(true)).put("author", author).put("isReply", isReply)
                .put("timeLabel", timeLabel.isEmpty() ? JSONObject.NULL : timeLabel)
                .put("text", text.isEmpty() ? JSONObject.NULL : String.join("\n", text))
                .put("mediaTypes", new JSONArray(media))
                .put("engagement", new JSONObject(engagement));
        }
    }
}
