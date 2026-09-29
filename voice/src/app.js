import { Conversation } from '@elevenlabs/client';

const $ = (id) => document.getElementById(id);
const startButton = $('start');
const muteButton = $('mute');
const endButton = $('end');
const status = $('status');
const meter = $('meter');
const messages = $('messages');
let conversation = null;
let muted = false;

function setState(text, active = false) {
  status.textContent = text;
  meter.classList.toggle('active', active);
}

function addMessage(role, text) {
  if (!text) return;
  const placeholder = messages.querySelector('.placeholder');
  if (placeholder) placeholder.remove();
  const item = document.createElement('p');
  item.className = `message ${role}`;
  item.textContent = `${role === 'agent' ? 'Sektor' : 'Tú'}: ${text}`;
  messages.appendChild(item);
  messages.scrollTop = messages.scrollHeight;
}

async function startCall() {
  startButton.disabled = true;
  setState('Solicitando acceso al micrófono…');
  try {
    const permissionStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    permissionStream.getTracks().forEach((track) => track.stop());
    const response = await fetch('/api/signed-url', { cache: 'no-store' });
    if (!response.ok) throw new Error('No se pudo obtener una sesión firmada');
    const { signedUrl } = await response.json();
    conversation = await Conversation.startSession({
      signedUrl,
      onConnect: () => {
        setState('Llamada conectada', true);
        muteButton.disabled = false;
        endButton.disabled = false;
      },
      onDisconnect: () => {
        setState('Llamada finalizada');
        startButton.disabled = false;
        muteButton.disabled = true;
        endButton.disabled = true;
        conversation = null;
      },
      onError: (error) => {
        console.error(error);
        setState('Error de conexión');
      },
      onModeChange: ({ mode }) => setState(mode === 'speaking' ? 'Sektor está hablando…' : 'Sektor está escuchando…', true),
      onMessage: (message) => addMessage(message.source === 'ai' ? 'agent' : 'user', message.message || message.text || '')
    });
  } catch (error) {
    console.error(error);
    setState(error?.message || 'No se pudo iniciar la llamada');
    startButton.disabled = false;
  }
}

startButton.addEventListener('click', startCall);
muteButton.addEventListener('click', () => {
  if (!conversation) return;
  muted = !muted;
  conversation.setMicMuted(muted);
  muteButton.textContent = muted ? 'Activar micro' : 'Silenciar';
  setState(muted ? 'Micrófono silenciado' : 'Sektor está escuchando…', !muted);
});
endButton.addEventListener('click', async () => {
  if (!conversation) return;
  endButton.disabled = true;
  await conversation.endSession();
});
window.addEventListener('beforeunload', () => { if (conversation) conversation.endSession(); });
