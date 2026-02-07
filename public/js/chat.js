// 1. Global Variables
let userName;
let ws;
let typingTimeout;

const MAX_MESSAGES = 50;

// 2. DOM Elements
const joinBtn    = document.getElementById('join-btn');
const nameInput  = document.getElementById('name-input');
const msgInput   = document.getElementById('msg');
const sendBtn    = document.getElementById('send-btn');
const emojiBtn   = document.getElementById('emoji-btn');
const emojiPanel = document.getElementById('emoji-panel');

// 3. Join Logic
function joinChat() {
    userName = nameInput.value.trim() || "Guest_" + Math.floor(Math.random() * 1000);

    const overlay = document.getElementById('name-overlay');
    if (overlay) overlay.style.display = 'none';

    const displayElem = document.getElementById('display-name');
    if (displayElem) displayElem.innerText = userName;

    connect(); // Start the WebSocket connection
}

// 4. WebSocket Logic
function connect() {
    ws = new WebSocket('ws://' + window.location.host + '/chat');

    ws.onopen = () => {
        ws.send(JSON.stringify({ type: 'join', name: userName }));
        startHeartbeat();
    };

    ws.onmessage = (e) => {
        const data = JSON.parse(e.data);
        switch (data.type) {
            case 'users':
                updateUserList(data.list);
                break;
            case 'typing':
                updateTypingIndicator(data.user, data.isTyping);
                break;
            default:
                appendMessage(data);
                break;
        }
    };

    ws.onclose = () => {
        appendMessage({ type: 'system', text: "Connection lost. Refreshing in 3s..." });
        setTimeout(() => location.reload(), 3000);
    };
}

function startHeartbeat() {
    setInterval(() => {
        if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: 'ping' }));
        }
    }, 20000); // 20 seconds
}

// 5. Chat Actions
function send() {
    const text = msgInput.value.trim();
    if (text && ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'message', text: text }));
        msgInput.value = '';

        // Stop typing indicator immediately
        ws.send(JSON.stringify({ type: 'typing', isTyping: false }));
        clearTimeout(typingTimeout);
    }
}

function appendMessage(data) {
    const chat = document.getElementById('chat');
    const div = document.createElement('div');

    if (data.type === 'system') {
        div.className = 'system';
        div.innerText = data.text;
    }
    else {
        div.innerHTML = `
            <span class="time">[${data.timestamp || '??:??'}]</span>
            <b>${data.user}:</b> ${data.text}
        `;
    }

    chat.appendChild(div);

    while (chat.children.length > MAX_MESSAGES) {
        chat.removeChild(chat.firstChild);
    }

    chat.scrollTop = chat.scrollHeight;
}

function updateUserList(list) {
    const ul = document.getElementById('user-list');
    if (ul) {
        ul.innerHTML = list.map(u => `<li>${u}</li>`).join('');
    }
}

function updateTypingIndicator(user, isTyping) {
    if (user === userName) return;
    let indicator = document.getElementById(`typing-${user}`);
    const chat = document.getElementById('chat');

    if (isTyping && !indicator) {
        indicator = document.createElement('div');
        indicator.id = `typing-${user}`;
        indicator.className = 'system';
        indicator.style.opacity = '0.7';
        indicator.innerText = `${user} is typing...`;
        chat.appendChild(indicator);
        chat.scrollTop = chat.scrollHeight;
    }
    else if (!isTyping && indicator) {
        indicator.remove();
    }
}

// 6. Event Listeners

// Join events
if (joinBtn) joinBtn.addEventListener('click', joinChat);
if (nameInput) {
    nameInput.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') joinChat();
    });
}

// Send events
if (sendBtn) sendBtn.addEventListener('click', send);
if (msgInput) {
    msgInput.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') send();
    });

    msgInput.addEventListener('input', () => {
        if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: 'typing', isTyping: true }));
            clearTimeout(typingTimeout);
            typingTimeout = setTimeout(() => {
                ws.send(JSON.stringify({ type: 'typing', isTyping: false }));
            }, 2000);
        }
    });
}
