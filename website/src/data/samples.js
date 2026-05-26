export const SAMPLES = [
  {
    id: "narrator",
    mode: "Voice Design",
    color: "var(--lavender-300)",
    seed: 3,
    voice: "A warm, deep narrator with a subtle British accent.",
    quote: "The valley opens after the last bend, slow, and quieter than the road would suggest.",
    duration: "0:08",
    delivery: "Calm / Subtle",
    src: "assets/voice-samples/voice-design-calm-subtle.wav",
  },
  {
    id: "host",
    mode: "Custom Voice",
    color: "var(--gold-300)",
    seed: 8,
    voice: "Aiden, English native",
    quote: "Hey, welcome back to Field Notes. Today we're walking through the demo build, end to end.",
    duration: "0:06",
    delivery: "Excited / Normal",
    src: "assets/voice-samples/custom-voice-aiden-excited.wav",
  },
  {
    id: "documentary",
    mode: "Voice Cloning",
    color: "var(--terracotta-300)",
    seed: 14,
    voice: "Cloned from internal-narration-v3.wav",
    quote: "Every measurement was logged, every observation written down. Only then could the model be trusted.",
    duration: "0:09",
    delivery: "Mirrors source clip",
    src: "assets/voice-samples/voice-cloning-mirrors-source.wav",
  },
];

export const DELIVERIES = [
  { label: "Neutral", color: "var(--emotion-neutral)" },
  { label: "Happy", color: "var(--emotion-happy)" },
  { label: "Sad", color: "var(--emotion-sad)" },
  { label: "Angry", color: "var(--emotion-angry)" },
  { label: "Fearful", color: "var(--emotion-fearful)" },
  { label: "Whisper", color: "var(--emotion-whisper)" },
  { label: "Dramatic", color: "var(--emotion-dramatic)" },
  { label: "Calm", color: "var(--emotion-calm)" },
  { label: "Excited", color: "var(--emotion-excited)" },
];

export const DELIVERY_COLORS = {
  Neutral: "#8C8F9B",
  Happy: "#F2C74D",
  Sad: "#8C9EC7",
  Angry: "#C75233",
  Fearful: "#9E80C7",
  Whisper: "#9E9EA8",
  Dramatic: "#C785A8",
  Calm: "#9EBC9E",
  Excited: "#EB9452",
};
