package com.localwebshare.app;

import android.content.Context;
import android.graphics.*;
import android.media.*;
import android.os.*;
import android.util.AttributeSet;
import android.view.View;

import java.io.File;
import java.nio.*;
import java.util.*;
import java.util.concurrent.*;

public final class AudioVisualizationView extends View {
    private static final ExecutorService ANALYZER = Executors.newSingleThreadExecutor();
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private volatile AudioAnalysis result;
    private MediaPlayer player;
    private boolean waveform;
    private boolean running;
    private final Runnable ticker = new Runnable(){ public void run(){ if(running){ invalidate(); MAIN.postDelayed(this,33); } } };

    public AudioVisualizationView(Context c){super(c);init();}
    public AudioVisualizationView(Context c, AttributeSet a){super(c,a);init();}
    private void init(){setMinimumHeight(dp(74));setOnClickListener(v->{waveform=!waveform;invalidate();});setContentDescription("Live spectrum. Tap to switch waveform");}
    public void load(File file){ result=null; invalidate(); ANALYZER.execute(()->{AudioAnalysis r=AudioAnalysis.analyze(file); MAIN.post(()->{result=r;invalidate();});}); }
    public void setPlayer(MediaPlayer p){player=p;}
    public void start(){if(!running){running=true;MAIN.post(ticker);}}
    public void stop(){running=false;MAIN.removeCallbacks(ticker);}

    @Override protected void onDraw(Canvas c){super.onDraw(c);int w=getWidth(),h=getHeight();if(w<=0||h<=0)return;paint.setColor(0x18000000);c.drawRoundRect(0,0,w,h,dp(12),dp(12),paint);AudioAnalysis r=result;if(r==null){paint.setColor(0x66777777);paint.setTextSize(dp(12));c.drawText("Analysing audio locally…",dp(10),h/2f,paint);return;}float progress=0;if(player!=null){try{int d=player.getDuration();if(d>0)progress=Math.max(0,Math.min(1,player.getCurrentPosition()/(float)d));}catch(Exception ignored){}}if(waveform)drawWaveform(c,r,progress,w,h);else drawSpectrum(c,r,progress,w,h);paint.setTextSize(dp(10));paint.setColor(0x88777777);c.drawText(waveform?"Waveform · tap for live spectrum":"Live spectrum · tap for waveform",dp(8),dp(12),paint);}
    private void drawSpectrum(Canvas c,AudioAnalysis r,float progress,int w,int h){double[] bands=r.spectrumAt(progress);float gap=dp(3),left=dp(8),right=dp(8),top=dp(18),bottom=dp(7);float bw=(w-left-right-gap*(bands.length-1))/Math.max(1,bands.length);for(int i=0;i<bands.length;i++){float bh=(float)Math.max(dp(3),(h-top-bottom)*bands[i]);float x=left+i*(bw+gap);paint.setColor(Color.HSVToColor(new float[]{(float)(i*275.0/Math.max(1,bands.length-1)),.82f,.94f}));c.drawRoundRect(x,h-bottom-bh,x+bw,h-bottom,dp(2),dp(2),paint);}}
    private void drawWaveform(Canvas c,AudioAnalysis r,float progress,int w,int h){double[] v=r.waveform;float gap=dp(1),left=dp(8),right=dp(8),top=dp(18),bottom=dp(7);float bw=(w-left-right-gap*(v.length-1))/Math.max(1,v.length);for(int i=0;i<v.length;i++){float bh=(float)Math.max(dp(2),(h-top-bottom)*v[i]);float x=left+i*(bw+gap);paint.setColor(i/(float)Math.max(1,v.length-1)<=progress?0xff448aff:0x44777777);float cy=(top+h-bottom)/2f;c.drawRoundRect(x,cy-bh/2,x+bw,cy+bh/2,dp(2),dp(2),paint);}}
    private int dp(int v){return Math.round(v*getResources().getDisplayMetrics().density);}

