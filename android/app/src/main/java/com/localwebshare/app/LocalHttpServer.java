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
          <title>Shar</title>
          <style>
            :root { color-scheme: light dark; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; --accent:#0a84ff; --accent-soft:color-mix(in srgb,var(--accent) 15%,Canvas); --card-min:150px; --text-scale:.90; --grid-gap:8px; }
            * { box-sizing:border-box; }
            html { font-size:calc(16px * var(--text-scale)); }
            body { margin:0; background:Canvas; color:CanvasText; }
            body[data-theme="forest"] { --accent:#26935b; }
            body[data-theme="sunset"] { --accent:#ef6334; }
            body[data-theme="violet"] { --accent:#8650ed; }
            body[data-theme="system"] { --accent:Highlight; }
            .shell { max-width:1320px; margin:0 auto; padding:8px 10px 42px; }
            .card { border:1px solid color-mix(in srgb,CanvasText 14%,transparent); border-radius:13px; padding:8px; margin:0 0 7px; background:color-mix(in srgb,Canvas 96%,CanvasText 4%); }
            .drop { border:1.5px dashed color-mix(in srgb,CanvasText 24%,transparent); border-radius:11px; min-height:64px; padding:9px 12px; display:grid; place-items:center; text-align:center; transition:.15s ease; cursor:pointer; }
            .drop.drag { border-color:var(--accent); background:var(--accent-soft); transform:scale(1.002); }
            .drop strong { display:block; font-size:.95rem; margin-bottom:2px; } .drop small { opacity:.6; font-size:.78rem; }
            #picker { display:none; } #status { white-space:pre-wrap; font-size:.72rem; margin:5px 0 2px; min-height:10px; } progress { width:100%; height:5px; accent-color:var(--accent); }
            .files-head { display:flex; gap:7px; align-items:center; margin:2px 0 7px; }
            .filters { display:flex; gap:5px; overflow:auto; scrollbar-width:none; flex:1; padding:2px 0; } .filters::-webkit-scrollbar{display:none}
            .filter { white-space:nowrap; border-radius:999px; min-height:28px; padding:4px 9px; font-size:.74rem; font-weight:650; }
            .filter.active { border-color:color-mix(in srgb,var(--accent) 65%,transparent); background:var(--accent-soft); }
            .count { opacity:.58; font-size:.72rem; white-space:nowrap; }
            button,.btn,select,input { font:inherit; }
            button,.btn,select { appearance:none; border:1px solid color-mix(in srgb,CanvasText 18%,transparent); border-radius:8px; background:color-mix(in srgb,CanvasText 6%,Canvas); color:inherit; padding:5px 8px; text-decoration:none; cursor:pointer; display:inline-flex; align-items:center; justify-content:center; gap:5px; min-height:30px; }
            button:hover,.btn:hover { background:color-mix(in srgb,CanvasText 11%,Canvas); }
            .head-tools { display:flex; gap:5px; margin-left:auto; } .settings-button,.info-button { color:var(--accent); min-width:34px; }
            .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(min(var(--card-min),calc(50% - var(--grid-gap))),1fr)); gap:var(--grid-gap); align-items:start; }
            .file { border:1px solid color-mix(in srgb,CanvasText 13%,transparent); border-radius:11px; overflow:hidden; background:Canvas; min-width:0; }
            .preview { width:100%; aspect-ratio:16/10; height:auto; border:0; border-radius:0; padding:0; margin:0; display:grid; place-items:center; background:color-mix(in srgb,CanvasText 7%,Canvas); cursor:pointer; overflow:hidden; }
            .preview img,.preview video { width:100%; height:100%; object-fit:cover; display:block; } .preview video { pointer-events:none; }
            .icon { font-size:2.5rem; opacity:.72; } .body { padding:7px; } .name { font-weight:650; overflow-wrap:anywhere; line-height:1.2; cursor:pointer; }
            .meta,.audio-meta { font-size:.68rem; opacity:.6; margin-top:3px; line-height:1.2; } .audio-meta { opacity:.78; }
            .audio-mini { display:grid; grid-template-columns:auto minmax(40px,1fr) auto; gap:5px; align-items:center; margin-top:6px; }
            .audio-mini button { min-width:30px; padding-inline:5px; }
            .audio-mini input[type=range] { width:100%; min-width:0; accent-color:var(--accent); } .time { font-size:.64rem; opacity:.6; font-variant-numeric:tabular-nums; }
            .actions { display:flex; gap:4px; margin-top:6px; align-items:center; } .danger { margin-left:auto; }
            .actions .action-button,.actions .btn { min-width:31px; padding-inline:6px; }
            .ui-icon { width:17px; height:17px; object-fit:contain; display:none; } .fallback-icon { display:none; font-size:1rem; line-height:1; }
            body[data-button-mode="icons"] .short-label,body[data-button-mode="icons"] .full-label { display:none; }
            body[data-button-mode="icons"] .ui-icon { display:inline-block; }
            body[data-button-mode="icons"] .fallback-icon.missing { display:inline-block; }
            body[data-button-mode="compact"] .ui-icon { display:inline-block; }
            body[data-button-mode="compact"] .fallback-icon.missing { display:inline-block; }
            body[data-button-mode="compact"] .full-label { display:none; }
            body[data-button-mode="text"] .short-label,body[data-button-mode="text"] .ui-icon,body[data-button-mode="text"] .fallback-icon { display:none; }
            body[data-view="list"] .grid { display:block; }
            body[data-view="list"] .file { display:grid; grid-template-columns:clamp(92px,var(--card-min),180px) minmax(0,1fr); margin-bottom:7px; }
            body[data-view="list"] .preview { height:100%; min-height:92px; aspect-ratio:auto; }
            .empty { padding:30px 10px; text-align:center; opacity:.65; }
            dialog { width:min(980px,calc(100vw - 18px)); max-height:calc(100vh - 18px); border:0; border-radius:15px; padding:0; background:Canvas; color:CanvasText; box-shadow:0 25px 80px #0008; overflow:hidden; }
            dialog::backdrop { background:#0009; backdrop-filter:blur(5px); }
            .modal-head { display:flex; gap:5px; align-items:center; border-bottom:1px solid color-mix(in srgb,CanvasText 14%,transparent); padding:7px 8px; }
            .modal-title { font-weight:700; overflow-wrap:anywhere; flex:1; min-width:0; }
            .modal-content-wrap { position:relative; background:#000; }
            .modal-content { min-height:300px; height:min(76vh,760px); overflow:auto; display:grid; place-items:center; background:#000; touch-action:pan-y; }
            .modal-content img,.modal-content video { width:100%; height:100%; max-width:100%; max-height:100%; object-fit:contain; display:block; } .modal-content audio { width:min(680px,calc(100% - 40px)); }
            .nav-arrow { position:absolute; z-index:3; top:50%; transform:translateY(-50%); width:40px; height:52px; border-radius:11px; background:#0008; color:white; border-color:#fff4; }
            .nav-arrow.prev { left:7px; } .nav-arrow.next { right:7px; } .nav-arrow:disabled { opacity:.2; cursor:default; }
            .viewer-position { font-size:.68rem; opacity:.65; white-space:nowrap; }
            .settings-backdrop { position:fixed; inset:0; background:#0005; opacity:0; pointer-events:none; transition:.18s ease; z-index:20; }
            .settings { position:fixed; z-index:21; right:0; top:0; bottom:0; width:min(360px,90vw); padding:16px; background:color-mix(in srgb,Canvas 94%,CanvasText 6%); box-shadow:-18px 0 50px #0005; transform:translateX(105%); transition:.22s ease; overflow:auto; }
            body.settings-open .settings { transform:translateX(0); } body.settings-open .settings-backdrop { opacity:1; pointer-events:auto; }
            .settings-head { display:flex; align-items:center; gap:8px; margin-bottom:18px; }.settings-head h2{font-size:1.15rem;margin:0;flex:1}.settings-group{margin:0 0 19px}.settings-group h3{font-size:.68rem;letter-spacing:.08em;text-transform:uppercase;opacity:.55;margin:0 0 8px}.settings label{display:block;font-size:.8rem;margin:8px 0 4px}.settings select{width:100%}.settings input[type=range]{width:100%;accent-color:var(--accent)}
            .range-label { display:flex!important; align-items:center; gap:8px; }.range-label span{flex:1}.range-label output{font-variant-numeric:tabular-nums;opacity:.65;font-size:.74rem}.settings-actions{display:flex;gap:6px;margin-top:9px}.settings-actions button{flex:1;font-size:.76rem}.settings-note{font-size:.72rem;opacity:.62;margin:7px 0 0;line-height:1.35}.toggle-label{display:flex!important;gap:8px;align-items:center}.toggle-label input{width:auto}.updates{padding:8px 12px 16px;max-height:min(70vh,620px);overflow:auto}.update{padding:10px 2px;border-bottom:1px solid color-mix(in srgb,CanvasText 12%,transparent)}.update:last-child{border-bottom:0}.update-head{display:flex;gap:8px;align-items:baseline}.update-version{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-weight:750;font-size:.78rem}.update-title{font-weight:700;font-size:.82rem}.update p{margin:4px 0 0;font-size:.74rem;opacity:.68;line-height:1.35}
            .theme-row{display:grid;grid-template-columns:repeat(5,1fr);gap:6px}.theme-swatch{height:32px;padding:0;border-radius:9px}.theme-swatch[data-theme-choice="ocean"]{background:#0a84ff}.theme-swatch[data-theme-choice="forest"]{background:#26935b}.theme-swatch[data-theme-choice="sunset"]{background:#ef6334}.theme-swatch[data-theme-choice="violet"]{background:#8650ed}.theme-swatch[data-theme-choice="system"]{background:linear-gradient(135deg,#111,#eee)}.theme-swatch.selected{outline:2px solid var(--accent);outline-offset:2px}
            .remote-body{padding:13px;display:grid;gap:11px}.remote-summary{font-size:.78rem;opacity:.7}.remote-link{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:6px}.remote-link input{min-width:0;border:1px solid color-mix(in srgb,CanvasText 18%,transparent);border-radius:8px;padding:7px;background:Canvas;color:CanvasText}.remote-qr{width:min(230px,72vw);height:auto;justify-self:center;background:white;border-radius:12px;padding:8px}.remote-actions{display:flex;flex-wrap:wrap;gap:6px}.remote-actions button{flex:1;min-width:110px}.remote-progress{width:100%;height:8px}.remote-note{font-size:.7rem;opacity:.62;line-height:1.35}.remote-status{font-size:.78rem;font-weight:650}.remote-status[data-state="live"]{color:#2fbf75}.remote-status[data-state="bad"]{color:#e05260}.remote-picker{display:none}
            @media (max-width:560px) { .shell{padding:6px 6px 32px}.card{padding:6px}.drop{min-height:56px}.files-head{gap:5px}.body{padding:6px}.actions{gap:3px}.action-button,.btn{padding-inline:5px}.nav-arrow{width:34px}.modal-head{gap:3px} body[data-view="list"] .file{grid-template-columns:96px minmax(0,1fr)} }
          </style>
        </head>
        <body data-button-mode="icons" data-view="grid" data-theme="ocean">
          <main class="shell">
            <section class="card">
              <div id="drop" class="drop" tabindex="0"><div><strong>Drop files here</strong><small>or click to choose — upload starts automatically</small></div></div>
              <input id="picker" type="file" multiple><div id="status"></div><progress id="progress" value="0" max="1" hidden></progress>
            </section>
            <div class="files-head">
              <div id="filters" class="filters"></div>
              <span id="count" class="count"></span>
              <div class="head-tools"><button id="remoteLocalButton" class="info-button" type="button" aria-label="Remote share files or folder" title="Remote share">↗</button><button id="infoButton" class="info-button" type="button" aria-label="Developer updates" hidden>ⓘ</button><button id="settingsButton" class="settings-button" type="button" aria-label="Settings">⚙</button></div>
            </div>
            <div id="files" class="grid">Loading…</div>
          </main>
          <div id="settingsBackdrop" class="settings-backdrop"></div>
          <aside id="settings" class="settings" aria-label="Settings">
            <div class="settings-head"><h2>Settings</h2><button id="settingsClose" type="button" aria-label="Close settings"></button></div>
            <div class="settings-group"><h3>Layout preset</h3><label for="presetSelect">Preset</label><select id="presetSelect"><option value="minimal">Minimal</option><option value="balanced">Balanced</option><option value="large">Large</option><option value="saved">My saved preset</option><option value="custom">Custom</option></select><div class="settings-actions"><button id="savePreset" type="button">Save current</button><button id="resetMinimal" type="button">Use minimal</button></div><p class="settings-note">Minimal is the default. Saving stores the current buttons, layout, theme, thumbnail size and text size in this browser.</p></div>
            <div class="settings-group"><h3>Buttons</h3><label for="buttonMode">Labels</label><select id="buttonMode"><option value="text">Text</option><option value="icons">Icons</option><option value="compact">Icon + short</option></select></div>
            <div class="settings-group"><h3>Files</h3><label for="viewMode">Layout</label><select id="viewMode"><option value="grid">Grid</option><option value="list">List</option></select><label class="range-label" for="thumbSize"><span>Thumbnail / card size</span><output id="thumbValue"></output></label><input id="thumbSize" type="range" min="120" max="320" step="10"><label class="range-label" for="textScale"><span>Text size</span><output id="textValue"></output></label><input id="textScale" type="range" min="75" max="125" step="5"><p class="settings-note">Smaller thumbnails automatically fit more grid columns. On narrow screens the grid keeps at least two columns.</p></div>
            <div class="settings-group"><h3>Colour theme</h3><div class="theme-row"><button class="theme-swatch" data-theme-choice="system" title="System"></button><button class="theme-swatch" data-theme-choice="ocean" title="Ocean"></button><button class="theme-swatch" data-theme-choice="forest" title="Forest"></button><button class="theme-swatch" data-theme-choice="sunset" title="Sunset"></button><button class="theme-swatch" data-theme-choice="violet" title="Violet"></button></div></div>
            <div class="settings-group"><h3>Developer</h3><label class="toggle-label"><input id="showDeveloperInfo" type="checkbox"> <span>Show ⓘ updates button</span></label><p class="settings-note">Hidden by default. Enable it to show a compact list of recent Shar development changes beside Settings.</p></div>
            <div class="settings-group"><h3>Remote sharing</h3><p class="settings-note">The ↗ button creates a temporary Internet share using encrypted WebRTC. Direct peer-to-peer is preferred; Shar TURN is used only when NAT/firewalls require a relay.</p></div>
            <div class="settings-group"><h3>Playback</h3><p class="settings-note">Only one audio or video player can play at a time.</p></div>
          </aside>
          <dialog id="developerInfo">
            <div class="modal-head"><div class="modal-title">Developer updates</div><button id="developerInfoClose" class="action-button" type="button"></button></div>
            <div class="updates">
              <div class="update"><div class="update-head"><span class="update-version">v2.0.5</span><span class="update-title">Remote service readiness</span></div><p>Fixed the signaling-service startup race and added readiness diagnostics before nginx/public-route validation.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.0.4</span><span class="update-title">Native iPhone Remote Share</span></div><p>Remote sharing now starts directly from the native iOS file card and shows a native QR/link transfer sheet without opening the local browser UI.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.0.3</span><span class="update-title">Public route verification</span></div><p>Made the real public HTTPS API authoritative and hardened nginx repair for duplicate/address-bound apex vhosts.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.0.2</span><span class="update-title">Remote routing repair</span></div><p>Fixed exact mojoworks.xyz API routing and automatic repair when the public share endpoint returns 404.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.0.1</span><span class="update-title">Android release fix</span></div><p>Restored Android release compilation and made the visible version read from package metadata.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v2.0.0</span><span class="update-title">Remote WebRTC sharing</span></div><p>Added temporary QR/link shares, encrypted peer-to-peer data channels, TURN fallback, and automated remote infrastructure deployment.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v1.7.6</span><span class="update-title">Optional developer info</span></div><p>Added the hidden-by-default ⓘ updates panel and Settings toggle.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v1.7.5</span><span class="update-title">Cross-platform audio fix</span></div><p>Kept iOS background audio while restoring the macOS release build.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v1.7.4</span><span class="update-title">Background audio</span></div><p>Audio can continue with Shar minimized or the iPhone screen locked.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v1.7.3</span><span class="update-title">Better preview</span></div><p>Images fit the viewer and previews gained a persistent X close control.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v1.7.2</span><span class="update-title">More ways to add</span></div><p>Added Photos & Videos, camera recording, and Files from the + menu.</p></div>
              <div class="update"><div class="update-head"><span class="update-version">v1.7.1</span><span class="update-title">Shar identity</span></div><p>Renamed the visible product to Shar and added the persistent iOS + importer.</p></div>
            </div>
          </dialog>
          <dialog id="remoteShare">
            <div class="modal-head"><div class="modal-title">Remote share</div><button id="remoteClose" class="action-button" type="button"></button></div>
            <div class="remote-body">
              <div id="remoteSummary" class="remote-summary">Choose a Shar file, local files, or a folder.</div>
              <div id="remoteStatus" class="remote-status">Ready.</div>
              <img id="remoteQR" class="remote-qr" alt="Shar remote share QR code" hidden>
              <div id="remoteLinkRow" class="remote-link" hidden><input id="remoteLink" readonly aria-label="Remote share link"><button id="remoteCopy" type="button">Copy</button></div>
              <progress id="remoteProgress" class="remote-progress" value="0" max="1" hidden></progress>
              <div class="remote-actions"><button id="remoteChooseFiles" type="button">Choose files</button><button id="remoteChooseFolder" type="button">Choose folder</button><button id="remoteSystemShare" type="button" hidden>Share link</button><button id="remoteCancel" type="button" hidden>Cancel share</button></div>
              <input id="remoteFilePicker" class="remote-picker" type="file" multiple><input id="remoteFolderPicker" class="remote-picker" type="file" webkitdirectory multiple>
              <div class="remote-note">Links expire after 30 minutes and accept one receiver. File bytes are not uploaded to the Shar coordination service. Keep this Shar page/app open until transfer completes.</div>
            </div>
          </dialog>
          <dialog id="viewer">
            <div class="modal-head">
              <button id="viewerPrev" class="action-button" type="button"></button><button id="viewerNext" class="action-button" type="button"></button>
              <div id="viewerTitle" class="modal-title"></div><span id="viewerPosition" class="viewer-position"></span>
              <a id="viewerDownload" class="btn action-button" download></a><button id="viewerDelete" class="action-button" type="button"></button><button id="viewerClose" class="action-button" type="button"></button>
            </div>
            <div class="modal-content-wrap"><button id="overlayPrev" class="nav-arrow prev" aria-label="Previous">‹</button><div id="viewerContent" class="modal-content"></div><button id="overlayNext" class="nav-arrow next" aria-label="Next">›</button></div>
          </dialog>
          <script>
            const q=s=>document.querySelector(s), filesEl=q('#files'),countEl=q('#count'),statusEl=q('#status'),progressEl=q('#progress'),dropEl=q('#drop'),pickerEl=q('#picker'),viewer=q('#viewer'),viewerTitle=q('#viewerTitle'),viewerContent=q('#viewerContent'),viewerDownload=q('#viewerDownload'),viewerPosition=q('#viewerPosition'),buttonMode=q('#buttonMode'),viewMode=q('#viewMode'),filtersEl=q('#filters'),presetSelect=q('#presetSelect'),thumbSize=q('#thumbSize'),thumbValue=q('#thumbValue'),textScale=q('#textScale'),textValue=q('#textValue'),infoButton=q('#infoButton'),showDeveloperInfo=q('#showDeveloperInfo'),developerInfo=q('#developerInfo'),remoteShare=q('#remoteShare'),remoteStatus=q('#remoteStatus'),remoteSummary=q('#remoteSummary'),remoteQR=q('#remoteQR'),remoteLink=q('#remoteLink'),remoteLinkRow=q('#remoteLinkRow'),remoteProgress=q('#remoteProgress'),remoteFilePicker=q('#remoteFilePicker'),remoteFolderPicker=q('#remoteFolderPicker');
            let currentFiles=[],viewerFiles=[],viewerIndex=-1,touchStartX=null,currentFilter='all';
            const REMOTE_API='https://mojoworks.xyz/api/shar/remote/v1';let remoteSession=null,remotePC=null,remoteDC=null,remoteSignalSeq=0,remotePollTimer=null,remotePendingCandidates=[],remoteSources=[],remoteSent=0,remoteCompleted=false;
            const glyph={preview:'👁',download:'↓',delete:'⌫',close:'×',play:'▶',pause:'Ⅱ',share:'↗',previous:'‹',next:'›',config:'⚙',info:'ⓘ'};
            const filterDefs=[['all','All'],['image','Images'],['audio','Audio'],['video','Video'],['document','Docs'],['file','Other']];
            const presets={minimal:{thumb:150,text:90,mode:'icons',view:'grid',theme:'ocean'},balanced:{thumb:210,text:100,mode:'compact',view:'grid',theme:'ocean'},large:{thumb:280,text:110,mode:'text',view:'grid',theme:'system'}};
            function bytes(n){const u=['B','KB','MB','GB','TB'];let i=0,v=Number(n);while(v>=1024&&i<u.length-1){v/=1024;i++}return `${v.toFixed(i?1:0)} ${u[i]}`}
            function time(v){if(!Number.isFinite(v)||v<0)return '0:00';v=Math.floor(v);return `${Math.floor(v/60)}:${String(v%60).padStart(2,'0')}`}
            function clamp(v,min,max){return Math.max(min,Math.min(max,Number(v)||min))}
            function mediaURL(f){return '/media/'+encodeURIComponent(f.name)} function downloadURL(f){return '/files/'+encodeURIComponent(f.name)} function artworkURL(f){return '/artwork/'+encodeURIComponent(f.name)}
            function iconName(kind){return kind==='image'?'photo':kind==='audio'?'sound-on':kind==='video'?'video':'file'}
            function uiIcon(name){const img=document.createElement('img');img.className='ui-icon';img.src='/ui-icon/'+name+'.svg';img.alt='';img.onerror=()=>{img.style.display='none';const fb=img.nextElementSibling;if(fb)fb.classList.add('missing')};return img}
            function setAction(el,icon,full,short=full){el.classList.add('action-button');el.replaceChildren();el.append(uiIcon(icon));const fb=document.createElement('span');fb.className='fallback-icon';fb.textContent=glyph[icon]||'•';const f=document.createElement('span');f.className='full-label';f.textContent=full;const s=document.createElement('span');s.className='short-label';s.textContent=short;el.append(fb,f,s);el.title=full;el.setAttribute('aria-label',full)}
            function applyMode(mode,persist=true){if(!['text','icons','compact'].includes(mode))mode='icons';document.body.dataset.buttonMode=mode;buttonMode.value=mode;if(persist)localStorage.setItem('lws-button-mode',mode)}
            function applyView(mode,persist=true){if(!['grid','list'].includes(mode))mode='grid';document.body.dataset.view=mode;viewMode.value=mode;if(persist)localStorage.setItem('lws-view-mode',mode)}
            function applyTheme(theme,persist=true){if(!['system','ocean','forest','sunset','violet'].includes(theme))theme='ocean';document.body.dataset.theme=theme;if(persist)localStorage.setItem('lws-theme',theme);document.querySelectorAll('.theme-swatch').forEach(x=>x.classList.toggle('selected',x.dataset.themeChoice===theme))}
            function applyDensity(thumb,text,persist=true){thumb=clamp(thumb,120,320);text=clamp(text,75,125);document.documentElement.style.setProperty('--card-min',thumb+'px');document.documentElement.style.setProperty('--text-scale',(text/100).toFixed(2));thumbSize.value=thumb;textScale.value=text;thumbValue.textContent=thumb+' px';textValue.textContent=text+'%';if(persist){localStorage.setItem('lws-thumb-size',String(thumb));localStorage.setItem('lws-text-scale',String(text))}}
            function savedPreset(){try{return JSON.parse(localStorage.getItem('lws-saved-preset')||'null')}catch{return null}}
            function currentSettings(){return{thumb:Number(thumbSize.value),text:Number(textScale.value),mode:buttonMode.value,view:viewMode.value,theme:document.body.dataset.theme||'ocean'}}
            function setPresetChoice(name){presetSelect.value=name;localStorage.setItem('lws-preset-v2',name)}
            function markCustom(){setPresetChoice('custom')}
            function applyPreset(name,persist=true){let p=presets[name];if(name==='saved')p=savedPreset();if(!p){name='minimal';p=presets.minimal}applyMode(p.mode,false);applyView(p.view,false);applyTheme(p.theme,false);applyDensity(p.thumb,p.text,false);localStorage.setItem('lws-button-mode',p.mode);localStorage.setItem('lws-view-mode',p.view);localStorage.setItem('lws-theme',p.theme);localStorage.setItem('lws-thumb-size',String(p.thumb));localStorage.setItem('lws-text-scale',String(p.text));if(persist)setPresetChoice(name);else presetSelect.value=name}
            function restoreUI(){const chosen=localStorage.getItem('lws-preset-v2');if(chosen==='saved'&&savedPreset()){applyPreset('saved',false);presetSelect.value='saved'}else if(chosen&&presets[chosen]){applyPreset(chosen,false);presetSelect.value=chosen}else if(chosen==='custom'){applyMode(localStorage.getItem('lws-button-mode')||'icons',false);applyView(localStorage.getItem('lws-view-mode')||'grid',false);applyTheme(localStorage.getItem('lws-theme')||'ocean',false);applyDensity(localStorage.getItem('lws-thumb-size')||150,localStorage.getItem('lws-text-scale')||90,false);presetSelect.value='custom'}else applyPreset('minimal',true);applyDeveloperInfo(localStorage.getItem('lws-show-developer-info')==='1',false)}
            function applyDeveloperInfo(show,persist=true){show=!!show;showDeveloperInfo.checked=show;infoButton.hidden=!show;if(persist)localStorage.setItem('lws-show-developer-info',show?'1':'0')}
            infoButton.textContent='ⓘ';infoButton.title='Developer updates';infoButton.setAttribute('aria-label','Developer updates');setAction(q('#settingsButton'),'config','Settings','Settings');setAction(q('#settingsClose'),'close','Close','Close');setAction(q('#developerInfoClose'),'close','Close','Close');restoreUI();
            presetSelect.onchange=()=>applyPreset(presetSelect.value,true);buttonMode.onchange=()=>{applyMode(buttonMode.value);markCustom()};viewMode.onchange=()=>{applyView(viewMode.value);markCustom()};thumbSize.oninput=()=>{applyDensity(thumbSize.value,textScale.value);markCustom()};textScale.oninput=()=>{applyDensity(thumbSize.value,textScale.value);markCustom()};document.querySelectorAll('.theme-swatch').forEach(x=>x.onclick=()=>{applyTheme(x.dataset.themeChoice);markCustom()});
            q('#savePreset').onclick=()=>{localStorage.setItem('lws-saved-preset',JSON.stringify(currentSettings()));setPresetChoice('saved');presetSelect.value='saved';q('#savePreset').textContent='Saved ✓';setTimeout(()=>q('#savePreset').textContent='Save current',1000)};q('#resetMinimal').onclick=()=>applyPreset('minimal',true);
            showDeveloperInfo.onchange=()=>applyDeveloperInfo(showDeveloperInfo.checked,true);infoButton.onclick=()=>developerInfo.showModal();q('#developerInfoClose').onclick=()=>developerInfo.close();developerInfo.addEventListener('click',e=>{if(e.target===developerInfo)developerInfo.close()});q('#settingsButton').onclick=()=>document.body.classList.add('settings-open');q('#settingsClose').onclick=q('#settingsBackdrop').onclick=()=>document.body.classList.remove('settings-open');
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
            async function remoteAPI(path,opt={}){const r=await fetch(REMOTE_API+path,{cache:'no-store',...opt,headers:{'Content-Type':'application/json',...(opt.headers||{})}});let j={};try{j=await r.json()}catch{}if(!r.ok)throw Error(j.error||`HTTP ${r.status}`);return j}
            function remoteSetStatus(text,state=''){remoteStatus.textContent=text;remoteStatus.dataset.state=state}
            function serverSource(f){return {path:f.name,name:f.name,size:Number(f.size),mime:f.mime||'application/octet-stream',stream:async()=>{const r=await fetch(mediaURL(f),{cache:'no-store'});if(!r.ok||!r.body)throw Error(`Could not read ${f.name}`);return r.body.getReader()}}}
            function fileSources(list){return [...list].map(f=>({path:f.webkitRelativePath||f.name,name:f.name,size:f.size,mime:f.type||'application/octet-stream',stream:async()=>f.stream().getReader()}))}
            function remoteCleanupConnection(){if(remotePollTimer)clearTimeout(remotePollTimer);remotePollTimer=null;try{remoteDC?.close()}catch{}try{remotePC?.close()}catch{}remoteDC=null;remotePC=null;remotePendingCandidates=[]}
            async function remoteCancel(){const s=remoteSession;remoteCleanupConnection();remoteSession=null;remoteCompleted=false;if(s?.id&&s.hostSecret)await remoteAPI('/session/'+encodeURIComponent(s.id),{method:'DELETE',headers:{Authorization:'Bearer '+s.hostSecret}}).catch(()=>{});remoteSetStatus('Share cancelled.');q('#remoteCancel').hidden=true;remoteQR.hidden=true;remoteLinkRow.hidden=true;remoteProgress.hidden=true}
            async function remoteSignal(type,payload){if(!remoteSession)throw Error('No remote session');return remoteAPI('/session/'+encodeURIComponent(remoteSession.id)+'/signal',{method:'POST',headers:{Authorization:'Bearer '+remoteSession.hostSecret},body:JSON.stringify({type,payload})})}
            async function remotePoll(){if(!remoteSession||remoteCompleted)return;try{const j=await remoteAPI('/session/'+encodeURIComponent(remoteSession.id)+'/signal?since='+remoteSignalSeq,{headers:{Authorization:'Bearer '+remoteSession.hostSecret}});for(const m of j.messages){remoteSignalSeq=Math.max(remoteSignalSeq,m.seq);if(m.type==='answer'){await remotePC.setRemoteDescription(m.payload);for(const c of remotePendingCandidates.splice(0))await remotePC.addIceCandidate(c)}else if(m.type==='candidate'&&m.payload){if(remotePC.remoteDescription)await remotePC.addIceCandidate(m.payload);else remotePendingCandidates.push(m.payload)}else if(m.type==='ready'){remoteSetStatus('Receiver joined — connecting…')}}}catch(e){remoteSetStatus('Remote connection error: '+e.message,'bad');return}remotePollTimer=setTimeout(remotePoll,650)}
            async function remoteConnectionLabel(){try{const stats=await remotePC.getStats();let pair=null;stats.forEach(x=>{if(x.type==='transport'&&x.selectedCandidatePairId)pair=stats.get(x.selectedCandidatePairId);if(x.type==='candidate-pair'&&x.selected)pair=x});if(pair){const local=stats.get(pair.localCandidateId),remote=stats.get(pair.remoteCandidateId);if(local?.candidateType==='relay'||remote?.candidateType==='relay')return 'Connected via TURN relay';return 'Connected peer-to-peer'}}catch{}return 'Connected'}
            async function waitRemoteBuffer(){if(!remoteDC||remoteDC.readyState!=='open')throw Error('Remote data channel closed');if(remoteDC.bufferedAmount<4*1024*1024)return;await new Promise((resolve,reject)=>{remoteDC.bufferedAmountLowThreshold=1024*1024;const done=()=>{remoteDC.removeEventListener('bufferedamountlow',done);resolve()};remoteDC.addEventListener('bufferedamountlow',done,{once:true});setTimeout(()=>{if(remoteDC?.bufferedAmount>=4*1024*1024)reject(Error('Receiver is not consuming data'))},30000)})}
            async function remoteSendBinary(chunk){const u=chunk instanceof Uint8Array?chunk:new Uint8Array(chunk);for(let o=0;o<u.byteLength;o+=65536){await waitRemoteBuffer();const part=u.subarray(o,Math.min(o+65536,u.byteLength));remoteDC.send(part);remoteSent+=part.byteLength;remoteProgress.value=remoteSent}}
            async function remoteSendFiles(){remoteSent=0;remoteProgress.hidden=false;remoteProgress.max=remoteSources.reduce((n,x)=>n+x.size,0)||1;remoteProgress.value=0;remoteDC.send(JSON.stringify({t:'manifest',files:remoteSources.map(x=>({path:x.path,name:x.name,size:x.size,mime:x.mime}))}));for(let i=0;i<remoteSources.length;i++){const s=remoteSources[i];remoteSetStatus(`Sending ${i+1}/${remoteSources.length}: ${s.path}`,'live');remoteDC.send(JSON.stringify({t:'file-start',i,path:s.path,name:s.name,size:s.size,mime:s.mime}));const reader=await s.stream();while(true){const {done,value}=await reader.read();if(done)break;if(value)await remoteSendBinary(value)}remoteDC.send(JSON.stringify({t:'file-end',i}))}remoteDC.send(JSON.stringify({t:'complete'}));remoteCompleted=true;remoteSetStatus('Transfer sent successfully.','live');remoteProgress.value=remoteProgress.max;q('#remoteCancel').textContent='Close'}
            async function remoteStart(sources){if(!window.RTCPeerConnection){remoteShare.showModal();remoteSetStatus('WebRTC is unavailable in this browser. Open Remote Share inside Shar or a modern browser.','bad');return}if(!sources.length)return;await remoteCancel().catch(()=>{});remoteSources=sources;remoteCompleted=false;remoteSignalSeq=0;remoteSummary.textContent=`${sources.length} item${sources.length===1?'':'s'} · ${bytes(sources.reduce((n,x)=>n+x.size,0))}`;remoteSetStatus('Creating temporary share…');remoteShare.showModal();try{remoteSession=await remoteAPI('/session',{method:'POST',body:JSON.stringify({files:sources.map(x=>({path:x.path,size:x.size,mime:x.mime})),ttlSeconds:1800,oneTime:true})});remoteLink.value=remoteSession.receiverUrl;remoteLinkRow.hidden=false;remoteQR.src=remoteSession.qrUrl+'?t='+Date.now();remoteQR.hidden=false;q('#remoteCancel').hidden=false;q('#remoteCancel').textContent='Cancel share';q('#remoteSystemShare').hidden=!navigator.share;remotePC=new RTCPeerConnection({iceServers:remoteSession.iceServers});remoteDC=remotePC.createDataChannel('shar-file',{ordered:true});remoteDC.binaryType='arraybuffer';remoteDC.onopen=async()=>{remoteSetStatus(await remoteConnectionLabel(),'live');remoteSendFiles().catch(e=>remoteSetStatus('Transfer failed: '+e.message,'bad'))};remoteDC.onerror=()=>remoteSetStatus('WebRTC data channel error.','bad');remotePC.onicecandidate=e=>{if(e.candidate)remoteSignal('candidate',e.candidate.toJSON()).catch(()=>{})};remotePC.onconnectionstatechange=async()=>{if(remotePC.connectionState==='connected')remoteSetStatus(await remoteConnectionLabel(),'live');else if(['failed','disconnected'].includes(remotePC.connectionState))remoteSetStatus('Connection '+remotePC.connectionState,remotePC.connectionState==='failed'?'bad':'')};const offer=await remotePC.createOffer();await remotePC.setLocalDescription(offer);await remoteSignal('offer',remotePC.localDescription);remoteSetStatus('Waiting for receiver…');remotePoll()}catch(e){remoteSetStatus('Could not create remote share: '+e.message,'bad');remoteCleanupConnection()}}
            setAction(q('#remoteClose'),'close','Close','Close');q('#remoteClose').onclick=()=>{if(remoteCompleted){remoteCleanupConnection();remoteShare.close()}else if(confirm('Cancel this remote share?'))remoteCancel().finally(()=>remoteShare.close())};q('#remoteCancel').onclick=()=>{if(remoteCompleted){remoteCleanupConnection();remoteShare.close()}else remoteCancel()};q('#remoteCopy').onclick=async()=>{try{await navigator.clipboard.writeText(remoteLink.value);q('#remoteCopy').textContent='Copied ✓';setTimeout(()=>q('#remoteCopy').textContent='Copy',900)}catch{remoteLink.select();document.execCommand('copy')}};q('#remoteSystemShare').onclick=()=>navigator.share?.({title:'Shar remote share',url:remoteLink.value});q('#remoteChooseFiles').onclick=()=>remoteFilePicker.click();q('#remoteChooseFolder').onclick=()=>remoteFolderPicker.click();remoteFilePicker.onchange=()=>{const x=fileSources(remoteFilePicker.files);remoteFilePicker.value='';remoteStart(x)};remoteFolderPicker.onchange=()=>{const x=fileSources(remoteFolderPicker.files);remoteFolderPicker.value='';remoteStart(x)};q('#remoteLocalButton').onclick=()=>{remoteSummary.textContent='Choose files or a folder from this device, or use Remote on a Shar file card.';remoteSetStatus('Ready.');remoteQR.hidden=true;remoteLinkRow.hidden=true;remoteProgress.hidden=true;q('#remoteCancel').hidden=true;remoteShare.showModal()};remoteShare.addEventListener('cancel',e=>{e.preventDefault();q('#remoteClose').click()});
            const remoteParam=new URLSearchParams(location.search).get('remote');
            function renderFilters(){filtersEl.replaceChildren();for(const [kind,label] of filterDefs){const b=document.createElement('button');b.className='filter'+(currentFilter===kind?' active':'');b.textContent=label;b.onclick=()=>{currentFilter=kind;localStorage.setItem('lws-filter',kind);renderFilters();renderFiles()};filtersEl.append(b)}}
            function renderFiles(){const visible=visibleFiles();filesEl.innerHTML='';countEl.textContent=currentFilter==='all'?`${visible.length} files`:`${visible.length} / ${currentFiles.length}`;if(!visible.length){const e=document.createElement('div');e.className='empty';e.textContent='No files in this category.';filesEl.append(e);return}for(const f of visible){const card=document.createElement('article');card.className='file';const p=document.createElement('button');p.className='preview';p.type='button';p.append(previewElement(f));p.onclick=()=>openPreview(f);const body=document.createElement('div');body.className='body';const n=document.createElement('div');n.className='name';n.textContent=f.title||f.name;n.onclick=()=>openPreview(f);body.append(n);if(f.kind==='audio'&&f.artist){const am=document.createElement('div');am.className='audio-meta';am.textContent=f.artist;body.append(am)}const m=document.createElement('div');m.className='meta';m.textContent=`${f.kind.toUpperCase()} • ${f.mime} • ${bytes(f.size)}`;body.append(m);if(f.kind==='audio')body.append(audioMini(f));const ac=document.createElement('div');ac.className='actions';const view=document.createElement('button');setAction(view,'preview','Preview','View');view.onclick=()=>openPreview(f);const d=document.createElement('a');d.className='btn';setAction(d,'download','Download','Down');d.href=downloadURL(f);d.download=f.name;const remote=document.createElement('button');setAction(remote,'share','Remote','Remote');remote.title='Share over the Internet with WebRTC';remote.onclick=()=>remoteStart([serverSource(f)]);const del=document.createElement('button');del.className='danger';setAction(del,'delete','Delete','Del');del.onclick=()=>removeFile(f).catch(showError);ac.append(view,d,remote,del);body.append(ac);card.append(p,body);filesEl.append(card)}}
            async function removeFile(f,fromViewer=false){if(!confirm(`Delete ${f.name}?`))return;const r=await fetch('/files/'+encodeURIComponent(f.name),{method:'DELETE'});if(!r.ok)throw Error(await r.text());const old=viewerIndex;await refresh();if(fromViewer){viewerFiles=visibleFiles();if(!viewerFiles.length)closePreview();else showViewer(Math.min(old,viewerFiles.length-1))}}
            async function refresh(){const r=await fetch('/api/files',{cache:'no-store'});if(!r.ok)throw Error(await r.text());currentFiles=await r.json();renderFilters();renderFiles()}
            async function uploadFile(file,index,total){statusEl.textContent=`Uploading ${index+1}/${total}: ${file.name}`;progressEl.hidden=false;progressEl.value=index/total;const r=await fetch('/upload?filename='+encodeURIComponent(file.name),{method:'POST',headers:{'Content-Type':file.type||'application/octet-stream'},body:file});if(!r.ok)throw Error(await r.text());progressEl.value=(index+1)/total}
            async function uploadFiles(list){const a=[...list].filter(Boolean);if(!a.length)return;try{for(let i=0;i<a.length;i++)await uploadFile(a[i],i,a.length);statusEl.textContent=`Uploaded ${a.length} file${a.length===1?'':'s'}.`;pickerEl.value='';await refresh()}catch(e){showError(e)}finally{setTimeout(()=>progressEl.hidden=true,900)}} function showError(e){statusEl.textContent='Error: '+(e?.message||e)}
            currentFilter=localStorage.getItem('lws-filter')||'all';if(!filterDefs.some(x=>x[0]===currentFilter))currentFilter='all';dropEl.onclick=()=>pickerEl.click();dropEl.onkeydown=e=>{if(e.key==='Enter'||e.key===' ')pickerEl.click()};pickerEl.onchange=()=>uploadFiles(pickerEl.files);for(const e of ['dragenter','dragover'])document.addEventListener(e,x=>{x.preventDefault();dropEl.classList.add('drag')});for(const e of ['dragleave','drop'])document.addEventListener(e,x=>{x.preventDefault();dropEl.classList.remove('drag')});document.addEventListener('drop',e=>uploadFiles(e.dataTransfer.files));refresh().then(()=>{if(remoteParam){const f=currentFiles.find(x=>x.name===remoteParam);if(f)remoteStart([serverSource(f)]);else showError(Error('Remote-share file was not found: '+remoteParam))}}).catch(e=>{filesEl.textContent='Could not load files.';showError(e)});
          </script>
        </body>
        </html>
""";
}
