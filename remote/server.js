#!/usr/bin/env node
'use strict';

const http = require('http');
const crypto = require('crypto');
const { spawn } = require('child_process');

const PORT = Number(process.env.SHAR_REMOTE_PORT || 8787);
const RECEIVE_BASE = process.env.SHAR_RECEIVE_BASE || 'https://mojoworks.xyz/labs/shar/receive.html';
const PUBLIC_API_BASE = process.env.SHAR_PUBLIC_API_BASE || 'https://mojoworks.xyz/api/shar/remote/v1';
const TURN_HOST = process.env.SHAR_TURN_HOST || '';
const TURN_PORT = Number(process.env.SHAR_TURN_PORT || 3479);
const TURN_SECRET = process.env.SHAR_TURN_SECRET || '';
const DEFAULT_TTL = Number(process.env.SHAR_SESSION_TTL || 1800);
const MAX_TTL = Number(process.env.SHAR_SESSION_MAX_TTL || 3600);
const MAX_BODY = 256 * 1024;
const MAX_FILES = 1000;
const MAX_SIGNALS = 256;
const MAX_ACTIVE_SESSIONS = Number(process.env.SHAR_MAX_ACTIVE_SESSIONS || 1000);
const MAX_CREATES_PER_HOUR = Number(process.env.SHAR_MAX_CREATES_PER_HOUR || 30);
const sessions = new Map();
const buckets = new Map();
const createBuckets = new Map();

