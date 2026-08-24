# phostor -- an app that adds stories to photos.
#
# A room of people looks at a photograph on a large screen and talks about it.
# This file shows the photograph, records the talk, and writes each visit down.
# Everything it writes goes under work_dir; photo_root is never touched.
#
# The rules this file lives by, all of them learned the expensive way:
#
#   * Every function called here is exported from the package. runApp() sources
#     this file with only library(phostor) attached, so an internal helper is
#     invisible. test-app.R asserts it.
#   * The tree is rendered ONCE. The selection highlight is moved on the client
#     (the ph_current handler), because rebuilding a tree to light a different
#     row is work with nothing to show for it.
#   * One global input per collection of clickable things, never one
#     observeEvent() per row -- those accumulate and leak.
#   * Audio chunks are acknowledged one at a time. Shiny coalesces repeated
#     setInputValue() calls on the same input within a flush, so a naive
#     fire-and-forget upload silently loses whichever chunk arrives second.
#   * The server ignores an audio chunk whose visit key it does not recognise.
#     That single rule makes every start/stop/discard race safe: late chunks
#     from a superseded recorder land nowhere.

library(shiny)
library(bslib)

if (!requireNamespace("phostor", quietly = TRUE)) {
  stop("phostor is not installed. Launch the app with phostor::ph_app().")
}
library(phostor)

# base R gained `%||%` only in 4.4, and phostor's own copy is internal: an app
# sourced with library(phostor) cannot see it. Local, and deliberately so.
`%||%` <- function(a, b) if (is.null(a)) b else a

# ph_app() writes <work_dir>/config.resolved.yml (absolute paths) and points
# PHOSTOR_CONFIG at it, because runApp() has already changed the working
# directory to this folder.
cfg <- ph_config(Sys.getenv("PHOSTOR_CONFIG", "config.resolved.yml"))
idx_all <- ph_read_index(cfg)

for (d in c(cfg$display_dir, cfg$thumb_dir, cfg$sidecar_dir, cfg$sessions_dir)) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}
addResourcePath("display", normalizePath(cfg$display_dir))
addResourcePath("thumbs", normalizePath(cfg$thumb_dir))
# Serves each visit's audio back to the browser for the prior-visits panel and
# for playback. Local, loopback-only, and the user's own files.
addResourcePath("sidecars", normalizePath(cfg$sidecar_dir))

