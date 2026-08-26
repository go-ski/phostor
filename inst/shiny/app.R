# phostor -- the Shiny app.
#
# Displays a photograph, records the conversation about it, and writes each
# visit to disk. Everything it writes goes under work_dir; photo_root is never
# touched.
#
# Constraints this file works under:
#
#   * Every function called here must be exported from the package. runApp()
#     sources this file with only library(phostor) attached, so an internal
#     helper is not visible. test-app.R asserts it.
#   * The tree is rendered once per session; the selection highlight is moved
#     on the client (the ph_current handler) rather than by re-rendering.
#   * One global input per set of clickable elements, not one observeEvent()
#     per row: those accumulate and leak.
#   * Audio chunks are acknowledged one at a time. Shiny coalesces repeated
#     setInputValue() calls on the same input within a flush, so sending
#     without waiting for an acknowledgement loses whichever chunk is second.
#   * The server ignores an audio chunk whose visit key it does not recognise.
#     This is what makes the start/stop/discard races safe: chunks from a
#     superseded recorder are dropped.

library(shiny)
library(bslib)

if (!requireNamespace("phostor", quietly = TRUE)) {
  stop("phostor is not installed. Launch the app with phostor::ph_app().")
}
library(phostor)

# base R gained `%||%` in 4.4, and phostor's own copy is internal, so an app
# sourced with library(phostor) can see neither. Defined locally.
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
# Serves each visit's audio to the browser for the prior-visits panel and for
# playback. Loopback only.
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
.ph-hist { font-size:.85rem; max-height:38vh; overflow-y:auto; }
.ph-hist audio { height:30px; vertical-align:middle; width:100%; max-width:22rem; }
.ph-hist .v { border-top:1px solid var(--ph-line); padding:.4rem 0; }
.ph-hist .vh { color:var(--ph-dim); font-size:.78rem; display:flex;
  align-items:center; gap:.6rem; flex-wrap:wrap; }
.ph-hist .said { color:var(--ph-dim); font-size:.78rem; margin-top:.2rem; }
/* The transcript. Phrases are inline so they wrap as ordinary prose; the
   highlight moves between them as the recording plays. */
