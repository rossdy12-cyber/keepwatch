package main

// The gothic WebRTC call page. Signalling is Server-Sent Events (GET /api/call/stream) + POST /api/call/signal,
// so the whole server stays dependency-free. Loaded inside Nocturne (iPhone) and in the browser (Windows).
const callHTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Nocturne Call</title>
<style>
  :root { --bg:#0b0608; --panel:#1c1116; --accent:#b01030; --accent2:#e04050; --text:#ede3e6; }
  * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
  html,body { margin:0; height:100%; background:var(--bg); color:var(--text);
    font-family:-apple-system,Segoe UI,Roboto,serif; overflow:hidden; }
  video { position:absolute; object-fit:cover; background:#000; }
  #remote { inset:0; width:100%; height:100%; }
  #local { width:30vw; max-width:160px; aspect-ratio:3/4; right:14px; top:14px; border-radius:14px;
    border:1px solid rgba(224,64,80,.5); box-shadow:0 6px 20px rgba(0,0,0,.6); z-index:2; }
  #status { position:absolute; top:16px; left:16px; z-index:3; font-size:14px; letter-spacing:1px;
    background:rgba(0,0,0,.45); padding:6px 12px; border-radius:20px; }
  #bar { position:absolute; left:0; right:0; bottom:calc(24px + env(safe-area-inset-bottom)); z-index:3;
    display:flex; gap:18px; justify-content:center; }
  button { width:62px; height:62px; border-radius:50%; border:1px solid rgba(255,255,255,.15);
    background:var(--panel); color:var(--text); font-size:22px; cursor:pointer; }
  button.end { background:var(--accent); border-color:transparent; }
  button.off { background:#333; }
  #title { position:absolute; bottom:calc(104px + env(safe-area-inset-bottom)); left:0; right:0; z-index:3;
    text-align:center; font-family:Georgia,serif; font-size:20px; text-shadow:0 1px 6px #000; }
</style>
</head>
<body>
  <video id="remote" autoplay playsinline></video>
  <video id="local" autoplay playsinline muted></video>
  <div id="status">Starting…</div>
  <div id="title"></div>
  <div id="bar">
    <button id="mic" title="Mute">&#127908;</button>
    <button id="cam" title="Camera">&#128247;</button>
    <button id="end" class="end" title="Hang up">&#128222;</button>
  </div>
<script>
const p = new URLSearchParams(location.search);
const room = p.get('room') || 'room';
const token = p.get('token') || '';
const myId = Math.random().toString(36).slice(2);
const S = document.getElementById('status');
document.getElementById('title').textContent = p.get('with') || '';
const localV = document.getElementById('local'), remoteV = document.getElementById('remote');
let pc, es, localStream, polite=false, otherSeen=false, started=false, makingOffer=false, ignoreOffer=false;
const q = 'room='+encodeURIComponent(room)+'&id='+myId+'&token='+encodeURIComponent(token);

function setStatus(t){ S.textContent = t; }
function sig(o){ fetch('/api/call/signal?'+q, {method:'POST', body:JSON.stringify(o)}).catch(()=>{}); }

async function begin(){
  let cfg = {iceServers:[{urls:'stun:stun.l.google.com:19302'}]};
  try { cfg = await (await fetch('/call/config')).json(); } catch(e){}
  try { localStream = await navigator.mediaDevices.getUserMedia({ video:true, audio:true }); }
  catch(e){ setStatus('Allow camera & microphone to call'); return; }
  localV.srcObject = localStream;
  pc = new RTCPeerConnection(cfg);
  pc.ontrack = (e)=>{ remoteV.srcObject = e.streams[0]; setStatus('Connected'); };
  pc.onicecandidate = ({candidate})=>{ if (candidate) sig({candidate}); };
  pc.onnegotiationneeded = async ()=>{
    try { makingOffer=true; await pc.setLocalDescription(); sig({desc: pc.localDescription}); }
    catch(e){ console.error(e); } finally { makingOffer=false; }
  };
  pc.onconnectionstatechange = ()=>{
    if (pc.connectionState==='connected') setStatus('Connected');
    else if (pc.connectionState==='failed') setStatus('Connection failed');
  };
  connect();
}

function connect(){
  es = new EventSource('/api/call/stream?'+q);
  es.onopen = ()=>{ setStatus('Waiting for the other person…'); sig({hello: myId}); };
  es.onerror = ()=>{ setStatus('Reconnecting…'); };
  es.onmessage = async (ev)=>{
    let d; try { d = JSON.parse(ev.data); } catch(e){ return; }
    if (d.hello !== undefined){
      if (!otherSeen && d.hello !== myId){ otherSeen = true; polite = myId < d.hello; sig({hello: myId}); addTracks(); }
      return;
    }
    if (d.bye){ setStatus('They hung up'); return; }
    try {
      if (d.desc){
        const collision = d.desc.type==='offer' && (makingOffer || pc.signalingState!=='stable');
        ignoreOffer = !polite && collision;
        if (ignoreOffer) return;
        await pc.setRemoteDescription(d.desc);
        if (d.desc.type==='offer'){ await pc.setLocalDescription(); sig({desc: pc.localDescription}); }
      } else if (d.candidate){
        try { await pc.addIceCandidate(d.candidate); } catch(e){ if (!ignoreOffer) throw e; }
      }
    } catch(e){ console.error(e); }
  };
}

function addTracks(){
  if (started) return; started = true;
  setStatus('Ringing…');
  localStream.getTracks().forEach(t=> pc.addTrack(t, localStream));
}

document.getElementById('mic').onclick = (e)=>{
  const tr = localStream && localStream.getAudioTracks()[0]; if (!tr) return;
  tr.enabled = !tr.enabled; e.currentTarget.classList.toggle('off', !tr.enabled);
};
document.getElementById('cam').onclick = (e)=>{
  const tr = localStream && localStream.getVideoTracks()[0]; if (!tr) return;
  tr.enabled = !tr.enabled; e.currentTarget.classList.toggle('off', !tr.enabled);
};
document.getElementById('end').onclick = ()=>{
  sig({bye:true});
  if (es) es.close();
  if (pc) pc.close();
  if (localStream) localStream.getTracks().forEach(t=> t.stop());
  setStatus('Call ended');
  setTimeout(()=>{ try{ window.close(); }catch(e){} location.href='about:blank'; }, 300);
};

begin();
</script>
</body>
</html>`
