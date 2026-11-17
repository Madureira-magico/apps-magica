package br.com.ricardomadureira.detector;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.view.KeyEvent;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import androidx.webkit.WebViewAssetLoader;

import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

/** Tela do Detector: a mesma página do iPhone, dentro de um WebView. */
public class Principal extends Activity implements Sensor.Ouvinte {

    private static final String SITE = "https://appassets.androidplatform.net/assets/www/";

    // faz a página achar que está no iPhone: os recados vão para o Android
    private static final String PONTE = "<script>window.webkit={messageHandlers:{"
            + "ima:{postMessage:function(o){AndroidIma.post(JSON.stringify(o))}},"
            + "barra:{postMessage:function(b){AndroidIma.barra(!!b)}},"
            + "estilo:{postMessage:function(){}}}};</script>";

    private WebView web;
    private PowerManager.WakeLock bolso;
    private boolean disfarce = false;

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().setStatusBarColor(Color.parseColor("#071a44"));

        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
        }

        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        if (pm.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
            bolso = pm.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "detector:bolso");
        }

        final WebViewAssetLoader carregador = new WebViewAssetLoader.Builder()
                .addPathHandler("/assets/", new WebViewAssetLoader.AssetsPathHandler(this))
                .build();

        web = new WebView(this);
        web.setBackgroundColor(Color.parseColor("#071a44"));
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(false);
        web.setVerticalScrollBarEnabled(false);
        web.setOverScrollMode(View.OVER_SCROLL_NEVER);
        web.addJavascriptInterface(this, "AndroidIma");
        web.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView v, WebResourceRequest r) {
                Uri u = r.getUrl();
                if (u.toString().equals(SITE + "index.html")) return paginaComPonte();
                return carregador.shouldInterceptRequest(u);
            }

            @Override
            public void onPageFinished(WebView v, String url) {
                // o detector continuou ligado com a tela fechada: mostra o botão aceso
                if (Sensor.ligado) v.evaluateJavascript("ligado=true;document.getElementById('pw').classList.add('on');", null);
            }
        });
        setContentView(web);
        web.loadUrl(SITE + "index.html");
        Sensor.ouvinte = this;
    }

    private WebResourceResponse paginaComPonte() {
        try (InputStream in = getAssets().open("www/index.html")) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            String html = out.toString("UTF-8").replaceFirst("<head>", "<head>" + PONTE);
            return new WebResourceResponse("text/html", "utf-8",
                    new ByteArrayInputStream(html.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception e) {
            return null;
        }
    }

    // ---------- recados da página ----------

    @JavascriptInterface
    public void post(String json) {
        try {
            JSONObject o = new JSONObject(json);
            if ("bolso".equals(o.optString("cmd"))) {
                boolean ligar = o.optBoolean("ligar");
                runOnUiThread(() -> apagarNoBolso(ligar));
            } else {
                Sensor.comando(getApplicationContext(), o);
            }
        } catch (Exception ignored) {}
    }

    @JavascriptInterface
    public void barra(boolean esconder) {
        runOnUiThread(() -> {
            disfarce = esconder;
            if (Build.VERSION.SDK_INT >= 30) {
                WindowInsetsController c = getWindow().getInsetsController();
                if (c == null) return;
                if (esconder) {
                    c.hide(WindowInsets.Type.systemBars());
                    c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
                } else {
                    c.show(WindowInsets.Type.systemBars());
                }
            } else {
                getWindow().getDecorView().setSystemUiVisibility(esconder
                        ? View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                        : 0);
            }
        });
    }

    private void apagarNoBolso(boolean ligar) {
        if (bolso == null) return;
        if (ligar && !bolso.isHeld()) bolso.acquire();
        if (!ligar && bolso.isHeld()) bolso.release();
    }

    // ---------- sinal do sensor para a página ----------

    @Override
    public void sinal(double valor, double limite, int estado) {
        final String js = String.format(Locale.US, "window.imaSinal&&imaSinal(%.2f,%.2f,%d)", valor, limite, estado);
        runOnUiThread(() -> { if (web != null) web.evaluateJavascript(js, null); });
    }

    // no disfarce, os botões de volume e o voltar não fazem nada
    @Override
    public boolean onKeyDown(int code, KeyEvent e) {
        if (disfarce && (code == KeyEvent.KEYCODE_VOLUME_UP || code == KeyEvent.KEYCODE_VOLUME_DOWN || code == KeyEvent.KEYCODE_BACK)) return true;
        return super.onKeyDown(code, e);
    }

    @Override
    public void onBackPressed() {
        if (disfarce) return;
        super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        if (Sensor.ouvinte == this) Sensor.ouvinte = null;
        apagarNoBolso(false);
        if (web != null) { web.destroy(); web = null; }
        super.onDestroy();
    }
}
