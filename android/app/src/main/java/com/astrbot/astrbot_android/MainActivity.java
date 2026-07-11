package com.astrbot.astrbot_android;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.webkit.ValueCallback;
import android.widget.Toast;

import androidx.activity.OnBackPressedCallback;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.fragment.app.FragmentActivity;
import androidx.fragment.app.FragmentManager;

import io.flutter.embedding.android.FlutterFragment;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugins.GeneratedPluginRegistrant;

public class MainActivity extends FragmentActivity {
    FlutterFragment flutterFragment;
    private static final String TAG_FLUTTER_FRAGMENT = "flutter_fragment";
    FragmentManager fragmentManager;
    private OnBackPressedCallback rootBackCallback;

    // 文件选择器相关
    private static final int FILE_CHOOSER_REQUEST_CODE = 1;
    private ValueCallback<Uri[]> filePathCallback;

    // 双击返回退出相关
    private boolean doubleBackToExitPressedOnce = false;
    private static final int DOUBLE_BACK_INTERVAL = 2000; // 2秒内连续按返回键

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        // Do not let FragmentManager restore an older cached-engine FlutterFragment
        // before this Activity can create a fresh new-engine fragment.
        super.onCreate(null);
        fragmentManager = getSupportFragmentManager();
        setContentView(com.astrbot.astrbot_android.R.layout.my_activity_layout);
        rootBackCallback = new OnBackPressedCallback(true) {
            @Override
            public void handleOnBackPressed() {
                handleRootBackPressed();
            }
        };
        getOnBackPressedDispatcher().addCallback(this, rootBackCallback);

        flutterFragment = (FlutterFragment) fragmentManager.findFragmentByTag(TAG_FLUTTER_FRAGMENT);
        if (flutterFragment == null) {
            flutterFragment = new FlutterFragment.NewEngineFragmentBuilder(AstrBotFlutterFragment.class)
                    .shouldAutomaticallyHandleOnBackPressed(true)
                    .build();
            fragmentManager
                    .beginTransaction()
                    .add(com.astrbot.astrbot_android.R.id.fl_container, flutterFragment, TAG_FLUTTER_FRAGMENT)
                    .commit();
        }
    }


    @Override
    public void onPostResume() {
        super.onPostResume();
        if (flutterFragment != null) {
            flutterFragment.onPostResume();
        }
    }

    @Override
    protected void onNewIntent(@NonNull Intent intent) {
        super.onNewIntent(intent);
        if (flutterFragment != null) {
            flutterFragment.onNewIntent(intent);
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, @Nullable Intent data) {
        super.onActivityResult(requestCode, resultCode, data);

        // 处理文件选择器返回的结果
        if (requestCode == FILE_CHOOSER_REQUEST_CODE) {
            if (filePathCallback == null) {
                return;
            }

            Uri[] results = null;
            if (resultCode == Activity.RESULT_OK && data != null) {
                String dataString = data.getDataString();
                if (dataString != null) {
                    results = new Uri[]{Uri.parse(dataString)};
                } else if (data.getClipData() != null) {
                    // 处理多文件选择
                    int count = data.getClipData().getItemCount();
                    results = new Uri[count];
                    for (int i = 0; i < count; i++) {
                        results[i] = data.getClipData().getItemAt(i).getUri();
                    }
                }
            }

            filePathCallback.onReceiveValue(results);
            filePathCallback = null;
        }

        // 传递给 FlutterFragment
        if (flutterFragment != null) {
            flutterFragment.onActivityResult(requestCode, resultCode, data);
        }
    }

    // 用于从 Flutter 端调用的方法，触发文件选择器
    public void openFileChooser(ValueCallback<Uri[]> callback) {
        filePathCallback = callback;

        Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);

        Intent chooserIntent = Intent.createChooser(intent, "选择文件");
        startActivityForResult(chooserIntent, FILE_CHOOSER_REQUEST_CODE);
    }

    private void handleRootBackPressed() {
        // Flutter cannot handle the current back action, so keep the existing
        // root-page behavior: press back twice to move the task to background.
        if (doubleBackToExitPressedOnce) {
            moveTaskToBack(true);
            return;
        }

        this.doubleBackToExitPressedOnce = true;
        Toast.makeText(this, "再按一次返回桌面", Toast.LENGTH_SHORT).show();

        new Handler().postDelayed(() -> doubleBackToExitPressedOnce = false, DOUBLE_BACK_INTERVAL);
    }

    private void setRootBackCallbackEnabled(boolean enabled) {
        if (rootBackCallback == null || rootBackCallback.isEnabled() == enabled) {
            return;
        }
        rootBackCallback.setEnabled(enabled);
    }

    @Override
    public void onRequestPermissionsResult(
            int requestCode,
            @NonNull String[] permissions,
            @NonNull int[] grantResults
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (flutterFragment != null) {
            flutterFragment.onRequestPermissionsResult(
                    requestCode,
                    permissions,
                    grantResults
            );
        }
    }

    @Override
    public void onUserLeaveHint() {
        if (flutterFragment != null) {
            flutterFragment.onUserLeaveHint();
        }
    }

    @Override
    public void onTrimMemory(int level) {
        super.onTrimMemory(level);
        if (flutterFragment != null) {
            flutterFragment.onTrimMemory(level);
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
    }

    public static class AstrBotFlutterFragment extends FlutterFragment {
        @Override
        public void setFrameworkHandlesBack(boolean frameworkHandlesBack) {
            FragmentActivity activity = getActivity();
            MainActivity mainActivity = activity instanceof MainActivity ? (MainActivity) activity : null;
            if (frameworkHandlesBack && mainActivity != null) {
                mainActivity.setRootBackCallbackEnabled(false);
            }
            super.setFrameworkHandlesBack(frameworkHandlesBack);
            if (!frameworkHandlesBack && mainActivity != null) {
                mainActivity.setRootBackCallbackEnabled(true);
            }
        }

        @Override
        public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
            GeneratedPluginRegistrant.registerWith(flutterEngine);
            new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), "astrbot_channel").setMethodCallHandler((call, result) -> {
                if ("lib_path".equals(call.method)) {
                    Context context = getContext();
                    if (context == null) {
                        result.error("NO_CONTEXT", "Android context is not available.", null);
                        return;
                    }
                    result.success(context.getApplicationContext().getApplicationInfo().nativeLibraryDir);
                } else {
                    result.notImplemented();
                }
            });
        }
    }

}
