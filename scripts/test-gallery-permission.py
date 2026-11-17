#!/usr/bin/env python3
"""Run the production gallery timing and permission classifiers without touching a phone."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
program = '''public class GalleryPermissionTest {
 static void check(boolean value){if(!value)throw new AssertionError();}
 public static void main(String[] args){
  GalleryWait ordinary=new GalleryWait(1000);
  check(!ordinary.expired(5999,false));check(ordinary.expired(6000,false));
  GalleryWait permission=new GalleryWait(1000);
  check(!permission.expired(5000,true));check(permission.remainingSeconds(5000)==15);
  check(!permission.expired(19999,true));check(permission.expired(20000,true));
  check(!permission.expired(24999,false));check(permission.expired(25000,false));
  check(permission.remainingSeconds(30000)==0);
  GalleryWait delayedGrant=new GalleryWait(0);
  check(!delayedGrant.expired(500,true));check(!delayedGrant.expired(15499,true));
  check(!delayedGrant.expired(15499,false));check(!delayedGrant.expired(20499,false));
  check(delayedGrant.expired(20500,false));
  String[] controllers={"com.android.permissioncontroller","com.google.android.permissioncontroller","com.samsung.android.permissioncontroller","com.android.packageinstaller","com.google.android.packageinstaller"};
  for(String pkg:controllers){
   check(GalleryPermission.canAllow(pkg,"Allow Threads to access photos, media and files on your device?"));
   check(GalleryPermission.canAllow(pkg,"Cho phép Threads truy cập ảnh và nội dung đa phương tiện?"));
   check(!GalleryPermission.canAllow(pkg,"Allow another app to access photos?"));
   check(!GalleryPermission.canAllow(pkg,"Allow Threads to access contacts?"));
   check(!GalleryPermission.canAllow(pkg,"Allow Threads photos and location?"));
   check(!GalleryPermission.canAllow(pkg,"Cho phép Threads dùng máy ảnh?"));
   check(!GalleryPermission.canAllow(pkg,"Allow Threads to access your microphone?"));
  }
  check(!GalleryPermission.canAllow("com.example.fake","Allow Threads to access photos?"));
  check(!GalleryPermission.canAllow("com.instagram.barcelona","Allow Threads to access photos?"));
  System.out.println("PASS: full 15s from permission detection, 5s gallery load, finite timeout; photo-only Threads Allow on five controllers; unrelated requests rejected");
 }
}'''
with tempfile.TemporaryDirectory(prefix='phonefarm-gallery-qa-') as temporary:
    directory = Path(temporary)
    (directory/'GalleryPermissionTest.java').write_text(program)
    subprocess.run(['javac','-d',str(directory),str(root/'android/GalleryWait.java'),str(root/'android/GalleryPermission.java'),str(directory/'GalleryPermissionTest.java')],check=True)
    subprocess.run(['java','-cp',str(directory),'GalleryPermissionTest'],check=True)
