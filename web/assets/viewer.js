const stream = document.getElementById('stream');
const video = document.getElementById('video');
const overlay = document.getElementById('input-overlay');
const keyboardCapture = document.getElementById('keyboard-capture');
const keyboardButton = document.getElementById('keyboard-button');
const inputStatus = document.getElementById('input-status');
const transportStatus = document.getElementById('transport-status');
const videoStatus = document.getElementById('video-status');
// viewer.js is served as a static file (no template substitution), so the token
// is injected by an inline script in viewer.html that sets window.__MIRADOR_TOKEN__.
const authToken = (typeof window !== 'undefined' && window.__MIRADOR_TOKEN__) || '';
const authHeaders = authToken ? { 'X-Mirador-Token': authToken } : {};
let pendingMove = null;
let moveScheduled = false;
let touchDragState = null;
let twoFingerScrollState = null;
let lastTouchEventAt = 0;

// Persistent low-latency input transport (WebSocket) with an HTTP fallback.
const wsScheme = location.protocol === 'https:' ? 'wss' : 'ws';
const wsTokenQuery = authToken ? `?token=${encodeURIComponent(authToken)}` : '';
const inputSocketURL = `${wsScheme}://${location.host}/ws/input${wsTokenQuery}`;
let inputSocket = null;
let inputSocketReady = false;
let inputSeq = 0;
let lastLatencyMs = null;
let reconnectDelay = 500;
let reconnectTimer = null;
const pendingInput = new Map();

function updateTransportStatus() {
  if (inputSocketReady) {
    const latency = lastLatencyMs == null ? '—' : `${Math.round(lastLatencyMs)}ms`;
    transportStatus.textContent = `ws ✓ ${latency}`;
  } else {
    transportStatus.textContent = 'ws… http fallback';
  }
}

// H.264 video transport: a binary WebSocket feeds Annex-B access units to a WebCodecs
// VideoDecoder rendered onto a <canvas>. When VideoDecoder is unavailable we leave the
// MJPEG <img> running as the fallback.
const wsVideoURL = `${wsScheme}://${location.host}/ws/video${wsTokenQuery}`;
const VIDEO_HEADER_BYTES = 17; // seq(8) + captureMillis(8) + flags(1)
// MJPEG fallback URL, used only when WebCodecs is unavailable or the H.264 decode fails.
// The <img> starts with no src so we never run a redundant MJPEG stream alongside H.264.
const mjpegSrc = '/stream.mjpg' + (authToken ? `?token=${encodeURIComponent(authToken)}` : '');
const canvasCtx = video.getContext('2d');
let videoSocket = null;
let videoDecoder = null;
let videoConfigured = false;
let videoActive = false;
let lastVideoCaptureMillis = null;
let videoReconnectDelay = 500;
let videoReconnectTimer = null;
let videoChunkCount = 0;
let videoOutputCount = 0;

// Send a short diagnostic string back to the server (logged to stderr) so decode
// failures on the device are visible without a remote debugger.
function sendVideoDiag(msg) {
  try {
    if (videoSocket && videoSocket.readyState === WebSocket.OPEN) {
      videoSocket.send('diag:' + msg);
    }
  } catch (_) {}
}

function webCodecsSupported() {
  return typeof window !== 'undefined' && 'VideoDecoder' in window && 'EncodedVideoChunk' in window;
}

function updateVideoStatus(text) {
  if (videoStatus) videoStatus.textContent = text;
}

function parseVideoMessage(buffer) {
  const view = new DataView(buffer);
  const seq = view.getUint32(0) * 4294967296 + view.getUint32(4);
  const captureMillis = view.getUint32(8) * 4294967296 + view.getUint32(12);
  const isKeyframe = (view.getUint8(16) & 0x01) === 1;
  const data = new Uint8Array(buffer, VIDEO_HEADER_BYTES);
  return { seq, captureMillis, isKeyframe, data };
}

// Build the WebCodecs codec string (avc1.PPCCLL) from the SPS NAL inside an Annex-B keyframe.
function avcCodecFromAnnexB(data) {
  let i = 0;
  while (i + 4 < data.length) {
    if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 1) {
      const nalType = data[i + 3] & 0x1f;
      if (nalType === 7 && i + 6 < data.length) {
        const hex = b => b.toString(16).padStart(2, '0');
        return `avc1.${hex(data[i + 4])}${hex(data[i + 5])}${hex(data[i + 6])}`;
      }
      i += 3;
    } else {
      i += 1;
    }
  }
  return 'avc1.42e01e'; // constrained baseline fallback
}

