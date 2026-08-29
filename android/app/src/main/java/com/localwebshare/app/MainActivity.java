package com.localwebshare.app;

import android.app.*;
import android.content.*;
import android.database.Cursor;
import android.graphics.*;
import android.media.MediaMetadataRetriever;
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
    private static final int PICK_FILES = 4001;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        sharedDir = new File(getFilesDir(), "shared");
        //noinspection ResultOfMethodCallIgnored
        sharedDir.mkdirs();
        server = new LocalHttpServer(sharedDir, this);
        setContentView(buildUI());
        refreshFiles();
    }

    private View buildUI() {
        ScrollView scroll=new ScrollView(this);
        LinearLayout root=new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setPadding(dp(18),dp(18),dp(18),dp(40)); scroll.addView(root);

        LinearLayout title=new LinearLayout(this);title.setOrientation(LinearLayout.HORIZONTAL);title.setGravity(Gravity.CENTER_VERTICAL);
        ImageView logo=new ImageView(this);logo.setImageResource(com.localwebshare.app.R.mipmap.ic_launcher);title.addView(logo,new LinearLayout.LayoutParams(dp(64),dp(64)));
        TextView h=new TextView(this);h.setText("Local Web Share\nWi-Fi media sharing");h.setTextSize(22);h.setPadding(dp(12),0,0,0);title.addView(h);root.addView(title);

        stateText=text("Sharing is OFF",18); stateText.setPadding(0,dp(20),0,dp(4));root.addView(stateText);
        addressText=text("Server stopped",14);addressText.setTextIsSelectable(true);root.addView(addressText);
        toggleButton=new Button(this);toggleButton.setText("Start Sharing");toggleButton.setOnClickListener(v->toggleServer());root.addView(toggleButton);

        Button importButton=new Button(this);importButton.setText("Import Files");importButton.setOnClickListener(v->chooseFiles());root.addView(importButton);

        LinearLayout filesHeader=new LinearLayout(this);filesHeader.setGravity(Gravity.CENTER_VERTICAL);filesHeader.setPadding(0,dp(18),0,dp(8));
        TextView fh=text("Files",20);filesHeader.addView(fh,new LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1));countText=text("0",14);filesHeader.addView(countText);root.addView(filesHeader);
        filesLayout=new LinearLayout(this);filesLayout.setOrientation(LinearLayout.VERTICAL);root.addView(filesLayout);
        TextView version=text("Version 1.4.0 (10400)",12);version.setPadding(0,dp(24),0,0);root.addView(version);
        return scroll;
    }

    private TextView text(String s,float size){TextView t=new TextView(this);t.setText(s);t.setTextSize(size);return t;}
    private int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}

    private void toggleServer(){
        if(server.isRunning()){server.stop();return;}
        try{server.start();}catch(Exception e){new AlertDialog.Builder(this).setTitle("Server error").setMessage(e.toString()).setPositiveButton("OK",null).show();}
    }

    @Override public void onFilesChanged(){runOnUiThread(this::refreshFiles);}
    @Override public void onState(String state){runOnUiThread(()->{
        boolean running=server.isRunning();stateText.setText(running?"Sharing is ON":"Sharing is OFF");toggleButton.setText(running?"Stop Sharing":"Start Sharing");String ip=LocalHttpServer.localIPv4();addressText.setText(running?(ip==null?"http://<device-ip>:8080":"http://"+ip+":8080"):"Server stopped");
    });}

    private void refreshFiles(){
        filesLayout.removeAllViews();File[] files=sharedDir.listFiles(File::isFile);if(files==null)files=new File[0];Arrays.sort(files,Comparator.comparing(File::getName,String.CASE_INSENSITIVE_ORDER));countText.setText(Integer.toString(files.length));
        if(files.length==0){TextView empty=text("No files yet. Upload from the browser or import files here.",14);empty.setPadding(0,dp(18),0,dp(18));filesLayout.addView(empty);return;}
        for(File f:files)filesLayout.addView(fileRow(f));
    }

    private View fileRow(File f){
        LinearLayout row=new LinearLayout(this);row.setOrientation(LinearLayout.HORIZONTAL);row.setGravity(Gravity.CENTER_VERTICAL);row.setPadding(0,dp(7),0,dp(7));
        ImageView thumb=new ImageView(this);thumb.setScaleType(ImageView.ScaleType.CENTER_CROP);Bitmap bmp=thumbnail(f);if(bmp!=null)thumb.setImageBitmap(bmp);else thumb.setImageResource(android.R.drawable.ic_menu_report_image);row.addView(thumb,new LinearLayout.LayoutParams(dp(58),dp(58)));
        LinearLayout info=new LinearLayout(this);info.setOrientation(LinearLayout.VERTICAL);info.setPadding(dp(12),0,dp(8),0);TextView name=text(f.getName(),16);TextView meta=text(MediaTypes.kind(f.getName()).toUpperCase(Locale.ROOT)+" • "+Formatter.formatFileSize(this,f.length()),12);info.addView(name);info.addView(meta);row.addView(info,new LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1));
        Button del=new Button(this);del.setText("Delete");del.setOnClickListener(v->confirmDelete(f));row.addView(del);
        row.setOnClickListener(v->openPreview(f));
        return row;
    }

    private Bitmap thumbnail(File f){
        try{String kind=MediaTypes.kind(f.getName());if(kind.equals("image"))return BitmapFactory.decodeFile(f.getAbsolutePath());if(kind.equals("video")){MediaMetadataRetriever r=new MediaMetadataRetriever();r.setDataSource(f.getAbsolutePath());Bitmap b=r.getFrameAtTime(0);r.release();return b;}}catch(Exception ignored){}return null;
    }

    private void openPreview(File f){Intent i=new Intent(this,PreviewActivity.class);i.putExtra("path",f.getAbsolutePath());startActivity(i);}
    private void confirmDelete(File f){new AlertDialog.Builder(this).setTitle("Delete "+f.getName()+"?").setNegativeButton("Cancel",null).setPositiveButton("Delete",(d,w)->{if(f.delete())refreshFiles();}).show();}

    private void chooseFiles(){Intent i=new Intent(Intent.ACTION_OPEN_DOCUMENT);i.setType("*/*");i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE,true);i.addCategory(Intent.CATEGORY_OPENABLE);startActivityForResult(i,PICK_FILES);}
    @Override protected void onActivityResult(int req,int res,Intent data){super.onActivityResult(req,res,data);if(req!=PICK_FILES||res!=RESULT_OK||data==null)return;if(data.getClipData()!=null){for(int x=0;x<data.getClipData().getItemCount();x++)importUri(data.getClipData().getItemAt(x).getUri());}else if(data.getData()!=null)importUri(data.getData());refreshFiles();}

    private void importUri(Uri uri){String name=queryName(uri);if(name==null)name="Imported-"+System.currentTimeMillis();File dest=unique(name);try(InputStream in=getContentResolver().openInputStream(uri);OutputStream out=new FileOutputStream(dest)){if(in!=null){byte[]buf=new byte[65536];int n;while((n=in.read(buf))>0)out.write(buf,0,n);}}catch(Exception e){Toast.makeText(this,e.toString(),Toast.LENGTH_LONG).show();}}
    private String queryName(Uri uri){try(Cursor c=getContentResolver().query(uri,new String[]{OpenableColumns.DISPLAY_NAME},null,null,null)){if(c!=null&&c.moveToFirst())return c.getString(0);}catch(Exception ignored){}return uri.getLastPathSegment();}
    private File unique(String name){File f=new File(sharedDir,new File(name).getName());if(!f.exists())return f;String base=f.getName(),ext="";int p=base.lastIndexOf('.');if(p>0){ext=base.substring(p);base=base.substring(0,p);}for(int n=2;;n++){f=new File(sharedDir,base+" "+n+ext);if(!f.exists())return f;}}

    @Override protected void onResume(){super.onResume();if(filesLayout!=null)refreshFiles();}
    @Override protected void onDestroy(){server.stop();super.onDestroy();}
}
