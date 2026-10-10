package com.metzrevive.home;

import android.os.Process;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.reflect.Method;

/** Runs only in an authenticated ADB shell. No listener, app permission or root. */
public final class RemoteBridge {
    private static final String ALLOWED = ",3,4,19,20,21,22,23,24,25,66,67,82,85,164,";
    public static void main(String[] arguments) throws Exception {
        if (Process.myUid() != 2000) throw new SecurityException("ADB shell required");
        Class<?> type = Class.forName("android.hardware.input.InputManager");
        Object manager = type.getMethod("getInstance").invoke(null);
        Method inject = type.getMethod("injectInputEvent", InputEvent.class, int.class);
        BufferedReader reader = new BufferedReader(new InputStreamReader(System.in, "UTF-8"));
        System.out.println("METZ_READY_1"); System.out.flush();
        String line;
        while ((line = reader.readLine()) != null) {
            if (line.equals("QUIT")) break;
            if (line.length() > 80) { System.out.println("ERROR"); System.out.flush(); continue; }
            try {
                String[] parts = line.split(" ");
                if (parts.length != 2 || !parts[0].equals("KEY")) throw new IllegalArgumentException();
                int key = Integer.parseInt(parts[1]);
                if (!ALLOWED.contains("," + key + ",")) throw new IllegalArgumentException();
                long time = SystemClock.uptimeMillis();
                KeyEvent down = new KeyEvent(time, time, KeyEvent.ACTION_DOWN, key, 0, 0,
                        KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0, InputDevice.SOURCE_KEYBOARD);
                KeyEvent up = KeyEvent.changeAction(down, KeyEvent.ACTION_UP);
                // WAIT_FOR_RESULT checks permission/delivery; neither event waits for UI rendering.
                boolean acceptedDown = (Boolean) inject.invoke(manager, down, 1);
                boolean acceptedUp = (Boolean) inject.invoke(manager, up, 1);
                System.out.println(acceptedDown && acceptedUp ? "OK" : "ERROR");
            } catch (Exception denied) { System.out.println("ERROR"); }
            System.out.flush();
        }
    }
}