// 1x1 transparent GIF — assigning it forcibly aborts the in-flight multipart MJPEG
// stream (removeAttribute('src') alone does not reliably close it in Safari).
const BLANK_GIF = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

function showVideoCanvas() {
  if (videoActive) return;
  videoActive = true;
  video.hidden = false;
  stream.classList.add('hidden');
  // Stop the MJPEG stream so we don't double-encode or hold a second capture slot.
  stream.src = BLANK_GIF;
}

function resetVideo(reason) {
  if (reason) sendVideoDiag('reset ' + reason);
  videoActive = false;
  videoConfigured = false;
  if (videoDecoder) {
    try { if (videoDecoder.state !== 'closed') videoDecoder.close(); } catch (_) {}
    videoDecoder = null;
  }
  video.hidden = true;
  stream.classList.remove('hidden');
  // Restore the MJPEG fallback stream.
  if (!stream.getAttribute('src') && mjpegSrc) stream.setAttribute('src', mjpegSrc);
  updateVideoStatus(reason ? ('mjpeg ⟵ ' + reason) : 'video fallback (mjpeg)');
}

// Split an Annex-B buffer into raw NAL units (start codes stripped).
function splitAnnexB(data) {
  const nals = [];
  const n = data.length;
  const atStart = p => data[p] === 0 && data[p + 1] === 0 && (data[p + 2] === 1 || (data[p + 2] === 0 && data[p + 3] === 1));
  let i = 0;
  while (i < n && !atStart(i)) i += 1;
  while (i < n) {
    const scLen = data[i + 2] === 1 ? 3 : 4;
    const start = i + scLen;
    let j = start;
    while (j < n && !atStart(j)) j += 1;
    if (j > start) nals.push(data.subarray(start, j));
    i = j;
  }
  return nals;
}

// Build an avcC (AVCDecoderConfigurationRecord) from one SPS and one PPS NAL.
function buildAvccDescription(sps, pps) {
  const out = new Uint8Array(11 + sps.length + pps.length);
  let p = 0;
  out[p++] = 1;          // configurationVersion
  out[p++] = sps[1];     // AVCProfileIndication
  out[p++] = sps[2];     // profile_compatibility
  out[p++] = sps[3];     // AVCLevelIndication
  out[p++] = 0xff;       // 6 bits reserved | lengthSizeMinusOne = 3 (4-byte lengths)
  out[p++] = 0xe1;       // 3 bits reserved | numOfSequenceParameterSets = 1
  out[p++] = (sps.length >> 8) & 0xff;
  out[p++] = sps.length & 0xff;
  out.set(sps, p); p += sps.length;
  out[p++] = 1;          // numOfPictureParameterSets
  out[p++] = (pps.length >> 8) & 0xff;
  out[p++] = pps.length & 0xff;
  out.set(pps, p);
  return out;
}

// Convert Annex-B NAL units to length-prefixed AVCC, dropping parameter-set/AUD NALs
// (SPS/PPS live in the decoder description for Safari's WebCodecs).
function annexBToAvcc(nals) {
  const kept = nals.filter(nal => {
    const type = nal[0] & 0x1f;
    return type !== 7 && type !== 8 && type !== 9;
  });
  let total = 0;
  for (const nal of kept) total += 4 + nal.length;
  const out = new Uint8Array(total);
  let p = 0;
  for (const nal of kept) {
    out[p++] = (nal.length >>> 24) & 0xff;
    out[p++] = (nal.length >>> 16) & 0xff;
    out[p++] = (nal.length >>> 8) & 0xff;
    out[p++] = nal.length & 0xff;
    out.set(nal, p); p += nal.length;
  }
  return out;
}

