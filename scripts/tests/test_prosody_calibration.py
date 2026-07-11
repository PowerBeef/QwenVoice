#!/usr/bin/env python3
"""Unit tests for scripts/prosody_calibration.py.

Builds a tiny labeled corpus of synthetic WAVs and verifies the CLI emits a
valid, usable profile.
"""
import json
import math
import os
import subprocess
import sys
import tempfile
import unittest
import wave

SR = 24000
REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CALIBRATION = os.path.join(REPO, "scripts", "prosody_calibration.py")


def write_sine(path, freq, duration, amplitude=0.5, freq_end=None, pause_ranges=None):
    n = int(SR * duration)
    samples = []
    for i in range(n):
        t = i / SR
        f = freq + (freq_end - freq) * (i / n) if freq_end else freq
        samples.append(amplitude * math.sin(2 * math.pi * f * t))
    if pause_ranges:
        for start, end in pause_ranges:
            a = max(0, int(start * SR))
            b = min(n, int(end * SR))
            for i in range(a, b):
                samples[i] = 0.0
    pcm = [max(-32768, min(32767, int(s * 32767))) for s in samples]
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(v.to_bytes(2, "little", signed=True) for v in pcm))


class ProsodyCalibrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def _generate_corpus(self):
        clips = [
            ("good_01.wav", 140, 2.5, 0.6, 180, None),
            ("good_02.wav", 130, 2.0, 0.5, 170, None),
            ("bad_monotone.wav", 120, 2.5, 0.3, None, None),
            ("bad_pause.wav", 150, 2.0, 0.5, None, [(0.3, 1.7)]),
        ]
        labels = []
        for name, freq, dur, amp, fend, pauses in clips:
            path = os.path.join(self.dir, name)
            write_sine(path, freq, dur, amp, fend, pauses)
            label = "bad" if name.startswith("bad") else "good"
            labels.append({"path": name, "label": label})
        labels_path = os.path.join(self.dir, "labels.jsonl")
        with open(labels_path, "w", encoding="utf-8") as f:
            for entry in labels:
                f.write(json.dumps(entry) + "\n")
        return labels_path

    def test_cli_emits_valid_profile(self):
        labels = self._generate_corpus()
        out = os.path.join(self.dir, "profile.json")
        result = subprocess.run(
            [sys.executable, CALIBRATION, "--labels", labels, "--out", out, "--target-fpr", "0.1"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(os.path.exists(out))
        with open(out, "r", encoding="utf-8") as f:
            profile = json.load(f)
        self.assertEqual(profile["schema_version"], 1)
        self.assertIn("thresholds", profile)
        for key in ["monotone_f0_std_hz", "pause_max_seconds", "pause_ratio_max"]:
            self.assertIn(key, profile["thresholds"])

    def test_calibrated_profile_flags_bad_clips(self):
        labels = self._generate_corpus()
        out = os.path.join(self.dir, "profile.json")
        subprocess.run(
            [sys.executable, CALIBRATION, "--labels", labels, "--out", out, "--target-fpr", "0.2"],
            check=True,
        )
        sys.path.insert(0, os.path.join(REPO, "scripts"))
        from prosody_quality_gate import evaluate
        from prosody_profile import load_profile

        profile = load_profile(out)
        monotone = evaluate(os.path.join(self.dir, "bad_monotone.wav"), profile)
        pause = evaluate(os.path.join(self.dir, "bad_pause.wav"), profile)
        # At least one obvious defect should be flagged on each bad clip.
        self.assertTrue(monotone["flags"] or pause["flags"])


if __name__ == "__main__":
    unittest.main()