    static final class AudioAnalysis {
        final double[] waveform; final List<double[]> spectra;
        AudioAnalysis(double[] w,List<double[]> s){waveform=w;spectra=s;}
        double[] spectrumAt(double p){if(spectra.isEmpty())return new double[20];if(spectra.size()==1)return spectra.get(0);double e=Math.max(0,Math.min(1,p))*(spectra.size()-1);int a=(int)Math.floor(e),b=Math.min(spectra.size()-1,a+1);double mix=e-a;double[] x=spectra.get(a),y=spectra.get(b),o=new double[Math.min(x.length,y.length)];for(int i=0;i<o.length;i++)o[i]=x[i]+(y[i]-x[i])*mix;return o;}
        static AudioAnalysis analyze(File file){ArrayList<Double> amps=new ArrayList<>();ArrayList<double[]> specs=new ArrayList<>();MediaExtractor ex=new MediaExtractor();MediaCodec codec=null;try{ex.setDataSource(file.getAbsolutePath());int track=-1;MediaFormat fmt=null;String mime=null;for(int i=0;i<ex.getTrackCount();i++){MediaFormat f=ex.getTrackFormat(i);String m=f.getString(MediaFormat.KEY_MIME);if(m!=null&&m.startsWith("audio/")){track=i;fmt=f;mime=m;break;}}if(track<0||fmt==null||mime==null)return new AudioAnalysis(new double[0],specs);ex.selectTrack(track);int rate=fmt.containsKey(MediaFormat.KEY_SAMPLE_RATE)?fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE):44100;int channels=fmt.containsKey(MediaFormat.KEY_CHANNEL_COUNT)?Math.max(1,fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)):2;int hop=Math.max(512,rate/20);float[] pending=new float[hop*3];int pendingCount=0;codec=MediaCodec.createDecoderByType(mime);codec.configure(fmt,null,null,0);codec.start();boolean inDone=false,outDone=false;MediaCodec.BufferInfo info=new MediaCodec.BufferInfo();while(!outDone){if(!inDone){int idx=codec.dequeueInputBuffer(10000);if(idx>=0){ByteBuffer in=codec.getInputBuffer(idx);if(in!=null){int size=ex.readSampleData(in,0);if(size<0){codec.queueInputBuffer(idx,0,0,0,MediaCodec.BUFFER_FLAG_END_OF_STREAM);inDone=true;}else{codec.queueInputBuffer(idx,0,size,ex.getSampleTime(),0);ex.advance();}}}}int out=codec.dequeueOutputBuffer(info,10000);if(out==MediaCodec.INFO_OUTPUT_FORMAT_CHANGED){MediaFormat of=codec.getOutputFormat();rate=of.containsKey(MediaFormat.KEY_SAMPLE_RATE)?of.getInteger(MediaFormat.KEY_SAMPLE_RATE):rate;channels=of.containsKey(MediaFormat.KEY_CHANNEL_COUNT)?Math.max(1,of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)):channels;hop=Math.max(512,rate/20);pending=new float[hop*3];pendingCount=0;}else if(out>=0){ByteBuffer buf=codec.getOutputBuffer(out);if(buf!=null&&info.size>0){buf.position(info.offset);buf.limit(info.offset+info.size);buf.order(ByteOrder.nativeOrder());int encoding=AudioFormat.ENCODING_PCM_16BIT;try{MediaFormat of=codec.getOutputFormat();if(of.containsKey(MediaFormat.KEY_PCM_ENCODING))encoding=of.getInteger(MediaFormat.KEY_PCM_ENCODING);}catch(Exception ignored){}if(encoding==AudioFormat.ENCODING_PCM_FLOAT){FloatBuffer fb=buf.asFloatBuffer();while(fb.remaining()>=channels){float mono=0;for(int ch=0;ch<channels;ch++)mono+=fb.get();mono/=channels;if(pendingCount>=pending.length)pending=Arrays.copyOf(pending,pending.length*2);pending[pendingCount++]=mono;while(pendingCount>=hop){process(pending,hop,rate,amps,specs);System.arraycopy(pending,hop,pending,0,pendingCount-hop);pendingCount-=hop;}}}else{ShortBuffer sb=buf.asShortBuffer();while(sb.remaining()>=channels){float mono=0;for(int ch=0;ch<channels;ch++)mono+=sb.get()/32768f;mono/=channels;if(pendingCount>=pending.length)pending=Arrays.copyOf(pending,pending.length*2);pending[pendingCount++]=mono;while(pendingCount>=hop){process(pending,hop,rate,amps,specs);System.arraycopy(pending,hop,pending,0,pendingCount-hop);pendingCount-=hop;}}}}codec.releaseOutputBuffer(out,false);if((info.flags&MediaCodec.BUFFER_FLAG_END_OF_STREAM)!=0)outDone=true;}}if(pendingCount>64)process(pending,pendingCount,rate,amps,specs);return new AudioAnalysis(resample(amps,104),specs);}catch(Exception e){return new AudioAnalysis(new double[0],specs);}finally{try{ex.release();}catch(Exception ignored){}if(codec!=null){try{codec.stop();}catch(Exception ignored){}try{codec.release();}catch(Exception ignored){}}}}
        static void process(float[] s,int n,int rate,List<Double> amps,List<double[]> specs){double sum=0;for(int i=0;i<n;i++)sum+=s[i]*s[i];double rms=Math.sqrt(sum/Math.max(1,n));double amp=Math.min(1,Math.sqrt(Math.max(0,rms))*2.7);amps.add(amp);int window=Math.min(1024,n),start=Math.max(0,(n-window)/2);double[] raw=new double[20];double peak=1e-8;for(int b=0;b<20;b++){double f=55*Math.pow(16000.0/55,b/19.0);raw[b]=f<rate*.48?goertzel(s,start,window,rate,f):0;peak=Math.max(peak,raw[b]);}double energy=Math.min(1,Math.max(.03,amp*1.9));for(int b=0;b<20;b++)raw[b]=Math.min(1,Math.pow(Math.max(0,raw[b]/peak),.5)*(.03+.97*energy));specs.add(raw);}
        static double goertzel(float[] s,int start,int n,int rate,double freq){if(n<2)return 0;double omega=2*Math.PI*freq/rate,coef=2*Math.cos(omega),s1=0,s2=0,den=n-1;for(int i=0;i<n;i++){double win=.5-.5*Math.cos(2*Math.PI*i/den);double s0=s[start+i]*win+coef*s1-s2;s2=s1;s1=s0;}return Math.sqrt(Math.max(0,s1*s1+s2*s2-coef*s1*s2))/n;}
        static double[] resample(List<Double> in,int count){if(in.isEmpty())return new double[0];double[] out=new double[count];for(int i=0;i<count;i++){int a=i*in.size()/count,b=Math.max(a+1,(i+1)*in.size()/count);double m=0;for(int j=a;j<Math.min(b,in.size());j++)m=Math.max(m,in.get(j));out[i]=m;}double peak=1e-8;for(double v:out)peak=Math.max(peak,v);for(int i=0;i<out.length;i++)out[i]=Math.min(1,Math.max(.04,Math.pow(out[i]/peak,.58)));return out;}
    }
}