function ensureDecoder(nals, rawKeyframe) {
  const sps = nals.find(nal => (nal[0] & 0x1f) === 7);
  const pps = nals.find(nal => (nal[0] & 0x1f) === 8);
  if (!sps || !pps) return false;
  videoDecoder = new VideoDecoder({
    output: frame => {
      try {
        videoOutputCount += 1;
        if (video.width !== frame.displayWidth || video.height !== frame.displayHeight) {
          video.width = frame.displayWidth;
          video.height = frame.displayHeight;
        }
        canvasCtx.drawImage(frame, 0, 0, video.width, video.height);
      } finally {
        frame.close();
      }
    },
    error: e => resetVideo('decoder-error ' + (e && e.message ? e.message : e))
  });
  // Safari's VideoDecoder needs avcC (length-prefixed) bitstreams, not Annex-B: pass the
  // SPS/PPS as a description and feed AVCC chunks below.
  const codec = avcCodecFromAnnexB(rawKeyframe);
  videoDecoder.configure({
    codec,
    description: buildAvccDescription(sps, pps),
    optimizeForLatency: true
  });
  videoConfigured = true;
  sendVideoDiag('configured codec=' + codec + ' sps=' + sps.length + ' pps=' + pps.length);
  return true;
}

function handleVideoMessage(buffer) {
  if (buffer.byteLength <= VIDEO_HEADER_BYTES) return;
  const frame = parseVideoMessage(buffer);
  const nals = splitAnnexB(frame.data);
  if (!videoConfigured) {
    if (!frame.isKeyframe) return; // wait for an IDR before configuring the decoder
    try { if (!ensureDecoder(nals, frame.data)) { sendVideoDiag('no sps/pps in keyframe'); return; } }
    catch (e) { resetVideo('configure ' + (e && e.message ? e.message : e)); return; }
  }
  if (!videoDecoder || videoDecoder.state !== 'configured') return;
  const avcc = annexBToAvcc(nals);
  if (avcc.length === 0) return;
  try {
    videoDecoder.decode(new EncodedVideoChunk({
      type: frame.isKeyframe ? 'key' : 'delta',
      timestamp: frame.captureMillis * 1000, // microseconds
      data: avcc
    }));
    videoChunkCount += 1;
    lastVideoCaptureMillis = frame.captureMillis;
    // Only treat the canvas as live once frames actually decode to output.
    if (videoOutputCount > 0) {
      showVideoCanvas();
      const age = Math.max(0, Math.round(Date.now() - frame.captureMillis));
      updateVideoStatus(`h264 ✓ ${age}ms`);
    }
  } catch (e) {
    resetVideo('decode ' + (e && e.message ? e.message : e));
  }
}

function scheduleVideoReconnect() {
  if (videoReconnectTimer) return;
  videoReconnectTimer = setTimeout(() => {
    videoReconnectTimer = null;
    connectVideoSocket();
  }, videoReconnectDelay);
  videoReconnectDelay = Math.min(videoReconnectDelay * 2, 5000);
}

function connectVideoSocket() {
  if (!webCodecsSupported()) {
    updateVideoStatus('video: mjpeg (no WebCodecs)');
    if (!stream.getAttribute('src')) stream.src = mjpegSrc; // start the MJPEG fallback
    return;
  }
  if (videoReconnectTimer) { clearTimeout(videoReconnectTimer); videoReconnectTimer = null; }
  let socket;
  try {
    socket = new WebSocket(wsVideoURL);
  } catch (_) {
    scheduleVideoReconnect();
    return;
  }
  socket.binaryType = 'arraybuffer';
  videoSocket = socket;
  socket.addEventListener('open', () => {
    videoReconnectDelay = 500;
    updateVideoStatus('h264 connecting…');
  });
  socket.addEventListener('message', event => {
    if (event.data instanceof ArrayBuffer) handleVideoMessage(event.data);
  });
  socket.addEventListener('close', () => {
    if (videoSocket === socket) videoSocket = null;
    resetVideo();
    scheduleVideoReconnect();
  });
  socket.addEventListener('error', () => {
    try { socket.close(); } catch (_) {}
  });
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectInputSocket();
  }, reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, 5000);
}

function handleInputAck(raw) {
  let message;
  try { message = JSON.parse(raw); } catch (_) { return; }
  if (message.type !== 'ack') return;
  const sentAt = pendingInput.get(message.seq);
  if (sentAt !== undefined) {
    lastLatencyMs = performance.now() - sentAt;
    pendingInput.delete(message.seq);
  }
  inputStatus.textContent = message.ok ? 'input ok' : 'input blocked';
  updateTransportStatus();
}