.ph-tx { margin:.3rem 0 .1rem; line-height:1.55; }
.ph-spk { cursor:pointer; font-size:.72rem; border-radius:9px; padding:0 .4rem;
  margin-right:.25rem; background:#3a4150; color:#cfd6e0; white-space:nowrap; }
.ph-spk:hover { background:var(--ph-on); color:#fff; }
.ph-spk.guess { background:transparent; color:var(--ph-dim);
  border:1px dashed var(--ph-line); }
.ph-ph { cursor:pointer; border-radius:3px; padding:0 .1rem;
  transition:background .12s; }
.ph-ph:hover { background:#242932; }
.ph-ph.on { background:var(--ph-on); color:#fff; }
.ph-tx.plain { color:var(--ph-ink); }
.ph-none { color:var(--ph-dim); font-style:italic; }

/* Presentation mode: photograph and recording indicator only. */
body.ph-present .bslib-sidebar-layout > .sidebar,
body.ph-present .ph-tags, body.ph-present .ph-hist-wrap,
body.ph-present .ph-hide { display:none !important; }
body.ph-present .ph-img-wrap { border-radius:0; }
body.ph-present { overflow:hidden; }
/* Hiding the sidebar leaves its grid column behind -- 340px of nothing down
   the left. bslib collapses to `0 minmax(0,1fr)` for its own closed state; the
   same is done here without its padding, which would inset the photograph. */
body.ph-present .bslib-sidebar-layout {
  grid-template-columns: 0 minmax(0, 1fr) !important; }
body.ph-present .bslib-sidebar-layout > .main { padding:0 !important; }
body.ph-present .bslib-sidebar-layout > .collapse-toggle {
  display:none !important; }

/* b: fold away what is under the photograph, keeping everything else. The
   caption stays, as it does in presentation mode -- a photograph on screen
   should always say what it is. .ph-img-wrap is flex:1 1 auto, so it takes
   the space without anything else having to change. */
body.ph-nobottom .ph-tags, body.ph-nobottom .ph-hist-wrap {
  display:none !important; }

/* How to leave presentation mode, said once on the way in and then faded.
   Long enough to read, gone before anyone is looking at the photograph. */
.ph-stopped { max-width:32rem; margin:18vh auto; text-align:center;
  color:var(--ph-dim); }
.ph-stopped h5 { color:var(--ph-ink); margin-bottom:.5rem; }
/* Shiny's own disconnect overlay would otherwise grey out the notice. */
body[data-ph-quit] #shiny-disconnected-overlay { display:none !important; }

.ph-hint { position:fixed; left:50%; bottom:4.5rem; transform:translateX(-50%);
  background:rgba(0,0,0,.72); color:var(--ph-ink); border:1px solid var(--ph-line);
  border-radius:999px; padding:.4rem 1rem; font-size:.85rem; z-index:1090;
  display:none; opacity:0; transition:opacity .5s; pointer-events:none; }
body.ph-present .ph-hint { display:block; }
body.ph-present .ph-hint.on { opacity:1; }
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

# The browser-side code: microphone, chunk queue, keyboard, playback clock.
# It uses jQuery only for shiny:connected, the documented hook for registering
# message handlers.
ph_js <- "
(function(){
  var PH = {
    stream:null, rec:null, key:null, mime:null,
    q:[], sending:false, seq:0, pending:{}, closing:{},
    order:[], current:null, chunkMs:5000,
    play:null, playIdx:0, audio:null, tagsFor:null, tagsWant:null,
    deviceId:null, sitting:false, checkOwnsStream:false, ac:null, meter:null,
    visitKey:'', ackedBy:{}, bytesBy:{}, stopped:{}, dropped:{},
    closeTimer:{}
  };
  window.PH = PH;

  function send(name, val){ Shiny.setInputValue(name, val, {priority:'event'}); }

  // ---- chunk queue -------------------------------------------------------
  // One chunk in flight at a time, each acknowledged by the server. Shiny
  // coalesces repeated writes to one input within a flush, so sending the
  // queue at once would drop all but the last.
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
  function acked(seq){
    var head = PH.q[0];
    // Ignore an acknowledgement that does not match the chunk in flight. The
    // retry below can put two copies of one chunk on the wire, and shifting
    // twice would discard the chunk behind it, which was never sent.
    //
    // Coerced rather than compared strictly: the number makes a round trip
    // through R and JSON, and a '7' or a [7] arriving here would reject every
    // acknowledgement and stall the queue for the rest of the sitting.
    var s = (seq == null) ? null : Number(seq);
    if (!head || (s !== null && head.seq !== s)) return;
    clearTimeout(PH.retry);
    PH.q.shift();
    bumpChunks(head.key);
    PH.sending = false;
    PH.pending[head.key] = (PH.pending[head.key] || 1) - 1;
    maybeDone(head.key);
    pump();
  }
  function queue(key, blob){
    var r = new FileReader();
    PH.pending[key] = (PH.pending[key] || 0) + 1;
    r.onloadend = function(){
      var s = String(r.result);
      PH.q.push({key:key, seq:++PH.seq, b64:s.slice(s.indexOf(',')+1)});
      pump();
    };
    r.readAsDataURL(blob);
  }
  // A visit is finished only once its recorder has stopped and every chunk it
  // produced has been acknowledged.
  //
  // MediaRecorder.stop() is asynchronous: the final dataavailable fires on a
  // later tick and onstop after it. Reporting the visit done before onstop
  // lets the server rename the .part file while its last chunk is still being
  // read, and that chunk then arrives with a key the server has forgotten.
  // stopped[key] is false only while a recorder for that key is running, so a
  // visit that never got one is treated as already stopped.
  function maybeDone(key){
    if (!PH.closing[key]) return;
    if (PH.stopped[key] === false) return;
    if ((PH.pending[key] || 0) > 0) return;
    delete PH.pending[key];
    delete PH.stopped[key];
    reportDone(key);
  }
  // The one place visit_done is sent, so the timer below is always cleared
  // with it. `bytes` is what MediaRecorder produced, which the server checks
  // against the file it wrote.
  function reportDone(key){
    delete PH.closing[key];
    clearTimeout(PH.closeTimer[key]);
    delete PH.closeTimer[key];
    send('visit_done', {key:key, at:Date.now(),
                        bytes:(PH.bytesBy[key] || 0)});
  }
  // Nothing else bounds that wait. A recorder that errors, or whose tracks the
  // system ends, may never fire onstop, and the visit would then stay open for
  // ever: the server never renames its .part, and End sitting never answers.
  // Report it once the wait is longer than any flush could take, and let the
  // byte comparison say what is missing. Chunks still queued are left where
  // they are -- the server appends a late arrival to the finished file.
  function armCloseTimer(key){
    clearTimeout(PH.closeTimer[key]);
    PH.closeTimer[key] = setTimeout(function(){
      if (PH.closing[key]) reportDone(key);
    }, Math.max(10000, 3 * PH.chunkMs));
  }

  // ---- DOM state hooks ---------------------------------------------------
  // Written to <body> so the browser tests can wait on state rather than
  // sleeping, and so the app's state is visible in the element inspector.
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
  // Two counters. phChunks is every chunk this page has had acknowledged;
  // phVisitChunks counts only those belonging to the visit currently open.
  // Only the second indicates whether the current photograph has recorded
  // anything: a chunk flushed by the previous recorder as it stopped would
  // otherwise be counted.
  function bumpChunks(key){
    var n = parseInt(document.body.dataset.phChunks || '0', 10) + 1;
    document.body.dataset.phChunks = n;
    if (key) PH.ackedBy[key] = (PH.ackedBy[key] || 0) + 1;
    showVisitChunks();
  }
  function showVisitChunks(){
    document.body.dataset.phVisitChunks =
      String((PH.visitKey && PH.ackedBy[PH.visitKey]) || 0);
    document.body.dataset.phVisitBytes =
      String((PH.visitKey && PH.bytesBy[PH.visitKey]) || 0);
  }
  function el(id){ return document.getElementById(id); }
  function setText(id, t){ var e = el(id); if (e) e.textContent = t; }

  // ---- recorder ----------------------------------------------------------
  // Order matters, and not for quality. AVFoundation -- which is what
  // transcription reads with -- opens MP4 and Ogg and cannot open WebM,
  // whatever codec is inside it. So the first three entries get a transcript
  // and the last two only get audio.
  //
  // AAC before plain 'audio/mp4' because Chrome answers the latter with Opus
  // in an MP4, which Firefox will not play back; both transcribe equally well.
  // Chunks concatenate for all five: each is a single MediaRecorder's output,
  // and MP4's init segment is followed by self-contained fragments.
  var PH_MIMES = ['audio/mp4;codecs=mp4a.40.2', 'audio/mp4',
                  'audio/ogg;codecs=opus',
                  'audio/webm;codecs=opus', 'audio/webm'];
  function pickMime(){
    if (typeof MediaRecorder === 'undefined') return null;
    for (var i=0;i<PH_MIMES.length;i++){
      if (MediaRecorder.isTypeSupported(PH_MIMES[i])) return PH_MIMES[i];
    }
    return null;
  }
  function mimeList(){
    if (typeof MediaRecorder === 'undefined') return [];
    return PH_MIMES.filter(function(m){ return MediaRecorder.isTypeSupported(m); });
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

  // Arming, with one automatic retry. On macOS the system permission grant
  // often lands just after the first getUserMedia() rejection: the prompt is
  // still on screen when the promise settles. Retried once, not in a loop.
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
  // Client-side except for the wording of the advice, which comes from
  // ph_mic_advice() in R so that it can be unit-tested.
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

    // getUserMedia() hands back a new MediaStream every time, and taking the
    // old one down ends the tracks the sitting's recorder is reading -- which
    // stops it with nothing on screen to say so. So while a sitting is in
    // progress the check meters the stream already open. Changing input needs
    // a pause: chunks from two recorders cannot be concatenated, so a new
    // stream has to start a new visit.
    var reuse = !!(PH.sitting && PH.stream && PH.stream.active !== false);
    var note = el('ph-mic-sitting');
    if (note) note.style.display = reuse ? 'block' : 'none';

    (reuse ? Promise.resolve(PH.stream) : openMic()).then(function(s){
      if (!reuse) {
        if (PH.stream && PH.stream !== s) stopStream(PH.stream);
        PH.stream = s;
        PH.checkOwnsStream = !PH.sitting;
      }
      setMic('on');
      meterStart(s);
      return listInputs().then(function(devs){
        fillDevices(devs, reuse);
        send('mic_check', Object.assign({ok: true, devices: devs,
                                         sitting: reuse}, env));
      });
    }).catch(function(err){
      setMic('error');
      send('mic_check', Object.assign(
        {ok: false, why: String((err && err.name) || err), devices: []}, env));
    });
  }

  function fillDevices(devs, lock){
    var sel = el('ph-mic-device');
    if (!sel) return;
    sel.innerHTML = '';
    devs.forEach(function(d){
      var o = document.createElement('option');
      o.value = d.id; o.textContent = d.label;
      if (PH.deviceId === d.id) o.selected = true;
      sel.appendChild(o);
    });
    // Locked while a sitting runs: switching input restarts the stream.
    sel.disabled = !!lock || devs.length < 2;
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
    // Release the microphone, and the browser's recording indicator, but only
    // if the check opened it. A session in progress keeps its stream.
    if (PH.checkOwnsStream && !PH.sitting) {
      stopStream(PH.stream); PH.stream = null; setMic('off');
    }
    PH.checkOwnsStream = false;
  }
  // The server has already opened a .part for this visit and still believes
  // the microphone is armed, so a recorder that fails to start must say so:
  // otherwise the bar reads REC over a file nothing is written to. mic_ready
  // is the channel the indicator and the advice line already watch.
  function noRecorder(why){
    setMic('error');
    send('mic_ready', {ok:false, why:why || 'norecorder'});
  }
  function startRec(key){
    if (!PH.mime) { noRecorder('nocodec'); return; }
    // `active` is false once every track has ended, which is what an unplugged
    // interface or a revoked permission leaves behind.
    if (!PH.stream || PH.stream.active === false) { noRecorder(); return; }
    stopRec();
    try {
      PH.rec = new MediaRecorder(PH.stream, {mimeType: PH.mime});
    } catch (e) { PH.rec = null; noRecorder(); return; }
    PH.key = key;
    PH.stopped[key] = false;
    PH.rec.onerror = function(){
      // Gave up mid-visit. Its tail is lost either way; saying so is what
      // stops the rest of the sitting being recorded into nothing.
      PH.stopped[key] = true;
      maybeDone(key);
      noRecorder();
    };
    PH.rec.ondataavailable = function(e){
      if (!e.data || e.data.size <= 0) return;
      if (PH.dropped[key]) return;          // a discarded take keeps nothing
      // What the microphone produced, against which what reached disk is
      // checked when the visit closes.
      PH.bytesBy[key] = (PH.bytesBy[key] || 0) + e.data.size;
      showVisitChunks();
      queue(key, e.data);
    };
    PH.rec.onstop = function(){
      PH.stopped[key] = true;
      maybeDone(key);
    };
    // Chunks from a single recorder concatenate into a valid WebM, so the
    // server can append them to disk with no muxing step.
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
  // server would not keep image and sound in step.
  function playAt(i){
    if (!PH.play || i >= PH.play.length) { playStop(true); return; }
    PH.playIdx = i;
    var it = PH.play[i];
    showPhoto(it);
    // The client keeps the clock -- a round trip per step would not hold image
    // and sound together -- but the server has to hear where the playback is,
    // or the panel and the tag fields stay on the photograph Play started from.
    send('play_at', {id: it.id, visit: it.visit});
    // Two visits to one photograph in a row leave the panel unrendered between
    // them, so last visit's highlight would sit there through this one.
    clearPhrases();
    var strip = document.getElementById('ph-play-fill');
    if (strip) strip.style.width = ((i+1)/PH.play.length*100) + '%';
    if (PH.audio) { PH.audio.pause(); PH.audio = null; }
    clearTimeout(PH.playTimer);
    if (it.audio) {
      PH.audio = new Audio(it.audio);
      // Detached from the document, so the delegated listener never sees it.
      // The panel it highlights into arrives a round trip later; until then
      // there is nothing to find and this does nothing.
      PH.audio.ontimeupdate = function(){
        // Only once the panel is this photograph's. Until the server has been
        // told where the playback is and sent the panel back, it still holds
        // the previous photograph -- whose visit 1 would otherwise be lit up
        // by this photograph's visit 1.
        var panel = document.querySelector('.ph-hist');
        if (!panel || panel.dataset.photo !== String(it.id)) return;
        var tx = el('ph-tx-' + it.visit);
        if (tx) markPhrase(tx.querySelectorAll('.ph-ph'), PH.audio.currentTime);
      };
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
    clearPhrases();
    PH.play = null;
    send('play_ended', {at:Date.now(), finished:!!finished});
  }

  // ---- presentation ------------------------------------------------------
  // The client is the only place this is held. The Presentation button asks
  // for a toggle rather than setting a value: with the state in two places,
  // entering by the button and leaving by the key left them disagreeing, and
  // the button then did nothing until it was clicked twice.
  function inPresent(){ return document.body.classList.contains('ph-present'); }
  // Presentation and full screen are one mode. requestFullscreen() takes the
  // whole display -- browser chrome, tabs, menu bar and Dock -- and needs a
  // user gesture, which is why the Presentation button is wired here on the
  // client rather than going through the server and coming back.
  //
  // If the browser refuses, presentation still happens, just in a window: the
  // rejection is caught rather than allowed to stop the mode from opening.
  function setPresent(on){
    document.body.classList.toggle('ph-present', !!on);
    if (on) {
      showPresentHint();
      var d = document.documentElement;
      if (d.requestFullscreen && !document.fullscreenElement) {
        var p = d.requestFullscreen();
        if (p && p.catch) p.catch(function(){});
      }
    } else if (document.fullscreenElement && document.exitFullscreen) {
      var q = document.exitFullscreen();
      if (q && q.catch) q.catch(function(){});
    }
  }
  // Escape, and the browser's own full-screen control, leave full screen
  // without telling the page. Presentation follows it out, so one Escape
  // leaves the whole mode rather than stranding half of it.
  document.addEventListener('fullscreenchange', function(){
    if (!document.fullscreenElement && inPresent()) setPresent(false);
  });
  function showPresentHint(){
    var h = el('ph-present-hint');
    if (!h) return;
    h.classList.add('on');
    clearTimeout(PH.hintTimer);
    PH.hintTimer = setTimeout(function(){ h.classList.remove('on'); }, 2500);
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
      // Open collapsed ancestors, so a photograph reached by keyboard or by
      // playback is visible in the tree.
      var p = el.parentElement;
      while (p) { if (p.tagName === 'DETAILS') p.open = true; p = p.parentElement; }
    }
  }

  // ---- tag fields --------------------------------------------------------
  function tagValues(){
    var sel = el('people');
    var people = (sel && sel.selectize) ? sel.selectize.getValue() : [];
    if (typeof people === 'string') people = people ? people.split(',') : [];
    var val = function(id){ var e = el(id); return e ? e.value : ''; };
    return {people: people, place: val('place'), event: val('event'),
            when: val('when')};
  }
  // Which photograph the fields are showing. Set only once they demonstrably
  // hold that photograph's text: the server sends the values it seeded, and
  // this compares them against the fields. Nothing about the order or timing
  // of the messages is assumed -- the custom message carrying the stamp and
  // the input messages carrying the text do not even arrive together.
  function tagsMatch(want){
    var v = tagValues();
    if (v.place !== want.place || v.event !== want.event ||
        v.when !== want.when) return false;
    var w = want.people || [];
    if (v.people.length !== w.length) return false;
    for (var i = 0; i < w.length; i++) {
      if (v.people[i] !== w[i]) return false;
    }
    return true;
  }
  function checkSeeded(){
    if (PH.tagsWant && tagsMatch(PH.tagsWant)) {
      PH.tagsFor = PH.tagsWant.rel;
      PH.tagsWant = null;
    }
  }
  // Only ever sent from a real user event, and only once the fields are known
  // to belong to a photograph. Filling them from the server fires the same
  // events field by field, and a report made partway through would pair one
  // photograph's stamp with another's half-replaced text.
  function reportTags(){
    if (!PH.tagsFor) return;
    var v = tagValues();
    v.rel = PH.tagsFor;
    send('tags_now', v);
  }
  // Delegated: the fields are re-rendered, and selectize replaces its own
  // element, so handlers bound to them would not survive.
  document.addEventListener('input', function(e){
    var id = e.target && e.target.id;
    if (id === 'place' || id === 'event' || id === 'when') reportTags();
  });
  // people is a selectize, which announces itself with jQuery's trigger();
  // a native listener does not reliably see that. Registered on connect,
  // where jQuery is certainly loaded.
  $(document).on('shiny:connected', function(){
    $(document).on('change', '#people', reportTags);
  });

  // ---- transcript follow-along -------------------------------------------
  // Two delegated listeners for every visit on screen, rather than a pair per
  // <audio>: the panel is re-rendered whenever the photograph changes, and
  // handlers bound to its elements would be rebound with it.
  //
  // Media events do not bubble, so timeupdate is caught in the capture phase.
  // That is what makes one document-level listener see all of them.
  function phrasesFor(audio){
    if (!audio || !audio.id || audio.id.indexOf('ph-a-') !== 0) return null;
    var tx = document.getElementById('ph-tx-' + audio.id.slice(5));
    return tx ? tx.querySelectorAll('.ph-ph') : null;
  }
  function clearMarks(spans){
    for (var i=0;i<spans.length;i++) spans[i].classList.remove('on');
  }
  // Move the highlight to whichever phrase holds t. Shared with playback,
  // whose audio is detached from the document and so never reaches the
  // delegated listener below.
  function markPhrase(spans, t){
    if (!spans || !spans.length) return;
    for (var i=0;i<spans.length;i++){
      var s = spans[i];
      // Up to the next phrase's start rather than this one's end, so the
      // highlight does not blink off in the pause between two phrases.
      var next = spans[i+1];
      var to = next ? parseFloat(next.dataset.t0) : parseFloat(s.dataset.t1);
      var on = t >= parseFloat(s.dataset.t0) && t < to;
      if (on === s.classList.contains('on')) continue;
      s.classList.toggle('on', on);
      if (on) s.scrollIntoView({block:'nearest'});
    }
  }
  function clearPhrases(){
    document.querySelectorAll('.ph-ph.on').forEach(function(e){
      e.classList.remove('on');
    });
  }
  document.addEventListener('timeupdate', function(e){
    markPhrase(phrasesFor(e.target), e.target.currentTime);
  }, true);
  document.addEventListener('ended', function(e){
    var spans = phrasesFor(e.target);
    if (spans) clearMarks(spans);
  }, true);

  // Clicking a speaker chip asks who it was. One delegated handler and one
  // input, rather than a control per phrase: a sitting can hold hundreds.
  document.addEventListener('click', function(e){
    var c = e.target.closest ? e.target.closest('.ph-spk') : null;
    if (!c) return;
    var tx = c.closest('.ph-tx');
    if (!tx) return;
    e.stopPropagation();
    send('speaker_pick', {rel: tx.dataset.rel, visit: Number(tx.dataset.visit),
                          start: Number(c.dataset.t0)});
  });

  // Clicking a phrase plays from where it was said.
  document.addEventListener('click', function(e){
    var s = e.target.closest ? e.target.closest('.ph-ph') : null;
    if (!s || !s.dataset.t0) return;
    var tx = s.closest('.ph-tx');
    if (!tx || !tx.id) return;
    var a = document.getElementById('ph-a-' + tx.id.slice(6));
    if (!a) return;
    a.currentTime = parseFloat(s.dataset.t0);
    a.play().catch(function(){});
  });

  // ---- keyboard ----------------------------------------------------------
  var PH_STEP = {ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1};
  document.addEventListener('keydown', function(e){
    var t = e.target;
    if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' ||
              t.isContentEditable)) return;
    // Up and down do what left and right do. In presentation there is no tree
    // to click, so it matters which key the hand reaches for, not which
    // direction the collection is drawn in.
    if (e.key in PH_STEP) {
      if (!PH.order.length) return;
      var i = PH.order.indexOf(PH.current);
      var n = i < 0 ? 0 : i + PH_STEP[e.key];
      if (n < 0 || n >= PH.order.length) return;
      e.preventDefault();
      send('photo_pick', PH.order[n]);
    } else if (e.key === 's') {
      setPresent(!inPresent());
    } else if (e.key === 'b') {
      document.body.classList.toggle('ph-nobottom');
    } else if (e.key === 'Escape') {
      // Leaves, never enters. In full screen the browser takes Escape for
      // itself and fullscreenchange brings presentation out; this is the path
      // when full screen was refused and the mode is running in a window.
      if (inPresent()) { e.preventDefault(); setPresent(false); }
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

    // What this browser supports, reported once on connect, so a browser
    // that cannot record is identified before Start session is pressed.
    send('browser_env', {secure: !!window.isSecureContext,
                         hasMedia: haveMedia(), mimes: mimeList(),
                         mime: pickMime(), ua: navigator.userAgent});

    // The microphone is armed on a click, never on page load, so the
    // browser's permission prompt appears in response to a user action.
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
    // Buttons inside the check panel are plain HTML, not Shiny inputs, so the
    // panel works while the server is busy.
    var wire = function(id, fn){ var b = el(id); if (b) b.onclick = fn; };
    wire('present', function(){ setPresent(!inPresent()); });
    wire('ph-mic-run', runCheck);
    wire('ph-mic-test', testRecord);
    wire('ph-mic-close', closeCheck);
    var dev = el('ph-mic-device');
    if (dev) dev.onchange = function(){
      if (PH.sitting) return;           // locked mid-sitting; see runCheck()
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
      armCloseTimer(m.key);
      maybeDone(m.key);
    });
    Shiny.addCustomMessageHandler('ph_visit_drop', function(m){
      // Throw away everything queued for this visit, then stop. The server
      // deletes the .part file and opens a fresh visit with a new key, so any
      // chunk still in flight lands on a key the server no longer knows.
      PH.dropped[m.key] = true;
      PH.q = PH.q.filter(function(c){ return c.key !== m.key; });
      PH.pending[m.key] = 0;
      delete PH.closing[m.key];
      delete PH.stopped[m.key];
      delete PH.bytesBy[m.key];
      clearTimeout(PH.closeTimer[m.key]);
      delete PH.closeTimer[m.key];
      if (PH.rec && PH.key === m.key) stopRec();
      send('drop_done', {key:m.key, at:Date.now()});
    });
    Shiny.addCustomMessageHandler('ph_chunk_ok', function(m){
      acked(m && m.seq);
    });
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
    // The tag fields are filled by the server, which takes a round trip, and
    // Shiny debounces text inputs on the way back. So input$place can still
    // hold the previous photograph's text when a move to the next one
    // arrives, and saving it there would write one photograph's tags onto
    // another -- reachable just by holding an arrow key down.
    //
    // The client reports the fields itself instead: what they hold, and which
    // photograph they hold it for, in one value that cannot be half stale.
    // What the server has just put into the fields, and for which photograph.
    // Until they actually hold it, the fields belong to no photograph and
    // nothing about them is reported.
    Shiny.addCustomMessageHandler('ph_tags_seeded', function(m){
      PH.tagsWant = m;
      PH.tagsFor = null;
      checkSeeded();
    });
    // Fired as each update reaches its input; the value lands just after, so
    // the check is deferred past it.
    $(document).on('shiny:updateinput', function(){
      setTimeout(checkSeeded, 0);
    });
    Shiny.addCustomMessageHandler('ph_quit', function(m){
      // Says what happened, rather than leaving Shiny's disconnect grey to
      // imply something went wrong. data-ph-quit is what the tests wait on.
      document.body.dataset.phQuit = '1';
      document.body.innerHTML =
        '<div class=\"ph-stopped\"><h5>phostor has stopped</h5>' +
        '<p>Everything recorded is on disk. You can close this tab.</p></div>';
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
        # Plain HTML, not an actionButton: full screen has to be asked for
        # inside the click that wants it, and a Shiny round trip is not that.
        # The microphone panel's buttons are client-wired for the same kind of
        # reason. See setPresent().
        tags$button(id = "present", type = "button",
                    class = "btn btn-sm btn-outline-secondary w-100",
                    "Presentation"),
        actionButton("quit", "Quit", class = "btn-sm btn-outline-danger")),
    uiOutput("tree"),
    div(class = "mt-2 pt-2 border-top small text-secondary",
        # Non-breaking, so the narrow sidebar wraps at a separator rather
        # than in the middle of "full screen".
        HTML(paste("&larr;&nbsp;&rarr;&nbsp;&uarr;&nbsp;&darr; move &middot;",
                   "<b>s</b>&nbsp;presentation &middot; <b>b</b>&nbsp;bottom",
                   "<br><b>Esc</b> leaves presentation")))
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
    # Static, hidden, and driven by the JavaScript above. Not a Shiny modal:
    # the check must work while the server is busy, and must not depend on
    # render timing to find its own elements.
    div(
      id = "ph-mic-panel", class = "ph-mic",
      tags$h6("Microphone check"),
      div(class = "row2",
          tags$select(id = "ph-mic-device"),
          tags$button(id = "ph-mic-run", class = "btn btn-sm btn-outline-light",
                      "Check")),
      div(class = "ph-level", tags$i(id = "ph-level-fill")),
      div(class = "hint", "Speak: the level bar should move."),
      div(class = "hint", id = "ph-mic-sitting", style = "display:none",
          paste("A sitting is in progress, so this check listens to the",
                "microphone already open. Pause the sitting to change input.")),
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
    uiOutput("integrity_warn"),
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
    div(class = "ph-hist-wrap ph-hide", uiOutput("history")),
    # Not .ph-hide: that is the class presentation mode hides, and this is the
    # one thing that has to be visible inside it.
    div(id = "ph-present-hint", class = "ph-hint",
        HTML("<b>s</b> or <b>Esc</b> to leave"))
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
    pausing = FALSE,         # Pause pressed, waiting for the visit to drain
    closed = list(),         # finalized visit key -> its final audio path
    closedvisit = list(),    # finalized visit key -> photo, number, audio name
    ext = NULL,              # container the browser records in
    dropped = list(),        # discarded visit key -> TRUE
    lastseq = list(),        # visit key -> highest chunk seq already written
    expected = list(),       # visit key -> bytes the browser said it recorded
    warnings = list(),       # visit key -> audio that did not arrive intact
    env = NULL,              # what the browser told us it can do
    browser = NA_character_, # its name, from the user agent
    visit = NULL,            # the open visit
    pending = list(),        # visits waiting for their last audio chunks
    seq = 0L,
    reserved = list(),       # rel_path -> highest visit number handed out
    ending = FALSE,          # End sitting pressed, waiting for visits to drain
    tick = 0L,
    quitting = FALSE,        # Quit pressed, waiting for visits to drain
    speaker_at = NULL,       # the phrase whose speaker is being named
    told_tuneR = FALSE,      # the missing-package notice, said once
    tags_for = NULL,         # photograph the tag fields currently hold
    tags_seeded = NULL,      # what was put in them, to tell an edit from that
    playing = FALSE
  )

  # Every message to the client goes through here. finalize_visit() also runs
  # from onSessionEnded(), when the websocket is gone and sendCustomMessage()
  # would raise inside a handler that cannot catch it.
  tell <- function(type, msg) {
    tryCatch(session$sendCustomMessage(type, msg), error = function(e) NULL)
  }

  # A render is named after its photograph and its size, and carries that
  # photograph's timestamp. The mtime rides along as ?v= so that replacing a
  # photograph in place changes the URL: without it the browser is handed a
  # Last-Modified from the original scan, which may be years old, and given no
  # Cache-Control it would treat the old copy as fresh for a very long time.
  render_url <- function(rel_path, kind) {
    rel <- ph_render_rel(cfg, rel_path, kind)
    abs <- file.path(if (identical(kind, "display")) cfg$display_dir
                     else cfg$thumb_dir, rel)
    v <- suppressWarnings(as.numeric(file.mtime(abs)))
    paste0(kind_prefix(kind), "/", ph_url_path(rel),
           if (is.na(v)) "" else paste0("?v=", format(round(v), scientific = FALSE)))
  }
  kind_prefix <- function(kind) if (identical(kind, "display")) "display" else "thumbs"

  row_of <- function(id) {
    if (is.null(id)) return(NULL)
    i <- match(as.integer(id), as.integer(rv$idx$id))
    if (is.na(i)) NULL else rv$idx[i, , drop = FALSE]
  }

  # ---- the tree: rendered once ------------------------------------------
  # Does not read rv$current: the highlight is moved on the client. rv$tick is
  # here so a new visit can repaint the badges, though that is normally done
  # client-side by ph_badge.
  output$tree <- renderUI({
    counts <- ph_visit_counts(cfg, rv$idx$rel_path)
    thumbs <- vapply(rv$idx$rel_path, render_url, character(1), "thumb",
                     USE.NAMES = FALSE)
    HTML(ph_tree_html(rv$idx, counts = counts, thumbs = thumbs))
  })

  # onFlushed() runs outside a reactive context, where reading rv$... raises
  # "Can't access reactive value outside of reactive consumer", so isolate().
  # The work has to happen here: before the tree exists there is no element
  # for the initial highlight to land on.
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

  # notify = FALSE when the client is already showing this photograph and only
  # the server has to catch up -- playback, which draws its own slideshow.
  # Re-sending the image there would fight the picture it has just put up.
  show_photo <- function(id, notify = TRUE) {
    r <- row_of(id)
    if (is.null(r)) return(invisible(NULL))
    rv$current <- as.integer(id)
    if (isTRUE(notify)) {
      tell("ph_show", list(
        id = as.integer(id),
        src = render_url(r$rel_path, "display"),
        caption = caption_html(r)))
    }
    seed_fields(r$rel_path)
    invisible(NULL)
  }

  # The fields show what is known about the photograph on screen, with or
  # without a sitting. rv$tags_for and rv$tags_seeded record which photograph
  # they belong to and what was put in them, so save_tags() can tell an edit
  # from the seeding itself and write only when something actually changed.
  seed_fields <- function(rel_path) {
    t <- ph_tags(cfg, rel_path)
    known <- ph_known_people(cfg)
    rv$tags_for <- rel_path
    rv$tags_seeded <- t
    updateSelectizeInput(session, "people",
                         choices = sort(unique(c(known, t$people))),
                         selected = t$people, server = FALSE)
    updateTextInput(session, "place", value = t$place)
    updateTextInput(session, "event", value = t$event)
    updateTextInput(session, "when", value = t$when)
    # The values as well as the photograph: the client watches for the fields
    # to actually hold these before it will report anything about them, which
    # is what stops one photograph's tags reaching another. See save_tags().
    tell("ph_tags_seeded", list(rel = rel_path, people = as.list(t$people),
                                place = t$place, event = t$event,
                                when = t$when))
  }

  # Read the fields and write them to the photograph they belong to. Called
  # while that photograph is still the one on screen -- before show_photo()
  # reseeds -- so the values are read synchronously and cannot be confused with
  # the next photograph's.
  # updateTextInput() round-trips through the browser, so for a moment after a
  # photograph is shown the fields still hold the previous one's text. This
  # says the browser has confirmed the seeding. Without it, paging quickly away
  # from a tagged photograph writes its tags onto the next one.
  save_tags <- function() {
    rel <- rv$tags_for
    if (is.null(rel)) return(invisible(NULL))
    # What the client says its fields hold, and which photograph they hold it
    # for. Read from `input$place` instead, this would write one photograph's
    # tags onto another: Shiny debounces text inputs, so the server's copy can
    # still be the previous photograph's when the move arrives. See the note
    # by ph_tags_seeded above.
    now <- input$tags_now
    if (is.null(now) || !identical(as.character(now$rel %||% ""), rel)) {
      return(invisible(NULL))
    }
    t <- ph_tags_clean(now)
    if (identical(t, rv$tags_seeded)) return(invisible(NULL))
    ph_write_tags(cfg, rel, t)
    rv$tags_seeded <- t
    rv$tick <- rv$tick + 1L
    invisible(NULL)
  }

  observeEvent(input$photo_pick, {
    id <- as.integer(input$photo_pick)
    if (isTRUE(rv$playing)) stop_play(finished = FALSE)
    if (identical(id, rv$current)) return()
    save_tags()
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
      title = "Recording started",
      p("The microphone is on. Conversation about each photograph is being ",
        "recorded, and will continue until you end the sitting."),
      p(class = "text-secondary",
        "Files are written to this computer, under the work directory. ",
        "Nothing is uploaded."),
      footer = modalButton("Begin"), easyClose = FALSE))
  })

  # What the browser supports, reported once on connect, so a browser that
  # cannot record is identified before a session starts.
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

  output$integrity_warn <- renderUI({
    w <- unlist(rv$warnings, use.names = FALSE)
    if (!length(w)) return(NULL)
    div(class = "ph-warn ph-warn-integrity", lapply(w, function(x) div(x)))
  })

  observeEvent(input$mic_check_btn, tell("ph_check", list(on = TRUE)))
  observeEvent(input$mic_retry, {
    rv$paused <- FALSE
    rv$mic_msg <- "asking for the microphone again..."
    tell("ph_arm", list(on = TRUE))
  })

  # The check panel is client-side; only the wording comes from here, where the
  # test suite can reach it.
  observeEvent(input$mic_check, {
    m <- input$mic_check
    rv$browser <- ph_browser_name(m$ua %||% "")
    devs <- m$devices %||% list()
    advice <- if (isTRUE(m$ok)) {
      sprintf("Microphone open in %s. %s",
              rv$browser %||% "this browser",
              if (length(devs) > 1)
                "Speak and check the level bar moves. Select a different input above if it does not."
              else "Speak and check the level bar moves.")
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
    # The recorder picks its own container from what the browser supports; the
    # extension has to follow it or the file is misnamed and unreadable.
    if (ok) rv$ext <- ph_audio_ext(input$mic_ready$mime)
    rv$mic_msg <- if (ok) NULL else {
      ph_mic_advice(as.character(input$mic_ready$why %||% ""), rv$browser)
    }
    # The session may already have opened a visit while the permission prompt
    # was on screen. That visit has no recorder attached, so close and reopen
    # it now that a microphone is available; otherwise the first photograph
    # records nothing.
    if (isTRUE(rv$armed) && !is.null(rv$visit) && is.null(rv$visit$part)) {
      close_visit()
    }
    open_visit()
  })

  observeEvent(input$stop_sitting, {
    rv$ending <- TRUE
    # A natural checkpoint: the photograph stays on screen, so nothing forces
    # its tags to disk until the next navigation without this.
    save_tags()
    close_visit()
    finish_sitting()
  })

  # An audio visit finalizes only once the browser has flushed its last chunk,
  # so the session cannot be closed the moment the button is pressed: its final
  # `leave` row would land after `end`. Wait for the queue to drain.
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
    if (!is.null(d) && !isTRUE(rv$quitting)) {
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
    # Pausing closes the visit rather than leaving a gap in its audio: chunks
    # from two different recorders cannot be concatenated, and a stop and
    # restart is what a second visit already represents.
    rv$pausing <- TRUE
    close_visit()
    finish_pause()
  })

  # ph_disarm stops the microphone tracks, which would cut off a recorder that
  # is still flushing its last chunk. Wait for the visit to drain first, the
  # way finish_sitting() does.
  finish_pause <- function() {
    if (!isTRUE(rv$pausing) || length(rv$pending)) return(invisible(NULL))
    tell("ph_disarm", list(on = FALSE))
    rv$armed <- FALSE
    rv$paused <- TRUE
    rv$pausing <- FALSE
    rv$mic_msg <- NULL
    if (!is.null(rv$session_dir)) ph_path_append(rv$session_dir, "pause")
    invisible(NULL)
  }

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
    # Two numbering guards; neither is sufficient alone. On disk,
    # ph_next_visit() sees the .part and .yml files of earlier visits,
    # including from previous sessions. In memory, `reserved` covers a visit
    # whose sidecar is not yet written: leaving a photograph and returning
    # would otherwise compute the same number twice.
    held <- as.integer(rv$reserved[[r$rel_path]] %||% 0L)
    n <- max(ph_next_visit(cfg, r$rel_path), held + 1L)
    rv$reserved[[r$rel_path]] <- n
    part <- if (isTRUE(rv$armed)) {
      ph_audio_open(cfg, r$rel_path, n, ext = rv$ext %||% "webm")
    } else NULL
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
    # The `leave` row is written here, while this photograph is the one being
    # left, so path.tsv reads in view order. Written at finalize_visit() time
    # instead -- which an audio visit reaches only after the browser flushes
    # its last chunk -- the next photograph's `show` would already precede
    # it.
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
    finalize_visit(as.character(input$visit_done$key),
                   bytes = input$visit_done$bytes)
  })

  finalize_visit <- function(key, bytes = NA) {
    v <- rv$pending[[key]]
    if (is.null(v)) return(invisible(NULL))
    rv$pending[[key]] <- NULL
    audio <- if (!is.null(v$part)) ph_audio_close(v$part) else NA_character_
    final <- if (!is.na(audio)) {
      file.path(ph_visit_dir(cfg, v$rel_path), audio)
    } else NULL
    # Remember where this visit's audio ended up, so a chunk still in flight
    # is appended rather than dropped.
    if (!is.null(final)) {
      rv$closed[[key]] <- final
      rv$closedvisit[[key]] <- list(rel_path = v$rel_path, visit = v$visit,
                                    audio = audio)
    }

    # What the browser said it recorded, against what reached the file. A
    # sitting cannot be repeated, so a shortfall is worth saying out loud.
    expected <- suppressWarnings(as.numeric(bytes %||% NA)[1])
    stored <- if (!is.null(final) && file.exists(final)) file.size(final) else 0
    if (!is.na(expected) && expected > 0) rv$expected[[key]] <- expected
    if (!is.na(expected) && expected > 0 && stored < expected) {
      rv$warnings[[key]] <- sprintf(
        "visit %d of %s: %.0f kB recorded, %.0f kB stored - audio may be incomplete",
        v$visit, v$rel_path, expected / 1024, stored / 1024)
    }
    dur <- v$duration %||% as.numeric(difftime(v$ended %||% Sys.time(),
                                               v$started, units = "secs"))
    # A visit shorter than min_visit_seconds with no audio leaves a path row
    # and nothing else, so paging through photographs does not write a record
    # for each one. What was typed is not part of this test any more: it
    # belongs to the photograph and was written to its tags.yml.
    keep <- !is.na(audio) || dur >= cfg$min_visit_seconds
    if (keep) {
      ph_write_sidecar(cfg, v$rel_path, v$visit, list(
        session = basename(v$session_dir %||% ""),
        started = format(as.POSIXct(v$started), "%Y-%m-%dT%H:%M:%SZ",
                         tz = "UTC"),
        ended = format(as.POSIXct(v$ended %||% Sys.time()),
                       "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
        duration = dur,
        audio = audio,
        bytes_expected = if (is.na(expected)) NA else expected))
    }
    if (keep) {
      tell("ph_badge", list(id = v$id,
                            n = ph_visit_counts(cfg, v$rel_path)))
    }
    # The recording is complete and renamed, so the photograph just left can be
    # transcribed while the next one is on screen. Started in the background:
    # waiting here would freeze the app mid-sitting.
    if (!is.na(audio)) ph_transcribe_visit(cfg, v$rel_path, v$visit, audio = audio)

    rv$tick <- rv$tick + 1L
    finish_pause()
    finish_sitting()
    finish_quit()
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
    rv$dropped[[key]] <- TRUE
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
    seq <- suppressWarnings(as.integer(ch$seq %||% NA))

    # A chunk resent by the client's retry must not be written twice. Sequence
    # numbers are monotonic per page, so anything at or below what this visit
    # has already stored is a repeat.
    last <- rv$lastseq[[key]] %||% -1L
    if (!is.na(seq) && seq <= last) {
      tell("ph_chunk_ok", list(seq = ch$seq))
      return()
    }

    # Three kinds of key, in order. An open visit takes the chunk in its .part
    # file. A visit that has already been finalized takes it appended to the
    # renamed file -- WebM chunks concatenate, so the file stays valid, and a
    # chunk that arrives a moment late is kept rather than lost. A discarded
    # visit takes nothing.
    target <- if (isTRUE(rv$dropped[[key]])) NULL
              else if (!is.null(rv$pending[[key]])) rv$pending[[key]]$part
              else rv$closed[[key]]
    if (!is.null(target)) {
      # The write can fail outright -- a removable drive unmounted, a
      # permission changed mid-sitting. Raising here would skip the
      # acknowledgement below, and the client would then retry this chunk for
      # ever: the visit would never finalize and End sitting would never
      # answer. Report it on screen and carry on.
      # Warnings are muffled with it: a connection that cannot be opened warns
      # and then raises, carrying the same text twice, and the message below is
      # where the user reads it.
      err <- tryCatch({ suppressWarnings(ph_audio_append(target, ch$b64)); NULL },
                      error = function(e) conditionMessage(e))
      if (is.null(err)) {
        if (!is.na(seq)) rv$lastseq[[key]] <- seq
        # A chunk appended after the visit closed may complete a file that was
        # reported short, so the warning it raised no longer holds.
        exp <- rv$expected[[key]]
        if (!is.null(exp) && file.exists(target) && file.size(target) >= exp) {
          rv$warnings[[key]] <- NULL
        }
        # The audio just got longer than whatever was transcribed from it.
        cv <- rv$closedvisit[[key]]
        if (!is.null(cv)) {
          ph_transcribe_visit(cfg, cv$rel_path, cv$visit, audio = cv$audio,
                              force = TRUE)
        }
      } else {
        rv$warnings[[key]] <- sprintf("%s could not be written: %s",
                                      basename(target), err)
      }
    }
    # Acknowledge whatever happened, or the client's queue stalls behind it.
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
      # Three states, not two: a paused session resumes, while a session whose
      # microphone never opened needs to retry. Presenting both as "Resume"
      # gave no indication that a failed microphone could be retried.
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

  # ---- who spoke -----------------------------------------------------------
  # Names offered are the ones already used in this photograph's sitting, plus
  # everyone tagged anywhere in the project: the people in a photograph and the
  # people discussing it overlap heavily in a family without being the same set.
  speaker_names <- function(rel_path, visit) {
    used <- ph_speakers_names(cfg, ph_visit_session(cfg, rel_path, visit))
    sort(unique(c(used, ph_known_people(cfg))))
  }

  observeEvent(input$speaker_pick, {
    pick <- input$speaker_pick
    rv$speaker_at <- pick
    now <- ph_speakers_read(cfg, pick$rel, as.integer(pick$visit))
    i <- which(abs(now$start - as.numeric(pick$start)) < 0.01)
    showModal(modalDialog(
      title = "Who said this?",
      selectizeInput("speaker_name", NULL,
                     choices = speaker_names(pick$rel, as.integer(pick$visit)),
                     selected = if (length(i)) now$speaker[i[1]] else "",
                     options = list(create = TRUE, persist = FALSE,
                                    placeholder = "a name, or type a new one")),
      div(class = "small text-secondary",
          if (requireNamespace("tuneR", quietly = TRUE)) {
            "Naming a phrase yourself is what the rest are worked out from."
          } else {
            HTML(paste("Names are saved, but spreading them needs the tuneR",
                       "package: <code>install.packages(\"tuneR\")</code>."))
          }),
      footer = tagList(
        modalButton("Cancel"),
        actionButton("speaker_clear", "No name",
                     class = "btn-sm btn-outline-secondary"),
        actionButton("speaker_save", "Save", class = "btn-sm btn-primary"))))
  })

  save_speaker <- function(name) {
    at <- rv$speaker_at
    if (is.null(at)) return(invisible(NULL))
    removeModal()
    ph_speaker_label(cfg, at$rel, as.integer(at$visit),
                     start = as.numeric(at$start), speaker = name)
    rv$speaker_at <- NULL
    spread_speakers(at$rel, as.integer(at$visit))
    rv$tick <- rv$tick + 1L
    invisible(NULL)
  }

  # Naming one phrase re-works the whole sitting, so the names appear on the
  # other photographs while you are still labelling. Recordings are decoded
  # once per session and kept, so this costs about a second the first time and
  # very little afterwards.
  #
  # Silent when it cannot help: tuneR is only suggested, and most machines will
  # not have it. Clicking a chip must save the label and never raise.
  spread_speakers <- function(rel_path, visit) {
    # Never raising and saying nothing are different things, and this used to
    # do the second: the label saved, nothing spread, and there was no way to
    # find out why. Said once a session rather than on every chip.
    if (!requireNamespace("tuneR", quietly = TRUE)) {
      if (!isTRUE(rv$told_tuneR)) {
        rv$told_tuneR <- TRUE
        showNotification(
          HTML(paste("Names are saved, but spreading them to the other",
                     "photographs needs the tuneR package.<br>",
                     "<code>install.packages(\"tuneR\")</code>, then start",
                     "phostor again.")),
          type = "warning", duration = 12)
      }
      return(invisible(NULL))
    }
    # A visit outside any sitting: nothing useful to say about it.
    sess <- ph_visit_session(cfg, rel_path, visit)
    if (is.null(sess)) return(invisible(NULL))
    res <- tryCatch({
      out <- ph_speakers_apply(cfg, sess, quiet = TRUE)
      list(named = if (is.null(out)) 0L else nrow(out),
           chk = ph_speakers_check(cfg, sess, quiet = TRUE))
    }, error = function(e) NULL)
    # The state right after the very first name: one voice is nothing to choose
    # between, and silence here reads as failure too.
    if (is.null(res) || is.null(res$chk)) {
      showNotification(
        "Saved. Name a phrase for a second voice and the rest will follow.",
        duration = 8)
      return(invisible(NULL))
    }
    # Until every voice has two examples, leaving one out leaves nothing to
    # recognise it by and the figure says nothing. Ask for more rather than
    # reporting a score that looks like failure.
    showNotification(
      if (isTRUE(res$chk$thin)) {
        sprintf("%d named. Name two phrases for each voice before the count means anything.",
                res$named)
      } else {
        sprintf("%d named. On the phrases you named yourself it gets %d of %d right.",
                res$named, res$chk$correct, res$chk$n)
      },
      type = if (!isTRUE(res$chk$thin) && isTRUE(res$chk$accuracy < 0.8))
               "warning" else "message",
      duration = 6)
    invisible(NULL)
  }
  observeEvent(input$speaker_save, save_speaker(input$speaker_name %||% ""))
  observeEvent(input$speaker_clear, save_speaker(""))

  # ---- quitting ------------------------------------------------------------
  observeEvent(input$quit, {
    running <- !is.null(rv$session_dir)
    showModal(modalDialog(
      title = "Quit phostor?",
      if (running) {
        paste("A sitting is in progress. Quitting ends it first, so the",
              "recording on screen is saved before phostor stops.")
      } else {
        "This stops phostor. Anything already recorded is on disk."
      },
      footer = tagList(modalButton("Cancel"),
                       actionButton("quit_confirm", "Quit",
                                    class = "btn-sm btn-danger"))))
  })

  observeEvent(input$quit_confirm, {
    removeModal()
    save_tags()
    rv$quitting <- TRUE
    if (!is.null(rv$session_dir)) {
      # The same path as End sitting. An audio visit reaches finalize_visit()
      # only after the browser flushes its last chunk, so the server cannot
      # stop here: finish_quit() waits for the queue to drain.
      rv$ending <- TRUE
      close_visit()
      finish_sitting()
    }
    finish_quit()
  })

  # Called wherever finish_sitting() is, and waits on the same condition: every
  # recording has reached disk.
  finish_quit <- function() {
    if (!isTRUE(rv$quitting) || length(rv$pending)) return(invisible(NULL))
    rv$quitting <- FALSE
    tell("ph_quit", list())
    # Sent before the socket closes: stopApp() here would return from runApp()
    # while the message was still queued, and the browser would show Shiny's
    # own disconnect grey instead of saying what happened.
    session$onFlushed(function() shiny::stopApp(), once = TRUE)
    invisible(NULL)
  }

  # ---- this photograph's visits ------------------------------------------
  # What was said about the photograph on screen: each visit's recording, and
  # its words, which light up as the recording reaches them.
  #
  # The transcript arrives seconds after the visit closes -- the helper runs
  # detached -- so this re-renders while one is outstanding. ph_visit_waiting()
  # bounds that: a WebM recording can never be transcribed, and one whose
  # transcription failed stops being waited for, so neither polls on.
  transcript_html <- function(rel_path, visit) {
    timed <- ph_transcript_timed(cfg, rel_path, visit)
    if (nrow(timed)) {
      spk <- ph_speakers_read(cfg, rel_path, visit)
      j <- match(round(timed$start, 2), round(spk$start, 2))
      name <- ifelse(is.na(j), "", spk$speaker[j])
      # A guess is dimmed; a person's answer is not. The chip sits outside the
      # phrase span so clicking it names the speaker rather than seeking the
      # audio, which is what clicking the words does.
      chip <- sprintf(
        "<span class=\"ph-spk%s\" data-t0=\"%.3f\">%s</span>",
        ifelse(!is.na(j) & spk$source[j] %in% "auto", " guess", ""),
        timed$start, ph_escape(ifelse(nzchar(name), name, "+")))
      return(div(class = "ph-tx", id = sprintf("ph-tx-%d", visit),
                 `data-rel` = rel_path, `data-visit` = as.integer(visit),
                 HTML(paste(paste0(chip, sprintf(
                   "<span class=\"ph-ph\" data-t0=\"%.3f\" data-t1=\"%.3f\">%s</span>",
                   timed$start, timed$end, ph_escape(timed$text))),
                   collapse = " "))))
    }
    # No timings: a transcript written before they existed, or a container the
    # transcriber cannot read. The prose still reads, it just cannot highlight.
    prose <- ph_transcript(cfg, rel_path, visit)
    if (is.na(prose)) return(NULL)
    if (!nzchar(trimws(prose))) {
      return(div(class = "ph-none", "No speech in this recording."))
    }
    div(class = "ph-tx plain", prose)
  }

  output$history <- renderUI({
    rv$tick
    r <- row_of(rv$current)
    if (is.null(r)) return(NULL)
    v <- ph_visits_for(cfg, r$rel_path)
    if (!length(v)) {
      return(div(class = "ph-hist text-secondary small",
                 "No visits to this photograph yet."))
    }
    # Re-render only while a transcript is genuinely on its way. Asking here,
    # inside the render, is what makes the polling stop by itself.
    if (any(vapply(v, function(s) ph_visit_waiting(cfg, r$rel_path, s$visit),
                   logical(1)))) {
      invalidateLater(2000, session)
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
          div(class = "vh",
              span(sprintf("visit %d · %s%s", s$visit,
                           s$started %||% "?",
                           if (!is.na(s$duration))
                             sprintf(" · %.0fs", s$duration) else "")),
              # The id pairs a player with its text; see phrasesFor() above.
              if (!is.null(url))
                tags$audio(id = sprintf("ph-a-%d", s$visit), controls = NA,
                           preload = "none", src = url)),
          transcript_html(r$rel_path, s$visit),
          if (nzchar(said)) div(class = "said", said))
    })
    # data-photo: visit numbers start again at 1 for every photograph, so
    # `ph-tx-1` alone does not say whose transcript it is. Playback checks this
    # before highlighting, or during the round trip after the photograph
    # changes it would light up the previous one's words.
    div(class = "ph-hist", `data-photo` = as.integer(rv$current),
        tags$details(open = NA,
                     tags$summary(sprintf("%d visit(s) to this photograph",
                                          length(v))),
                     rows))
  })

  # ---- playback ----------------------------------------------------------
  observeEvent(input$play, {
    d <- input$play_session
    if (is.null(d) || !nzchar(d)) return()
    # Playback reseeds the fields as it goes, so anything typed and not yet
    # navigated away from would be lost for good without this.
    save_tags()
    close_visit()
    pl <- ph_playlist(cfg, d)
    if (!nrow(pl)) {
      showNotification("That sitting has no completed visits.",
                       type = "warning")
      return()
    }
    items <- lapply(seq_len(nrow(pl)), function(i) {
      r <- row_of(pl$id[i])
      list(id = as.integer(pl$id[i]),
           # The visit, so the client can find the transcript to highlight.
           visit = as.integer(pl$visit[i]),
           src = render_url(pl$rel_path[i], "display"),
           caption = caption_html(r),
           duration = if (is.na(pl$duration[i])) 3 else pl$duration[i],
           audio = if (is.na(pl$audio[i])) NULL else
             sprintf("sidecars/%s", ph_url_path(pl$audio[i])))
    })
    rv$playing <- TRUE
    tell("ph_play", list(items = items))
  })

  # Where the playback has reached. The panel below the photograph and the tag
  # fields read rv$current, so without this they stay on whatever was on screen
  # when Play was pressed -- and typing into a field would then write against
  # that photograph rather than the one being shown.
  #
  # No visit is opened or closed here: watching a sitting back is not recording
  # one, and input$play has already closed whatever was open.
  observeEvent(input$play_at, {
    id <- as.integer(input$play_at$id)
    if (is.na(id) || identical(id, rv$current)) return()
    show_photo(id, notify = FALSE)
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

  # A closed browser tab must not lose the visit in progress: finalize it so
  # its audio is renamed and its sidecar written.
  session$onSessionEnded(function() {
    isolate({
      # A closed tab must not lose what was typed about the photograph on
      # screen; unlike the recording, it needs nothing from the browser.
      save_tags()
      # Not close_visit(): that asks the browser to flush its recorder, and
      # there is no browser left to ask. Use what already reached disk and
      # write the sidecar from that.
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
