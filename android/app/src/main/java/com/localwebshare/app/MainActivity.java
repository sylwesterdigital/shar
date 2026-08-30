package com.localwebshare.app;

import android.app.*;
import android.content.*;
import android.database.Cursor;
import android.graphics.*;
import android.media.*;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.text.format.Formatter;
import android.view.*;
import android.widget.*;

import java.io.*;
import java.util.*;

public class MainActivity extends Activity implements LocalHttpServer.Listener {
    private File sharedDir;
    private LocalHttpServer server;
    private TextView stateText, addressText, countText;
    private LinearLayout filesLayout;
    private Button toggleButton;
    private MediaPlayer inlinePlayer;
    private File inlineFile;
    private Button inlineButton;
    private int buttonMode;
    private boolean showDeveloperInfo;
    private boolean rebuilding;
    private static final int PICK_FILES = 4001;
    private static final String PRODUCT_URL = "https://mojoworks.xyz/labs/shar/";
    private static final String SOURCE_URL = "https://github.com/sylwesterdigital/shar";
    private static final String SUPPORT_URL = "https://mojoworks.xyz/labs/shar/support.html";
    private static final String BUILDER_NAME = "WORKWORK.FUN LTD";
    private static final String COPYRIGHT = "© 2026 Sylwester Mielniczuk, CEO of WORKWORK.FUN LTD";

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        sharedDir = new File(getFilesDir(), "shared"); sharedDir.mkdirs();
        server = new LocalHttpServer(sharedDir, this);
        buttonMode=getPreferences(MODE_PRIVATE).getInt("button_mode",2);
        showDeveloperInfo=getPreferences(MODE_PRIVATE).getBoolean("show_developer_info",false);
        rebuildUI();
    }

    private void rebuildUI(){rebuilding=true;setContentView(buildUI());refreshFiles();onState(server.isRunning()?"running":"stopped");rebuilding=false;}

    private View buildUI() {
        ScrollView scroll=new ScrollView(this); LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(dp(18),dp(18),dp(18),dp(40));scroll.addView(root);
        LinearLayout title=new LinearLayout(this);title.setOrientation(LinearLayout.HORIZONTAL);title.setGravity(Gravity.CENTER_VERTICAL);ImageView logo=new ImageView(this);logo.setImageResource(R.mipmap.ic_launcher);title.addView(logo,new LinearLayout.LayoutParams(dp(64),dp(64)));TextView h=text("Shar\nWi-Fi media sharing",22);h.setPadding(dp(12),0,0,0);title.addView(h,new LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1));if(showDeveloperInfo){Button info=new Button(this);info.setText("ⓘ");info.setContentDescription("Developer updates");info.setOnClickListener(v->showDeveloperUpdates());title.addView(info);}root.addView(title);
        stateText=text("Sharing is OFF",18);stateText.setPadding(0,dp(20),0,dp(4));root.addView(stateText);addressText=text("Server stopped",14);addressText.setTextIsSelectable(true);root.addView(addressText);
        toggleButton=new Button(this);toggleButton.setOnClickListener(v->toggleServer());root.addView(toggleButton);
        Button importButton=new Button(this);setLabel(importButton,"Import Files","Import","＋");importButton.setOnClickListener(v->chooseFiles());root.addView(importButton);
        LinearLayout modeRow=new LinearLayout(this);modeRow.setGravity(Gravity.CENTER_VERTICAL);TextView ml=text("Buttons",14);modeRow.addView(ml);Spinner spinner=new Spinner(this);ArrayAdapter<String>a=new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,new String[]{"Text","Icons","Icon + short"});spinner.setAdapter(a);spinner.setSelection(buttonMode,false);spinner.setOnItemSelectedListener(new android.widget.AdapterView.OnItemSelectedListener(){public void onNothingSelected(android.widget.AdapterView<?>p){}public void onItemSelected(android.widget.AdapterView<?>p,View v,int pos,long id){if(rebuilding||pos==buttonMode)return;buttonMode=pos;getPreferences(MODE_PRIVATE).edit().putInt("button_mode",pos).apply();rebuildUI();}});modeRow.addView(spinner,new LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1));root.addView(modeRow);
        CheckBox developerToggle=new CheckBox(this);developerToggle.setText("Show ⓘ developer updates");developerToggle.setChecked(showDeveloperInfo);developerToggle.setOnCheckedChangeListener((button,checked)->{if(rebuilding)return;showDeveloperInfo=checked;getPreferences(MODE_PRIVATE).edit().putBoolean("show_developer_info",checked).apply();rebuildUI();});root.addView(developerToggle);
        LinearLayout filesHeader=new LinearLayout(this);filesHeader.setGravity(Gravity.CENTER_VERTICAL);filesHeader.setPadding(0,dp(18),0,dp(8));TextView fh=text("Files",20);filesHeader.addView(fh,new LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1));countText=text("0",14);filesHeader.addView(countText);root.addView(filesHeader);filesLayout=new LinearLayout(this);filesLayout.setOrientation(LinearLayout.VERTICAL);root.addView(filesLayout);
        LinearLayout aboutRow=new LinearLayout(this);aboutRow.setGravity(Gravity.CENTER_VERTICAL);aboutRow.setPadding(0,dp(24),0,0);Button about=new Button(this);about.setText("About Shar");about.setOnClickListener(v->showAbout());aboutRow.addView(about,new LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1));Button support=new Button(this);support.setText("♥ Support Shar");support.setOnClickListener(v->openExternal(SUPPORT_URL));aboutRow.addView(support,new LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1));root.addView(aboutRow);TextView version=text(appVersionLabel(),12);version.setPadding(0,dp(6),0,0);root.addView(version);return scroll;
    }

    private void showDeveloperUpdates(){
        String message="v2.1.6  Playback + company polish\nmacOS keeps a single audio session across Grid/List, adds top Support/About/Config controls, refreshes Stripe on the website, and identifies WORKWORK.FUN LTD with Sylwester Mielniczuk copyright.\n\n"+
                "v2.1.5  Stripe support checkout\nSupport Shar now opens the centralized Stripe-backed support experience using the configured Payment Link / Buy Button.\n\n"+
                "v2.1.4  Release pipeline resilience\nA locked iPhone can no longer abort an otherwise successful distribution release after installation.\n\n"+
                "v2.1.3  Unified native library UI\nBrought macOS grid/list, media filters and cog-based Config in line with iOS; added explicit About/Support information across native clients.\n\n"+
                "v2.1.2  Native macOS Secure Remote Share\nRemote sharing on macOS now stays inside the native Shar app with PIN, QR/link, approval, encrypted-transfer progress and verified completion UI.\n\n"+
                "v2.1.1  Android build fix\nFixed the secure-share browser embedding escape regression and added a Java text-block compile guard.\n\n"+
                "v2.1.0  Secure Remote Share\nAdded AES-256-GCM encryption, separate PIN verification, sender approval, SHA-256 integrity checks, and hardened TURN/API privacy.\n\n"+
                "v2.0.8  Remote sender startup fix\nFixed native iOS Remote Share startup and removed Google STUN from runtime ICE.\n\n"+
                "v2.0.7  Remote completion handshake\nSuccessful remote downloads stay complete and explicitly confirm receipt back to the sender.\n\n"+
                "v2.0.6  Native link sharing\nFixed iPhone Remote Share so Share link opens the native iOS share sheet for Messages, Mail, AirDrop and installed messaging apps.\n\n"+
                "v2.0.5  Remote service readiness\nFixed the signaling-service startup race and added readiness diagnostics before nginx/public-route validation.\n\n"+
                "v2.0.4  Native iPhone Remote Share\nRemote sharing now starts directly from the native iOS file card and shows a native QR/link transfer sheet without opening the local browser UI.\n\n"+
                "v2.0.3  Public route verification\nMade the real public HTTPS API authoritative and hardened nginx repair for duplicate/address-bound apex vhosts.\n\n"+
                "v2.0.2  Remote routing repair\nFixed exact mojoworks.xyz API routing and automatic public-endpoint repair.\n\n"+
                "v2.0.1  Android release fix\nRestored Android release compilation and kept version display sourced from package metadata.\n\n"+
            "v2.0.0  Remote WebRTC sharing\nExpiring QR/link shares with P2P data channels and TURN fallback.\n\n"+
            "v1.7.6  Optional developer info\nHidden-by-default ⓘ updates panel and preference.\n\n"+
            "v1.7.5  Cross-platform audio fix\nRestored macOS release builds while keeping iOS background audio.\n\n"+
            "v1.7.4  Background audio\nAudio continues while Shar is minimized or the screen is locked.\n\n"+
            "v1.7.3  Better preview\nFit-first images and a persistent X close control.\n\n"+
            "v1.7.2  More ways to add\nPhotos & Videos, camera recording, and Files from +.\n\n"+
            "v1.7.1  Shar identity\nShar branding and persistent iOS + importer.";
        new AlertDialog.Builder(this).setTitle("Developer updates").setMessage(message).setPositiveButton("Close",null).show();
    }

    private void showAbout(){
        String version=appVersionLabel();
        new AlertDialog.Builder(this)
                .setTitle("About Shar")
                .setMessage(version+"\n\nCompany: "+BUILDER_NAME+"\n"+COPYRIGHT+"\nMojoWorks is a creative sub-brand of WORKWORK.FUN LTD.\n\n"+PRODUCT_URL+"\n\nSource: "+SOURCE_URL)
                .setPositiveButton("Support Shar",(d,w)->openExternal(SUPPORT_URL))
                .setNeutralButton("Website",(d,w)->openExternal(PRODUCT_URL))
                .setNegativeButton("Close",null)
                .show();
    }

    private void openExternal(String value){
        try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(value))); }
        catch(Exception e) { Toast.makeText(this,"Could not open link",Toast.LENGTH_LONG).show(); }
    }

    private String appVersionLabel(){
        try {
            android.content.pm.PackageInfo info=getPackageManager().getPackageInfo(getPackageName(),0);
            long code=android.os.Build.VERSION.SDK_INT>=android.os.Build.VERSION_CODES.P ? info.getLongVersionCode() : info.versionCode;
            return "Version "+(info.versionName==null?"?":info.versionName)+" ("+code+")";
        } catch(Exception ignored) {
            return "Version ?";
        }
    }

    private String label(String full,String shortText,String icon){return buttonMode==0?full:buttonMode==1?icon:icon+" "+shortText;}
    private void setLabel(Button b,String full,String shortText,String icon){b.setText(label(full,shortText,icon));b.setContentDescription(full);}
    private TextView text(String s,float size){TextView t=new TextView(this);t.setText(s);t.setTextSize(size);return t;} private int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}

    private void toggleServer(){if(server.isRunning()){server.stop();return;}try{server.start();}catch(Exception e){new AlertDialog.Builder(this).setTitle("Server error").setMessage(e.toString()).setPositiveButton("OK",null).show();}}
    @Override public void onFilesChanged(){runOnUiThread(this::refreshFiles);} @Override public void onState(String state){runOnUiThread(()->{if(stateText==null)return;boolean running=server.isRunning();stateText.setText(running?"Sharing is ON":"Sharing is OFF");setLabel(toggleButton,running?"Stop Sharing":"Start Sharing",running?"Stop":"Start",running?"■":"▶");String ip=LocalHttpServer.localIPv4();addressText.setText(running?(ip==null?"http://<device-ip>:8080":"http://"+ip+":8080"):"Server stopped");});}

    private void refreshFiles(){if(filesLayout==null)return;filesLayout.removeAllViews();File[] fs=sortedFiles();countText.setText(Integer.toString(fs.length));if(fs.length==0){TextView empty=text("No files yet. Upload from the browser or import files here.",14);empty.setPadding(0,dp(18),0,dp(18));filesLayout.addView(empty);return;}for(File f:fs)filesLayout.addView(fileRow(f));}
    private File[] sortedFiles(){File[] fs=sharedDir.listFiles(File::isFile);if(fs==null)fs=new File[0];Arrays.sort(fs,Comparator.comparing(File::getName,String.CASE_INSENSITIVE_ORDER));return fs;}

    private View fileRow(File f){
        LinearLayout row=new LinearLayout(this);row.setOrientation(LinearLayout.HORIZONTAL);row.setGravity(Gravity.CENTER_VERTICAL);row.setPadding(0,dp(7),0,dp(7));
        ImageView thumb=new ImageView(this);thumb.setScaleType(ImageView.ScaleType.CENTER_CROP);Bitmap bmp=thumbnail(f);if(bmp!=null)thumb.setImageBitmap(bmp);else thumb.setImageResource(android.R.drawable.ic_menu_report_image);row.addView(thumb,new LinearLayout.LayoutParams(dp(58),dp(58)));
        LinearLayout info=new LinearLayout(this);info.setOrientation(LinearLayout.VERTICAL);info.setPadding(dp(12),0,dp(8),0);String[] md=audioMetadata(f);TextView name=text(md[0]!=null?md[0]:f.getName(),16);info.addView(name);if(md[1]!=null){TextView artist=text(md[1],12);artist.setAlpha(.7f);info.addView(artist);}TextView meta=text(MediaTypes.kind(f.getName()).toUpperCase(Locale.ROOT)+" • "+Formatter.formatFileSize(this,f.length()),12);info.addView(meta);row.addView(info,new LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1));
        if(MediaTypes.kind(f.getName()).equals("audio")){Button play=new Button(this);setLabel(play,"Play","Play","▶");play.setOnClickListener(v->{playInline(f,play);});row.addView(play);}
        Button remote=new Button(this);setLabel(remote,"Remote","Remote","↗");remote.setOnClickListener(v->openRemoteShare(f));row.addView(remote);
        Button del=new Button(this);setLabel(del,"Delete","Del","⌫");del.setOnClickListener(v->confirmDelete(f));row.addView(del);row.setOnClickListener(v->openPreview(f));return row;
    }

    private void playInline(File f,Button b){try{if(inlinePlayer!=null&&inlineFile!=null&&inlineFile.equals(f)){if(inlinePlayer.isPlaying()){inlinePlayer.pause();setLabel(b,"Play","Play","▶");}else{inlinePlayer.start();setLabel(b,"Pause","Pause","Ⅱ");}return;}stopInline();inlinePlayer=new MediaPlayer();inlinePlayer.setDataSource(f.getAbsolutePath());inlinePlayer.prepare();inlinePlayer.start();inlineFile=f;inlineButton=b;setLabel(b,"Pause","Pause","Ⅱ");inlinePlayer.setOnCompletionListener(mp->{setLabel(b,"Play","Play","▶");stopInline();});}catch(Exception e){Toast.makeText(this,e.toString(),Toast.LENGTH_LONG).show();stopInline();}}
    private void stopInline(){if(inlinePlayer!=null){try{inlinePlayer.stop();}catch(Exception ignored){}inlinePlayer.release();}if(inlineButton!=null)setLabel(inlineButton,"Play","Play","▶");inlinePlayer=null;inlineFile=null;inlineButton=null;}

    private Bitmap thumbnail(File f){try{String kind=MediaTypes.kind(f.getName());if(kind.equals("image"))return BitmapFactory.decodeFile(f.getAbsolutePath());if(kind.equals("video")||kind.equals("audio")){MediaMetadataRetriever r=new MediaMetadataRetriever();r.setDataSource(f.getAbsolutePath());if(kind.equals("audio")){byte[] art=r.getEmbeddedPicture();r.release();return art==null?null:BitmapFactory.decodeByteArray(art,0,art.length);}Bitmap b=r.getFrameAtTime(0);r.release();return b;}}catch(Exception ignored){}return null;}
    private String[] audioMetadata(File f){if(!MediaTypes.kind(f.getName()).equals("audio"))return new String[]{null,null};try{MediaMetadataRetriever r=new MediaMetadataRetriever();r.setDataSource(f.getAbsolutePath());String title=r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE),artist=r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST);r.release();return new String[]{blank(title)?null:title,blank(artist)?null:artist};}catch(Exception ignored){return new String[]{null,null};}}
    private boolean blank(String s){return s==null||s.trim().isEmpty();}

    private void openRemoteShare(File f){stopInline();if(!server.isRunning()){try{server.start();}catch(Exception e){Toast.makeText(this,e.toString(),Toast.LENGTH_LONG).show();return;}}Intent i=new Intent(this,RemoteShareActivity.class);i.putExtra("name",f.getName());startActivity(i);}
    private void openPreview(File f){stopInline();Intent i=new Intent(this,PreviewActivity.class);i.putExtra("dir",sharedDir.getAbsolutePath());i.putExtra("name",f.getName());i.putExtra("button_mode",buttonMode);startActivity(i);} private void confirmDelete(File f){new AlertDialog.Builder(this).setTitle("Delete "+f.getName()+"?").setNegativeButton("Cancel",null).setPositiveButton("Delete",(d,w)->{if(f.delete())refreshFiles();}).show();}
    private void chooseFiles(){Intent i=new Intent(Intent.ACTION_OPEN_DOCUMENT);i.setType("*/*");i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE,true);i.addCategory(Intent.CATEGORY_OPENABLE);startActivityForResult(i,PICK_FILES);} @Override protected void onActivityResult(int req,int res,Intent data){super.onActivityResult(req,res,data);if(req!=PICK_FILES||res!=RESULT_OK||data==null)return;if(data.getClipData()!=null){for(int x=0;x<data.getClipData().getItemCount();x++)importUri(data.getClipData().getItemAt(x).getUri());}else if(data.getData()!=null)importUri(data.getData());refreshFiles();}
    private void importUri(Uri uri){String name=queryName(uri);if(name==null)name="Imported-"+System.currentTimeMillis();File dest=unique(name);try(InputStream in=getContentResolver().openInputStream(uri);OutputStream out=new FileOutputStream(dest)){if(in!=null){byte[]buf=new byte[65536];int n;while((n=in.read(buf))>0)out.write(buf,0,n);}}catch(Exception e){Toast.makeText(this,e.toString(),Toast.LENGTH_LONG).show();}} private String queryName(Uri uri){try(Cursor c=getContentResolver().query(uri,new String[]{OpenableColumns.DISPLAY_NAME},null,null,null)){if(c!=null&&c.moveToFirst())return c.getString(0);}catch(Exception ignored){}return uri.getLastPathSegment();} private File unique(String name){File f=new File(sharedDir,new File(name).getName());if(!f.exists())return f;String base=f.getName(),ext="";int p=base.lastIndexOf('.');if(p>0){ext=base.substring(p);base=base.substring(0,p);}for(int n=2;;n++){f=new File(sharedDir,base+" "+n+ext);if(!f.exists())return f;}}
    @Override protected void onResume(){super.onResume();if(filesLayout!=null)refreshFiles();} @Override protected void onDestroy(){stopInline();server.stop();super.onDestroy();}
}
