import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.MotionEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import org.json.JSONObject;
import java.io.File;

/** Configures only Gboard's language settings. No profile/account data is copied. */
public final class GboardSetup {
    private static final String PACKAGE="com.google.android.inputmethod.latin";
    public static void main(String[] args)throws Exception {
        AccessibilitySession.run(automation -> {
            String status=args.length==1&&args[0].equals("select")?selectVietnamese(automation):configure(automation);
            System.out.println(new JSONObject().put("keyboardStatus",status));
        });
    }
    private static String selectVietnamese(UiAutomation ui)throws Exception {
        Rect space=KeyboardReader.layout(ui).keys.get("space");
        if(space==null||space.isEmpty())return "keyboard_hidden";
        AccessibilitySession.requireProfile();
        long time=SystemClock.uptimeMillis();
        MotionEvent down=MotionEvent.obtain(time,time,MotionEvent.ACTION_DOWN,space.centerX(),space.centerY(),0);
        down.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        MotionEvent up=MotionEvent.obtain(time,time+700,MotionEvent.ACTION_UP,space.centerX(),space.centerY(),0);
        up.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        try { if(!ui.injectInputEvent(down,true))return "layout_unavailable";SystemClock.sleep(700); }
        finally { ui.injectInputEvent(up,true);down.recycle();up.recycle(); }
        for(int attempt=0;attempt<20;attempt++){
            AccessibilitySession.requireProfile();
            String marker=System.getenv("CLASSPATH");
            if(marker!=null&&!new File(marker).exists())return "cancelled";
            for(AccessibilityWindowInfo window:ui.getWindows()){
                AccessibilityNodeInfo root=window.getRoot();
                if(root==null||root.getPackageName()==null)continue;
                String pkg=root.getPackageName().toString();
                if(!pkg.equals(PACKAGE)&&!pkg.equals("android"))continue;
                AccessibilityNodeInfo language=findVietnameseChoice(root);
                if(language!=null&&tap(ui,language)){SystemClock.sleep(350);return "telex_selected";}
            }
            SystemClock.sleep(150);
        }
        return "layout_unavailable";
    }
    private static AccessibilityNodeInfo findVietnameseChoice(AccessibilityNodeInfo node){
        if(node==null||!node.isVisibleToUser())return null;
        String text=String.valueOf(node.getText()),description=String.valueOf(node.getContentDescription());
        if(!node.isEditable()&&actionable(node)&&(text.startsWith("Tiếng Việt")||text.startsWith("Vietnamese")
            ||description.startsWith("Tiếng Việt")||description.startsWith("Vietnamese")))return node;
        for(int i=0;i<node.getChildCount();i++){AccessibilityNodeInfo match=findVietnameseChoice(node.getChild(i));if(match!=null)return match;}
        return null;
    }
    private static String configure(UiAutomation ui)throws Exception {
        boolean added=false, searched=false;
        long until=SystemClock.uptimeMillis()+60_000;
        while(SystemClock.uptimeMillis()<until){
            AccessibilitySession.requireProfile();
            String marker=System.getenv("CLASSPATH");
            if(marker!=null&&!new File(marker).exists())return "cancelled";
            AccessibilityNodeInfo root=ui.getRootInActiveWindow();
            if(root==null||!PACKAGE.contentEquals(root.getPackageName())){SystemClock.sleep(200);continue;}
            AccessibilityNodeInfo add=find(root,"Add keyboard","Thêm bàn phím");
            if(add!=null){
                if(added&&vietnameseScreen(root))return "telex_configured";
                AccessibilityNodeInfo existing=find(root,"Vietnamese","Vietnamese (Vietnam)","Tiếng Việt","Tiếng Việt (Việt Nam)");
                tap(ui,existing!=null?existing:add);SystemClock.sleep(400);continue;
            }
            AccessibilityNodeInfo telex=find(root,"Telex");
            AccessibilityNodeInfo done=find(root,"Done","Xong");
            if(telex==null&&vietnameseScreen(root))telex=find(root,"QWERTY");
            if(telex!=null&&vietnameseScreen(root)){
                AccessibilityNodeInfo card=telex;
                while(card.getParent()!=null&&!card.isClickable())card=card.getParent();
                if(!checked(card)&&!tap(ui,telex))return "layout_unavailable";
                SystemClock.sleep(200);
                AccessibilityNodeInfo fresh=ui.getRootInActiveWindow();
                AccessibilityNodeInfo finish=find(fresh,"Done","Xong");
                // Existing-language layout changes save immediately and have only Up;
                // adding a language for the first time shows a Done button instead.
                if(finish==null)finish=find(fresh,"Navigate up","Điều hướng lên","Quay lại");
                if(!tap(ui,finish))return "layout_unavailable";
                added=true;SystemClock.sleep(500);continue;
            }
            AccessibilityNodeInfo vietnamese=find(root,"Vietnamese","Vietnamese (Vietnam)","Tiếng Việt","Tiếng Việt (Việt Nam)");
            if(vietnamese!=null){tap(ui,vietnamese);SystemClock.sleep(400);continue;}
            AccessibilityNodeInfo languages=find(root,"Languages","Ngôn ngữ");
            if(languages!=null){tap(ui,languages);SystemClock.sleep(400);continue;}
            AccessibilityNodeInfo search=find(root,"Search","Search icon","Search languages","Tìm kiếm","Tìm ngôn ngữ");
            if(!searched&&search!=null){tap(ui,search);SystemClock.sleep(300);}
            AccessibilityNodeInfo editor=editable(ui.getRootInActiveWindow());
            if(editor!=null&&!searched){
                Bundle value=new Bundle();value.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,"Vietnamese");
                AccessibilitySession.requireProfile();editor.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT,value);
                searched=true;SystemClock.sleep(500);continue;
            }
            if(!scroll(ui,root))SystemClock.sleep(300);
        }
        return "layout_unavailable";
    }
    private static boolean vietnameseScreen(AccessibilityNodeInfo node){
        if(node==null)return false;
        String label=String.valueOf(node.getText())+" "+String.valueOf(node.getContentDescription());
        if(label.contains("Tiếng Việt")||label.contains("Vietnamese"))return true;
        for(int i=0;i<node.getChildCount();i++)if(vietnameseScreen(node.getChild(i)))return true;
        return false;
    }
    private static boolean checked(AccessibilityNodeInfo node){
        if(node==null)return false;
        if(node.isChecked()||node.isSelected())return true;
        for(int i=0;i<node.getChildCount();i++)if(checked(node.getChild(i)))return true;
        return false;
    }
    private static AccessibilityNodeInfo find(AccessibilityNodeInfo node,String...values){
        if(node==null||!node.isVisibleToUser())return null;
        for(String value:values)if(!node.isEditable()&&(value.equalsIgnoreCase(String.valueOf(node.getText()))||value.equalsIgnoreCase(String.valueOf(node.getContentDescription())))
            &&(actionable(node)||String.valueOf(node.getClassName()).endsWith("ImageButton")))return node;
        for(int i=0;i<node.getChildCount();i++){AccessibilityNodeInfo found=find(node.getChild(i),values);if(found!=null)return found;}
        return null;
    }
    private static boolean actionable(AccessibilityNodeInfo node){
        for(int depth=0;node!=null&&depth<4;depth++,node=node.getParent())if(node.isClickable()&&node.isEnabled())return true;
        return false;
    }
    private static AccessibilityNodeInfo editable(AccessibilityNodeInfo node){
        if(node==null||!node.isVisibleToUser())return null;
        if(node.isEditable())return node;
        for(int i=0;i<node.getChildCount();i++){AccessibilityNodeInfo found=editable(node.getChild(i));if(found!=null)return found;}
        return null;
    }
    private static boolean scroll(UiAutomation ui,AccessibilityNodeInfo node){
        if(node==null)return false;
        if(node.isScrollable()){
            AccessibilitySession.requireProfile();
            if(node.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)){SystemClock.sleep(250);return true;}
        }
        for(int i=0;i<node.getChildCount();i++)if(scroll(ui,node.getChild(i)))return true;
        return false;
    }
    private static boolean tap(UiAutomation ui,AccessibilityNodeInfo node){
        if(node==null)return false;
        AccessibilitySession.requireProfile();
        String marker=System.getenv("CLASSPATH");
        if(marker!=null&&!new File(marker).exists())return false;
        AccessibilityNodeInfo click=node;
        while(click!=null){if(click.isClickable()&&click.isEnabled()&&click.performAction(AccessibilityNodeInfo.ACTION_CLICK))return true;click=click.getParent();}
        Rect bounds=new Rect();node.getBoundsInScreen(bounds);if(bounds.isEmpty())return false;
        long time=SystemClock.uptimeMillis();
        MotionEvent down=MotionEvent.obtain(time,time,MotionEvent.ACTION_DOWN,bounds.centerX(),bounds.centerY(),0);
        MotionEvent up=MotionEvent.obtain(time,time+60,MotionEvent.ACTION_UP,bounds.centerX(),bounds.centerY(),0);
        down.setSource(InputDevice.SOURCE_TOUCHSCREEN);up.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        try{return ui.injectInputEvent(down,true)&&ui.injectInputEvent(up,true);}finally{down.recycle();up.recycle();}
    }
}
