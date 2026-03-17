from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Optional
import json
import re


MEANINGFUL_NEUTRAL_LABEL = "normal tone"

INTENSITY_TO_STRENGTH = {
    "subtle": "light",
    "normal": "medium",
    "strong": "strong",
}

STRENGTH_FALLBACKS = {
    "light": ["light"],
    "medium": ["medium", "light"],
    "strong": ["strong", "medium", "light"],
}

SAMPLING_PROFILES = {
    "light": {"temperature": 0.72, "top_p": 0.84, "repetition_penalty": 1.06},
    "medium": {"temperature": 0.88, "top_p": 0.9, "repetition_penalty": 1.03},
    "strong": {"temperature": 1.02, "top_p": 0.95, "repetition_penalty": 1.0},
}

PRESET_PROSODY = {
    "happy": {
        "light": "Add a gentle smile to the delivery, slightly brighter pitch movement, quick but not rushed phrase endings, and lightly buoyant energy.",
        "medium": "Use a clearly cheerful delivery with brighter pitch lifts, lively energy, clean forward pacing, and lightly playful phrase endings.",
        "strong": "Use overt joy and enthusiasm with bright pitch arcs, energetic pacing, crisp attacks, tighter pauses, and celebratory emphasis.",
    },
    "sad": {
        "light": "Keep the voice subdued with softer energy, longer vowels, slightly falling pitch, and gentler phrase endings.",
        "medium": "Use a distinctly somber delivery with reduced energy, longer pauses, deeper falling pitch, and softened consonant attacks.",
        "strong": "Use a deeply sorrowful delivery with heavy pacing, lingering vowels, weighted pauses, lower pitch centers, and a fragile emotional tone.",
    },
    "angry": {
        "light": "Add restrained irritation with firmer consonants, tighter pacing, and sharper pitch drops at key words.",
        "medium": "Use clear frustration with stronger attack, tense pacing, narrower pauses, and forceful emphasis on stressed words.",
        "strong": "Use intense anger with high energy, forceful consonant attack, aggressive pitch drops, clipped pauses, and hard-edged emphasis.",
    },
    "fearful": {
        "light": "Add unease with slightly quicker breaths, cautious pauses, and light pitch instability.",
        "medium": "Use audible anxiety with tighter phrasing, smaller wavering pitch, faster phrase onsets, and fragile pauses.",
        "strong": "Use palpable panic with urgent pacing, tremble-like pitch movement, uneven breathy pauses, and strained emphasis.",
    },
    "whisper": {
        "light": "Keep the delivery soft and close with reduced projection, careful pacing, and short intimate pauses.",
        "medium": "Use a hushed whisper with intimate pacing, softened attacks, and delicate phrase endings.",
        "strong": "Use a very intimate whisper with barely projected onset, long close pauses, softened consonants, and a breathy confidential tone.",
    },
    "dramatic": {
        "light": "Add mild theatrical emphasis with slightly wider pitch movement and more sculpted pauses.",
        "medium": "Use expressive theatrical phrasing with deliberate pauses, larger pitch arcs, and bolder stress on key words.",
        "strong": "Use highly dramatic phrasing with sweeping pitch movement, pronounced pauses, bold attacks, and stage-like emphasis.",
    },
    "calm": {
        "light": "Keep the delivery relaxed with smooth phrase transitions, softer attack, and measured pacing.",
        "medium": "Use a soothing reassuring delivery with steady pacing, smooth onset, warm held vowels, and unhurried pauses.",
        "strong": "Use a deeply serene delivery with slow deliberate pacing, very smooth attacks, settled pitch, and spacious calming pauses.",
    },
    "excited": {
        "light": "Add a little extra energy with brighter pitch and faster phrase endings.",
        "medium": "Use an energetic enthusiastic delivery with lively pitch movement, quicker pacing, and eager emphasis.",
        "strong": "Use very high excitement with fast energetic pacing, bright pitch jumps, emphatic attack, and eager compressed pauses.",
    },
    "neutral": {
        "light": "Keep the delivery natural and clear.",
        "medium": "Keep the delivery natural and clear.",
        "strong": "Keep the delivery natural and clear.",
    },
}


