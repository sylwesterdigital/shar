package com.localwebshare.app;

import android.util.Log;
import android.media.MediaMetadataRetriever;
import android.util.Base64;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

final class LocalHttpServer {
    interface Listener { void onFilesChanged(); void onState(String state); }

    private final File root;
    private final Listener listener;
    private final ExecutorService workers = Executors.newCachedThreadPool();
    private volatile boolean running;
    private ServerSocket serverSocket;
    private Thread acceptThread;

    LocalHttpServer(File root, Listener listener) {
        this.root = root;
        this.listener = listener;
        //noinspection ResultOfMethodCallIgnored
        root.mkdirs();
    }

    synchronized void start() throws IOException {
        if (running) return;
        serverSocket = new ServerSocket();
        serverSocket.setReuseAddress(true);
        serverSocket.bind(new InetSocketAddress(8080));
        running = true;
        acceptThread = new Thread(() -> {
            listener.onState("running");
            while (running) {
                try {
                    Socket socket = serverSocket.accept();
                    socket.setSoTimeout(30000);
                    workers.execute(() -> handle(socket));
                } catch (IOException e) {
                    if (running) Log.e("LocalWebShare", "accept", e);
                }
            }
        }, "LocalWebShareAccept");
        acceptThread.start();
    }

    synchronized void stop() {
        running = false;
        try { if (serverSocket != null) serverSocket.close(); } catch (IOException ignored) {}
        serverSocket = null;
        listener.onState("stopped");
    }

    boolean isRunning() { return running; }

    private void handle(Socket socket) {
        try (socket; BufferedInputStream in = new BufferedInputStream(socket.getInputStream()); BufferedOutputStream out = new BufferedOutputStream(socket.getOutputStream())) {
            byte[] headerBytes = readHeaders(in);
            if (headerBytes == null) return;
            String headerText = new String(headerBytes, StandardCharsets.ISO_8859_1);
            String[] lines = headerText.split("\\r\\n");
            if (lines.length == 0) { sendText(out, "400 Bad Request", "Bad request"); return; }
            String[] request = lines[0].split(" ");
            if (request.length < 2) { sendText(out, "400 Bad Request", "Bad request"); return; }
            String method = request[0].toUpperCase(Locale.ROOT);
            String target = request[1];
            String path = target.split("\\?", 2)[0];
            Map<String,String> headers = new HashMap<>();
            for (int i=1;i<lines.length;i++) {
                int p=lines[i].indexOf(':');
                if (p>0) headers.put(lines[i].substring(0,p).trim().toLowerCase(Locale.ROOT), lines[i].substring(p+1).trim());
            }

            if (method.equals("GET") && path.equals("/")) sendHtml(out);
            else if (method.equals("GET") && path.equals("/api/files")) sendFilesJson(out);
            else if (method.equals("POST") && path.equals("/upload")) upload(out, in, target, headers);
            else if (method.equals("GET") && path.startsWith("/media/")) sendFile(out, path.substring(7), headers, true);
            else if (method.equals("GET") && path.startsWith("/artwork/")) sendArtwork(out, path.substring(9));
            else if (method.equals("GET") && path.startsWith("/ui-icon/")) sendUIIcon(out, path.substring(9));
            else if (method.equals("GET") && path.startsWith("/files/")) sendFile(out, path.substring(7), headers, false);
            else if (method.equals("DELETE") && path.startsWith("/files/")) delete(out, path.substring(7));
            else sendText(out, "404 Not Found", "Not found");
            out.flush();
        } catch (Exception e) {
            Log.e("LocalWebShare", "connection", e);
        }
    }

    private byte[] readHeaders(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int state=0, v;
        while ((v=in.read()) != -1) {
            b.write(v);
            if (state==0 && v=='\r') state=1;
            else if (state==1 && v=='\n') state=2;
            else if (state==2 && v=='\r') state=3;
            else if (state==3 && v=='\n') break;
            else state=0;
            if (b.size()>65536) return null;
        }
        return b.toByteArray();
    }

    private void upload(OutputStream out, InputStream in, String target, Map<String,String> headers) throws IOException {
        String lengthText=headers.get("content-length");
        if (lengthText==null) { sendText(out,"411 Length Required","Content-Length required"); return; }
        long remaining;
        try { remaining=Long.parseLong(lengthText); } catch(Exception e){ sendText(out,"400 Bad Request","Bad Content-Length"); return; }
        String filename=query(target,"filename");
        filename=safeName(filename);
        if (filename==null) { sendText(out,"400 Bad Request","Missing filename"); return; }
        File dest=unique(filename), tmp=new File(root,".upload-"+UUID.randomUUID()+".tmp");
        try (FileOutputStream fos=new FileOutputStream(tmp)) {
            byte[] buf=new byte[262144];
            while (remaining>0) {
                int n=in.read(buf,0,(int)Math.min(buf.length,remaining));
                if(n<0) throw new EOFException("Upload ended early");
                fos.write(buf,0,n); remaining-=n;
            }
        }
        if (!tmp.renameTo(dest)) {
            try (InputStream src=new FileInputStream(tmp); OutputStream dst=new FileOutputStream(dest)) { byte[] copy=new byte[65536]; int n; while((n=src.read(copy))>0) dst.write(copy,0,n); }
            //noinspection ResultOfMethodCallIgnored
            tmp.delete();
        }
        listener.onFilesChanged();
        sendJson(out,"201 Created","{\"ok\":true,\"name\":\""+json(dest.getName())+"\"}");
    }

