(() => {
  const config = window.CHEMK_SUPABASE_CONFIG;
  let client = null;
  let channel = null;
  let playerId = null;
  let roomCode = null;
  const stateListeners = new Set();
  const hitListeners = new Set();
  const playerStates = new Map();

  function getClient() {
    if (!config || !config.url || !config.publishableKey) {
      throw new Error("Не настроено подключение Supabase.");
    }
    if (!window.supabase || typeof window.supabase.createClient !== "function") {
      throw new Error("Библиотека Supabase не загрузилась. Проверьте подключение к интернету.");
    }
    if (!client) client = window.supabase.createClient(config.url, config.publishableKey);
    return client;
  }

  function makeRoomCode() {
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    const bytes = new Uint8Array(6);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, byte => alphabet[byte % alphabet.length]).join("");
  }

  function currentPlayers() {
    if (!channel) return [];
    return Object.entries(channel.presenceState()).flatMap(([id, entries]) => {
      const presence = entries[0] || {};
      return [{ id, nickname: String(presence.nickname || "Игрок").slice(0, 16) }];
    });
  }

  function notifyPlayers() {
    const players = currentPlayers();
    window.dispatchEvent(new CustomEvent("chemk-online-players", { detail: players }));
  }

  async function connect(code, nickname) {
    if (channel) await disconnect();
    const normalizedCode = String(code || "").trim().toUpperCase();
    if (!/^[A-HJ-NP-Z2-9]{6}$/.test(normalizedCode)) {
      throw new Error("Код комнаты должен состоять из 6 букв или цифр.");
    }
    const safeNickname = String(nickname || "").trim().slice(0, 16) || "Игрок";
    playerId = crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    roomCode = normalizedCode;
    channel = getClient().channel(`chemk-room-${roomCode}`, {
      config: { broadcast: { self: false }, presence: { key: playerId }, private: false }
    });
    const joiningChannel = channel;
    joiningChannel
      .on("presence", { event: "sync" }, notifyPlayers)
      .on("broadcast", { event: "state" }, ({ payload }) => {
        if (!payload || payload.id === playerId) return;
        playerStates.set(payload.id, payload);
        stateListeners.forEach(listener => listener(payload));
      })
      .on("broadcast", { event: "hit" }, ({ payload }) => {
        if (payload) hitListeners.forEach(listener => listener(payload));
      });

    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error("Не удалось подключиться к комнате за 12 секунд.")), 12000);
      joiningChannel.subscribe(async status => {
        if (status === "SUBSCRIBED") {
          clearTimeout(timeout);
          if (channel !== joiningChannel) {
            reject(new Error("Подключение к комнате было отменено."));
            return;
          }
          try {
            const existingPlayers = currentPlayers();
            if (existingPlayers.length >= 8) {
              await disconnect();
              reject(new Error("Комната заполнена (максимум 8 игроков)."));
              return;
            }
            await joiningChannel.track({ nickname: safeNickname, joinedAt: new Date().toISOString() });
            notifyPlayers();
            resolve();
          } catch (error) {
            clearTimeout(timeout);
            reject(error);
          }
        } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT" || status === "CLOSED") {
          clearTimeout(timeout);
          reject(new Error(`Соединение с комнатой не удалось: ${status}`));
        }
      });
    });
    return { id: playerId, roomCode };
  }

  async function send(event, payload) {
    if (!channel) return;
    const status = await channel.send({ type: "broadcast", event, payload });
    if (status !== "ok") throw new Error(`Не удалось отправить данные в комнату: ${status}`);
  }

  async function disconnect() {
    if (channel) {
      const oldChannel = channel;
      channel = null;
      await getClient().removeChannel(oldChannel);
    }
    playerStates.clear();
    notifyPlayers();
    playerId = null;
    roomCode = null;
  }

  window.ChemkOnline = Object.freeze({
    createRoom: async nickname => {
      const code = makeRoomCode();
      await connect(code, nickname);
      return code;
    },
    joinRoom: connect,
    disconnect,
    get id() { return playerId; },
    get roomCode() { return roomCode; },
    get players() { return currentPlayers(); },
    get playerStates() { return playerStates; },
    sendState: payload => send("state", { ...payload, id: playerId }),
    sendHit: payload => send("hit", payload),
    onState: listener => { stateListeners.add(listener); return () => stateListeners.delete(listener); },
    onHit: listener => { hitListeners.add(listener); return () => hitListeners.delete(listener); }
  });
})();