function now() { return Date.now(); }
function token(bytes=24) { return crypto.randomBytes(bytes).toString('base64url'); }
function json(res, status, obj) {
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(status, {
    'Content-Type':'application/json; charset=utf-8',
    'Content-Length':body.length,
    'Cache-Control':'no-store',
    'Access-Control-Allow-Origin':'*',
    'Access-Control-Allow-Headers':'authorization,content-type,x-shar-client',
    'Access-Control-Allow-Methods':'GET,POST,DELETE,OPTIONS',
    'X-Content-Type-Options':'nosniff',
    'Referrer-Policy':'no-referrer'
  });
  res.end(body);
}
function fail(res, status, message) { json(res, status, {ok:false,error:message}); }
function clientIP(req) { return String(req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim(); }
function rateLimit(req, res) {
  const ip = clientIP(req) || 'unknown', t = now(), windowMs = 60_000, max = 600;
  let b = buckets.get(ip);
  if (!b || t-b.start >= windowMs) b = {start:t,count:0};
  b.count++; buckets.set(ip,b);
  if (b.count > max) { fail(res,429,'Too many requests'); return false; }
  return true;
}
function allowSessionCreate(req, res) {
  if (sessions.size >= MAX_ACTIVE_SESSIONS) { fail(res,503,'Shar remote is temporarily at session capacity'); return false; }
  const ip=clientIP(req)||'unknown', t=now(), windowMs=60*60*1000;
  let b=createBuckets.get(ip);
  if (!b || t-b.start >= windowMs) b={start:t,count:0};
  b.count++; createBuckets.set(ip,b);
  if (b.count > MAX_CREATES_PER_HOUR) { fail(res,429,'Too many new shares from this address'); return false; }
  return true;
}
function readJSON(req, res) {
  return new Promise((resolve, reject) => {
    let total=0, chunks=[];
    req.on('data', c => { total += c.length; if (total > MAX_BODY) { reject(new Error('Request too large')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => {
      try { resolve(chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}); }
      catch { reject(new Error('Invalid JSON')); }
    });
    req.on('error', reject);
  }).catch(err => { if (!res.headersSent) fail(res,400,err.message); throw err; });
}
function normalizeManifest(raw) {
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > MAX_FILES) throw new Error(`files must contain 1-${MAX_FILES} items`);
  let total=0;
  const files = raw.map((f, i) => {
    const path = String(f.path || f.name || '').replace(/\\/g,'/').replace(/^\/+/, '');
    if (!path || path.includes('\0') || path.split('/').some(x => x === '..')) throw new Error(`Invalid file path at item ${i+1}`);
    const size = Number(f.size);
    if (!Number.isFinite(size) || size < 0 || !Number.isSafeInteger(size)) throw new Error(`Invalid size at item ${i+1}`);
    total += size;
    const mime = String(f.mime || 'application/octet-stream').slice(0,200);
    return {path:path.slice(0,1024), name:path.split('/').pop(), size, mime};
  });
  return {files,totalBytes:total};
}
function bearer(req) {
  const h=String(req.headers.authorization||'');
  return h.startsWith('Bearer ') ? h.slice(7) : '';
}
function sessionFor(id) {
  const s=sessions.get(id);
  if (!s) return null;
  if (s.expiresAt <= now() || s.revoked || (s.completed && s.oneTime)) { sessions.delete(id); return null; }
  return s;
}
function iceServers() {
  const out=[{urls:['stun:stun.l.google.com:19302']}];
  if (TURN_HOST && TURN_SECRET) {
    const expiry=Math.floor(Date.now()/1000)+3600;
    const username=`${expiry}:${token(8)}`;
    const credential=crypto.createHmac('sha1',TURN_SECRET).update(username).digest('base64');
    out.push({urls:[`turn:${TURN_HOST}:${TURN_PORT}?transport=udp`,`turn:${TURN_HOST}:${TURN_PORT}?transport=tcp`],username,credential});
  }
  return out;
}
function publicSession(s) {
  return {ok:true,id:s.id,files:s.files,totalBytes:s.totalBytes,expiresAt:new Date(s.expiresAt).toISOString(),joined:!!s.guestToken,completed:!!s.completed,oneTime:s.oneTime};
}
function signalTargetQueue(s, from) { return from === 'host' ? s.toGuest : s.toHost; }
function addSignal(s, from, body) {
  const type=String(body.type||'');
  if (!['offer','answer','candidate','ready','cancel','status'].includes(type)) throw new Error('Invalid signal type');
  const q=signalTargetQueue(s,from);
  q.push({seq:++s.seq,from,type,payload:body.payload ?? null,at:Date.now()});
  if (q.length > MAX_SIGNALS) q.splice(0,q.length-MAX_SIGNALS);
}
function routeParts(url) { return new URL(url,'http://localhost').pathname.split('/').filter(Boolean); }

setInterval(() => {
  const t=now();
  for (const [id,s] of sessions) if (s.expiresAt <= t || s.revoked || (s.completed && s.oneTime)) sessions.delete(id);
  for (const [ip,b] of buckets) if (t-b.start>120000) buckets.delete(ip);
  for (const [ip,b] of createBuckets) if (t-b.start>2*60*60*1000) createBuckets.delete(ip);
},30000).unref();

const server=http.createServer(async (req,res) => {
  if (req.method === 'OPTIONS') { res.writeHead(204,{'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,content-type,x-shar-client','Access-Control-Allow-Methods':'GET,POST,DELETE,OPTIONS','Cache-Control':'no-store'}); return res.end(); }
  if (!rateLimit(req,res)) return;
  const parts=routeParts(req.url);
  if (req.method==='GET' && parts.length===1 && parts[0]==='health') return json(res,200,{ok:true,service:'shar-remote',version:'2.0.6',sessions:sessions.size,turn:!!(TURN_HOST&&TURN_SECRET)});
  if (req.method==='POST' && parts.length===1 && parts[0]==='session') {
    if (!allowSessionCreate(req,res)) return;
    let body; try { body=await readJSON(req,res); } catch { return; }
    try {
      const m=normalizeManifest(body.files);
      const ttl=Math.max(300,Math.min(MAX_TTL,Number(body.ttlSeconds)||DEFAULT_TTL));
      const id=token(24), hostSecret=token(32);
      const s={id,hostSecret,guestToken:null,files:m.files,totalBytes:m.totalBytes,createdAt:now(),expiresAt:now()+ttl*1000,oneTime:body.oneTime!==false,completed:false,revoked:false,toHost:[],toGuest:[],seq:0};
      sessions.set(id,s);
      return json(res,201,{...publicSession(s),hostSecret,receiverUrl:`${RECEIVE_BASE}?share=${encodeURIComponent(id)}`,qrUrl:`${PUBLIC_API_BASE}/qr/${encodeURIComponent(id)}.svg`,iceServers:iceServers()});
    } catch(e) { return fail(res,400,e.message); }
  }
  if (parts[0]==='session' && parts[1]) {
    const id=parts[1], s=sessionFor(id);
    if (!s) return fail(res,404,'Share not found or expired');
    if (req.method==='GET' && parts.length===2) return json(res,200,publicSession(s));
    if (req.method==='POST' && parts.length===3 && parts[2]==='join') {
      if (s.completed && s.oneTime) return fail(res,410,'Share already completed');
      if (s.guestToken) return fail(res,409,'A receiver is already connected to this share');
      s.guestToken=token(32);
      addSignal(s,'guest',{type:'ready',payload:{}});
      return json(res,200,{...publicSession(s),guestToken:s.guestToken,iceServers:iceServers()});
    }
    if (req.method==='POST' && parts.length===3 && parts[2]==='signal') {
      const auth=bearer(req); let from='';
      if (auth && auth===s.hostSecret) from='host'; else if (auth && auth===s.guestToken) from='guest'; else return fail(res,403,'Invalid share credential');
      let body; try { body=await readJSON(req,res); } catch { return; }
      try { addSignal(s,from,body); return json(res,202,{ok:true,seq:s.seq}); } catch(e) { return fail(res,400,e.message); }
    }
    if (req.method==='GET' && parts.length===3 && parts[2]==='signal') {
      const auth=bearer(req); let role='';
      if (auth && auth===s.hostSecret) role='host'; else if (auth && auth===s.guestToken) role='guest'; else return fail(res,403,'Invalid share credential');
      const u=new URL(req.url,'http://localhost'); const since=Math.max(0,Number(u.searchParams.get('since'))||0);
      const q=role==='host'?s.toHost:s.toGuest;
      return json(res,200,{ok:true,messages:q.filter(x=>x.seq>since),latest:s.seq});
    }
    if (req.method==='POST' && parts.length===3 && parts[2]==='complete') {
      if (bearer(req)!==s.guestToken) return fail(res,403,'Invalid receiver credential');
      s.completed=true; return json(res,200,{ok:true});
    }
    if (req.method==='DELETE' && parts.length===2) {
      if (bearer(req)!==s.hostSecret) return fail(res,403,'Invalid host credential');
      s.revoked=true; sessions.delete(id); return json(res,200,{ok:true});
    }
  }
  if (req.method==='GET' && parts.length===2 && parts[0]==='qr' && parts[1].endsWith('.svg')) {
    const id=parts[1].slice(0,-4), s=sessionFor(id); if (!s) return fail(res,404,'Share not found or expired');
    const receiverUrl=`${RECEIVE_BASE}?share=${encodeURIComponent(id)}`;
    res.writeHead(200,{'Content-Type':'image/svg+xml; charset=utf-8','Cache-Control':'no-store','Access-Control-Allow-Origin':'*','X-Content-Type-Options':'nosniff'});
    const q=spawn('qrencode',['-t','SVG','-m','1','-o','-',receiverUrl],{stdio:['ignore','pipe','ignore']});
    q.stdout.pipe(res); q.on('error',()=>{if(!res.headersSent)fail(res,500,'QR generator unavailable');else res.end();});
    return;
  }
  return fail(res,404,'Not found');
});

server.listen(PORT,'127.0.0.1',()=>console.log(`Shar remote signaling listening on 127.0.0.1:${PORT}`));