function connectInputSocket() {
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  let socket;
  try {
    socket = new WebSocket(inputSocketURL);
  } catch (_) {
    scheduleReconnect();
    return;
  }
  inputSocket = socket;
  socket.addEventListener('open', () => {
    inputSocketReady = true;
    reconnectDelay = 500;
    updateTransportStatus();
  });
  socket.addEventListener('message', event => handleInputAck(event.data));
  socket.addEventListener('close', () => {
    inputSocketReady = false;
    if (inputSocket === socket) inputSocket = null;
    pendingInput.clear();
    updateTransportStatus();
    scheduleReconnect();
  });
  socket.addEventListener('error', () => {
    try { socket.close(); } catch (_) {}
  });
}

async function refreshMetrics() {
  try {
    const res = await fetch('/metrics', { cache: 'no-store', headers: authHeaders });
    const data = await res.json();
    const age = Math.round(data.latestFrameAgeMillis || 0);
    const fps = Math.round((data.fps || 0) * 10) / 10;
    const kbits = Math.round((data.bitrateBitsPerSec || 0) / 1000);
    const dispatch = Math.round((data.inputDispatchMillis || 0) * 100) / 100;
    const encFps = Math.round((data.encodeFps || 0) * 10) / 10;
    const encKbits = Math.round((data.encodeBitrateBitsPerSec || 0) / 1000);
    const encMs = Math.round((data.encodeMillis || 0) * 100) / 100;
    document.getElementById('metrics').textContent =
      `rss=${Math.round(data.rssBytes / 1024 / 1024)}MB fps=${fps} ${kbits}kbit/s enc=${encFps}fps ${encKbits}kbit/s ${encMs}ms streams=${data.activeStreams}/${data.videoStreams || 0} dropped=${data.droppedFrames}/${data.incompleteFrames || 0} age=${age}ms input=${data.inputSockets || 0} dispatch=${dispatch}ms`;
  } catch (_) {
    document.getElementById('metrics').textContent = 'metrics unavailable';
  }
}

function imageContentRect() {
  // Map input coordinates against whichever surface is showing: the H.264 canvas when
  // active, otherwise the MJPEG image.
  const usingVideo = videoActive && video.width > 0 && video.height > 0;
  const el = usingVideo ? video : stream;
  const rect = el.getBoundingClientRect();
  const naturalWidth = usingVideo ? video.width : (stream.naturalWidth || 1920);
  const naturalHeight = usingVideo ? video.height : (stream.naturalHeight || 1080);
  const imageAspect = naturalWidth / naturalHeight;
  const boxAspect = rect.width / rect.height;
  let width, height, left, top;
  if (boxAspect > imageAspect) {
    height = rect.height;
    width = height * imageAspect;
    left = rect.left + (rect.width - width) / 2;
    top = rect.top;
  } else {
    width = rect.width;
    height = width / imageAspect;
    left = rect.left;
    top = rect.top + (rect.height - height) / 2;
  }
  return { left, top, width, height };
}

function normalizedPoint(event) {
  const rect = imageContentRect();
  const x = (event.clientX - rect.left) / rect.width;
  const y = (event.clientY - rect.top) / rect.height;
  if (x < 0 || x > 1 || y < 0 || y > 1) return null;
  return { x, y };
}

function normalizedTouchPoint(touch) {
  return normalizedPoint({ clientX: touch.clientX, clientY: touch.clientY });
}

function touchCentroid(touches) {
  let clientX = 0;
  let clientY = 0;
  for (const touch of touches) {
    clientX += touch.clientX;
    clientY += touch.clientY;
  }
  clientX /= touches.length;
  clientY /= touches.length;
  return { clientX, clientY };
}

function modifierPayload(event) {
  return {
    shiftKey: event.shiftKey,
    ctrlKey: event.ctrlKey,
    altKey: event.altKey,
    metaKey: event.metaKey
  };
}

function focusKeyboardCapture() {
  try { keyboardCapture.focus({ preventScroll: true }); } catch (_) { keyboardCapture.focus(); }
  keyboardCapture.value = '';
}

function isPrintableTextKey(event) {
  return event.key && event.key.length === 1 && !event.metaKey && !event.ctrlKey && !event.altKey;
}

// HTTP fallback: one POST per event. Used when the WebSocket is not open.
async function postInput(payload) {
  try {
    const res = await fetch('/input', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', ...authHeaders },
      body: JSON.stringify(payload),
      keepalive: false
    });
    inputStatus.textContent = res.ok ? `input ${payload.type}` : `input blocked (${res.status})`;
  } catch (error) {
    inputStatus.textContent = 'input failed';
  }
}

