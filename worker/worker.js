/* ===================== 黑膠猜歌 - 連線對戰後端（Cloudflare Workers + Durable Objects）=====================
   把 _serve.ps1 裡的房間邏輯（建立房間、加入、搶答、聊天室…）原封不動搬過來，
   每個房間用一個獨立的 Durable Object instance（用房號當 key）記住自己的狀態，
   這樣不管玩家連到哪個 Cloudflare 節點，同一個房號永遠會導到同一個 DO，狀態不會亂掉。
======================================================= */

const MAX_PLAYERS = 8;
// 超過這個時間沒有來輪詢房間狀態，就當作那個人已經離開了。
// 抓 60 秒是因為瀏覽器把分頁切到背景時會把計時器降頻（Chrome 最慢到一分鐘一次），
// 抓太短會把還在玩、只是切到別的分頁的人踢掉。
const GHOST_MS = 60000;

function corsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
  };
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...corsHeaders() },
  });
}

function randCode() {
  return String(Math.floor(1000 + Math.random() * 9000));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders() });
    }

    if (path === "/api/create-room" && request.method === "POST") {
      const body = await request.json().catch(() => ({}));
      // 隨機挑一個 4 位數房號；萬一撞到別的還在跑的房間（機率很低）就重試
      for (let attempt = 0; attempt < 5; attempt++) {
        const code = randCode();
        const stub = env.ROOMS.get(env.ROOMS.idFromName(code));
        const res = await stub.fetch("https://do/init", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ name: body.name, code }),
        });
        const data = await res.json();
        if (data.ok) return json(data);
      }
      return json({ ok: false, error: "could not allocate room code" }, 500);
    }

    // 這個要擺在通用的 /api/ 分支前面，否則會被當成「沒帶房號」直接回 400。
    // 雲端版沒有區網 IP 可以分享，回 null 讓前端改用目前網址當分享連結。
    if (path === "/api/server-info") {
      return json({ ok: true, lanIp: null, port: null, cloud: true });
    }

    if (path.startsWith("/api/")) {
      let code = url.searchParams.get("code");
      let bodyText = null;
      if (request.method === "POST") {
        bodyText = await request.text();
        try {
          const parsed = JSON.parse(bodyText);
          if (parsed && parsed.code) code = parsed.code;
        } catch (e) {}
      }
      if (!code) return json({ ok: false, error: "missing code" }, 400);

      const stub = env.ROOMS.get(env.ROOMS.idFromName(code));
      const forwardInit = { method: request.method, headers: { "Content-Type": "application/json" } };
      if (bodyText !== null) forwardInit.body = bodyText;
      const res = await stub.fetch("https://do" + path + url.search, forwardInit);
      const data = await res.json().catch(() => ({ ok: false, error: "bad upstream response" }));
      return json(data, res.status);
    }

    return json({ ok: false, error: "not found" }, 404);
  },
};

export class RoomDO {
  constructor(state, env) {
    this.state = state;
    this.room = null;
    this.state.blockConcurrencyWhile(async () => {
      this.room = (await this.state.storage.get("room")) || null;
    });
  }

  now() {
    return Date.now();
  }

  async save() {
    if (this.room) await this.state.storage.put("room", this.room);
  }

  newPlayerId() {
    return crypto.randomUUID().replace(/-/g, "").slice(0, 8);
  }

  // 把「早就離線但沒送出 leave-room」的人清掉（例如瀏覽器當掉、斷網）。
  // 不清的話，那個人重新加入就會在名單裡出現兩次。
  pruneGhosts() {
    const room = this.room;
    if (!room) return;
    const now = this.now();
    const ids = Object.keys(room.players);
    if (ids.length <= 1) return; // 只剩一個人就別踢了，不然房間會直接空掉
    let removed = false;
    for (const id of ids) {
      const p = room.players[id];
      if (p.lastSeen && now - p.lastSeen > GHOST_MS) {
        delete room.players[id];
        delete room.answers[id];
        removed = true;
      }
    }
    if (removed && !room.players[room.hostPlayerId]) {
      room.hostPlayerId = Object.keys(room.players)[0] || room.hostPlayerId;
    }
  }