    private void delete(OutputStream out,String encoded) throws IOException {
        String name=safeName(urlDecode(encoded));
        if(name==null){sendText(out,"400 Bad Request","Bad filename");return;}
        File f=new File(root,name);
        if(!f.isFile()||!f.delete()){sendText(out,"404 Not Found","File not found");return;}
        listener.onFilesChanged();
        sendJson(out,"200 OK","{\"ok\":true}");
    }

    private void sendFilesJson(OutputStream out) throws IOException {
        File[] files=root.listFiles(File::isFile); if(files==null) files=new File[0];
        Arrays.sort(files,Comparator.comparing(File::getName,String.CASE_INSENSITIVE_ORDER));
        StringBuilder s=new StringBuilder("[");
        for(File f:files){
            if(f.getName().startsWith(".upload-")) continue;
            if(s.length()>1)s.append(',');
            String kind=MediaTypes.kind(f.getName());
            String title=null,artist=null; boolean hasArtwork=false;
            if(kind.equals("audio")){
                try{MediaMetadataRetriever r=new MediaMetadataRetriever();r.setDataSource(f.getAbsolutePath());title=r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE);artist=r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST);hasArtwork=r.getEmbeddedPicture()!=null;r.release();}catch(Exception ignored){}
            }
            s.append("{\"name\":\"").append(json(f.getName())).append("\",\"size\":").append(f.length())
             .append(",\"kind\":\"").append(kind).append("\",\"mime\":\"").append(MediaTypes.mime(f.getName()))
             .append("\",\"modified\":").append(f.lastModified()/1000.0).append(",\"hasArtwork\":").append(hasArtwork);
            if(title!=null&&!title.trim().isEmpty())s.append(",\"title\":\"").append(json(title)).append("\"");
            if(artist!=null&&!artist.trim().isEmpty())s.append(",\"artist\":\"").append(json(artist)).append("\"");
            s.append('}');
        }
        s.append(']'); sendJson(out,"200 OK",s.toString());
    }

    private void sendArtwork(OutputStream out,String encoded) throws IOException {
        String name=safeName(urlDecode(encoded));if(name==null){sendText(out,"400 Bad Request","Bad filename");return;}
        File f=new File(root,name);if(!f.isFile()){sendText(out,"404 Not Found","File not found");return;}
        try{MediaMetadataRetriever r=new MediaMetadataRetriever();r.setDataSource(f.getAbsolutePath());byte[] art=r.getEmbeddedPicture();r.release();if(art==null){sendText(out,"404 Not Found","Artwork not found");return;}String type=art.length>4&&art[0]==(byte)0x89&&art[1]==0x50&&art[2]==0x4e&&art[3]==0x47?"image/png":"image/jpeg";writeHeaders(out,"200 OK",art.length,type,(String[])null);out.write(art);}catch(Exception e){sendText(out,"404 Not Found","Artwork not found");}
    }

    private void sendUIIcon(OutputStream out,String encoded) throws IOException {
        String name=urlDecode(encoded).replace(".svg","");String value=GeneratedUIIcons.BASE64.get(name);if(value==null){sendText(out,"404 Not Found","Icon not found");return;}byte[] data=Base64.decode(value,Base64.DEFAULT);writeHeaders(out,"200 OK",data.length,"image/svg+xml; charset=utf-8",(String[])null);out.write(data);
    }

    private void sendFile(OutputStream out,String encoded,Map<String,String> headers,boolean inline) throws IOException {
        String name=safeName(urlDecode(encoded)); if(name==null){sendText(out,"400 Bad Request","Bad filename");return;}
        File f=new File(root,name); if(!f.isFile()){sendText(out,"404 Not Found","File not found");return;}
        long size=f.length(), start=0,end=Math.max(0,size-1); boolean partial=false;
        String range=headers.get("range");
        if(range!=null && range.toLowerCase(Locale.ROOT).startsWith("bytes=") && size>0){
            String spec=range.substring(6).split(",",2)[0]; int dash=spec.indexOf('-');
            try {
                if(dash>=0){String a=spec.substring(0,dash).trim(),b=spec.substring(dash+1).trim();
                    if(a.isEmpty()){long suffix=Long.parseLong(b);start=Math.max(0,size-suffix);} else start=Long.parseLong(a);
                    if(!b.isEmpty())end=Math.min(size-1,Long.parseLong(b)); partial=start>=0&&start<size&&end>=start;}
            }catch(Exception ignored){}
            if(!partial){writeHeaders(out,"416 Range Not Satisfiable",0,"application/octet-stream",null,"Content-Range: bytes */"+size);return;}
        }
        long len=size==0?0:end-start+1;
        List<String> extra=new ArrayList<>(); extra.add("Accept-Ranges: bytes");
        extra.add("Content-Disposition: "+(inline?"inline":"attachment")+"; filename=\""+name.replace("\"","_")+"\"");
        if(partial)extra.add("Content-Range: bytes "+start+"-"+end+"/"+size);
        writeHeaders(out,partial?"206 Partial Content":"200 OK",len,MediaTypes.mime(name),extra.toArray(new String[0]));
        if(len==0)return;
        try(RandomAccessFile raf=new RandomAccessFile(f,"r")){raf.seek(start);byte[]buf=new byte[262144];long remaining=len;while(remaining>0){int n=raf.read(buf,0,(int)Math.min(buf.length,remaining));if(n<0)break;out.write(buf,0,n);remaining-=n;}}
    }

    private void sendHtml(OutputStream out) throws IOException {
        byte[] b=WEB_PAGE.getBytes(StandardCharsets.UTF_8); writeHeaders(out,"200 OK",b.length,"text/html; charset=utf-8",null); out.write(b);
    }
    private void sendJson(OutputStream out,String status,String json) throws IOException {byte[]b=json.getBytes(StandardCharsets.UTF_8);writeHeaders(out,status,b.length,"application/json; charset=utf-8",null);out.write(b);}
    private void sendText(OutputStream out,String status,String text) throws IOException {byte[]b=text.getBytes(StandardCharsets.UTF_8);writeHeaders(out,status,b.length,"text/plain; charset=utf-8",null);out.write(b);}
    private void writeHeaders(OutputStream out,String status,long length,String type,String[] extra) throws IOException {
        StringBuilder s=new StringBuilder("HTTP/1.1 ").append(status).append("\r\nContent-Length: ").append(length).append("\r\nContent-Type: ").append(type).append("\r\nCache-Control: no-store\r\nConnection: close\r\n");
        if(extra!=null)for(String h:extra)s.append(h).append("\r\n"); s.append("\r\n"); out.write(s.toString().getBytes(StandardCharsets.ISO_8859_1));
    }
    private void writeHeaders(OutputStream out,String status,long length,String type,String ignored,String extra) throws IOException {writeHeaders(out,status,length,type,new String[]{extra});}

    private File unique(String name){File f=new File(root,name);if(!f.exists())return f;String ext="",base=name;int p=name.lastIndexOf('.');if(p>0){ext=name.substring(p);base=name.substring(0,p);}for(int i=2;;i++){f=new File(root,base+" "+i+ext);if(!f.exists())return f;}}
    private String query(String target,String key){try{URI u=new URI("http://localhost"+target);String q=u.getRawQuery();if(q==null)return null;for(String part:q.split("&")){String[]kv=part.split("=",2);if(urlDecode(kv[0]).equals(key))return kv.length>1?urlDecode(kv[1]):"";}}catch(Exception ignored){}return null;}
    private String safeName(String n){if(n==null)return null;n=new File(n).getName().trim();if(n.isEmpty()||n.equals(".")||n.equals("..")||n.startsWith("."))return null;return n.replace('/','_').replace('\\','_').replace(':','_');}
    private String urlDecode(String v){try{return URLDecoder.decode(v,StandardCharsets.UTF_8.name());}catch(Exception e){return v;}}
    private String json(String v){return v.replace("\\","\\\\").replace("\"","\\\"").replace("\n","\\n").replace("\r","\\r");}

    static String localIPv4(){
        try{Enumeration<NetworkInterface>ifs=NetworkInterface.getNetworkInterfaces();while(ifs.hasMoreElements()){NetworkInterface ni=ifs.nextElement();if(!ni.isUp()||ni.isLoopback())continue;Enumeration<InetAddress>as=ni.getInetAddresses();while(as.hasMoreElements()){InetAddress a=as.nextElement();if(a instanceof Inet4Address&&!a.isLoopbackAddress())return a.getHostAddress();}}}catch(Exception ignored){}return null;
    }

    private static final String WEB_PAGE = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width,initial-scale=1">
          <title>Local Web Share</title>
          <style>
            :root { color-scheme: light dark; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; --accent:#0a84ff; --accent-soft:color-mix(in srgb,var(--accent) 15%,Canvas); }
            * { box-sizing:border-box; }
            body { margin:0; background:Canvas; color:CanvasText; }
            body[data-theme="forest"] { --accent:#26935b; }
            body[data-theme="sunset"] { --accent:#ef6334; }
            body[data-theme="violet"] { --accent:#8650ed; }
            body[data-theme="system"] { --accent:Highlight; }
            .shell { max-width:1180px; margin:0 auto; padding:12px 14px 56px; }
            .card { border:1px solid color-mix(in srgb,CanvasText 15%,transparent); border-radius:15px; padding:12px; margin:0 0 10px; background:color-mix(in srgb,Canvas 95%,CanvasText 5%); }
            .drop { border:2px dashed color-mix(in srgb,CanvasText 25%,transparent); border-radius:13px; min-height:92px; padding:16px; display:grid; place-items:center; text-align:center; transition:.15s ease; cursor:pointer; }
            .drop.drag { border-color:var(--accent); background:var(--accent-soft); transform:scale(1.003); }
            .drop strong { display:block; font-size:16px; margin-bottom:3px; } .drop small { opacity:.62; }
            #picker { display:none; } #status { white-space:pre-wrap; font-size:12px; margin:7px 0 3px; min-height:14px; } progress { width:100%; height:6px; accent-color:var(--accent); }
            .files-head { display:flex; gap:10px; align-items:center; margin:4px 0 9px; }
            .filters { display:flex; gap:7px; overflow:auto; scrollbar-width:none; flex:1; padding:2px 0; } .filters::-webkit-scrollbar{display:none}
            .filter { white-space:nowrap; border-radius:999px; min-height:31px; padding:6px 10px; font-size:12px; font-weight:650; }
            .filter.active { border-color:color-mix(in srgb,var(--accent) 65%,transparent); background:var(--accent-soft); }
            .count { opacity:.6; font-size:12px; white-space:nowrap; }
            button,.btn,select { appearance:none; border:1px solid color-mix(in srgb,CanvasText 18%,transparent); border-radius:9px; background:color-mix(in srgb,CanvasText 6%,Canvas); color:inherit; padding:7px 10px; font:inherit; text-decoration:none; cursor:pointer; display:inline-flex; align-items:center; justify-content:center; gap:6px; min-height:34px; }
            button:hover,.btn:hover { background:color-mix(in srgb,CanvasText 11%,Canvas); }
            .settings-button { margin-left:auto; color:var(--accent); font-size:17px; min-width:38px; }
            .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(220px,1fr)); gap:11px; }
            .file { border:1px solid color-mix(in srgb,CanvasText 14%,transparent); border-radius:14px; overflow:hidden; background:Canvas; min-width:0; }
            .preview { width:100%; height:150px; border:0; border-radius:0; padding:0; margin:0; display:grid; place-items:center; background:color-mix(in srgb,CanvasText 7%,Canvas); cursor:pointer; overflow:hidden; }
            .preview img,.preview video { width:100%; height:100%; object-fit:cover; display:block; } .preview video { pointer-events:none; }
            .icon { font-size:44px; opacity:.72; } .body { padding:10px; } .name { font-weight:650; overflow-wrap:anywhere; line-height:1.25; cursor:pointer; }
            .meta,.audio-meta { font-size:11px; opacity:.62; margin-top:4px; } .audio-meta { opacity:.82; }
            .audio-mini { display:grid; grid-template-columns:auto 1fr auto; gap:7px; align-items:center; margin-top:8px; }
            .audio-mini input[type=range] { width:100%; min-width:0; accent-color:var(--accent); } .time { font-size:10px; opacity:.6; font-variant-numeric:tabular-nums; }
            .actions { display:flex; gap:6px; margin-top:9px; align-items:center; } .danger { margin-left:auto; }
            .ui-icon { width:18px; height:18px; object-fit:contain; display:none; } .fallback-icon { display:none; font-size:16px; line-height:1; }
            body[data-button-mode="icons"] .short-label,body[data-button-mode="icons"] .full-label { display:none; }
            body[data-button-mode="icons"] .ui-icon,body[data-button-mode="icons"] .fallback-icon { display:inline-block; }
            body[data-button-mode="compact"] .ui-icon,body[data-button-mode="compact"] .fallback-icon { display:inline-block; }
            body[data-button-mode="compact"] .full-label { display:none; }
            body[data-button-mode="text"] .short-label,body[data-button-mode="text"] .ui-icon,body[data-button-mode="text"] .fallback-icon { display:none; }
            body[data-view="list"] .grid { display:block; }
            body[data-view="list"] .file { display:grid; grid-template-columns:150px minmax(0,1fr); margin-bottom:9px; }
            body[data-view="list"] .preview { height:118px; }
            .empty { padding:35px 12px; text-align:center; opacity:.65; }
            dialog { width:min(980px,calc(100vw - 18px)); max-height:calc(100vh - 18px); border:0; border-radius:17px; padding:0; background:Canvas; color:CanvasText; box-shadow:0 25px 80px #0008; overflow:hidden; }
            dialog::backdrop { background:#0009; backdrop-filter:blur(5px); }
            .modal-head { display:flex; gap:6px; align-items:center; border-bottom:1px solid color-mix(in srgb,CanvasText 14%,transparent); padding:9px 10px; }
            .modal-title { font-weight:700; overflow-wrap:anywhere; flex:1; min-width:0; }
            .modal-content-wrap { position:relative; background:#000; }
            .modal-content { min-height:300px; height:min(76vh,760px); overflow:auto; display:grid; place-items:center; background:#000; touch-action:pan-y; }
            .modal-content img,.modal-content video { max-width:100%; max-height:100%; } .modal-content audio { width:min(680px,calc(100% - 40px)); }
            .nav-arrow { position:absolute; z-index:3; top:50%; transform:translateY(-50%); width:42px; height:54px; border-radius:13px; background:#0008; color:white; border-color:#fff4; }
            .nav-arrow.prev { left:8px; } .nav-arrow.next { right:8px; } .nav-arrow:disabled { opacity:.2; cursor:default; }
            .viewer-position { font-size:11px; opacity:.65; white-space:nowrap; }
            .settings-backdrop { position:fixed; inset:0; background:#0005; opacity:0; pointer-events:none; transition:.18s ease; z-index:20; }
            .settings { position:fixed; z-index:21; right:0; top:0; bottom:0; width:min(350px,88vw); padding:18px; background:color-mix(in srgb,Canvas 93%,CanvasText 7%); box-shadow:-18px 0 50px #0005; transform:translateX(105%); transition:.22s ease; overflow:auto; }
            body.settings-open .settings { transform:translateX(0); } body.settings-open .settings-backdrop { opacity:1; pointer-events:auto; }
            .settings-head { display:flex; align-items:center; gap:8px; margin-bottom:22px; }.settings-head h2{font-size:20px;margin:0;flex:1}.settings-group{margin:0 0 22px}.settings-group h3{font-size:11px;letter-spacing:.08em;text-transform:uppercase;opacity:.55;margin:0 0 9px}.settings label{display:block;font-size:13px;margin:8px 0 4px}.settings select{width:100%}.theme-row{display:grid;grid-template-columns:repeat(5,1fr);gap:7px}.theme-swatch{height:35px;padding:0;border-radius:10px}.theme-swatch[data-theme-choice="ocean"]{background:#0a84ff}.theme-swatch[data-theme-choice="forest"]{background:#26935b}.theme-swatch[data-theme-choice="sunset"]{background:#ef6334}.theme-swatch[data-theme-choice="violet"]{background:#8650ed}.theme-swatch[data-theme-choice="system"]{background:linear-gradient(135deg,#111,#eee)}.theme-swatch.selected{outline:3px solid var(--accent);outline-offset:2px}
            @media (max-width:560px) { .shell{padding:8px 8px 40px}.grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:7px}.preview{height:118px}.body{padding:8px}.actions{gap:4px}.action-button,.btn{padding-inline:7px}.nav-arrow{width:36px}.modal-head{gap:4px} body[data-view="list"] .file{grid-template-columns:105px minmax(0,1fr)} body[data-view="list"] .preview{height:105px} }
          </style>
        </head>
        <body data-button-mode="compact" data-view="grid" data-theme="ocean">
          <main class="shell">
            <section class="card">
              <div id="drop" class="drop" tabindex="0"><div><strong>Drop files here</strong><small>or click to choose — upload starts automatically</small></div></div>
              <input id="picker" type="file" multiple><div id="status"></div><progress id="progress" value="0" max="1" hidden></progress>
            </section>
            <div class="files-head">
              <div id="filters" class="filters"></div>
              <span id="count" class="count"></span>
              <button id="settingsButton" class="settings-button" type="button" aria-label="Settings">⚙</button>
            </div>
            <div id="files" class="grid">Loading…</div>
          </main>
          <div id="settingsBackdrop" class="settings-backdrop"></div>
          <aside id="settings" class="settings" aria-label="Settings">
            <div class="settings-head"><h2>Settings</h2><button id="settingsClose" type="button" aria-label="Close settings">×</button></div>
            <div class="settings-group"><h3>Buttons</h3><label for="buttonMode">Labels</label><select id="buttonMode"><option value="text">Text</option><option value="icons">Icons</option><option value="compact">Icon + short</option></select></div>
            <div class="settings-group"><h3>Files</h3><label for="viewMode">Layout</label><select id="viewMode"><option value="grid">Grid</option><option value="list">List</option></select></div>
            <div class="settings-group"><h3>Colour theme</h3><div class="theme-row"><button class="theme-swatch" data-theme-choice="system" title="System"></button><button class="theme-swatch" data-theme-choice="ocean" title="Ocean"></button><button class="theme-swatch" data-theme-choice="forest" title="Forest"></button><button class="theme-swatch" data-theme-choice="sunset" title="Sunset"></button><button class="theme-swatch" data-theme-choice="violet" title="Violet"></button></div></div>
            <div class="settings-group"><h3>Playback</h3><p style="font-size:12px;opacity:.65;margin:0">Only one audio or video player can play at a time.</p></div>
          </aside>
          <dialog id="viewer">
            <div class="modal-head">
              <button id="viewerPrev" class="action-button" type="button"></button><button id="viewerNext" class="action-button" type="button"></button>
              <div id="viewerTitle" class="modal-title"></div><span id="viewerPosition" class="viewer-position"></span>
              <a id="viewerDownload" class="btn action-button" download></a><button id="viewerDelete" class="action-button" type="button"></button><button id="viewerClose" class="action-button" type="button"></button>
            </div>
            <div class="modal-content-wrap"><button id="overlayPrev" class="nav-arrow prev" aria-label="Previous">‹</button><div id="viewerContent" class="modal-content"></div><button id="overlayNext" class="nav-arrow next" aria-label="Next">›</button></div>
          </dialog>
          <script>
            const q=s=>document.querySelector(s), filesEl=q('#files'),countEl=q('#count'),statusEl=q('#status'),progressEl=q('#progress'),dropEl=q('#drop'),pickerEl=q('#picker'),viewer=q('#viewer'),viewerTitle=q('#viewerTitle'),viewerContent=q('#viewerContent'),viewerDownload=q('#viewerDownload'),viewerPosition=q('#viewerPosition'),buttonMode=q('#buttonMode'),viewMode=q('#viewMode'),filtersEl=q('#filters');
            let currentFiles=[],viewerFiles=[],viewerIndex=-1,touchStartX=null,currentFilter='all';
            const glyph={preview:'👁',download:'↓',delete:'⌫',close:'×',play:'▶',pause:'Ⅱ',share:'↗',previous:'‹',next:'›',config:'⚙'};
            const filterDefs=[['all','All'],['image','Images'],['audio','Audio'],['video','Video'],['document','Docs'],['file','Other']];
            function bytes(n){const u=['B','KB','MB','GB','TB'];let i=0,v=Number(n);while(v>=1024&&i<u.length-1){v/=1024;i++}return `${v.toFixed(i?1:0)} ${u[i]}`}
            function time(v){if(!Number.isFinite(v)||v<0)return '0:00';v=Math.floor(v);return `${Math.floor(v/60)}:${String(v%60).padStart(2,'0')}`}
            function mediaURL(f){return '/media/'+encodeURIComponent(f.name)} function downloadURL(f){return '/files/'+encodeURIComponent(f.name)} function artworkURL(f){return '/artwork/'+encodeURIComponent(f.name)}
            function iconName(kind){return kind==='image'?'photo':kind==='audio'?'sound-on':kind==='video'?'video':'file'}
            function uiIcon(name){const img=document.createElement('img');img.className='ui-icon';img.src='/ui-icon/'+name+'.svg';img.alt='';img.onerror=()=>{img.style.display='none';const fb=img.nextElementSibling;if(fb)fb.style.display='inline-block'};return img}
            function setAction(el,icon,full,short=full){el.classList.add('action-button');el.replaceChildren();el.append(uiIcon(icon));const fb=document.createElement('span');fb.className='fallback-icon';fb.textContent=glyph[icon]||'•';const f=document.createElement('span');f.className='full-label';f.textContent=full;const s=document.createElement('span');s.className='short-label';s.textContent=short;el.append(fb,f,s);el.title=full;el.setAttribute('aria-label',full)}
            function applyMode(mode){if(!['text','icons','compact'].includes(mode))mode='compact';document.body.dataset.buttonMode=mode;buttonMode.value=mode;localStorage.setItem('lws-button-mode',mode)}
            function applyView(mode){if(!['grid','list'].includes(mode))mode='grid';document.body.dataset.view=mode;viewMode.value=mode;localStorage.setItem('lws-view-mode',mode)}
            function applyTheme(theme){if(!['system','ocean','forest','sunset','violet'].includes(theme))theme='ocean';document.body.dataset.theme=theme;localStorage.setItem('lws-theme',theme);document.querySelectorAll('.theme-swatch').forEach(x=>x.classList.toggle('selected',x.dataset.themeChoice===theme))}
            setAction(q('#settingsButton'),'config','Settings','Settings');setAction(q('#settingsClose'),'close','Close','Close');applyMode(localStorage.getItem('lws-button-mode')||'compact');applyView(localStorage.getItem('lws-view-mode')||'grid');applyTheme(localStorage.getItem('lws-theme')||'ocean');buttonMode.onchange=()=>applyMode(buttonMode.value);viewMode.onchange=()=>applyView(viewMode.value);document.querySelectorAll('.theme-swatch').forEach(x=>x.onclick=()=>applyTheme(x.dataset.themeChoice));
            q('#settingsButton').onclick=()=>document.body.classList.add('settings-open');q('#settingsClose').onclick=q('#settingsBackdrop').onclick=()=>document.body.classList.remove('settings-open');
            function visibleFiles(){return currentFilter==='all'?currentFiles:currentFiles.filter(f=>f.kind===currentFilter)}
            function pauseOtherMedia(except){document.querySelectorAll('audio,video').forEach(m=>{if(m!==except&&!m.paused)m.pause()})}
            function bindExclusive(media){media.addEventListener('play',()=>pauseOtherMedia(media));return media}
            function genericPreview(f){const d=document.createElement('div');d.className='icon';const i=uiIcon(iconName(f.kind));i.style.width='54px';i.style.height='54px';i.style.display='block';i.onerror=()=>{i.remove();d.textContent=f.kind==='audio'?'🎵':f.kind==='video'?'🎬':f.kind==='image'?'🖼️':'📄'};d.append(i);return d}
            function previewElement(f,large=false){const url=mediaURL(f);if(f.kind==='image'){const x=new Image;x.src=url;x.alt=f.name;x.loading=large?'eager':'lazy';return x}if(f.kind==='video'){const v=bindExclusive(document.createElement('video'));v.src=url;v.preload='metadata';v.playsInline=true;if(large){v.controls=true;v.autoplay=true}else{v.muted=true;v.tabIndex=-1}return v}if(f.kind==='audio'){if(!large&&f.hasArtwork){const x=new Image;x.src=artworkURL(f);x.alt=f.title||f.name;x.loading='lazy';return x}if(large){const box=document.createElement('div');box.style.width='min(700px,90%)';box.style.color='white';box.style.textAlign='center';if(f.hasArtwork){const x=new Image;x.src=artworkURL(f);x.style.maxWidth='280px';x.style.maxHeight='280px';x.style.borderRadius='14px';box.append(x)}const t=document.createElement('h3');t.textContent=f.title||f.name;box.append(t);if(f.artist){const a=document.createElement('p');a.textContent=f.artist;a.style.opacity='.7';box.append(a)}const audio=bindExclusive(document.createElement('audio'));audio.src=url;audio.controls=true;audio.autoplay=true;audio.preload='metadata';box.append(audio);return box}}return genericPreview(f)}
            function showViewer(i){viewerFiles=visibleFiles();if(!viewerFiles.length)return;viewerIndex=Math.max(0,Math.min(i,viewerFiles.length-1));const f=viewerFiles[viewerIndex];pauseOtherMedia(null);viewerTitle.textContent=f.title||f.name;viewerPosition.textContent=`${viewerIndex+1} / ${viewerFiles.length}`;viewerDownload.href=downloadURL(f);viewerDownload.download=f.name;viewerContent.replaceChildren(previewElement(f,true));for(const id of ['viewerPrev','overlayPrev'])q('#'+id).disabled=viewerIndex<=0;for(const id of ['viewerNext','overlayNext'])q('#'+id).disabled=viewerIndex>=viewerFiles.length-1;if(!viewer.open)viewer.showModal()}
            function openPreview(f){viewerFiles=visibleFiles();const i=viewerFiles.findIndex(x=>x.name===f.name);showViewer(i<0?0:i)} function closePreview(){pauseOtherMedia(null);viewer.close();viewerContent.replaceChildren()}
            function prev(){if(viewerIndex>0)showViewer(viewerIndex-1)} function next(){if(viewerIndex+1<viewerFiles.length)showViewer(viewerIndex+1)}
            setAction(q('#viewerPrev'),'previous','Previous','Prev');setAction(q('#viewerNext'),'next','Next','Next');setAction(viewerDownload,'download','Download','Down');setAction(q('#viewerDelete'),'delete','Delete','Del');setAction(q('#viewerClose'),'close','Close','Close');q('#viewerPrev').onclick=q('#overlayPrev').onclick=prev;q('#viewerNext').onclick=q('#overlayNext').onclick=next;q('#viewerClose').onclick=closePreview;q('#viewerDelete').onclick=()=>{const f=viewerFiles[viewerIndex];if(f)removeFile(f,true).catch(showError)};
            viewer.addEventListener('click',e=>{if(e.target===viewer)closePreview()});viewerContent.addEventListener('touchstart',e=>{touchStartX=e.changedTouches[0].clientX},{passive:true});viewerContent.addEventListener('touchend',e=>{if(touchStartX==null)return;const dx=e.changedTouches[0].clientX-touchStartX;touchStartX=null;if(dx>60)prev();else if(dx<-60)next()},{passive:true});document.addEventListener('keydown',e=>{if(!viewer.open)return;if(e.key==='ArrowLeft')prev();else if(e.key==='ArrowRight')next();else if(e.key==='Escape')closePreview()});
            function audioMini(f){const wrap=document.createElement('div');wrap.className='audio-mini';const audio=bindExclusive(document.createElement('audio'));audio.src=mediaURL(f);audio.preload='metadata';const play=document.createElement('button');setAction(play,'play','Play','Play');const seek=document.createElement('input');seek.type='range';seek.min=0;seek.max=1;seek.step=.01;seek.value=0;const tm=document.createElement('span');tm.className='time';tm.textContent='0:00';play.onclick=e=>{e.stopPropagation();audio.paused?audio.play():audio.pause()};audio.onplay=()=>setAction(play,'pause','Pause','Pause');audio.onpause=()=>setAction(play,'play','Play','Play');audio.onloadedmetadata=()=>{seek.max=Number.isFinite(audio.duration)?audio.duration:1};audio.ontimeupdate=()=>{seek.value=audio.currentTime;tm.textContent=time(audio.currentTime)};seek.oninput=e=>{e.stopPropagation();audio.currentTime=Number(seek.value)};seek.onclick=e=>e.stopPropagation();wrap.append(play,seek,tm,audio);audio.hidden=true;return wrap}
            function renderFilters(){filtersEl.replaceChildren();for(const [kind,label] of filterDefs){const b=document.createElement('button');b.className='filter'+(currentFilter===kind?' active':'');b.textContent=label;b.onclick=()=>{currentFilter=kind;localStorage.setItem('lws-filter',kind);renderFilters();renderFiles()};filtersEl.append(b)}}
            function renderFiles(){const visible=visibleFiles();filesEl.innerHTML='';countEl.textContent=currentFilter==='all'?`${visible.length} files`:`${visible.length} / ${currentFiles.length}`;if(!visible.length){const e=document.createElement('div');e.className='empty';e.textContent='No files in this category.';filesEl.append(e);return}for(const f of visible){const card=document.createElement('article');card.className='file';const p=document.createElement('button');p.className='preview';p.type='button';p.append(previewElement(f));p.onclick=()=>openPreview(f);const body=document.createElement('div');body.className='body';const n=document.createElement('div');n.className='name';n.textContent=f.title||f.name;n.onclick=()=>openPreview(f);body.append(n);if(f.kind==='audio'&&f.artist){const am=document.createElement('div');am.className='audio-meta';am.textContent=f.artist;body.append(am)}const m=document.createElement('div');m.className='meta';m.textContent=`${f.kind.toUpperCase()} • ${f.mime} • ${bytes(f.size)}`;body.append(m);if(f.kind==='audio')body.append(audioMini(f));const ac=document.createElement('div');ac.className='actions';const view=document.createElement('button');setAction(view,'preview','Preview','View');view.onclick=()=>openPreview(f);const d=document.createElement('a');d.className='btn';setAction(d,'download','Download','Down');d.href=downloadURL(f);d.download=f.name;const del=document.createElement('button');del.className='danger';setAction(del,'delete','Delete','Del');del.onclick=()=>removeFile(f).catch(showError);ac.append(view,d,del);body.append(ac);card.append(p,body);filesEl.append(card)}}
            async function removeFile(f,fromViewer=false){if(!confirm(`Delete ${f.name}?`))return;const r=await fetch('/files/'+encodeURIComponent(f.name),{method:'DELETE'});if(!r.ok)throw Error(await r.text());const old=viewerIndex;await refresh();if(fromViewer){viewerFiles=visibleFiles();if(!viewerFiles.length)closePreview();else showViewer(Math.min(old,viewerFiles.length-1))}}
            async function refresh(){const r=await fetch('/api/files',{cache:'no-store'});if(!r.ok)throw Error(await r.text());currentFiles=await r.json();renderFilters();renderFiles()}
            async function uploadFile(file,index,total){statusEl.textContent=`Uploading ${index+1}/${total}: ${file.name}`;progressEl.hidden=false;progressEl.value=index/total;const r=await fetch('/upload?filename='+encodeURIComponent(file.name),{method:'POST',headers:{'Content-Type':file.type||'application/octet-stream'},body:file});if(!r.ok)throw Error(await r.text());progressEl.value=(index+1)/total}
            async function uploadFiles(list){const a=[...list].filter(Boolean);if(!a.length)return;try{for(let i=0;i<a.length;i++)await uploadFile(a[i],i,a.length);statusEl.textContent=`Uploaded ${a.length} file${a.length===1?'':'s'}.`;pickerEl.value='';await refresh()}catch(e){showError(e)}finally{setTimeout(()=>progressEl.hidden=true,900)}} function showError(e){statusEl.textContent='Error: '+(e?.message||e)}
            currentFilter=localStorage.getItem('lws-filter')||'all';if(!filterDefs.some(x=>x[0]===currentFilter))currentFilter='all';dropEl.onclick=()=>pickerEl.click();dropEl.onkeydown=e=>{if(e.key==='Enter'||e.key===' ')pickerEl.click()};pickerEl.onchange=()=>uploadFiles(pickerEl.files);for(const e of ['dragenter','dragover'])document.addEventListener(e,x=>{x.preventDefault();dropEl.classList.add('drag')});for(const e of ['dragleave','drop'])document.addEventListener(e,x=>{x.preventDefault();dropEl.classList.remove('drag')});document.addEventListener('drop',e=>uploadFiles(e.dataTransfer.files));refresh().catch(e=>{filesEl.textContent='Could not load files.';showError(e)});
          </script>
        </body>
        </html>
""";
}
