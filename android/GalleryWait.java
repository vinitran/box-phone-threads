/** Monotonic gallery wait: allow a full 15 seconds from the first permission dialog,
 * then up to five more seconds for the gallery to load. No permission is accepted here. */
final class GalleryWait {
    private long deadline;
    private long permissionDeadline = -1;
    GalleryWait(long now) { deadline = now + 5_000; }
    boolean expired(long now, boolean permission) {
        if (permission && permissionDeadline < 0) {
            permissionDeadline = now + 15_000;
            deadline = permissionDeadline + 5_000;
        }
        return now >= (permission ? permissionDeadline : deadline);
    }
    int remainingSeconds(long now) { return (int) Math.max(0, (permissionDeadline - now + 999) / 1_000); }
}