  touch(playerId) {
    if (this.room && playerId && this.room.players[playerId]) {
      this.room.players[playerId].lastSeen = this.now();
    }
  }

  advancePhase() {
    const room = this.room;
    if (!room) return;
    const now = this.now();
    const elapsed = now - room.phaseStartedAt;

    if (room.phase === "countdown") {
      if (elapsed >= 3000) {
        room.phase = "playing";
        room.phaseStartedAt = now;
        room.answers = {};
      }
      return;
    }

    if (room.phase === "playing") {
      // 搶答制：只要有人答對就立刻公布，不用等全部人都作答完
      const keys = Object.keys(room.answers);
      const anyCorrect = keys.some((k) => room.answers[k].correct);
      const allAnswered = keys.length >= Object.keys(room.players).length;
      const clipMs = (Number(room.clipSeconds[room.index]) || 0) * 1000 + 3000;
      if (anyCorrect || allAnswered || elapsed >= clipMs) {
        let winnerId = null;
        let bestMs = Infinity;
        for (const k of keys) {
          const a = room.answers[k];
          if (a.correct && a.atMs < bestMs) {
            bestMs = a.atMs;
            winnerId = k;
          }
        }
        if (winnerId && room.players[winnerId]) room.players[winnerId].score++;
        room.lastRoundWinnerId = winnerId;
        room.phase = "revealed";
        room.phaseStartedAt = now;
      }
      return;
    }

    if (room.phase === "revealed") {
      if (elapsed >= 4000) {
        if (room.index >= room.songIds.length - 1) {
          room.phase = "finished";
        } else {
          room.index++;
          room.phase = "countdown";
          room.phaseStartedAt = now;
          room.answers = {};
        }
      }
    }
  }

  publicState() {
    const room = this.room;
    const players = Object.keys(room.players).map((id) => ({
      id,
      name: room.players[id].name,
      score: room.players[id].score,
      answered: Object.prototype.hasOwnProperty.call(room.answers, id),
    }));
    const winnerName =
      room.lastRoundWinnerId && room.players[room.lastRoundWinnerId]
        ? room.players[room.lastRoundWinnerId].name
        : null;
    return {
      ok: true,
      code: room.code,
      phase: room.phase,
      index: room.index,
      total: room.songIds.length,
      correctSongId: room.songIds[room.index] ?? null,
      clipSeconds: room.clipSeconds[room.index] ?? null,
      start: room.starts[room.index] ?? null,
      phaseStartedAt: room.phaseStartedAt,
      serverNow: this.now(),
      hostPlayerId: room.hostPlayerId,
      players,
      lastRoundWinnerId: room.lastRoundWinnerId,
      lastRoundWinnerName: winnerName,
      chat: room.chat,
    };
  }

  json(obj, status = 200) {
    return new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json" } });
  }

  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname;
    let body = {};
    if (request.method === "POST") body = await request.json().catch(() => ({}));

    if (path === "/init") {
      if (this.room) return this.json({ ok: false, error: "exists" });
      const playerId = this.newPlayerId();
      const name = (body.name && String(body.name).trim()) || "Player1";
      this.room = {
        code: body.code,
        hostPlayerId: playerId,
        players: { [playerId]: { name, score: 0, lastSeen: this.now() } },
        nextPlayerNum: 2,
        diffKey: null,
        songIds: [],
        clipSeconds: [],
        starts: [],
        index: 0,
        phase: "lobby",
        phaseStartedAt: this.now(),
        answers: {},
        lastRoundWinnerId: null,
        chat: [],
        chatSeq: 0,
      };
      await this.save();
      return this.json({ ok: true, code: this.room.code, playerId, name });
    }

    if (!this.room) return this.json({ ok: false, error: "room not found" }, 404);
    const room = this.room;

