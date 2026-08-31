package com.localwebshare.app;

import android.app.*;
import android.graphics.*;
import android.media.*;
import android.os.*;
import android.text.*;
import android.text.style.*;
import android.view.*;
import android.widget.*;

import java.io.File;
import java.util.*;

public class PreviewActivity extends Activity {
    private MediaPlayer player;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private Runnable updater;
    private File[] files = new File[0];
    private int index;
    private LinearLayout root;
    private FrameLayout contentHost;
    private TextView title, position;
    private Button prev, next, del, done;
    private int buttonMode;
    private GestureDetector gestures;
    private AudioVisualizationView audioVisualization;
    private TextView captionText, captionStatus;
    private final List<CaptionWord> captionWords = new ArrayList<>();

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        File dir = new File(getIntent().getStringExtra("dir"));
        String name = getIntent().getStringExtra("name");
        buttonMode = getIntent().getIntExtra("button_mode", 2);
        File[] all = dir.listFiles(File::isFile);
        if (all != null) files = all;
        Arrays.sort(files, Comparator.comparing(File::getName, String.CASE_INSENSITIVE_ORDER));
        for (int i=0;i<files.length;i++) if (files[i].getName().equals(name)) { index=i; break; }
        if (files.length==0) { finish(); return; }
        gestures = new GestureDetector(this, new GestureDetector.SimpleOnGestureListener(){
            @Override public boolean onFling(MotionEvent e1, MotionEvent e2, float vx, float vy) {
                float dx=e2.getX()-e1.getX(); if(Math.abs(dx)>80){if(dx<0)goNext();else goPrev();return true;} return false;
            }
        });
        build(); showCurrent();
    }

    private void build(){
        root=new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL);
        root.addView(toolbar(),new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.WRAP_CONTENT));
        contentHost=new FrameLayout(this); contentHost.setOnTouchListener((v,e)->gestures.onTouchEvent(e));
        root.addView(contentHost,new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,0,1)); setContentView(root);
    }
    private String label(String full,String shortText,String icon){return buttonMode==0?full:buttonMode==1?icon:icon+" "+shortText;}
    private void setLabel(Button b,String f,String s,String i){b.setText(label(f,s,i));b.setContentDescription(f);}
    private View toolbar(){
        LinearLayout bar=new LinearLayout(this);bar.setGravity(Gravity.CENTER_VERTICAL);bar.setPadding(12,8,12,8);
        prev=new Button(this);setLabel(prev,"Previous","Prev","‹");prev.setOnClickListener(v->goPrev());bar.addView(prev);
        next=new Button(this);setLabel(next,"Next","Next","›");next.setOnClickListener(v->goNext());bar.addView(next);
        LinearLayout names=new LinearLayout(this);names.setOrientation(LinearLayout.VERTICAL);title=new TextView(this);title.setTextSize(17);title.setSingleLine(true);position=new TextView(this);position.setTextSize(11);names.addView(title);names.addView(position);bar.addView(names,new LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1));
        del=new Button(this);setLabel(del,"Delete","Del","⌫");del.setOnClickListener(v->confirmDelete());bar.addView(del);
        done=new Button(this);setLabel(done,"Done","Done","×");done.setOnClickListener(v->finish());bar.addView(done);return bar;
    }
    private File file(){return files[index];}
    private void goPrev(){if(index>0){index--;showCurrent();}}
    private void goNext(){if(index+1<files.length){index++;showCurrent();}}
    private void showCurrent(){
        releasePlayer(); captionWords.clear(); captionText=null; captionStatus=null;
        File f=file();title.setText(f.getName());position.setText((index+1)+" / "+files.length+" • swipe left/right");prev.setEnabled(index>0);next.setEnabled(index+1<files.length);
        contentHost.removeAllViews();View c=contentFor(f);c.setOnTouchListener((v,e)->gestures.onTouchEvent(e));contentHost.addView(c,new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.MATCH_PARENT));
    }
    private View contentFor(File f){switch(MediaTypes.kind(f.getName())){case"image":return image(f);case"video":return video(f);case"audio":return audio(f);default:return info(f);}}
    private View image(File f){ImageView v=new ImageView(this);v.setBackgroundColor(0xff000000);v.setScaleType(ImageView.ScaleType.FIT_CENTER);v.setImageBitmap(BitmapFactory.decodeFile(f.getAbsolutePath()));return v;}
    private View video(File f){VideoView v=new VideoView(this);MediaController c=new MediaController(this);v.setMediaController(c);v.setVideoPath(f.getAbsolutePath());v.setOnPreparedListener(mp->v.start());return v;}

    private View audio(File f){
        ScrollView scroll=new ScrollView(this); LinearLayout box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setGravity(Gravity.CENTER_HORIZONTAL);box.setPadding(dp(22),dp(20),dp(22),dp(24));scroll.addView(box,new ScrollView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.WRAP_CONTENT));
        try {
            MediaMetadataRetriever r=new MediaMetadataRetriever();r.setDataSource(f.getAbsolutePath());byte[] art=r.getEmbeddedPicture();String mt=r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE),ma=r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST);r.release();
            if(art!=null){ImageView iv=new ImageView(this);iv.setScaleType(ImageView.ScaleType.CENTER_CROP);iv.setImageBitmap(BitmapFactory.decodeByteArray(art,0,art.length));box.addView(iv,new LinearLayout.LayoutParams(dp(220),dp(220)));}
            TextView name=new TextView(this);name.setText(mt==null||mt.trim().isEmpty()?f.getName():mt);name.setTextSize(20);name.setGravity(Gravity.CENTER);name.setPadding(0,dp(12),0,0);box.addView(name);
            if(ma!=null&&!ma.trim().isEmpty()){TextView ar=new TextView(this);ar.setText(ma);ar.setGravity(Gravity.CENTER);ar.setAlpha(.7f);box.addView(ar);}

            audioVisualization=new AudioVisualizationView(this);audioVisualization.load(f);box.addView(audioVisualization,new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,dp(84)));

            LinearLayout captions=new LinearLayout(this);captions.setOrientation(LinearLayout.VERTICAL);captions.setPadding(0,dp(8),0,dp(8));
            Button captionButton=new Button(this);setLabel(captionButton,"Create captions","Captions","CC");captions.addView(captionButton,new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.WRAP_CONTENT));
            captionText=new TextView(this);captionText.setGravity(Gravity.CENTER);captionText.setTextSize(16);captionText.setMinHeight(dp(44));captionText.setPadding(dp(6),dp(8),dp(6),dp(4));captions.addView(captionText,new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.WRAP_CONTENT));
            captionStatus=new TextView(this);captionStatus.setGravity(Gravity.CENTER);captionStatus.setTextSize(11);captionStatus.setAlpha(.68f);captionStatus.setText("Local Whisper • audio is never uploaded");captions.addView(captionStatus,new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.WRAP_CONTENT));
            box.addView(captions,new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.WRAP_CONTENT));
            captionButton.setOnClickListener(v->{
                captionButton.setEnabled(false);captionWords.clear();captionText.setText("");
                LocalWhisperBridge.transcribe(this,f.getAbsolutePath(),new LocalWhisperBridge.Callback(){
                    public void onProgress(String message){captionStatus.setText(message+" • local only");}
                    public void onSuccess(String tsv){parseCaptions(tsv);captionButton.setEnabled(true);captionStatus.setText(captionWords.isEmpty()?"No speech recognized • nothing was uploaded":"Local Whisper • audio is never uploaded");updateCaptionHighlight();}
                    public void onError(String message){captionButton.setEnabled(true);captionStatus.setText("Local captions failed: "+message+" • nothing was uploaded");}
                });
            });

            SeekBar seek=new SeekBar(this);box.addView(seek,new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,ViewGroup.LayoutParams.WRAP_CONTENT));
            Button play=new Button(this);setLabel(play,"Play","Play","▶");box.addView(play);
            player=new MediaPlayer();player.setDataSource(f.getAbsolutePath());player.prepare();seek.setMax(Math.max(1,player.getDuration()));audioVisualization.setPlayer(player);audioVisualization.start();
            play.setOnClickListener(v->{if(player.isPlaying()){player.pause();setLabel(play,"Play","Play","▶");}else{player.start();setLabel(play,"Pause","Pause","Ⅱ");}});
            seek.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onProgressChanged(SeekBar b,int p,boolean u){if(u&&player!=null){player.seekTo(p);updateCaptionHighlight();}}public void onStartTrackingTouch(SeekBar b){}public void onStopTrackingTouch(SeekBar b){}});
            updater=new Runnable(){public void run(){if(player!=null){seek.setProgress(player.getCurrentPosition());updateCaptionHighlight();handler.postDelayed(this,50);}}};handler.post(updater);
        } catch(Exception e){TextView t=new TextView(this);t.setText("Cannot play audio: "+e);box.addView(t);}
        return scroll;
    }

    private static final class CaptionWord { final String text; final long startMs,endMs; CaptionWord(String t,long s,long e){text=t;startMs=s;endMs=e;} }
    private void parseCaptions(String tsv){captionWords.clear();if(tsv==null)return;for(String row:tsv.split("\\n")){String[] p=row.split("\\t",3);if(p.length<3)continue;try{long a=Long.parseLong(p[0]),b=Math.max(a+80,Long.parseLong(p[1]));String[] words=p[2].trim().split("\\s+");int weight=0;for(String w:words)weight+=Math.max(1,w.length());double cursor=a;for(String w:words){int ww=Math.max(1,w.length());double d=(b-a)*(ww/(double)Math.max(1,weight));captionWords.add(new CaptionWord(w,(long)cursor,(long)Math.max(cursor+60,cursor+d)));cursor+=d;}}catch(Exception ignored){}}}
    private void updateCaptionHighlight(){if(captionText==null||captionWords.isEmpty()||player==null)return;long now;try{now=player.getCurrentPosition();}catch(Exception e){return;}int current=-1;for(int i=0;i<captionWords.size();i++){if(captionWords.get(i).startMs<=now)current=i;else break;}if(current<0)current=0;int lo=Math.max(0,current-5),hi=Math.min(captionWords.size(),current+7);StringBuilder text=new StringBuilder();ArrayList<int[]> ranges=new ArrayList<>();for(int i=lo;i<hi;i++){if(text.length()>0)text.append(' ');int a=text.length();text.append(captionWords.get(i).text);ranges.add(new int[]{a,text.length(),i});}SpannableString span=new SpannableString(text.toString());for(int[] r:ranges)if(r[2]==current){span.setSpan(new ForegroundColorSpan(0xff448aff),r[0],r[1],Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);span.setSpan(new StyleSpan(Typeface.BOLD),r[0],r[1],Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);span.setSpan(new UnderlineSpan(),r[0],r[1],Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);}captionText.setText(span);}

    private View info(File f){LinearLayout box=new LinearLayout(this);box.setGravity(Gravity.CENTER);TextView t=new TextView(this);t.setText(f.getName()+"\n\n"+MediaTypes.mime(f.getName())+"\n"+f.length()+" bytes");t.setGravity(Gravity.CENTER);box.addView(t);return box;}
    private void confirmDelete(){File f=file();new AlertDialog.Builder(this).setTitle("Delete "+f.getName()+"?").setNegativeButton("Cancel",null).setPositiveButton("Delete",(d,w)->{if(f.delete()){List<File> left=new ArrayList<>(Arrays.asList(files));left.remove(index);files=left.toArray(new File[0]);if(files.length==0){setResult(RESULT_OK);finish();}else{if(index>=files.length)index=files.length-1;showCurrent();}}}).show();}
    private int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}
    private void releasePlayer(){if(updater!=null){handler.removeCallbacks(updater);updater=null;}if(audioVisualization!=null){audioVisualization.stop();audioVisualization=null;}if(player!=null){player.release();player=null;}}
    @Override protected void onDestroy(){releasePlayer();super.onDestroy();}
}
