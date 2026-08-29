package com.localwebshare.app;

import android.util.Log;

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
        for(int i=0;i<files.length;i++){
            File f=files[i]; if(f.getName().startsWith(".upload-")) continue;
            if(s.length()>1)s.append(',');
            s.append("{\"name\":\"").append(json(f.getName())).append("\",\"size\":").append(f.length())
             .append(",\"kind\":\"").append(MediaTypes.kind(f.getName())).append("\",\"mime\":\"").append(MediaTypes.mime(f.getName()))
             .append("\",\"modified\":").append(f.lastModified()/1000.0).append('}');
        }
        s.append(']'); sendJson(out,"200 OK",s.toString());
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
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Local Web Share</title>
<style>:root{color-scheme:light dark;font-family:system-ui,-apple-system,sans-serif}*{box-sizing:border-box}body{margin:0;background:Canvas;color:CanvasText}.shell{max-width:1100px;margin:auto;padding:28px 18px 70px}.sub{opacity:.68}.card{border:1px solid color-mix(in srgb,CanvasText 18%,transparent);border-radius:18px;padding:18px;margin:18px 0}.drop{border:2px dashed color-mix(in srgb,CanvasText 28%,transparent);border-radius:16px;min-height:145px;display:grid;place-items:center;text-align:center;cursor:pointer}.drop.drag{border-color:#0a84ff;background:#0a84ff18}.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:14px}.file{border:1px solid color-mix(in srgb,CanvasText 14%,transparent);border-radius:15px;overflow:hidden}.preview{width:100%;height:150px;border:0;display:grid;place-items:center;background:color-mix(in srgb,CanvasText 7%,Canvas);cursor:pointer;overflow:hidden}.preview img,.preview video{width:100%;height:100%;object-fit:cover}.preview video{pointer-events:none}.body{padding:12px}.name{font-weight:650;overflow-wrap:anywhere;cursor:pointer}.meta{font-size:12px;opacity:.62;margin-top:5px}.audio{width:100%;margin-top:10px}.actions{display:flex;gap:8px;margin-top:12px}button,.btn{border:1px solid #8886;border-radius:9px;background:#8881;color:inherit;padding:7px 10px;text-decoration:none;cursor:pointer}.danger{margin-left:auto}dialog{width:min(900px,calc(100vw - 28px));border:0;border-radius:18px;padding:0;background:Canvas;color:CanvasText}.modal{padding:14px}.content{min-height:300px;display:grid;place-items:center;background:#000}.content img,.content video{max-width:100%;max-height:70vh}.content audio{width:min(680px,90%)}#picker{display:none}progress{width:100%}</style></head>
<body><main class="shell"><h1>Local Web Share</h1><p class="sub">Drop files to upload. Preview images, audio and video directly in the browser.</p><section class="card"><div id="drop" class="drop"><div><strong>Drop files here</strong><br><small>or click to choose files — upload starts automatically</small></div></div><input id="picker" type="file" multiple><p id="status"></p><progress id="progress" value="0" max="1" hidden></progress></section><section class="card"><h2>Files <small id="count"></small></h2><div id="files" class="grid">Loading…</div></section></main><dialog id="viewer"><div class="modal"><button id="close">Close</button><h3 id="title"></h3></div><div id="content" class="content"></div></dialog>
<script>const q=s=>document.querySelector(s),drop=q('#drop'),picker=q('#picker'),files=q('#files'),status=q('#status'),progress=q('#progress'),viewer=q('#viewer'),content=q('#content'),title=q('#title');const bytes=n=>n<1024?n+' B':n<1048576?(n/1024).toFixed(1)+' KB':n<1073741824?(n/1048576).toFixed(1)+' MB':(n/1073741824).toFixed(1)+' GB';const media=f=>'/media/'+encodeURIComponent(f.name),download=f=>'/files/'+encodeURIComponent(f.name);function icon(f){return f.kind==='image'?'🖼️':f.kind==='audio'?'🎵':f.kind==='video'?'🎬':'📄'}function previewEl(f){if(f.kind==='image'){let x=new Image;x.src=media(f);x.loading='lazy';return x}if(f.kind==='video'){let v=document.createElement('video');v.src=media(f);v.preload='metadata';v.muted=true;return v}let s=document.createElement('div');s.style.fontSize='46px';s.textContent=icon(f);return s}function openPreview(f){title.textContent=f.name;content.innerHTML='';let el;if(f.kind==='image'){el=new Image;el.src=media(f)}else if(f.kind==='video'){el=document.createElement('video');el.src=media(f);el.controls=true;el.autoplay=true}else if(f.kind==='audio'){el=document.createElement('audio');el.src=media(f);el.controls=true;el.autoplay=true}else{el=document.createElement('div');el.style.color='white';el.textContent='Preview not available for this file type.'}content.append(el);viewer.showModal()}q('#close').onclick=()=>viewer.close();async function remove(f){if(!confirm('Delete '+f.name+'?'))return;let r=await fetch(download(f),{method:'DELETE'});if(!r.ok)throw Error(await r.text());refresh()}async function refresh(){let r=await fetch('/api/files',{cache:'no-store'}),a=await r.json();files.innerHTML='';q('#count').textContent='('+a.length+')';if(!a.length){files.textContent='No files yet.';return}for(let f of a){let card=document.createElement('article');card.className='file';let p=document.createElement('button');p.className='preview';p.append(previewEl(f));p.onclick=()=>openPreview(f);let b=document.createElement('div');b.className='body';let n=document.createElement('div');n.className='name';n.textContent=f.name;n.onclick=()=>openPreview(f);let m=document.createElement('div');m.className='meta';m.textContent=f.kind.toUpperCase()+' • '+bytes(f.size);b.append(n,m);if(f.kind==='audio'){let a=document.createElement('audio');a.className='audio';a.controls=true;a.preload='metadata';a.src=media(f);b.append(a)}let ac=document.createElement('div');ac.className='actions';let v=document.createElement('button');v.textContent='Preview';v.onclick=()=>openPreview(f);let d=document.createElement('a');d.className='btn';d.textContent='Download';d.href=download(f);d.download=f.name;let del=document.createElement('button');del.className='danger';del.textContent='Delete';del.onclick=()=>remove(f).catch(e=>status.textContent=e);ac.append(v,d,del);b.append(ac);card.append(p,b);files.append(card)}}async function upload(list){let a=[...list];for(let i=0;i<a.length;i++){status.textContent='Uploading '+(i+1)+'/'+a.length+': '+a[i].name;progress.hidden=false;progress.value=i/a.length;let r=await fetch('/upload?filename='+encodeURIComponent(a[i].name),{method:'POST',body:a[i]});if(!r.ok)throw Error(await r.text());progress.value=(i+1)/a.length}status.textContent='Uploaded '+a.length+' file(s).';setTimeout(()=>progress.hidden=true,800);refresh()}drop.onclick=()=>picker.click();picker.onchange=()=>upload(picker.files).catch(e=>status.textContent=e);for(let e of ['dragenter','dragover'])document.addEventListener(e,x=>{x.preventDefault();drop.classList.add('drag')});for(let e of ['dragleave','drop'])document.addEventListener(e,x=>{x.preventDefault();drop.classList.remove('drag')});document.addEventListener('drop',e=>upload(e.dataTransfer.files).catch(x=>status.textContent=x));refresh();</script></body></html>
""";
}
