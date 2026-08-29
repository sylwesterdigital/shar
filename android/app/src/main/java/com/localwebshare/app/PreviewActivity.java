package com.localwebshare.app;

import android.app.*;
import android.graphics.BitmapFactory;
import android.media.MediaPlayer;
import android.os.*;
import android.view.*;
import android.widget.*;

import java.io.File;

public class PreviewActivity extends Activity {
    private MediaPlayer player;
    private final Handler handler=new Handler(Looper.getMainLooper());
    private Runnable updater;
    private File file;

    @Override public void onCreate(Bundle state){
        super.onCreate(state);
        String path=getIntent().getStringExtra("path");
        file=path==null?null:new File(path);
        if(file==null||!file.isFile()){finish();return;}
        setTitle(file.getName());
        LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);
        root.addView(toolbar(),new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.WRAP_CONTENT));
        View content=contentFor(file);
        root.addView(content,new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,0,1));
        setContentView(root);
    }

    private View toolbar(){
        LinearLayout bar=new LinearLayout(this);bar.setGravity(Gravity.CENTER_VERTICAL);bar.setPadding(16,8,16,8);
        TextView title=new TextView(this);title.setText(file.getName());title.setTextSize(17);title.setSingleLine(true);bar.addView(title,new LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1));
        Button del=new Button(this);del.setText("Delete");del.setOnClickListener(v->new AlertDialog.Builder(this).setTitle("Delete "+file.getName()+"?").setNegativeButton("Cancel",null).setPositiveButton("Delete",(d,w)->{if(file.delete()){setResult(RESULT_OK);finish();}}).show());bar.addView(del);
        Button done=new Button(this);done.setText("Done");done.setOnClickListener(v->finish());bar.addView(done);return bar;
    }

    private View contentFor(File f){String kind=MediaTypes.kind(f.getName());switch(kind){case"image":return image(f);case"video":return video(f);case"audio":return audio(f);default:return info(f);}}
    private View image(File f){ImageView v=new ImageView(this);v.setBackgroundColor(0xff000000);v.setScaleType(ImageView.ScaleType.FIT_CENTER);v.setImageBitmap(BitmapFactory.decodeFile(f.getAbsolutePath()));return v;}
    private View video(File f){VideoView v=new VideoView(this);MediaController c=new MediaController(this);v.setMediaController(c);v.setVideoPath(f.getAbsolutePath());v.setOnPreparedListener(mp->v.start());return v;}
    private View audio(File f){LinearLayout root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setGravity(Gravity.CENTER);root.setPadding(40,40,40,40);TextView name=new TextView(this);name.setText(f.getName());name.setTextSize(20);root.addView(name);SeekBar seek=new SeekBar(this);root.addView(seek,new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.WRAP_CONTENT));Button play=new Button(this);play.setText("Play");root.addView(play);try{player=new MediaPlayer();player.setDataSource(f.getAbsolutePath());player.prepare();seek.setMax(Math.max(1,player.getDuration()));play.setOnClickListener(v->{if(player.isPlaying()){player.pause();play.setText("Play");}else{player.start();play.setText("Pause");}});seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onProgressChanged(SeekBar b,int p,boolean u){if(u)player.seekTo(p);}public void onStartTrackingTouch(SeekBar b){}public void onStopTrackingTouch(SeekBar b){}});updater=new Runnable(){public void run(){if(player!=null){seek.setProgress(player.getCurrentPosition());handler.postDelayed(this,250);}}};handler.post(updater);}catch(Exception e){name.setText("Cannot play audio: "+e);}return root;}
    private View info(File f){LinearLayout root=new LinearLayout(this);root.setGravity(Gravity.CENTER);TextView t=new TextView(this);t.setText(f.getName()+"\n\n"+MediaTypes.mime(f.getName())+"\n"+f.length()+" bytes");t.setGravity(Gravity.CENTER);root.addView(t);return root;}
    @Override protected void onDestroy(){if(updater!=null)handler.removeCallbacks(updater);if(player!=null){player.release();player=null;}super.onDestroy();}
}