@dataclass(frozen=True)
class CloneDeliveryProfile:
    preset_id: Optional[str]
    intensity: Optional[str]
    custom_text: Optional[str]
    final_instruction: str

    @property
    def trimmed_instruction(self) -> str:
        return (self.final_instruction or "").strip()

    @property
    def is_meaningful(self) -> bool:
        trimmed = self.trimmed_instruction
        return bool(trimmed) and trimmed.lower() != MEANINGFUL_NEUTRAL_LABEL

    @property
    def is_custom(self) -> bool:
        return bool((self.custom_text or "").strip()) or not (self.preset_id or "").strip()

    @property
    def canonical_intensity(self) -> Optional[str]:
        raw = (self.intensity or "").strip().lower()
        return raw if raw in INTENSITY_TO_STRENGTH else None

    @property
    def starting_strength(self) -> str:
        if self.is_custom:
            return "medium"
        return INTENSITY_TO_STRENGTH.get(self.canonical_intensity or "normal", "medium")

    @property
    def fallback_ladder(self) -> list[str]:
        return list(STRENGTH_FALLBACKS[self.starting_strength])


@dataclass(frozen=True)
class CloneDeliveryPlan:
    profile: CloneDeliveryProfile
    compiled_instruction: str
    styled_text: str
    strength_level: str
    sampling_profile: dict[str, float]
    fallback_ladder: list[str]
    styled_text_applied: bool


def parse_clone_delivery_profile(raw_profile: Any, fallback_instruction: Optional[str] = None) -> Optional[CloneDeliveryProfile]:
    if isinstance(raw_profile, CloneDeliveryProfile):
        return raw_profile

    profile = raw_profile if isinstance(raw_profile, dict) else {}
    preset_id = _clean(profile.get("preset_id"))
    intensity = _clean(profile.get("intensity"))
    custom_text = _clean(profile.get("custom_text"))
    final_instruction = _clean(profile.get("final_instruction")) or _clean(fallback_instruction)

    parsed = CloneDeliveryProfile(
        preset_id=preset_id,
        intensity=intensity,
        custom_text=custom_text,
        final_instruction=final_instruction or "Normal tone",
    )

    return parsed if parsed.is_meaningful else None


def delivery_profile_fingerprint(raw_profile: Any, fallback_instruction: Optional[str] = None) -> str:
    profile = parse_clone_delivery_profile(raw_profile, fallback_instruction=fallback_instruction)
    if profile is None:
        return ""

    payload = {
        "preset_id": profile.preset_id,
        "intensity": profile.canonical_intensity,
        "custom_text": _clean(profile.custom_text),
        "final_instruction": profile.trimmed_instruction,
    }
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def build_clone_delivery_plan(
    raw_profile: Any,
    text: str,
    has_reference_transcript: bool,
    strength_override: Optional[str] = None,
    fallback_instruction: Optional[str] = None,
) -> Optional[CloneDeliveryPlan]:
    profile = parse_clone_delivery_profile(raw_profile, fallback_instruction=fallback_instruction)
    if profile is None:
        return None

    strength = strength_override or profile.starting_strength
    if strength not in SAMPLING_PROFILES:
        strength = profile.starting_strength

    styled_text = _style_text(
        text=text,
        preset_id=profile.preset_id,
        strength=strength,
        is_custom=profile.is_custom,
    )
    compiled_instruction = _compile_instruction(
        profile=profile,
        strength=strength,
        has_reference_transcript=has_reference_transcript,
    )

    return CloneDeliveryPlan(
        profile=profile,
        compiled_instruction=compiled_instruction,
        styled_text=styled_text,
        strength_level=strength,
        sampling_profile=dict(SAMPLING_PROFILES[strength]),
        fallback_ladder=list(STRENGTH_FALLBACKS[strength]),
        styled_text_applied=styled_text != text,
    )


