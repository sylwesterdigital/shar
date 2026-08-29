package com.localwebshare.app;

import android.app.Activity;
import android.os.Bundle;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

public class RemoteShareActivity extends Activity {
    private WebView webView;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String name=getIntent().getStringExtra("name");
        webView=new WebView(this);
        WebSettings s=webView.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setAllowFileAccess(false);
        s.setMediaPlaybackRequiresUserGesture(false);
        webView.setWebViewClient(new WebViewClient());
        setContentView(webView);
        String q=name==null?"":"?remote="+URLEncoder.encode(name, StandardCharsets.UTF_8);
        webView.loadUrl("http://127.0.0.1:8080/"+q);
    }
    @Override public void onBackPressed(){ if(webView!=null&&webView.canGoBack())webView.goBack();else super.onBackPressed(); }
    @Override protected void onDestroy(){ if(webView!=null){webView.destroy();webView=null;}super.onDestroy(); }
}