ph_css <- "
:root { --ph-bg:#111316; --ph-panel:#1b1e23; --ph-line:#2b3038;
        --ph-ink:#e8eaed; --ph-dim:#9aa3ad; --ph-rec:#e5484d; --ph-on:#3b82f6; }
body { background:var(--ph-bg); color:var(--ph-ink); }
.bslib-sidebar-layout > .sidebar { background:var(--ph-panel); }
.ph-tree { font-size:.86rem; user-select:none; }
.ph-tree details { margin:0 0 0 .35rem; }
.ph-tree summary.ph-d { cursor:pointer; padding:.15rem .2rem; color:var(--ph-dim);
  font-weight:600; letter-spacing:.01em; }
.ph-tree summary.ph-d:hover { color:var(--ph-ink); }
.ph-p { display:flex; align-items:center; gap:.45rem; cursor:pointer;
  padding:.12rem .3rem; margin-left:.9rem; border-radius:4px; }
.ph-p:hover { background:#242932; }
.ph-p-on { background:var(--ph-on); color:#fff; }
.ph-p-on .ph-n { color:#fff; }
.ph-t { width:30px; height:30px; object-fit:cover; border-radius:3px;
  background:#000; flex:0 0 auto; }
.ph-n { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.ph-b { margin-left:auto; font-size:.7rem; background:#3a4150; color:#cfd6e0;
  border-radius:9px; padding:0 .38rem; flex:0 0 auto; }
.ph-p-on .ph-b { background:#1e40af; color:#fff; }
.ph-empty { color:var(--ph-dim); padding:.6rem; }

.ph-stage { display:flex; flex-direction:column; height:100%; min-height:0; }
.ph-img-wrap { flex:1 1 auto; min-height:0; display:flex; align-items:center;
  justify-content:center; background:#000; border-radius:6px; overflow:hidden; }
#ph-photo { max-width:100%; max-height:100%; object-fit:contain; display:block; }
.ph-cap { flex:0 0 auto; padding:.4rem .1rem .1rem; color:var(--ph-dim);
  font-size:.85rem; display:flex; gap:1rem; flex-wrap:wrap; }
.ph-cap b { color:var(--ph-ink); font-weight:600; }

.ph-bar { display:flex; align-items:center; gap:.6rem; flex-wrap:wrap;
  padding:.35rem 0 .5rem; border-bottom:1px solid var(--ph-line);
  margin-bottom:.5rem; }
.ph-rec { display:inline-flex; align-items:center; gap:.45rem;
  font-weight:700; letter-spacing:.06em; font-size:.95rem;
  padding:.25rem .7rem; border-radius:999px; border:1px solid var(--ph-line);
  color:var(--ph-dim); }
.ph-rec.on { color:#fff; background:var(--ph-rec); border-color:var(--ph-rec); }
.ph-rec .dot { width:.62rem; height:.62rem; border-radius:50%;
  background:currentColor; }
.ph-rec.on .dot { animation:ph-blink 1.4s steps(1,end) infinite; }
@keyframes ph-blink { 50% { opacity:.15; } }
.ph-meta { color:var(--ph-dim); font-size:.82rem; }

.ph-tags { border-top:1px solid var(--ph-line); padding-top:.5rem;
  margin-top:.5rem; }
.ph-tags .form-group { margin-bottom:.4rem; }
.ph-tags label { color:var(--ph-dim); font-size:.78rem; margin-bottom:.1rem; }
.ph-hist { font-size:.85rem; }
.ph-hist audio { height:30px; vertical-align:middle; }
.ph-hist .v { border-top:1px solid var(--ph-line); padding:.4rem 0; }
.ph-hist .vh { color:var(--ph-dim); font-size:.78rem; }

/* Presentation mode: the photograph and the fact that it is recording. */
body.ph-present .bslib-sidebar-layout > .sidebar,
body.ph-present .ph-tags, body.ph-present .ph-hist-wrap,
body.ph-present .ph-hide { display:none !important; }
body.ph-present .ph-img-wrap { border-radius:0; }
body.ph-present { overflow:hidden; }
.ph-mic { position:fixed; right:1rem; top:3.4rem; width:26rem; max-width:92vw;
  z-index:1080; background:var(--ph-panel); border:1px solid var(--ph-line);
  border-radius:8px; padding:.8rem; box-shadow:0 10px 30px rgba(0,0,0,.5);
  display:none; }
.ph-mic h6 { margin:0 0 .5rem; font-size:.95rem; }
.ph-mic .row2 { display:flex; gap:.4rem; align-items:center; margin-bottom:.5rem; }
.ph-mic select { flex:1 1 auto; background:#12151a; color:var(--ph-ink);
  border:1px solid var(--ph-line); border-radius:4px; padding:.25rem .4rem;
  font-size:.82rem; max-width:100%; }
.ph-level { height:12px; background:#0d1014; border:1px solid var(--ph-line);
  border-radius:6px; overflow:hidden; margin:.35rem 0 .2rem; }
.ph-level i { display:block; height:100%; width:0;
  background:linear-gradient(90deg,#22c55e,#eab308,#ef4444); transition:width .05s; }
.ph-mic .hint { color:var(--ph-dim); font-size:.78rem; }
.ph-mic .advice { font-size:.86rem; margin:.5rem 0 .3rem; }
.ph-mic .detail { color:var(--ph-dim); font-size:.74rem;
  font-family:ui-monospace,SFMono-Regular,Menlo,monospace; word-break:break-all; }
.ph-mic audio { width:100%; margin-top:.4rem; display:none; }
.ph-warn { background:#4a1d1d; border:1px solid #7f1d1d; color:#fecaca;
  padding:.4rem .7rem; border-radius:6px; font-size:.85rem; margin-bottom:.5rem; }
.ph-play-strip { height:4px; background:var(--ph-line); border-radius:2px;
  overflow:hidden; margin-top:.4rem; }
.ph-play-strip i { display:block; height:100%; background:var(--ph-on); width:0; }
"

# All of the browser-side machinery: microphone, chunk queue, keyboard, and the
# playback clock. It runs without jQuery except for shiny:connected, which is
# the documented hook for registering message handlers.
ph_js <- "
(function(){
  var PH = {
    stream:null, rec:null, key:null, mime:null,
    q:[], sending:false, seq:0, pending:{}, closing:{},
    order:[], current:null, chunkMs:5000,
    play:null, playIdx:0, audio:null,
    deviceId:null, sitting:false, checkOwnsStream:false, ac:null, meter:null,
    visitKey:'', ackedBy:{}
  };
  window.PH = PH;

  function send(name, val){ Shiny.setInputValue(name, val, {priority:'event'}); }

  // ---- chunk queue -------------------------------------------------------
  // One chunk in flight at a time, each acknowledged by the server. Shiny
  // coalesces repeated writes to one input within a flush, so sending the
  // whole queue at once would drop all but the last.
  function pump(){
    if (PH.sending || !PH.q.length) return;
    PH.sending = true;
    var c = PH.q[0];
    send('audio_chunk', c);
    PH.retry = setTimeout(function(){
      // The server did not acknowledge. Re-send rather than stall the queue.
      PH.sending = false; pump();
    }, 4000);
  }
  function acked(){
    clearTimeout(PH.retry);
    var c = PH.q.shift();
    bumpChunks(c && c.key);
    PH.sending = false;
    if (c) {
      PH.pending[c.key] = (PH.pending[c.key] || 1) - 1;
      maybeDone(c.key);
    }
    pump();
  }
  function queue(key, blob, last){
    var r = new FileReader();
    PH.pending[key] = (PH.pending[key] || 0) + 1;
    r.onloadend = function(){
      var s = String(r.result);
      PH.q.push({key:key, seq:++PH.seq, b64:s.slice(s.indexOf(',')+1),
                 last:!!last});
      pump();
    };
    r.readAsDataURL(blob);
  }
  // A visit is finished only once its recorder has stopped AND every chunk it
  // produced has been acknowledged. Announcing it earlier would let the server
  // rename a .part file that still has bytes coming.
  function maybeDone(key){
    if (!PH.closing[key]) return;
    if ((PH.pending[key] || 0) > 0) return;
    delete PH.closing[key];
    delete PH.pending[key];
    send('visit_done', {key:key, at:Date.now()});
  }

  // ---- DOM state hooks ---------------------------------------------------
  // Written to <body> so the browser tests can wait on real state instead of
  // sleeping, and so anyone can see what the app thinks is happening by
  // looking at the element inspector.
  function setMic(state){
    document.body.dataset.phMic = state;
    var el = document.getElementById('ph-mic-state');
    if (el) el.textContent = state;
  }
  function setVisit(key){
    PH.visitKey = key || '';
    document.body.dataset.phVisit = PH.visitKey;
    showVisitChunks();
  }
  // Two counters, because they answer different questions. phChunks is every
  // chunk this page has ever had acknowledged; phVisitChunks is how many
  // belong to the visit currently open. Only the second can tell you whether
  // THIS photograph has recorded anything yet -- a chunk flushed by the
  // previous recorder as it stopped would otherwise be mistaken for one.
  function bumpChunks(key){
    var n = parseInt(document.body.dataset.phChunks || '0', 10) + 1;
    document.body.dataset.phChunks = n;
    if (key) PH.ackedBy[key] = (PH.ackedBy[key] || 0) + 1;
    showVisitChunks();
  }
  function showVisitChunks(){
    document.body.dataset.phVisitChunks =
      String((PH.visitKey && PH.ackedBy[PH.visitKey]) || 0);
  }
  function el(id){ return document.getElementById(id); }
  function setText(id, t){ var e = el(id); if (e) e.textContent = t; }

  // ---- recorder ----------------------------------------------------------
  function pickMime(){
    if (typeof MediaRecorder === 'undefined') return null;
    var want = ['audio/webm;codecs=opus', 'audio/webm'];
    for (var i=0;i<want.length;i++){
      if (MediaRecorder.isTypeSupported(want[i])) return want[i];
    }
    return null;
  }
  function mimeList(){
    var all = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus',
               'audio/mp4'];
    if (typeof MediaRecorder === 'undefined') return [];
    return all.filter(function(m){ return MediaRecorder.isTypeSupported(m); });
  }

  // ---- microphone --------------------------------------------------------
  function haveMedia(){
    return !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
  }
  function constraints(){
    return PH.deviceId ? {audio: {deviceId: {exact: PH.deviceId}}}
                       : {audio: true};
  }
  function openMic(){
    if (!haveMedia()) return Promise.reject({name: 'insecure'});
    return navigator.mediaDevices.getUserMedia(constraints());
  }
  function listInputs(){
    if (!navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) {
      return Promise.resolve([]);
    }
    return navigator.mediaDevices.enumerateDevices().then(function(ds){
      return ds.filter(function(d){ return d.kind === 'audioinput'; })
               .map(function(d, i){
                 return {id: d.deviceId,
                         label: d.label || ('input ' + (i + 1) + ' (unnamed until allowed)')};
               });
    }).catch(function(){ return []; });
  }

  // Arming, with exactly one automatic retry. On macOS the OS permission grant
  // routinely lands a moment AFTER the first getUserMedia() rejection -- the
  // prompt is still on screen when the promise settles -- so a single retry
  // turns a dead end into a working microphone. Once, never a loop.
  function arm(isRetry){
    PH.mime = pickMime();
    setMic('arming');
    if (!PH.mime) { setMic('error'); send('mic_ready', {ok:false, why:'nocodec'}); return; }
    openMic().then(function(s){
      if (PH.stream && PH.stream !== s) stopStream(PH.stream);
      PH.stream = s;
      setMic('on');
      send('mic_ready', {ok:true, mime:PH.mime, deviceId:PH.deviceId || null});
    }).catch(function(err){
      var name = String((err && err.name) || err);
      if (!isRetry && (name === 'NotFoundError' || name === 'NotAllowedError')) {
        setTimeout(function(){ arm(true); }, 1200);
        return;
      }
      setMic('error');
      send('mic_ready', {ok:false, why:name});
    });
  }
  function stopStream(s){
    if (!s) return;
    s.getTracks().forEach(function(t){ t.stop(); });
  }

  // ---- the microphone check ----------------------------------------------
  // Entirely client-side except for the wording of the advice, which comes
  // from ph_mic_advice() in R so that every branch of it can be tested.
  function meterStart(stream){
    meterStop();
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    try { PH.ac = new AC(); } catch (e) { return; }
    if (PH.ac.resume) PH.ac.resume();
    var src = PH.ac.createMediaStreamSource(stream);
    var an = PH.ac.createAnalyser();
    an.fftSize = 1024;
    src.connect(an);
    var buf = new Uint8Array(an.fftSize);
    var peak = 0;
    (function tick(){
      an.getByteTimeDomainData(buf);
      var sum = 0;
      for (var i = 0; i < buf.length; i++) {
        var v = (buf[i] - 128) / 128; sum += v * v;
      }
      var rms = Math.sqrt(sum / buf.length);
      peak = Math.max(rms, peak * 0.9);            // fall back slowly, so a
      var bar = el('ph-level-fill');               // short word still shows
      if (bar) bar.style.width = Math.min(100, Math.round(peak * 320)) + '%';
      PH.meter = requestAnimationFrame(tick);
    })();
  }
  function meterStop(){
    if (PH.meter) cancelAnimationFrame(PH.meter);
    PH.meter = null;
    if (PH.ac && PH.ac.close) { try { PH.ac.close(); } catch (e) {} }
    PH.ac = null;
  }

  function panel(on){
    var p = el('ph-mic-panel');
    if (p) p.style.display = on ? 'block' : 'none';
  }

  function runCheck(){
    panel(true);
    setText('ph-mic-advice', 'Asking for the microphone...');
    setText('ph-mic-detail', '');
    var a = el('ph-test-audio'); if (a) a.style.display = 'none';
    PH.mime = pickMime();
    var env = {secure: !!window.isSecureContext, hasMedia: haveMedia(),
               mimes: mimeList(), ua: navigator.userAgent};
    openMic().then(function(s){
      if (PH.stream && PH.stream !== s) stopStream(PH.stream);
      PH.stream = s;
      PH.checkOwnsStream = !PH.sitting;
      setMic('on');
      meterStart(s);
      return listInputs().then(function(devs){
        fillDevices(devs);
        send('mic_check', Object.assign({ok: true, devices: devs}, env));
      });
    }).catch(function(err){
      setMic('error');
      send('mic_check', Object.assign(
        {ok: false, why: String((err && err.name) || err), devices: []}, env));
    });
  }

  function fillDevices(devs){
    var sel = el('ph-mic-device');
    if (!sel) return;
    sel.innerHTML = '';
    devs.forEach(function(d){
      var o = document.createElement('option');
      o.value = d.id; o.textContent = d.label;
      if (PH.deviceId === d.id) o.selected = true;
      sel.appendChild(o);
    });
    sel.disabled = devs.length < 2;
  }

  function testRecord(){
    if (!PH.stream || !PH.mime) { setText('ph-test-note', 'no microphone yet'); return; }
    var rec, parts = [];
    try { rec = new MediaRecorder(PH.stream, {mimeType: PH.mime}); }
    catch (e) { setText('ph-test-note', 'could not start: ' + e); return; }
    rec.ondataavailable = function(e){ if (e.data && e.data.size) parts.push(e.data); };
    rec.onstop = function(){
      var blob = new Blob(parts, {type: PH.mime});
      var a = el('ph-test-audio');
      if (a) { a.src = URL.createObjectURL(blob); a.style.display = 'block'; }
      setText('ph-test-note',
              'recorded ' + Math.round(blob.size / 1024) + ' kB - press play to hear it');
      document.body.dataset.phTest = String(blob.size);
    };
    rec.start();
    setText('ph-test-note', 'recording, say something...');
    setTimeout(function(){ try { rec.stop(); } catch (e) {} }, 3000);
  }

  function closeCheck(){
    panel(false);
    meterStop();
    // Release the microphone -- and the browser's recording indicator -- but
    // only if the check opened it. A sitting in progress keeps its stream.
    if (PH.checkOwnsStream && !PH.sitting) {
      stopStream(PH.stream); PH.stream = null; setMic('off');
    }
    PH.checkOwnsStream = false;
  }
  function startRec(key){
    if (!PH.stream || !PH.mime) return;
    stopRec(false);
    try {
      PH.rec = new MediaRecorder(PH.stream, {mimeType: PH.mime});
    } catch (e) { PH.rec = null; return; }
    PH.key = key;
    PH.rec.ondataavailable = function(e){
      if (e.data && e.data.size > 0) queue(key, e.data, false);
    };
    PH.rec.onstop = function(){ maybeDone(key); };
    // Chunks from ONE recorder concatenate into a valid WebM, which is what
    // lets the server append them straight to disk with no muxing step.
    PH.rec.start(PH.chunkMs);
  }
  function stopRec(){
    if (PH.rec && PH.rec.state !== 'inactive') {
      try { PH.rec.stop(); } catch (e) {}
    }
    PH.rec = null;
  }

  // ---- playback ----------------------------------------------------------
  // The audio element's 'ended' event is the clock. Driving this from the
  // server could not keep image and sound in step.
  function playAt(i){
    if (!PH.play || i >= PH.play.length) { playStop(true); return; }
    PH.playIdx = i;
    var it = PH.play[i];
    showPhoto(it);
    var strip = document.getElementById('ph-play-fill');
    if (strip) strip.style.width = ((i+1)/PH.play.length*100) + '%';
    if (PH.audio) { PH.audio.pause(); PH.audio = null; }
    clearTimeout(PH.playTimer);
    if (it.audio) {
      PH.audio = new Audio(it.audio);
      PH.audio.onended = function(){ playAt(i+1); };
      PH.audio.onerror = function(){ playAt(i+1); };
      PH.audio.play().catch(function(){ playAt(i+1); });
    } else {
      var ms = Math.max(1200, (it.duration || 2) * 1000);
      PH.playTimer = setTimeout(function(){ playAt(i+1); }, ms);
    }
  }
  function playStop(finished){
    clearTimeout(PH.playTimer);
    if (PH.audio) { PH.audio.pause(); PH.audio = null; }
    PH.play = null;
    send('play_ended', {at:Date.now(), finished:!!finished});
  }

  function showPhoto(it){
    var im = document.getElementById('ph-photo');
    if (im && it.src) im.src = it.src;
    var cap = document.getElementById('ph-cap');
    if (cap) cap.innerHTML = it.caption || '';
    if (it.id) markCurrent(it.id);
  }
  function markCurrent(id){
    PH.current = id;
    document.querySelectorAll('.ph-p-on').forEach(function(e){
      e.classList.remove('ph-p-on');
    });
    var el = document.getElementById('ph-p-' + id);
    if (el) {
      el.classList.add('ph-p-on');
      el.scrollIntoView({block:'nearest'});
      // Open every collapsed ancestor, so a photograph reached by keyboard or
      // by playback is actually visible in the tree.
      var p = el.parentElement;
      while (p) { if (p.tagName === 'DETAILS') p.open = true; p = p.parentElement; }
    }
  }

  // ---- keyboard ----------------------------------------------------------
  document.addEventListener('keydown', function(e){
    var t = e.target;
    if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' ||
              t.isContentEditable)) return;
    if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
      if (!PH.order.length) return;
      var i = PH.order.indexOf(PH.current);
      var n = i < 0 ? 0 : i + (e.key === 'ArrowRight' ? 1 : -1);
      if (n < 0 || n >= PH.order.length) return;
      e.preventDefault();
      send('photo_pick', PH.order[n]);
    } else if (e.key === 's') {
      document.body.classList.toggle('ph-present');
    } else if (e.key === 'f') {
      if (document.fullscreenElement) document.exitFullscreen();
      else document.documentElement.requestFullscreen();
    }
  });

  $(document).on('shiny:connected', function(){
    Shiny.addCustomMessageHandler('ph_init', function(m){
      PH.order = m.order || [];
      PH.chunkMs = (m.chunk_seconds || 5) * 1000;
    });
    Shiny.addCustomMessageHandler('ph_show', showPhoto);
    Shiny.addCustomMessageHandler('ph_current', markCurrent);
    Shiny.addCustomMessageHandler('ph_badge', function(m){
      var el = document.getElementById('ph-p-' + m.id);
      if (!el) return;
      var b = el.querySelector('.ph-b');
      if (!b) {
        b = document.createElement('span');
        b.className = 'ph-b';
        el.appendChild(b);
      }
      b.textContent = m.n;
    });

    // What this browser can actually do, reported once on connect so the app
    // can say that Safari cannot record before anyone presses Start sitting,
    // rather than at the moment the room falls quiet and looks at the screen.
    send('browser_env', {secure: !!window.isSecureContext,
                         hasMedia: haveMedia(), mimes: mimeList(),
                         mime: pickMime(), ua: navigator.userAgent});

    // Arming the microphone is a deliberate, visible act: it happens on a
    // click, never on load, and the browser's own permission prompt is part of
    // the point.
    Shiny.addCustomMessageHandler('ph_arm', function(m){
      PH.sitting = true;
      arm(false);
    });
    Shiny.addCustomMessageHandler('ph_disarm', function(m){
      PH.sitting = false;
      stopRec();
      meterStop();
      stopStream(PH.stream);
      PH.stream = null;
      setMic('off');
    });
    Shiny.addCustomMessageHandler('ph_check', function(m){ runCheck(); });
    Shiny.addCustomMessageHandler('ph_advice', function(m){
      setText('ph-mic-advice', m.advice || '');
      setText('ph-mic-detail', m.detail || '');
    });
    // Buttons inside the check panel are plain HTML, not Shiny inputs: the
    // panel has to work whether or not the server is busy.
    var wire = function(id, fn){ var b = el(id); if (b) b.onclick = fn; };
    wire('ph-mic-run', runCheck);
    wire('ph-mic-test', testRecord);
    wire('ph-mic-close', closeCheck);
    var dev = el('ph-mic-device');
    if (dev) dev.onchange = function(){
      PH.deviceId = dev.value || null;
      runCheck();                       // reopen on the newly chosen device
    };
    Shiny.addCustomMessageHandler('ph_visit_open', function(m){
      setVisit(m.key);
      if (m.record) startRec(m.key); else PH.key = m.key;
    });
    Shiny.addCustomMessageHandler('ph_visit_close', function(m){
      setVisit('');
      PH.closing[m.key] = true;
      if (PH.rec && PH.key === m.key) stopRec();
      maybeDone(m.key);
    });
    Shiny.addCustomMessageHandler('ph_visit_drop', function(m){
      // Throw away everything queued for this visit, then stop. The server
      // deletes the .part file and opens a fresh visit with a new key, so any
      // chunk still in flight lands on a key the server no longer knows.
      PH.q = PH.q.filter(function(c){ return c.key !== m.key; });
      PH.pending[m.key] = 0;
      delete PH.closing[m.key];
      if (PH.rec && PH.key === m.key) stopRec();
      send('drop_done', {key:m.key, at:Date.now()});
    });
    Shiny.addCustomMessageHandler('ph_chunk_ok', function(m){ acked(); });
    Shiny.addCustomMessageHandler('ph_play', function(m){
      PH.play = m.items || [];
      if (!PH.play.length) { playStop(true); return; }
      playAt(0);
    });
    Shiny.addCustomMessageHandler('ph_play_stop', function(m){ playStop(false); });
    Shiny.addCustomMessageHandler('ph_play_step', function(m){
      if (!PH.play) return;
      playAt(Math.min(PH.play.length - 1, Math.max(0, PH.playIdx + m.by)));
    });
    Shiny.addCustomMessageHandler('ph_present', function(m){
      document.body.classList.toggle('ph-present', !!m.on);
    });
  });
})();
"

ui <- page_sidebar(
  title = paste("phostor —", cfg$title),
  theme = bs_theme(version = 5, bg = "#111316", fg = "#e8eaed",
                   primary = "#3b82f6"),
  fillable = TRUE,
  tags$head(tags$style(HTML(ph_css)), tags$script(HTML(ph_js))),
  sidebar = sidebar(
    width = 340,
    div(class = "d-flex gap-1 mb-1",
        actionButton("present", "Presentation", class = "btn-sm btn-outline-secondary w-100")),
    uiOutput("tree"),
    div(class = "mt-2 pt-2 border-top small text-secondary",
        HTML("&larr; &rarr; move &middot; <b>s</b> sidebar &middot; <b>f</b> full screen"))
  ),
  div(
    class = "ph-stage",
    div(
      class = "ph-bar",
      uiOutput("rec", inline = TRUE),
      div(class = "ph-hide",
          actionButton("mic_check_btn", "Check microphone",
                       class = "btn-sm btn-outline-light")),
      div(class = "ph-hide", uiOutput("sitting_controls", inline = TRUE)),
      div(class = "ph-meta ph-hide", textOutput("sitting_info", inline = TRUE)),
      div(class = "ms-auto ph-hide", uiOutput("play_controls", inline = TRUE))
    ),
    # Static, hidden, and owned entirely by the JavaScript above. Deliberately
    # not a Shiny modal: a microphone check has to work even when the server is
    # busy, and it must not depend on render timing to find its own elements.
    div(
      id = "ph-mic-panel", class = "ph-mic",
      tags$h6("Microphone check"),
      div(class = "row2",
          tags$select(id = "ph-mic-device"),
          tags$button(id = "ph-mic-run", class = "btn btn-sm btn-outline-light",
                      "Check")),
      div(class = "ph-level", tags$i(id = "ph-level-fill")),
      div(class = "hint", "Say something — the bar should move."),
      div(class = "advice", id = "ph-mic-advice"),
      div(class = "detail", id = "ph-mic-detail"),
      div(class = "row2 mt-2",
          tags$button(id = "ph-mic-test",
                      class = "btn btn-sm btn-outline-light",
                      "Record 3 seconds"),
          tags$button(id = "ph-mic-close",
                      class = "btn btn-sm btn-outline-secondary", "Close")),
      div(class = "hint", id = "ph-test-note"),
      tags$audio(id = "ph-test-audio", controls = NA)
    ),
    uiOutput("browser_banner"),
    div(class = "ph-img-wrap", tags$img(id = "ph-photo", alt = "")),
    div(id = "ph-cap", class = "ph-cap"),
    div(class = "ph-play-strip ph-hide", tags$i(id = "ph-play-fill")),
    div(
      class = "ph-tags ph-hide",
      layout_columns(
        col_widths = c(6, 6),
        selectizeInput("people", "Who is in this photograph?", choices = NULL,
                       multiple = TRUE,
                       options = list(create = TRUE, persist = FALSE,
                                      placeholder = "type a name and press enter")),
        layout_columns(
          col_widths = c(4, 4, 4),
          textInput("place", "Place", ""),
          textInput("event", "Event", ""),
          textInput("when", "When", "")
        )
      )
    ),
    div(class = "ph-hist-wrap ph-hide", uiOutput("history"))
  )
)

server <- function(input, output, session) {
  rv <- reactiveValues(
    idx = idx_all,
    current = NULL,          # photo id on screen
    session_dir = NULL,      # NULL until a sitting starts
    armed = FALSE,           # microphone open
    mic_msg = NULL,
    paused = FALSE,          # Pause pressed, as against arming having failed
    env = NULL,              # what the browser told us it can do
    browser = NA_character_, # its name, from the user agent
    visit = NULL,            # the open visit
    pending = list(),        # visits waiting for their last audio chunks
    seq = 0L,
    reserved = list(),       # rel_path -> highest visit number handed out
    ending = FALSE,          # End sitting pressed, waiting for visits to drain
    tick = 0L,
    playing = FALSE,
    present = FALSE
  )

  # Every message to the client goes through here: finalize_visit() also runs
  # from onSessionEnded(), by which point the websocket is gone and a bare
  # sendCustomMessage() would raise inside a handler nobody can catch.
  tell <- function(type, msg) {
    tryCatch(session$sendCustomMessage(type, msg), error = function(e) NULL)
  }

  row_of <- function(id) {
    if (is.null(id)) return(NULL)
    i <- match(as.integer(id), as.integer(rv$idx$id))
    if (is.na(i)) NULL else rv$idx[i, , drop = FALSE]
  }

  # ---- the tree: rendered once ------------------------------------------
  # Deliberately does NOT read rv$current -- the highlight is moved on the
  # client. rv$tick is here so a new visit can repaint the badges, and even
  # that is normally done client-side by ph_badge.
  output$tree <- renderUI({
    counts <- ph_visit_counts(cfg, rv$idx$rel_path)
    HTML(ph_tree_html(rv$idx, counts = counts))
  })

  # onFlushed() runs outside a reactive context, where reading rv$... raises
  # "Can't access reactive value outside of reactive consumer". isolate() is
  # the fix, not moving the work: this has to happen after the tree exists, or
  # the initial highlight has no element to land on.
  session$onFlushed(function() {
    isolate({
      tell("ph_init", list(order = as.list(ph_tree_order(rv$idx)),
                           chunk_seconds = cfg$chunk_seconds))
      if (nrow(rv$idx)) show_photo(ph_tree_order(rv$idx)[[1]])
    })
  }, once = TRUE)

  # ---- showing a photograph ---------------------------------------------
  caption_html <- function(r) {
    if (is.null(r)) return("")
    cap <- if (!is.na(r$capture)) {
      sprintf("<b>%s</b>%s", ph_escape(r$capture),
              if (identical(r$capture_src, "CreateDate")) " (CreateDate)" else "")
    } else "<b>no date recorded</b>"
    dims <- if (!is.na(r$width) && !is.na(r$height)) {
      sprintf("%d &times; %d", r$width, r$height)
    } else ""
    paste0("<span><b>", ph_escape(r$name), "</b></span>",
           "<span>", ph_escape(if (nzchar(r$dir)) r$dir else "."), "</span>",
           "<span>", cap, "</span>",
           if (nzchar(dims)) paste0("<span>", dims, "</span>") else "")
  }

  show_photo <- function(id) {
    r <- row_of(id)
    if (is.null(r)) return(invisible(NULL))
    rv$current <- as.integer(id)
    tell("ph_show", list(
      id = as.integer(id),
      src = sprintf("display/%d.jpg", as.integer(id)),
      caption = caption_html(r)))
    seed_fields(r$rel_path)
    invisible(NULL)
  }

  # A second visit starts from what the room already established, not from
  # blank. Nothing is overwritten: this seeds the form, and the new visit gets
  # its own sidecar.
  seed_fields <- function(rel_path) {
    last <- ph_last_visit(cfg, rel_path)
    known <- ph_known_people(cfg)
    sel <- if (is.null(last)) character(0) else last$people
    updateSelectizeInput(session, "people",
                         choices = sort(unique(c(known, sel))),
                         selected = sel, server = FALSE)
    updateTextInput(session, "place", value = as.character(last$place %||% ""))
    updateTextInput(session, "event", value = as.character(last$event %||% ""))
    updateTextInput(session, "when", value = as.character(last$when %||% ""))
  }

  observeEvent(input$photo_pick, {
    id <- as.integer(input$photo_pick)
    if (isTRUE(rv$playing)) stop_play(finished = FALSE)
    if (identical(id, rv$current)) return()
    close_visit()
    show_photo(id)
    open_visit()
  })

  # ---- a sitting ---------------------------------------------------------
  observeEvent(input$start, {
    rv$paused <- FALSE
    rv$session_dir <- ph_path_new(cfg)
    rv$mic_msg <- "asking for the microphone..."
    tell("ph_arm", list(on = TRUE))
    showModal(modalDialog(
      title = "This room is being recorded",
      p("phostor is now recording the conversation about each photograph, ",
        "and will keep recording until you stop the sitting."),
      p(class = "text-secondary",
        "Everything is written to this laptop, under the work directory. ",
        "Nothing is uploaded anywhere."),
      footer = modalButton("Everyone knows — begin"), easyClose = FALSE))
  })

  # What the browser can do, reported once on connect. Knowing this before a
  # sitting starts is the whole point: a browser that cannot record should say
  # so while there is still time to open a different one.
  observeEvent(input$browser_env, {
    rv$env <- input$browser_env
    rv$browser <- ph_browser_name(input$browser_env$ua %||% "")
  })

  output$browser_banner <- renderUI({
    e <- rv$env
    if (is.null(e)) return(NULL)
    why <- if (!isTRUE(e$hasMedia) || !isTRUE(e$secure)) "insecure"
           else if (is.null(e$mime) || !length(e$mime)) "nocodec"
           else return(NULL)
    div(class = "ph-warn",
        strong("This browser cannot record. "),
        ph_mic_advice(why, rv$browser))
  })

  observeEvent(input$mic_check_btn, tell("ph_check", list(on = TRUE)))
  observeEvent(input$mic_retry, {
    rv$paused <- FALSE
    rv$mic_msg <- "asking for the microphone again..."
    tell("ph_arm", list(on = TRUE))
  })

  # The check panel is client-side; only the wording comes from here, so that
  # every branch of it is reachable by the test suite.
  observeEvent(input$mic_check, {
    m <- input$mic_check
    rv$browser <- ph_browser_name(m$ua %||% "")
    devs <- m$devices %||% list()
    advice <- if (isTRUE(m$ok)) {
      sprintf("Microphone open in %s. %s",
              rv$browser %||% "this browser",
              if (length(devs) > 1)
                "Speak, and check the bar moves. Pick a different input above if it does not."
              else "Speak, and check the bar moves.")
    } else {
      ph_mic_advice(as.character(m$why %||% ""), rv$browser)
    }
    tell("ph_advice", list(
      advice = advice,
      detail = sprintf("%s | secure:%s | inputs:%d | formats: %s",
                       rv$browser %||% "unknown browser",
                       if (isTRUE(m$secure)) "yes" else "NO", length(devs),
                       if (length(m$mimes)) paste(unlist(m$mimes),
                                                  collapse = ", ")
                       else "none")))
  })

  observeEvent(input$mic_ready, {
    ok <- isTRUE(input$mic_ready$ok)
    rv$armed <- ok
    rv$mic_msg <- if (ok) NULL else {
      ph_mic_advice(as.character(input$mic_ready$why %||% ""), rv$browser)
    }
    # The sitting may already have opened a visit while the permission prompt
    # was on screen. That one was opened with no recorder attached, so close it
    # and open it again now that there is a microphone -- otherwise the first
    # photograph of the evening is the one photograph with no audio.
    if (isTRUE(rv$armed) && !is.null(rv$visit) && is.null(rv$visit$part)) {
      close_visit()
    }
    open_visit()
  })

  observeEvent(input$stop_sitting, {
    rv$ending <- TRUE
    close_visit()
    finish_sitting()
  })

  # An audio visit finalizes only once the browser has flushed its last chunk,
  # so the sitting cannot be wound up the moment the button is pressed: its
  # final `leave` row would land after `end`. Wait for the queue to drain.
  finish_sitting <- function() {
    if (!isTRUE(rv$ending) || length(rv$pending)) return(invisible(NULL))
    d <- rv$session_dir
    if (!is.null(d)) ph_path_append(d, "end")
    tell("ph_disarm", list(on = FALSE))
    rv$armed <- FALSE
    rv$ending <- FALSE
    rv$session_dir <- NULL
    rv$reserved <- list()
    rv$mic_msg <- NULL
    if (!is.null(d)) {
      p <- ph_path_read(d)
      showModal(modalDialog(
        title = "Sitting ended",
        sprintf("%d visit(s) recorded to %s", sum(p$event == "leave"),
                basename(d)),
        easyClose = TRUE, footer = modalButton("Close")))
    }
    invisible(NULL)
  }

  observeEvent(input$pause, {
    # Pausing closes the visit rather than splicing a gap into its audio:
    # chunks from two different recorders cannot be concatenated, and a visit
    # that stops and restarts is exactly what a second visit already means.
    close_visit()
    tell("ph_disarm", list(on = FALSE))
    rv$armed <- FALSE
    rv$paused <- TRUE
    rv$mic_msg <- NULL
    if (!is.null(rv$session_dir)) ph_path_append(rv$session_dir, "pause")
  })

  observeEvent(input$resume, {
    rv$paused <- FALSE
    if (!is.null(rv$session_dir)) ph_path_append(rv$session_dir, "resume")
    tell("ph_arm", list(on = TRUE))
  })

  # ---- visits ------------------------------------------------------------
  open_visit <- function() {
    if (is.null(rv$session_dir) || is.null(rv$current)) return(invisible(NULL))
    if (!is.null(rv$visit)) return(invisible(NULL))
    r <- row_of(rv$current)
    if (is.null(r)) return(invisible(NULL))
    rv$seq <- rv$seq + 1L
    key <- sprintf("v%d", rv$seq)
    # Two numbering guards, because neither alone is enough. On disk,
    # ph_next_visit() sees the .part and .yml files of every earlier visit,
    # including from previous sittings. In memory, `reserved` covers the visit
    # whose sidecar has not been written yet -- leaving a photograph and coming
    # straight back would otherwise compute the same number twice.
    held <- as.integer(rv$reserved[[r$rel_path]] %||% 0L)
    n <- max(ph_next_visit(cfg, r$rel_path), held + 1L)
    rv$reserved[[r$rel_path]] <- n
    part <- if (isTRUE(rv$armed)) ph_audio_open(cfg, r$rel_path, n) else NULL
    rv$visit <- list(key = key, id = as.integer(rv$current),
                     rel_path = r$rel_path, visit = n, session_dir = rv$session_dir,
                     started = Sys.time(), part = part)
    rv$pending[[key]] <- rv$visit
    ph_path_append(rv$session_dir, "show", rel_path = r$rel_path, visit = n)
    tell("ph_visit_open",
                              list(key = key, record = isTRUE(rv$armed)))
    invisible(NULL)
  }

  close_visit <- function() {
    v <- rv$visit
    if (is.null(v)) return(invisible(NULL))
    v$ended <- Sys.time()
    v$fields <- list(people = input$people %||% character(0),
                     place = input$place %||% "",
                     event = input$event %||% "",
                     when = input$when %||% "")
    # The `leave` row is written NOW, while this photograph is still the one
    # being left, so path.tsv reads in the order the evening actually took. If
    # it waited for finalize_visit() -- which an audio visit reaches only once
    # the browser has flushed its last chunk -- the next photograph's `show`
    # would already be above it.
    v$duration <- as.numeric(difftime(v$ended, v$started, units = "secs"))
    if (!is.null(v$session_dir)) {
      ph_path_append(v$session_dir, "leave", rel_path = v$rel_path,
                     visit = v$visit, duration = v$duration)
    }
    rv$pending[[v$key]] <- v
    rv$visit <- NULL
    if (!is.null(v$part)) {
      # The client answers with visit_done once its recorder has stopped and
      # every chunk has been acknowledged.
      tell("ph_visit_close", list(key = v$key))
    } else {
      finalize_visit(v$key)
    }
    invisible(NULL)
  }

  observeEvent(input$visit_done, {
    finalize_visit(as.character(input$visit_done$key))
  })

  finalize_visit <- function(key) {
    v <- rv$pending[[key]]
    if (is.null(v)) return(invisible(NULL))
    rv$pending[[key]] <- NULL
    audio <- if (!is.null(v$part)) ph_audio_close(v$part) else NA_character_
    dur <- v$duration %||% as.numeric(difftime(v$ended %||% Sys.time(),
                                               v$started, units = "secs"))
    f <- v$fields %||% list()
    said <- length(f$people) > 0 || any(nzchar(c(f$place %||% "",
                                                 f$event %||% "",
                                                 f$when %||% "")))
    # A visit too short to have held a conversation, with nothing typed and no
    # audio, leaves a row in the path and nothing else. Paging past forty
    # photographs looking for one must not leave forty empty records.
    keep <- !is.na(audio) || said || dur >= cfg$min_visit_seconds
    if (keep) {
      ph_write_sidecar(cfg, v$rel_path, v$visit, list(
        session = basename(v$session_dir %||% ""),
        started = format(as.POSIXct(v$started), "%Y-%m-%dT%H:%M:%SZ",
                         tz = "UTC"),
        ended = format(as.POSIXct(v$ended %||% Sys.time()),
                       "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
        duration = dur,
        audio = audio,
        people = f$people, place = f$place, event = f$event, when = f$when))
    }
    if (keep) {
      tell("ph_badge", list(id = v$id,
                            n = ph_visit_counts(cfg, v$rel_path)))
    }
    rv$tick <- rv$tick + 1L
    finish_sitting()
    invisible(NULL)
  }

  observeEvent(input$discard, {
    v <- rv$visit
    if (is.null(v)) return()
    tell("ph_visit_drop", list(key = v$key))
  })

  observeEvent(input$drop_done, {
    key <- as.character(input$drop_done$key)
    v <- rv$pending[[key]]
    if (is.null(v)) return()
    if (!is.null(v$part)) ph_audio_discard(v$part)
    rv$pending[[key]] <- NULL
    if (identical(rv$visit$key, key)) rv$visit <- NULL
    if (!is.null(rv$session_dir)) {
      ph_path_append(rv$session_dir, "discard", rel_path = v$rel_path,
                     visit = v$visit)
    }
    open_visit()
  })

  # ---- audio chunks ------------------------------------------------------
  observeEvent(input$audio_chunk, {
    ch <- input$audio_chunk
    key <- as.character(ch$key %||% "")
    v <- rv$pending[[key]]
    # An unknown key is a chunk from a superseded recorder: a discarded visit,
    # or one whose file has already been renamed. Dropping it is the whole
    # reason the races above are safe. Acknowledge anyway, or the client's
    # queue stalls behind it.
    if (!is.null(v) && !is.null(v$part)) ph_audio_append(v$part, ch$b64)
    tell("ph_chunk_ok", list(seq = ch$seq))
  })

  # ---- indicators and controls ------------------------------------------
  output$rec <- renderUI({
    on <- isTRUE(rv$armed) && !is.null(rv$visit)
    div(class = paste("ph-rec", if (on) "on" else ""),
        span(class = "dot"), span(if (on) "REC" else "not recording"))
  })

  output$sitting_controls <- renderUI({
    if (is.null(rv$session_dir)) {
      return(actionButton("start", "Start sitting", class = "btn-sm btn-danger"))
    }
    tagList(
      # Three states, not two. A paused sitting resumes; a sitting whose
      # microphone never opened needs to try again -- and that used to be the
      # same undocumented "Resume" button, which is why the failure looked
      # like a dead end.
      if (isTRUE(rv$armed)) {
        actionButton("pause", "Pause", class = "btn-sm btn-outline-light")
      } else if (isTRUE(rv$paused)) {
        actionButton("resume", "Resume", class = "btn-sm btn-outline-light")
      } else {
        actionButton("mic_retry", "Try the microphone again",
                     class = "btn-sm btn-warning")
      },
      actionButton("discard", "Discard this take",
                   class = "btn-sm btn-outline-warning"),
      actionButton("stop_sitting", "End sitting",
                   class = "btn-sm btn-outline-danger")
    )
  })

  output$sitting_info <- renderText({
    if (!is.null(rv$mic_msg)) return(rv$mic_msg)
    if (is.null(rv$session_dir)) {
      return("no sitting in progress — nothing is being recorded")
    }
    v <- rv$visit
    sprintf("sitting %s%s", basename(rv$session_dir),
            if (!is.null(v)) sprintf(" · visit %d", v$visit) else "")
  })

  output$play_controls <- renderUI({
    rv$tick
    sess <- ph_sessions(cfg)
    if (!nrow(sess)) return(NULL)
    if (isTRUE(rv$playing)) {
      return(tagList(
        actionButton("play_back", "⏮", class = "btn-sm btn-outline-light"),
        actionButton("play_fwd", "⏭", class = "btn-sm btn-outline-light"),
        actionButton("play_stop", "Stop", class = "btn-sm btn-outline-light")))
    }
    tagList(
      div(class = "d-inline-block", style = "width:15rem",
          selectInput("play_session", NULL,
                      choices = stats::setNames(sess$dir,
                                                sprintf("%s (%d)", sess$session,
                                                        sess$visits)),
                      width = "100%")),
      actionButton("play", "Play", class = "btn-sm btn-primary"))
  })

  observeEvent(input$present, {
    rv$present <- !isTRUE(rv$present)
    tell("ph_present", list(on = rv$present))
  })

  # ---- prior visits ------------------------------------------------------
  output$history <- renderUI({
    rv$tick
    r <- row_of(rv$current)
    if (is.null(r)) return(NULL)
    v <- ph_visits_for(cfg, r$rel_path)
    if (!length(v)) {
      return(div(class = "ph-hist text-secondary small",
                 "No earlier visits to this photograph."))
    }
    rows <- lapply(v, function(s) {
      url <- if (!is.na(s$audio_path)) {
        sprintf("sidecars/%s/%s", ph_url_path(r$rel_path),
                ph_url_path(basename(s$audio_path)))
      } else NULL
      said <- paste(stats::na.omit(c(
        if (length(s$people)) paste(s$people, collapse = ", "),
        s$place %||% NULL, s$event %||% NULL, s$when %||% NULL)),
        collapse = " · ")
      div(class = "v",
          div(class = "vh", sprintf("visit %d · %s%s", s$visit,
                                    s$started %||% "?",
                                    if (!is.na(s$duration))
                                      sprintf(" · %.0fs", s$duration) else "")),
          if (!is.null(url)) tags$audio(controls = NA, preload = "none",
                                        src = url),
          if (nzchar(said)) div(said))
    })
    div(class = "ph-hist",
        tags$details(tags$summary(sprintf("%d earlier visit(s)", length(v))),
                     rows))
  })

  # ---- playback ----------------------------------------------------------
  observeEvent(input$play, {
    d <- input$play_session
    if (is.null(d) || !nzchar(d)) return()
    close_visit()
    pl <- ph_playlist(cfg, d)
    if (!nrow(pl)) {
      showNotification("That sitting has no completed visits.", type = "warning")
      return()
    }
    items <- lapply(seq_len(nrow(pl)), function(i) {
      r <- row_of(pl$id[i])
      list(id = as.integer(pl$id[i]),
           src = sprintf("display/%d.jpg", as.integer(pl$id[i])),
           caption = caption_html(r),
           duration = if (is.na(pl$duration[i])) 3 else pl$duration[i],
           audio = if (is.na(pl$audio[i])) NULL else
             sprintf("sidecars/%s", ph_url_path(pl$audio[i])))
    })
    rv$playing <- TRUE
    tell("ph_play", list(items = items))
  })

  stop_play <- function(finished = FALSE) {
    rv$playing <- FALSE
    tell("ph_play_stop", list(on = FALSE))
  }
  observeEvent(input$play_stop, stop_play(FALSE))
  observeEvent(input$play_ended, { rv$playing <- FALSE })
  observeEvent(input$play_fwd,
               tell("ph_play_step", list(by = 1)))
  observeEvent(input$play_back,
               tell("ph_play_step", list(by = -1)))

  # A closed browser tab must not lose the visit in progress: finalize it, so
  # its audio is renamed and its sidecar written.
  session$onSessionEnded(function() {
    isolate({
      # Not close_visit(): that asks the browser to flush its recorder, and
      # there is no browser left to ask. Take what already reached disk, write
      # the sidecar, and let the .part rename stand for the rest.
      v <- rv$visit
      if (!is.null(v)) {
        v$ended <- Sys.time()
        v$fields <- list(people = input$people %||% character(0),
                         place = input$place %||% "",
                         event = input$event %||% "",
                         when = input$when %||% "")
        rv$pending[[v$key]] <- v
        rv$visit <- NULL
      }
      for (k in names(rv$pending)) finalize_visit(k)
    })
  })
}

shinyApp(ui, server)