def _compile_instruction(
    profile: CloneDeliveryProfile,
    strength: str,
    has_reference_transcript: bool,
) -> str:
    transcript_clause = (
        "Use the transcript-aligned speaking rhythm from the reference as the identity anchor."
        if has_reference_transcript
        else "Lean on the reference timbre and speaker identity even without transcript alignment."
    )

    if profile.is_custom:
        custom_text = _clean(profile.custom_text) or profile.trimmed_instruction
        return (
            "Keep the cloned speaker identity anchored to the reference voice. "
            f"Deliver the new line with this requested style: {custom_text}. "
            "Translate that style into noticeable prosody: adjust energy, pacing, pitch movement, "
            "attack on stressed words, and pause shape without changing the spoken words. "
            f"{transcript_clause}"
        )

    preset_id = (profile.preset_id or "neutral").strip().lower()
    prosody = PRESET_PROSODY.get(preset_id, PRESET_PROSODY["neutral"])[strength]
    return (
        "Keep the cloned speaker identity anchored to the reference voice while changing only delivery. "
        f"{prosody} "
        "Do not drift into a different speaker identity. "
        f"{transcript_clause}"
    )


def _style_text(text: str, preset_id: Optional[str], strength: str, is_custom: bool) -> str:
    cleaned = _normalize_spacing(text)
    if not cleaned:
        return text

    if is_custom:
        return _ensure_terminal_punctuation(cleaned)

    preset = (preset_id or "neutral").strip().lower()
    if preset in {"neutral", ""}:
        return cleaned

    if preset in {"angry", "excited", "happy"}:
        return _energetic_text(cleaned, strength)
    if preset in {"sad", "fearful", "whisper"}:
        return _fragile_text(cleaned, strength)
    if preset == "dramatic":
        return _dramatic_text(cleaned, strength)
    if preset == "calm":
        return _calm_text(cleaned, strength)
    return _ensure_terminal_punctuation(cleaned)


def _clean(value: Any) -> Optional[str]:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _normalize_spacing(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def _ensure_terminal_punctuation(text: str, punctuation: str = ".") -> str:
    if re.search(r"[.!?…]+$", text):
        return text
    return f"{text}{punctuation}"


def _energetic_text(text: str, strength: str) -> str:
    if strength == "strong":
        styled = re.sub(r",\s*", "! ", text)
        return _ensure_terminal_punctuation(styled, "!")
    if strength == "medium":
        return _ensure_terminal_punctuation(text, "!")
    return _ensure_terminal_punctuation(text, ".")


def _fragile_text(text: str, strength: str) -> str:
    if strength == "strong":
        styled = re.sub(r",\s*", "... ", text)
        return styled if styled.endswith("...") else f"{styled}..."
    if strength == "medium":
        return text if text.endswith("...") else f"{text}..."
    return _ensure_terminal_punctuation(text, ".")


def _dramatic_text(text: str, strength: str) -> str:
    if strength == "strong":
        styled = re.sub(r",\s*", " -- ", text)
        return _ensure_terminal_punctuation(styled, "!")
    if strength == "medium":
        styled = re.sub(r",\s*", "... ", text)
        return _ensure_terminal_punctuation(styled, ".")
    return _ensure_terminal_punctuation(text, ".")


def _calm_text(text: str, strength: str) -> str:
    if strength == "strong":
        styled = re.sub(r"(?<![,.!?])\s+(and|but|so)\s+", r", \1 ", text, count=1, flags=re.IGNORECASE)
        return _ensure_terminal_punctuation(styled, ".")
    if strength == "medium":
        return _ensure_terminal_punctuation(text, ".")
    return text
