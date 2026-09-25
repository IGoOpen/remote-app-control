import { RemoteScreen, RemoteViewer } from '../src/index.ts';

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const params = new URLSearchParams(location.search);
const server = $<HTMLInputElement>('server');
const code = $<HTMLInputElement>('code');
const status = $('status');
const logs = $('logs');

server.value = params.get('server') ?? 'ws://localhost:8080';
code.value = params.get('code') ?? '';

let viewer: RemoteViewer | null = null;
let screen: RemoteScreen | null = null;

function connect(): void {
  screen?.destroy();
  viewer?.disconnect();
  logs.textContent = '';

  viewer = new RemoteViewer({ server: server.value.trim() });
  screen = new RemoteScreen($('screen'), viewer);
  viewer.on('status', (s) => {
    status.textContent = s === 'connected' ? `Live · ${viewer?.deviceInfo.platform ?? ''}` : s;
    if (s === 'disconnected' && viewer?.error) status.textContent = `Disconnected: ${viewer.error}`;
  });
  viewer.on('logs', (entries) => {
    const follow = logs.scrollTop + logs.clientHeight >= logs.scrollHeight - 24;
    for (const entry of entries) {
      const line = document.createElement('div');
      line.textContent = `${entry.time.toISOString().slice(11, 23)}  ${entry.message}`;
      if (entry.isError) line.className = 'error';
      logs.appendChild(line);
    }
    if (follow) logs.scrollTop = logs.scrollHeight;
  });
  viewer.connect(code.value.trim()).catch(() => {});
}

$('connect').addEventListener('click', connect);
code.addEventListener('keydown', (e) => e.key === 'Enter' && connect());
$('back').addEventListener('click', () => viewer?.back());
if (code.value) connect();