    if (path === "/api/join-room") {
      this.pruneGhosts();
      // 同一個人重新連上來（重新整理、不小心關掉分頁又回來）就沿用原本的位子，
      // 不要再開一個新的，否則名單上會出現兩個同樣的人。
      const rejoinId = body.rejoinId && String(body.rejoinId);
      if (rejoinId && room.players[rejoinId]) {
        const nm = (body.name && String(body.name).trim());
        if (nm) room.players[rejoinId].name = nm;
        room.players[rejoinId].lastSeen = this.now();
        await this.save();
        return this.json({ ok: true, playerId: rejoinId, name: room.players[rejoinId].name, rejoined: true });
      }
      if (room.phase !== "lobby") return this.json({ ok: false, error: "already started" }, 409);
      if (Object.keys(room.players).length >= MAX_PLAYERS)
        return this.json({ ok: false, error: "room full" }, 409);
      const playerId = this.newPlayerId();
      const name = (body.name && String(body.name).trim()) || "Player" + room.nextPlayerNum;
      room.nextPlayerNum++;
      room.players[playerId] = { name, score: 0, lastSeen: this.now() };
      await this.save();
      return this.json({ ok: true, playerId, name });
    }

    if (path === "/api/start-game") {
      if (body.playerId !== room.hostPlayerId) return this.json({ ok: false, error: "only host can start" }, 403);
      if (Object.keys(room.players).length < 2)
        return this.json({ ok: false, error: "need at least 2 players" }, 409);
      if (room.phase !== "lobby") {
        return this.json(this.publicState());
      }
      room.diffKey = body.diffKey;
      room.songIds = Array.isArray(body.songIds) ? body.songIds : [];
      room.clipSeconds = Array.isArray(body.clipSeconds) ? body.clipSeconds : [];
      room.starts = Array.isArray(body.starts) ? body.starts : [];
      room.index = 0;
      room.phase = "countdown";
      room.phaseStartedAt = this.now();
      room.answers = {};
      await this.save();
      return this.json(this.publicState());
    }

    if (path === "/api/room-state") {
      // 每次輪詢都當成一次「我還在」的心跳
      this.touch(url.searchParams.get("playerId"));
      this.pruneGhosts();
      this.advancePhase();
      await this.save();
      return this.json(this.publicState());
    }

    if (path === "/api/submit-answer") {
      this.touch(body.playerId);
      this.advancePhase();
      const playerId = body.playerId;
      if (room.phase === "playing" && room.players[playerId] && !room.answers[playerId]) {
        const atMs = this.now() - room.phaseStartedAt;
        const correct = String(body.songId) === String(room.songIds[room.index]);
        room.answers[playerId] = { songId: body.songId, atMs, correct };
        this.advancePhase();
      }
      await this.save();
      return this.json(this.publicState());
    }

    if (path === "/api/return-to-lobby") {
      room.phase = "lobby";
      room.phaseStartedAt = this.now();
      room.index = 0;
      room.songIds = [];
      room.clipSeconds = [];
      room.starts = [];
      room.answers = {};
      room.lastRoundWinnerId = null;
      for (const pid of Object.keys(room.players)) room.players[pid].score = 0;
      await this.save();
      return this.json(this.publicState());
    }

    if (path === "/api/leave-room") {
      const playerId = body.playerId;
      if (room.players[playerId]) delete room.players[playerId];
      // 連他這一輪的作答一起清掉，否則「是不是大家都答完了」會多算一票
      delete room.answers[playerId];
      if (Object.keys(room.players).length === 0) {
        this.room = null;
        await this.state.storage.deleteAll();
        return this.json({ ok: true });
      }
      if (room.hostPlayerId === playerId) room.hostPlayerId = Object.keys(room.players)[0];
      await this.save();
      return this.json({ ok: true });
    }

    if (path === "/api/send-chat") {
      const playerId = body.playerId;
      if (!room.players[playerId]) return this.json({ ok: false, error: "not in room" }, 403);
      let text = String(body.text || "").trim();
      if (text.length > 200) text = text.slice(0, 200);
      if (text.length > 0) {
        room.chatSeq++;
        room.chat.push({ id: room.chatSeq, playerId, name: room.players[playerId].name, text, ts: this.now() });
        if (room.chat.length > 50) room.chat = room.chat.slice(room.chat.length - 50);
      }
      await this.save();
      return this.json({ ok: true });
    }

    return this.json({ ok: false, error: "not found" }, 404);
  }
}
