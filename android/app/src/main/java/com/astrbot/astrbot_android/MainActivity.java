package com.astrbot.astrbot_android;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.webkit.ValueCallback;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
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

import com.norman.webviewup.lib.UpgradeCallback;
import com.norman.webviewup.lib.WebViewUpgrade;
import com.norman.webviewup.lib.source.UpgradeAssetSource;

import java.util.HashMap;
import java.util.Map;

public class MainActivity extends FragmentActivity implements UpgradeCallback {
    private static final String TAG = "AstrBotChromium";
    private static final String BUNDLED_WEBVIEW_ASSET =
            "133.0.6943.138_min26_arm32+64.apk";
    private static final String BUNDLED_WEBVIEW_VERSION = "133.0.6943.138";

    FlutterFragment flutterFragment;
    private static final String TAG_FLUTTER_FRAGMENT = "flutter_fragment";
    FragmentManager fragmentManager;
    private OnBackPressedCallback rootBackCallback;
    private ProgressBar kernelProgressBar;
    private TextView kernelStatusText;
    private boolean flutterAttached = false;

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

        initializeBundledWebView();
    }

    private void initializeBundledWebView() {
        showKernelLoadingUi();
        WebViewUpgrade.addUpgradeCallback(this);

        if (WebViewUpgrade.isCompleted()) {
            onUpgradeComplete();
            return;
        }

        try {
            UpgradeAssetSource source = new UpgradeAssetSource(
                    getApplicationContext(),
                    BUNDLED_WEBVIEW_ASSET,
                    BUNDLED_WEBVIEW_VERSION
            );
            WebViewUpgrade.upgrade(source);
        } catch (Throwable throwable) {
            onUpgradeError(throwable);
        }
    }

    private void attachFlutterFragment() {
        if (flutterAttached || isFinishing() || isDestroyed()) {
            return;
        }
        flutterAttached = true;
        View splashContainer = findViewById(
                com.astrbot.astrbot_android.R.id.splash_container
        );
        if (splashContainer != null) {
            splashContainer.setVisibility(View.GONE);
        }

        flutterFragment = (FlutterFragment) fragmentManager.findFragmentByTag(
                TAG_FLUTTER_FRAGMENT
        );
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

    private void showKernelLoadingUi() {
        FrameLayout container = findViewById(
                com.astrbot.astrbot_android.R.id.splash_container
        );
        if (container == null) {
            return;
        }
        container.removeAllViews();
        container.setBackgroundColor(Color.WHITE);

        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setGravity(Gravity.CENTER);
        int padding = (int) (24 * getResources().getDisplayMetrics().density);
        content.setPadding(padding, padding, padding, padding);

        kernelStatusText = new TextView(this);
        kernelStatusText.setText("正在准备内置 Chromium 内核...");
        kernelStatusText.setTextColor(Color.DKGRAY);
        kernelStatusText.setTextSize(16);
        kernelStatusText.setGravity(Gravity.CENTER);

        kernelProgressBar = new ProgressBar(
                this,
                null,
                android.R.attr.progressBarStyleHorizontal
        );
        kernelProgressBar.setMax(100);
        kernelProgressBar.setProgress(0);

        content.addView(
                kernelStatusText,
                new LinearLayout.LayoutParams(
                        LinearLayout.LayoutParams.MATCH_PARENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT
                )
        );
        LinearLayout.LayoutParams progressParams = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
        );
        progressParams.topMargin = (int) (16 * getResources().getDisplayMetrics().density);
        content.addView(kernelProgressBar, progressParams);

        FrameLayout.LayoutParams contentParams = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER
        );
        container.addView(content, contentParams);
    }

    @Override
    public void onUpgradeProcess(float percent) {
        runOnUiThread(() -> {
            int progress = Math.max(0, Math.min(100, Math.round(percent * 100)));
            if (kernelProgressBar != null) {
                kernelProgressBar.setProgress(progress);
            }
            if (kernelStatusText != null) {
                kernelStatusText.setText("正在准备内置 Chromium 内核 " + progress + "%");
            }
        });
    }

    @Override
    public void onUpgradeComplete() {
        runOnUiThread(() -> {
            WebViewUpgrade.removeUpgradeCallback(this);
            Log.i(
                    TAG,
                    "Bundled WebView enabled: "
                            + WebViewUpgrade.getUpgradeWebViewPackageName()
                            + " "
                            + WebViewUpgrade.getUpgradeWebViewVersion()
            );
            attachFlutterFragment();
        });
    }

    @Override
    public void onUpgradeError(Throwable throwable) {
        runOnUiThread(() -> {
            WebViewUpgrade.removeUpgradeCallback(this);
            Log.e(TAG, "Bundled WebView failed; falling back to system WebView", throwable);
            if (kernelStatusText != null) {
                kernelStatusText.setText("内置 Chromium 内核加载失败，正在使用系统 WebView");
            }
            new Handler().postDelayed(this::attachFlutterFragment, 700);
        });
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
        WebViewUpgrade.removeUpgradeCallback(this);
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
                } else if ("webview_kernel_info".equals(call.method)) {
                    boolean bundled = WebViewUpgrade.isCompleted();
                    String packageName = bundled
                            ? WebViewUpgrade.getUpgradeWebViewPackageName()
                            : WebViewUpgrade.getSystemWebViewPackageName();
                    String version = bundled
                            ? WebViewUpgrade.getUpgradeWebViewVersion()
                            : WebViewUpgrade.getSystemWebViewPackageVersion();
                    Map<String, Object> info = new HashMap<>();
                    info.put("source", bundled ? "bundled" : "system");
                    info.put("packageName", packageName == null ? "" : packageName);
                    info.put("version", version == null ? "" : version);
                    result.success(info);
                } else {
                    result.notImplemented();
                }
            });
        }
    }

}