// Preferred path: send over the persistent WebSocket with a sequence number so
// the server can ack and we can measure round-trip dispatch latency.
function sendInput(payload) {
  if (inputSocket && inputSocketReady && inputSocket.readyState === WebSocket.OPEN) {
    const seq = ++inputSeq;
    payload.seq = seq;
    pendingInput.set(seq, performance.now());
    if (pendingInput.size > 256) {
      pendingInput.delete(pendingInput.keys().next().value);
    }
    try {
      inputSocket.send(JSON.stringify(payload));
      return;
    } catch (_) {
      pendingInput.delete(seq);
    }
  }
  postInput(payload);
}

function pointerPayload(type, event) {
  const point = normalizedPoint(event);
  if (!point) return null;
  return {
    type,
    x: point.x,
    y: point.y,
    button: event.button,
    buttons: event.buttons,
    ...modifierPayload(event)
  };
}

function sendPointer(type, event) {
  const payload = pointerPayload(type, event);
  if (payload) sendInput(payload);
}

function scheduleMove(event) {
  const payload = pointerPayload('pointerMove', event);
  if (!payload) return;
  pendingMove = payload;
  if (moveScheduled) return;
  moveScheduled = true;
  requestAnimationFrame(() => {
    moveScheduled = false;
    if (pendingMove) {
      sendInput(pendingMove);
      pendingMove = null;
    }
  });
}

function sendTouchTap(point) {
  sendInput({ type: 'pointerDown', x: point.x, y: point.y, button: 0, buttons: 1 });
  sendInput({ type: 'pointerUp', x: point.x, y: point.y, button: 0, buttons: 0 });
}

function sendTouchDragMove(point) {
  sendInput({ type: 'pointerMove', x: point.x, y: point.y, button: 0, buttons: 1 });
}

function distanceBetween(a, b) {
  const dx = a.clientX - b.clientX;
  const dy = a.clientY - b.clientY;
  return Math.hypot(dx, dy);
}

function handleTouchStart(event) {
  event.preventDefault();
  lastTouchEventAt = performance.now();
  focusKeyboardCapture();
  if (event.touches.length === 1) {
    const touch = event.touches[0];
    const point = normalizedTouchPoint(touch);
    touchDragState = point ? {
      startPoint: point,
      lastPoint: point,
      startClientX: touch.clientX,
      startClientY: touch.clientY,
      moved: false,
      dragging: false,
      startedAt: performance.now()
    } : null;
    twoFingerScrollState = null;
  } else if (event.touches.length === 2) {
    const centroid = touchCentroid(event.touches);
    const point = normalizedPoint(centroid);
    twoFingerScrollState = point ? { point, clientX: centroid.clientX, clientY: centroid.clientY } : null;
    touchDragState = null;
  }
}

function handleTouchMove(event) {
  event.preventDefault();
  lastTouchEventAt = performance.now();
  if (event.touches.length === 1 && touchDragState) {
    const touch = event.touches[0];
    const point = normalizedTouchPoint(touch);
    if (!point) return;
    const movedPixels = distanceBetween(touch, { clientX: touchDragState.startClientX, clientY: touchDragState.startClientY });
    touchDragState.moved = touchDragState.moved || movedPixels > 8;
    if (touchDragState.moved && !touchDragState.dragging) {
      sendInput({ type: 'pointerDown', x: touchDragState.startPoint.x, y: touchDragState.startPoint.y, button: 0, buttons: 1 });
      touchDragState.dragging = true;
    }
    touchDragState.lastPoint = point;
    if (touchDragState.dragging) sendTouchDragMove(point);
  } else if (event.touches.length === 2 && twoFingerScrollState) {
    const centroid = touchCentroid(event.touches);
    const point = normalizedPoint(centroid) || twoFingerScrollState.point;
    const deltaX = centroid.clientX - twoFingerScrollState.clientX;
    const deltaY = centroid.clientY - twoFingerScrollState.clientY;
    twoFingerScrollState = { point, clientX: centroid.clientX, clientY: centroid.clientY };
    sendInput({ type: 'scroll', x: point.x, y: point.y, deltaX: -deltaX, deltaY: -deltaY });
  }
}

