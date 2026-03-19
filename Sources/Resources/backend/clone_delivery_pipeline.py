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

CLONE_EMOTION_INSTRUCT = {
    "happy": "Speak with a happy, cheerful tone.",
    "sad": "Speak in a sad, melancholic tone.",
    "angry": "Speak with an angry, frustrated tone.",
    "fearful": "Speak in a fearful, anxious tone.",
    "whisper": "Speak in a soft whisper.",
    "dramatic": "Speak with dramatic, theatrical emphasis.",
    "calm": "Speak in a calm, soothing tone.",
    "excited": "Speak with excited, energetic enthusiasm.",
    "neutral": None,
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
    styled_text: str
    strength_level: str
    sampling_profile: dict[str, float]
    fallback_ladder: list[str]
    styled_text_applied: bool

    @property
    def clone_instruct(self) -> Optional[str]:
        if self.profile.is_custom:
            custom = (self.profile.custom_text or "").strip()
            return custom if custom else None
        preset = (self.profile.preset_id or "neutral").strip().lower()
        return CLONE_EMOTION_INSTRUCT.get(preset)


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

    return CloneDeliveryPlan(
        profile=profile,
        styled_text=styled_text,
        strength_level=strength,
        sampling_profile=dict(SAMPLING_PROFILES[strength]),
        fallback_ladder=list(STRENGTH_FALLBACKS[strength]),
        styled_text_applied=styled_text != text,
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