function handleTouchEnd(event) {
  event.preventDefault();
  lastTouchEventAt = performance.now();
  if (event.touches.length === 0 && touchDragState) {
    if (touchDragState.dragging) {
      const point = touchDragState.lastPoint;
      sendInput({ type: 'pointerUp', x: point.x, y: point.y, button: 0, buttons: 0 });
    } else if (!touchDragState.moved) {
      sendTouchTap(touchDragState.startPoint);
    }
    touchDragState = null;
  }
  if (event.touches.length < 2) twoFingerScrollState = null;
}

overlay.addEventListener('pointerdown', event => {
  if (event.pointerType === 'touch' || performance.now() - lastTouchEventAt < 600) return;
  event.preventDefault();
  focusKeyboardCapture();
  overlay.setPointerCapture(event.pointerId);
  sendPointer('pointerDown', event);
});

overlay.addEventListener('pointermove', event => {
  if (event.pointerType === 'touch' || performance.now() - lastTouchEventAt < 600) return;
  event.preventDefault();
  const events = event.getCoalescedEvents ? event.getCoalescedEvents() : [event];
  scheduleMove(events[events.length - 1]);
});

overlay.addEventListener('pointerup', event => {
  if (event.pointerType === 'touch' || performance.now() - lastTouchEventAt < 600) return;
  event.preventDefault();
  focusKeyboardCapture();
  sendPointer('pointerUp', event);
});

overlay.addEventListener('touchstart', handleTouchStart, { passive: false });
overlay.addEventListener('touchmove', handleTouchMove, { passive: false });
overlay.addEventListener('touchend', handleTouchEnd, { passive: false });
overlay.addEventListener('touchcancel', handleTouchEnd, { passive: false });

overlay.addEventListener('wheel', event => {
  event.preventDefault();
  focusKeyboardCapture();
  const point = normalizedPoint(event);
  if (!point) return;
  sendInput({ type: 'scroll', x: point.x, y: point.y, deltaX: event.deltaX, deltaY: event.deltaY, ...modifierPayload(event) });
}, { passive: false });

function handleKeyDown(event) {
  if (isPrintableTextKey(event)) {
    return;
  }
  event.preventDefault();
  sendInput({ type: 'keyDown', key: event.key, code: event.code, repeat: event.repeat, ...modifierPayload(event) });
}

function handleKeyUp(event) {
  if (isPrintableTextKey(event)) {
    return;
  }
  event.preventDefault();
  sendInput({ type: 'keyUp', key: event.key, code: event.code, repeat: event.repeat, ...modifierPayload(event) });
}

keyboardCapture.addEventListener('keydown', handleKeyDown);
keyboardCapture.addEventListener('keyup', handleKeyUp);
overlay.addEventListener('keydown', handleKeyDown);
overlay.addEventListener('keyup', handleKeyUp);

keyboardCapture.addEventListener('beforeinput', event => {
  if (event.data && event.data.length > 0) {
    event.preventDefault();
    sendInput({ type: 'text', text: event.data });
    keyboardCapture.value = '';
  }
});

keyboardCapture.addEventListener('input', event => {
  const text = keyboardCapture.value;
  if (text.length > 0) {
    sendInput({ type: 'text', text });
    keyboardCapture.value = '';
  }
});

keyboardButton.addEventListener('click', event => {
  event.preventDefault();
  focusKeyboardCapture();
  inputStatus.textContent = 'keyboard ready';
});

window.addEventListener('resize', () => {
  focusKeyboardCapture();
});

document.addEventListener('visibilitychange', () => {
  if (!document.hidden) focusKeyboardCapture();
});

setInterval(refreshMetrics, 1000);
refreshMetrics();
focusKeyboardCapture();
updateTransportStatus();
connectInputSocket();
connectVideoSocket();
// Report only a stall (chunks arriving but the decoder produces no output), not steady state.
let lastDiagChunks = 0;
setInterval(() => {
  if (videoConfigured && videoDecoder) {
    const advanced = videoChunkCount > lastDiagChunks;
    lastDiagChunks = videoChunkCount;
    if (advanced && videoOutputCount === 0) {
      sendVideoDiag(`stall chunks=${videoChunkCount} outputs=0 state=${videoDecoder.state} queue=${videoDecoder.decodeQueueSize}`);
    }
  }
}, 2000);
